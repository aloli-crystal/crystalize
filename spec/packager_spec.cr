# Composant testé : Crystalize::Packager (paquet FreeBSD).
# Cas couverts : valeurs par défaut, validation des noms et chemins, script
# rc.d et pre-install (syntaxe sh), liste pkg, manifeste JSON, analyse de
# ldd, arbre écrit quand pkg est absent.
# Dépendances : /bin/sh (sh -n). pkg create n'est pas lancé (FreeBSD seul).
require "./spec_helper"
require "compress/gzip"

private def manifest(platform = "freebsd-x86_64") : Crystalize::Manifest
  Crystalize::Manifest.new("smsi", "production", "0123456789abcdef" * 2 + "01234567", 1_761_688_800_i64,
    "3.4.10", platform, "0.1.0", Crystalize::PLACEHOLDER, 0, %w[test], Crystalize::Config::Runtime.new)
end

private def package(yaml = "{}") : Crystalize::Config::Package
  Crystalize::Config::Package.from_yaml(yaml)
end

private def binary(dir : String) : String
  archive = File.join(dir, "archive")
  File.open(archive, "w") do |file|
    Compress::Gzip::Writer.open(file) do |gzip|
      writer = Crystalize::Tar::Writer.new(gzip, 0_i64)
      source = File.join(dir, "src")
      File.write(source, manifest.to_yaml)
      writer.add_file(Crystalize::Manifest::PATH, source, false)
      writer.finish
    end
  end
  File.write(File.join(dir, "launcher"), "LAUNCHER")
  output = File.join(dir, "smsi")
  Crystalize::Payload.write(output, File.join(dir, "launcher"), archive)
  output
end

private def sh_ok?(script : String) : Bool
  Process.run("/bin/sh", ["-n", "-c", script]).success?
end

describe Crystalize::Packager do
  it "déduit nom, version, utilisateur et dossier d'état" do
    packager = Crystalize::Packager.new(package, "/x/smsi", manifest)
    packager.name.should eq("smsi")
    packager.version.should eq("2025.10.28.220000")
    packager.user.should eq("smsi")
    packager.group.should eq("smsi")
    packager.state_dir.should eq("/var/db/smsi")
    packager.prefix.should eq("/usr/local")
  end

  it "honore la configuration" do
    config = package(%({name: smsi-app, version: "1.2.3", user: www, group: www, state_dir: /srv/smsi, prefix: /opt/}))
    packager = Crystalize::Packager.new(config, "/x/smsi", manifest)
    {packager.name, packager.version, packager.user, packager.state_dir, packager.prefix}
      .should eq({"smsi-app", "1.2.3", "www", "/srv/smsi", "/opt"})
  end

  it "refuse noms, versions et chemins dangereux" do
    [%({user: "a b"}), %({name: "x;rm"}), %({version: "1-2"}), %({state_dir: relatif}),
     %({state_dir: "/a b"}), %({prefix: "/usr/$(id)"})].each do |yaml|
      expect_raises(Crystalize::Error, /invalide|absolu/) { Crystalize::Packager.new(package(yaml), "/x/smsi", manifest) }
    end
  end

  it "écrit un script rc.d valide, supervisé par daemon(8)" do
    config = package(%({rc_require: [LOGIN, postgresql], rc_command: serve}))
    script = Crystalize::Packager.new(config, "/x/smsi", manifest).rc_script
    sh_ok?(script).should be_true
    script.should start_with("#!/bin/sh\n")
    script.should contain("# PROVIDE: smsi\n# REQUIRE: LOGIN postgresql\n")
    script.should contain("rcvar=smsi_enable")
    script.should contain(%(: ${smsi_config:="/usr/local/etc/smsi.yml"}))
    script.should contain(%(procname="/usr/sbin/daemon"))
    script.should contain("-u ${smsi_user} /usr/local/bin/smsi -c ${smsi_config} ${smsi_command}")
    script.should contain(%(: ${smsi_env:="HOME=/var/db/smsi"}))
    script.should contain("extra_commands=\"migrate\"")
  end

  it "assainit le nom des variables rc.conf" do
    m = manifest
    m.app = "my-app"
    Crystalize::Packager.new(package, "/x/b", m).rc_script.should contain("rcvar=my_app_enable")
  end

  it "crée groupe et utilisateur une seule fois, avec uid/gid facultatifs" do
    script = Crystalize::Packager.new(package(%({uid: 900, gid: 901})), "/x/smsi", manifest).pre_install
    sh_ok?(script).should be_true
    script.should contain("pw groupadd smsi -g 901")
    script.should contain("pw useradd smsi -u 900 -g smsi -d /var/db/smsi -s /usr/sbin/nologin")
    script.should contain("if ! pw usershow smsi")
  end

  it "liste les fichiers avec des droits explicites" do
    Crystalize::Packager.new(package, "/x/smsi", manifest).plist.lines.should eq([
      "@(root,wheel,555) bin/smsi",
      "@(root,wheel,555) etc/rc.d/smsi",
      "@sample(root,smsi,640) etc/smsi.yml.sample",
      "@dir(root,smsi,750) etc/smsi",
      "@dir(smsi,smsi,750) /var/db/smsi",
    ])
  end

  it "produit un manifeste JSON avec dépendances, script et message" do
    packager = Crystalize::Packager.new(package(%({maintainer: it@aloli.fr})), "/x/smsi", manifest)
    deps = [Crystalize::Packager::Dependency.new("age", "security/age", "1.2.1")]
    json = JSON.parse(packager.manifest_json(deps))
    json["name"].should eq("smsi")
    json["origin"].should eq("local/smsi")
    json["prefix"].should eq("/usr/local")
    json["maintainer"].should eq("it@aloli.fr")
    json["deps"]["age"]["origin"].should eq("security/age")
    json["scripts"]["pre-install"].as_s.should contain("pw useradd")
    json["messages"][0]["message"].as_s.should contain("service smsi migrate")
  end

  it "fournit un modèle de configuration cohérent avec le paquet" do
    sample = Crystalize::Packager.new(package(%({state_dir: /srv/smsi})), "/x/smsi", manifest).sample_config
    config = Crystalize::RuntimeConfig.from_yaml(sample)
    config.state_dir.should eq("/srv/smsi")
    config.storage.path.should eq("/srv/smsi/ged")
    config.secrets.not_nil!.file.should eq("/usr/local/etc/smsi/secrets.age")
  end

  it "extrait les bibliothèques résolues d'une sortie de ldd" do
    output = <<-LDD
      /tmp/0.elf:
      \tlibyaml-0.so.2 => /usr/local/lib/libyaml-0.so.2 (0x8002a0000)
      \tlibc.so.7 => /lib/libc.so.7 (0x8003c0000)
      \tlibruby.so.34 => not found (0)
      /tmp/1.elf:
      \tlibyaml-0.so.2 => /usr/local/lib/libyaml-0.so.2 (0x8002a0000)
      LDD
    Crystalize::Packager.parse_ldd(output).should eq(["/usr/local/lib/libyaml-0.so.2", "/lib/libc.so.7"])
  end

  {% unless flag?(:freebsd) %}
    it "écrit l'arbre et le manifeste quand pkg est absent" do
      with_tempdir do |dir|
        exe = binary(dir)
        work = Crystalize::Packager.new(package(%({version: "1.0"})), exe, manifest).run(File.join(dir, "out"))
        work.should eq(File.join(dir, "out", "smsi-1.0"))
        root = File.join(work, "root")
        File.read(File.join(root, "usr/local/bin/smsi")).should eq(File.read(exe))
        File.info(File.join(root, "usr/local/etc/rc.d/smsi")).permissions.owner_execute?.should be_true
        File.exists?(File.join(root, "usr/local/etc/smsi.yml.sample")).should be_true
        Dir.exists?(File.join(root, "usr/local/etc/smsi")).should be_true
        Dir.exists?(File.join(root, "var/db/smsi")).should be_true
        JSON.parse(File.read(File.join(work, "+MANIFEST")))["version"].should eq("1.0")
        File.read(File.join(work, "pkg-plist")).should contain("bin/smsi")
      end
    end
  {% end %}
end
