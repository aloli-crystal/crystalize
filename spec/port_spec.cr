# Composants testés : Crystalize::Source (dépôt local ou miroir d'une URL),
# Builder#build_env (build.pass_env), Crystalize::Port (Makefile, plist,
# script rc.d, message) et DistInfo.
# Dépendances : git, /bin/sh. L'archive source (bundle cache) n'est pas
# produite ici : voir l'essai sur une vraie application.
require "./spec_helper"

private def git(dir : String, *args : String) : String
  output = IO::Memory.new
  status = Process.run("git", ["-C", dir] + args.to_a, output: output, error: Process::Redirect::Close,
    env: {"GIT_AUTHOR_DATE" => "2025-10-28T22:00:00Z", "GIT_COMMITTER_DATE" => "2025-10-28T22:00:00Z"})
  raise "git #{args.join(' ')}" unless status.success?
  output.to_s.strip
end

private def repo(dir : String) : String
  path = File.join(dir, "repo")
  Dir.mkdir_p(path)
  git(path, "init", "-q", "-b", "production")
  git(path, "config", "user.email", "t@example.org")
  git(path, "config", "user.name", "T")
  File.write(File.join(path, "Gemfile"), "source \"https://rubygems.org\"\n")
  git(path, "add", ".")
  git(path, "commit", "-q", "-m", "init")
  path
end

private def config(yaml : String) : Crystalize::Config
  Crystalize::Config.from_yaml(yaml)
end

describe Crystalize::Source do
  it "distingue chemins locaux et URL" do
    %w[git@github.aloli:aloli/smsi.git github.aloli:aloli/smsi.git ssh://git@h/o/r.git
      https://h/o/r.git file:///srv/r.git].each { |url| Crystalize::Source.remote?(url).should be_true }
    %w[. ../smsi /home/p/smsi ./a:b].each { |path| Crystalize::Source.remote?(path).should be_false }
  end

  it "lit le commit d'un dépôt local" do
    with_tempdir do |dir|
      path = repo(dir)
      source = Crystalize::Source.new(config("app: {name: demo, repository: #{path}}").app, dir)
      commit, time = source.resolve("production")
      commit.should eq(git(path, "rev-parse", "HEAD"))
      time.should eq(1_761_688_800)
    end
  end

  it "tient un miroir d'un dépôt distant et le met à jour" do
    with_tempdir do |dir|
      path = repo(dir)
      ENV["CRYSTALIZE_CACHE"] = File.join(dir, "cache")
      begin
        app = config("app: {name: demo, repository: \"file://#{path}\"}").app
        first, _ = Crystalize::Source.new(app, dir).resolve("production")
        Dir.glob(File.join(dir, "cache", "repos", "demo-*.git")).size.should eq(1)
        File.write(File.join(path, "x"), "1")
        git(path, "add", "x")
        git(path, "commit", "-q", "-m", "x")
        second, _ = Crystalize::Source.new(app, dir).resolve("production")
        second.should_not eq(first)
        second.should eq(git(path, "rev-parse", "HEAD"))
        target = File.join(dir, "export")
        Dir.mkdir_p(target)
        Crystalize::Source.new(app, dir).export(second, target)
        File.read(File.join(target, "x")).should eq("1")
      ensure
        ENV.delete("CRYSTALIZE_CACHE")
      end
    end
  end

  it "utilise la clé SSH dédiée" do
    with_tempdir do |dir|
      key = File.join(dir, "deploy")
      File.write(key, "k")
      env = Crystalize::Source.new(config("app: {name: demo, repository: \"git@h:o/r.git\", ssh_key: deploy}").app, dir).env
      env["GIT_SSH_COMMAND"].should eq("ssh -i '#{key}' -o IdentitiesOnly=yes")
      expect_raises(Crystalize::Error, /ssh_key introuvable/) do
        Crystalize::Source.new(config("app: {name: demo, ssh_key: absente}").app, dir).env
      end
    end
  end
end

describe "Builder#build_env" do
  it "reprend les variables de build.pass_env, même BUNDLE_*" do
    ENV["BUNDLE_GITHUB__COM"] = "x-access-token:secret"
    begin
      cfg = config("app: {name: demo}\nbuild: {pass_env: [BUNDLE_GITHUB__COM, ABSENTE_XYZ]}")
      env = Crystalize::Builder.new(cfg, "/tmp").build_env("/ruby", 0_i64)
      env["BUNDLE_GITHUB__COM"].should eq("x-access-token:secret")
      env.has_key?("ABSENTE_XYZ").should be_false
    ensure
      ENV.delete("BUNDLE_GITHUB__COM")
    end
  end

  it "écarte les autres variables BUNDLE_*" do
    ENV["BUNDLE_GITHUB__COM"] = "secret"
    begin
      env = Crystalize::Builder.new(config("app: {name: demo}"), "/tmp").build_env("/ruby", 0_i64)
      env["BUNDLE_GITHUB__COM"].should be_nil
    ensure
      ENV.delete("BUNDLE_GITHUB__COM")
    end
  end
end

LOCK = <<-LOCK
  GEM
    remote: https://rubygems.org/
    specs:
      nokogiri (1.18.10)
        mini_portile2 (~> 2.8.2)
      nokogiri (1.18.10-arm64-darwin)
      pg (1.6.3)
      pg (1.6.3-x86_64-linux)
      rake (13.3.1)

  PLATFORMS
    arm64-darwin
    x86_64-freebsd-15

  DEPENDENCIES
    pg

  BUNDLED WITH
     2.6.9
  LOCK

private def port(dir : String, yaml : String) : Crystalize::Port
  path = repo(dir)
  yml = File.join(path, "crystalize.yml")
  File.write(yml, yaml)
  Crystalize::Port.new(Crystalize::Config.load(yml), yml)
end

describe Crystalize::Port do
  it "retient la variante source de chaque gem, triée" do
    Crystalize::Port.gem_files(LOCK).should eq(%w[nokogiri-1.18.10.gem pg-1.6.3.gem rake-13.3.1.gem])
  end

  it "refuse une gem sans variante source, et les sources git" do
    expect_raises(Crystalize::Error, /variantes précompilées/) do
      Crystalize::Port.gem_files(LOCK.sub("    rake (13.3.1)\n", "    rake (13.3.1-arm64-darwin)\n"))
    end
    expect_raises(Crystalize::Error, /section GIT/) do
      Crystalize::Port.gem_files("GIT\n  remote: https://g/x.git\n\n" + LOCK)
    end
  end

  it "signale un verrou sans plate-forme FreeBSD" do
    Crystalize::Port.platform_warning(LOCK).should be_nil
    Crystalize::Port.platform_warning(LOCK.sub("  x86_64-freebsd-15\n", "")).not_nil!.should contain("--add-platform")
  end

  it "lit les gems du vrai verrou de smsi" do
    lock = "/Users/philippe/prod-aloli/smsi-ror--ruby-34/Gemfile.lock"
    if File.exists?(lock)
      gems = Crystalize::Port.gem_files(File.read(lock))
      gems.size.should eq(170)
      gems.should contain("pg-1.6.3.gem")
      gems.none?(&.includes?("darwin")).should be_true
    end
  end

  it "exige une catégorie et une URL joignable depuis le builder" do
    with_tempdir do |dir|
      expect_raises(Crystalize::Error, /port.category requis/) { port(dir, "app: {name: smsi, repository: .}\n").category }
    end
    with_tempdir do |dir|
      expect_raises(Crystalize::Error, /port.source_url requis/) { port(dir, "app: {name: smsi, repository: .}\n").source_url }
    end
  end

  it "décrit un port sans secret, construit hors ligne" do
    with_tempdir do |dir|
      p = port(dir, <<-YAML)
        app: {name: smsi, repository: .}
        package: {maintainer: it@aloli.fr}
        port:
          category: security
          source_url: git@github.com:aloli/smsi.git
          lib_depends: ["libpq.so.5:databases/postgresql18-client"]
        YAML
      p.info.ruby_version = "3.4.10"
      p.info.ruby_tarball = "ruby-3.4.10.tar.gz"
      make = p.makefile
      make.should contain("PORTNAME=\tsmsi\nDISTVERSION=\t2025.10.28.220000\nCATEGORIES=\tsecurity\n")
      make.should contain("BUILD_DEPENDS=\tcrystalize:devel/crystalize")
      make.should contain("libpq.so.5:databases/postgresql18-client")
      make.should contain("CRYSTALIZE_COMMIT=\t#{p.info.commit}")
      make.should contain(%(${GREP} -aq "comment=${CRYSTALIZE_COMMIT}"))
      make.should contain("--from-dist ${WRKSRC}")
      make.should contain("${INSTALL_SCRIPT} ${WRKDIR}/smsi")
      make.should_not contain("INSTALL_PROGRAM}")
      make.should end_with(".include <bsd.port.mk>\n")
      p.descriptor.should eq("git@github.com:aloli/smsi.git #{p.info.commit} smsi-#{p.info.commit}.tar /usr/local/etc/poudriere.d/keys/smsi\n")
      p.makefile_gems.should contain("https://cache.ruby-lang.org/pub/ruby/3.4/:ruby")
      p.makefile_gems.should contain("DISTFILES+=\t${CRYSTALIZE_GEMS:S/$/:gems/}")
      p.rc_script.should contain("%%PREFIX%%/bin/smsi -c")
      Process.run("/bin/sh", ["-n", "-c", p.rc_script]).success?.should be_true
      p.plist.should contain("@dir(smsi,smsi,750) /var/db/smsi\n")
    end
  end

  it "relit la description d'un dossier de sources" do
    with_tempdir do |dir|
      info = Crystalize::DistInfo.new("smsi", "production", "c" * 40, 1_i64, "3.4.10", "ruby-3.4.10.tar.gz", "0.1.0")
      File.write(File.join(dir, Crystalize::DistInfo::PATH), info.to_yaml)
      Crystalize::DistInfo.load(dir).ruby_tarball.should eq("ruby-3.4.10.tar.gz")
      expect_raises(Crystalize::Error, /pas un dossier de sources/) { Crystalize::DistInfo.load(File.join(dir, "x")) }
    end
  end
end
