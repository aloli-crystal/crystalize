# Composant testé : Crystalize::Extractor (extraction d'une version du lanceur).
# Cas couverts : extraction et droits, remplacement du préfixe fictif, longueur
# du chemin de version, idempotence, liens vers le dossier d'état, empreinte
# fausse ou contenu altéré, refus des chemins « .. » et absolus, liens
# symboliques sortant de la racine, état trop long, conservation de deux versions.
# Dépendances : aucune (spec_helper uniquement).
require "./spec_helper"
require "compress/gzip"

private PH = Crystalize::PLACEHOLDER

private def manifest(placeholder : String = PH) : Crystalize::Manifest
  Crystalize::Manifest.new("demo", "main", "a" * 40, 1_i64, "3.4.2", "x86_64-linux",
    "0.0.0", placeholder, 1, %w[test], Crystalize::Config::Runtime.new)
end

# Construit un exécutable à charge utile ; le bloc ajoute les entrées.
private def build(dir : String, tag : String, &) : Crystalize::Payload::Info
  archive = File.join(dir, "archive-#{tag}")
  File.open(archive, "w") do |file|
    Compress::Gzip::Writer.open(file) do |gzip|
      writer = Crystalize::Tar::Writer.new(gzip, 0_i64)
      yield writer
      writer.finish
    end
  end
  File.write(File.join(dir, "launcher"), "L")
  output = File.join(dir, "exe-#{tag}")
  Crystalize::Payload.write(output, File.join(dir, "launcher"), archive)
  Crystalize::Payload.locate(output).not_nil!
end

private def put(dir : String, writer : Crystalize::Tar::Writer, name : String, content : String, executable = false) : Nil
  source = File.join(dir, "src-#{Random::Secure.hex(4)}")
  File.write(source, content)
  writer.add_file(name, source, executable)
  File.delete(source)
end

private def standard(dir : String, tag : String, placeholder : String = PH) : Crystalize::Payload::Info
  build(dir, tag) do |writer|
    writer.add_dir(".crystalize")
    put(dir, writer, ".crystalize/compiled.txt", "app/lib/x.yarb\n")
    writer.add_dir("app")
    writer.add_dir("app/lib")
    put(dir, writer, "app/lib/x.yarb", "AAA#{placeholder}ZZZ#{tag}")
    put(dir, writer, "app/Gemfile", "source 'x'")
  end
end

private def state_in(dir : String) : String
  path = File.join(dir, "state")
  Dir.mkdir_p(path)
  File.realpath(path)
end

describe Crystalize::Extractor do
  it "extrait, remplace le préfixe fictif et conserve la longueur du chemin" do
    with_tempdir do |dir|
      info = standard(dir, "a")
      state = state_in(dir)
      release = Crystalize::Extractor.new(info, manifest).ensure(state)

      release.bytesize.should eq(PH.bytesize)
      File.dirname(release).should eq(File.join(state, "releases"))
      File.basename(release).should start_with(info.id)
      File.basename(release).should match(/\A[0-9a-f]{16}_*\z/)
      File.exists?(File.join(release, ".crystalize", ".complete")).should be_true

      data = File.read(File.join(release, "app", "lib", "x.yarb"))
      data.should eq("AAA#{release}ZZZa")
      data.should_not contain("@crystalize-root@")
      File.read(File.join(release, "app", "Gemfile")).should eq("source 'x'")
    end
  end

  it "ne laisse aucun dossier temporaire après une extraction réussie" do
    with_tempdir do |dir|
      state = state_in(dir)
      Crystalize::Extractor.new(standard(dir, "a"), manifest).ensure(state)
      Dir.children(File.join(state, "releases")).none?(&.starts_with?(".tmp-")).should be_true
    end
  end

  it "conserve les droits d'exécution" do
    with_tempdir do |dir|
      info = build(dir, "x") do |writer|
        writer.add_dir(".crystalize")
        put(dir, writer, ".crystalize/compiled.txt", "")
        writer.add_dir("app")
        put(dir, writer, "run", "#!/bin/sh\n", true)
        put(dir, writer, "data", "d", false)
      end
      release = Crystalize::Extractor.new(info, manifest).ensure(state_in(dir))
      File.info(File.join(release, "run")).permissions.owner_execute?.should be_true
      File.info(File.join(release, "data")).permissions.owner_execute?.should be_false
    end
  end

  it "ne réextrait pas une version déjà complète" do
    with_tempdir do |dir|
      state = state_in(dir)
      extractor = Crystalize::Extractor.new(standard(dir, "a"), manifest)
      first = extractor.ensure(state)
      File.write(File.join(first, "sentinelle"), "ici")
      extractor.ensure(state).should eq(first)
      File.exists?(File.join(first, "sentinelle")).should be_true
    end
  end

  it "redirige les dossiers inscriptibles vers le dossier d'état" do
    with_tempdir do |dir|
      state = state_in(dir)
      release = Crystalize::Extractor.new(standard(dir, "a"), manifest).ensure(state)
      %w[log tmp storage].each do |name|
        link = File.join(release, "app", name)
        File.symlink?(link).should be_true
        File.readlink(link).should eq(File.join(state, name))
      end
    end
  end

  it "refuse un état dont le chemin est trop long pour le préfixe fictif" do
    with_tempdir do |dir|
      short = "/@p@".ljust(40, '@')
      info = standard(dir, "a", short)
      expect_raises(Crystalize::Error, /trop long/) do
        Crystalize::Extractor.new(info, manifest(short)).ensure(state_in(dir))
      end
    end
  end

  describe "intégrité" do
    it "refuse une empreinte de remorque fausse et ne laisse rien d'installé" do
      with_tempdir do |dir|
        info = standard(dir, "a")
        File.open(info.executable, "r+") do |file|
          file.seek(info.offset + info.size)
          file.write(Bytes.new(32, 0x42_u8))
        end
        bad = Crystalize::Payload.locate(info.executable).not_nil!
        state = state_in(dir)
        expect_raises(Crystalize::Error, /SHA-256/) { Crystalize::Extractor.new(bad, manifest).ensure(state) }
        releases = Dir.children(File.join(state, "releases"))
        releases.should be_empty
      end
    end

    it "refuse une charge utile dont un octet a été altéré" do
      with_tempdir do |dir|
        info = standard(dir, "a")
        bytes = File.read(info.executable).to_slice.dup
        middle = (info.offset + info.size // 2).to_i
        bytes[middle] = bytes[middle] ^ 0x01_u8
        File.write(info.executable, bytes)
        state = state_in(dir)
        expect_raises(Exception) do
          Crystalize::Extractor.new(Crystalize::Payload.locate(info.executable).not_nil!, manifest).ensure(state)
        end
        Dir.children(File.join(state, "releases")).should be_empty
      end
    end

    it "refuse une charge utile tronquée sans remorque (locate renvoie nil)" do
      with_tempdir do |dir|
        info = standard(dir, "a")
        bytes = File.read(info.executable).to_slice
        File.write(info.executable, bytes[0, bytes.size - 100])
        Crystalize::Payload.locate(info.executable).should be_nil
      end
    end
  end

  describe "chemins dangereux" do
    {"../evil", "/abs/evil", "app/../../evil", "a/b/../../../evil"}.each do |name|
      it "refuse le fichier #{name.inspect} et n'écrit rien hors de la racine" do
        with_tempdir do |dir|
          info = build(dir, "e") do |writer|
            writer.add_dir(".crystalize")
            put(dir, writer, ".crystalize/compiled.txt", "")
            put(dir, writer, name, "pwn")
          end
          state = state_in(dir)
          expect_raises(Crystalize::Error, /refusé/) { Crystalize::Extractor.new(info, manifest).ensure(state) }
          File.exists?(File.join(dir, "evil")).should be_false
          File.exists?(File.join(state, "evil")).should be_false
          File.exists?(File.join(state, "releases", "evil")).should be_false
          Dir.children(File.join(state, "releases")).should be_empty
        end
      end
    end

    it "refuse un dossier « ../x »" do
      with_tempdir do |dir|
        info = build(dir, "e") do |writer|
          writer.add_dir("../x")
        end
        expect_raises(Crystalize::Error, /refusé/) { Crystalize::Extractor.new(info, manifest).ensure(state_in(dir)) }
      end
    end

    it "ne permet pas d'écrire hors de la racine à travers un lien symbolique absolu" do
      with_tempdir do |dir|
        outside = File.join(dir, "outside")
        Dir.mkdir_p(outside)
        info = build(dir, "e") do |writer|
          writer.add_dir(".crystalize")
          put(dir, writer, ".crystalize/compiled.txt", "")
          writer.add_dir("app")
          writer.add_symlink("out", outside)
          put(dir, writer, "out/pwned", "pwn")
        end
        # Refusé dès l'écriture à travers le lien, avant même de juger sa cible.
        expect_raises(Crystalize::Error, /traverse un lien/) { Crystalize::Extractor.new(info, manifest).ensure(state_in(dir)) }
        File.exists?(File.join(outside, "pwned")).should be_false
      end
    end

    it "ne permet pas d'écrire hors de la racine à travers un lien symbolique relatif" do
      with_tempdir do |dir|
        outside = File.join(dir, "outside")
        Dir.mkdir_p(outside)
        info = build(dir, "e") do |writer|
          writer.add_dir(".crystalize")
          put(dir, writer, ".crystalize/compiled.txt", "")
          writer.add_dir("app")
          writer.add_symlink("out", "../../../../../../../../../../../..#{outside}")
          put(dir, writer, "out/pwned", "pwn")
        end
        # Refusé dès l'écriture à travers le lien, avant même de juger sa cible.
        expect_raises(Crystalize::Error, /traverse un lien/) { Crystalize::Extractor.new(info, manifest).ensure(state_in(dir)) }
        File.exists?(File.join(outside, "pwned")).should be_false
      end
    end
    it "refuse d'écrire à travers un lien interne à l'archive" do
      with_tempdir do |dir|
        info = build(dir, "e") do |writer|
          writer.add_dir(".crystalize")
          put(dir, writer, ".crystalize/compiled.txt", "")
          writer.add_dir("app")
          writer.add_dir("app/sub")
          writer.add_symlink("app/raccourci", "sub")
          put(dir, writer, "app/raccourci/fichier", "x")
        end
        expect_raises(Crystalize::Error, /traverse un lien/) { Crystalize::Extractor.new(info, manifest).ensure(state_in(dir)) }
      end
    end

    it "accepte un lien relatif qui reste dans l'archive" do
      with_tempdir do |dir|
        info = build(dir, "e") do |writer|
          writer.add_dir(".crystalize")
          put(dir, writer, ".crystalize/compiled.txt", "")
          writer.add_dir("app")
          put(dir, writer, "app/cible.txt", "ok")
          writer.add_symlink("app/lien.txt", "cible.txt")
        end
        release = Crystalize::Extractor.new(info, manifest).ensure(state_in(dir))
        File.read(File.join(release, "app", "lien.txt")).should eq("ok")
      end
    end
  end

  describe "conservation des versions" do
    it "ne garde que deux versions après quatre installations" do
      with_tempdir do |dir|
        state = state_in(dir)
        last = nil
        %w[a b c d].each_with_index do |tag, index|
          last = Crystalize::Extractor.new(standard(dir, tag), manifest).ensure(state)
          Dir.children(File.join(state, "releases")).each do |child|
            File.touch(File.join(state, "releases", child), Time.utc(2020, 1, 1 + index)) unless File.join(state, "releases", child) == last
          end
        end
        remaining = Dir.children(File.join(state, "releases")).reject(&.starts_with?(".tmp-"))
        remaining.size.should eq(2)
        remaining.should contain(File.basename(last.not_nil!))
      end
    end

    it "supprime la plus ancienne quand trois versions coexisteraient" do
      with_tempdir do |dir|
        state = state_in(dir)
        old = Crystalize::Extractor.new(standard(dir, "a"), manifest).ensure(state)
        File.touch(old, Time.utc(2019, 1, 1))
        mid = Crystalize::Extractor.new(standard(dir, "b"), manifest).ensure(state)
        File.touch(mid, Time.utc(2020, 1, 1))
        current = Crystalize::Extractor.new(standard(dir, "c"), manifest).ensure(state)
        Dir.exists?(old).should be_false
        Dir.exists?(mid).should be_true
        Dir.exists?(current).should be_true
      end
    end

    it "conserve deux versions quand il n'y en a que deux" do
      with_tempdir do |dir|
        state = state_in(dir)
        a = Crystalize::Extractor.new(standard(dir, "a"), manifest).ensure(state)
        b = Crystalize::Extractor.new(standard(dir, "b"), manifest).ensure(state)
        Dir.exists?(a).should be_true
        Dir.exists?(b).should be_true
      end
    end
  end
end
