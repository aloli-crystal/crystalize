# Composant testé : Crystalize::Extractor#write (liens symboliques et noms
# d'entrées), via Extractor#ensure.
# Cas couverts : lien absolu, lien « ../ » sortant, lien relatif profond qui
# ressort, lien relatif profond qui reste dedans, écriture à travers un lien
# interne vers un dossier (fichier et sous-dossier), nom vide, nom « ./ »,
# lien interne valide vers un dossier.
# Dépendances : aucune (spec_helper uniquement).
require "./spec_helper"
require "compress/gzip"

private def manifest : Crystalize::Manifest
  Crystalize::Manifest.new("demo", "main", "a" * 40, 1_i64, "3.4.2", "x86_64-linux",
    "0.0.0", Crystalize::PLACEHOLDER, 1, %w[test], Crystalize::Config::Runtime.new)
end

private def build(dir : String, &) : Crystalize::Payload::Info
  archive = File.join(dir, "archive")
  File.open(archive, "w") do |file|
    Compress::Gzip::Writer.open(file) do |gzip|
      writer = Crystalize::Tar::Writer.new(gzip, 0_i64)
      writer.add_dir(".crystalize")
      source = File.join(dir, "src")
      File.write(source, "")
      writer.add_file(".crystalize/compiled.txt", source, false)
      writer.add_dir("app")
      yield writer, dir
      writer.finish
    end
  end
  File.write(File.join(dir, "launcher"), "L")
  output = File.join(dir, "exe")
  Crystalize::Payload.write(output, File.join(dir, "launcher"), archive)
  Crystalize::Payload.locate(output).not_nil!
end

private def add_file(writer : Crystalize::Tar::Writer, dir : String, name : String, content : String) : Nil
  source = File.join(dir, "src-#{Random::Secure.hex(4)}")
  File.write(source, content)
  writer.add_file(name, source, false)
  File.delete(source)
end

private def state_in(dir : String) : String
  path = File.join(dir, "state")
  Dir.mkdir_p(path)
  File.realpath(path)
end

private def extract(info : Crystalize::Payload::Info, dir : String) : String
  Crystalize::Extractor.new(info, manifest).ensure(state_in(dir))
end

describe "Extractor#write : liens et noms d'entrées" do
  it "refuse un lien symbolique absolu" do
    with_tempdir do |dir|
      info = build(dir) { |writer, _| writer.add_symlink("app/abs", "/etc/passwd") }
      expect_raises(Crystalize::Error, /lien refusé/) { extract(info, dir) }
      Dir.children(File.join(dir, "state", "releases")).should be_empty
    end
  end

  it "refuse un lien « ../ » qui sort de la racine d'extraction" do
    with_tempdir do |dir|
      info = build(dir) { |writer, _| writer.add_symlink("lnk", "../evil") }
      expect_raises(Crystalize::Error, /lien refusé/) { extract(info, dir) }
    end
  end

  it "refuse un lien « ../../x » depuis un sous-dossier" do
    with_tempdir do |dir|
      info = build(dir) { |writer, _| writer.add_symlink("app/lnk", "../../x") }
      expect_raises(Crystalize::Error, /lien refusé/) { extract(info, dir) }
    end
  end

  it "refuse un lien relatif profond qui ressort (a/b/../../../x)" do
    with_tempdir do |dir|
      info = build(dir) { |writer, _| writer.add_symlink("lnk", "a/b/../../../x") }
      expect_raises(Crystalize::Error, /lien refusé/) { extract(info, dir) }
    end
  end

  it "accepte un lien relatif profond qui reste dans la racine" do
    with_tempdir do |dir|
      info = build(dir) do |writer, d|
        add_file(writer, d, "app/cible", "ok")
        writer.add_symlink("app/lnk", "a/b/../../cible")
      end
      release = extract(info, dir)
      File.readlink(File.join(release, "app", "lnk")).should eq("a/b/../../cible")
    end
  end

  it "refuse d'écrire un fichier à travers un lien interne vers un dossier" do
    with_tempdir do |dir|
      info = build(dir) do |writer, d|
        writer.add_dir("app/reel")
        writer.add_symlink("app/alias", "reel")
        add_file(writer, d, "app/alias/fichier", "x")
      end
      expect_raises(Crystalize::Error, /traverse un lien/) { extract(info, dir) }
      Dir.children(File.join(dir, "state", "releases")).should be_empty
    end
  end

  it "refuse de créer un sous-dossier à travers un lien interne" do
    with_tempdir do |dir|
      info = build(dir) do |writer, _|
        writer.add_dir("app/reel")
        writer.add_symlink("app/alias", "reel")
        writer.add_dir("app/alias/sous")
      end
      expect_raises(Crystalize::Error, /traverse un lien/) { extract(info, dir) }
    end
  end

  it "accepte un lien interne vers un dossier (sans écriture à travers)" do
    with_tempdir do |dir|
      info = build(dir) do |writer, d|
        writer.add_dir("app/reel")
        add_file(writer, d, "app/reel/f", "contenu")
        writer.add_symlink("app/alias", "reel")
      end
      release = extract(info, dir)
      File.read(File.join(release, "app", "alias", "f")).should eq("contenu")
    end
  end

  it "refuse une entrée au nom vide" do
    with_tempdir do |dir|
      info = build(dir) { |writer, d| add_file(writer, d, "", "x") }
      expect_raises(Crystalize::Error, /refusé/) { extract(info, dir) }
      Dir.children(File.join(dir, "state", "releases")).should be_empty
    end
  end

  it "n'écrit rien d'inattendu pour un dossier nommé « ./ »" do
    with_tempdir do |dir|
      info = build(dir) { |writer, _| writer.add_dir("./") }
      release = extract(info, dir)
      Dir.children(release).sort.should eq([".crystalize", "app"])
    end
  end

  it "ne laisse pas un fichier nommé « ./ » écraser quoi que ce soit" do
    with_tempdir do |dir|
      info = build(dir) { |writer, d| add_file(writer, d, "./", "x") }
      begin
        extract(info, dir)
      rescue Crystalize::Error | File::Error
      end
      File.exists?(File.join(dir, "evil")).should be_false
      Dir.children(File.join(dir, "state", "releases")).reject(&.starts_with?(".tmp-")).each do |child|
        File.file?(File.join(dir, "state", "releases", child)).should be_false
      end
    end
  end
end

describe "Extractor : liens jugés après résolution des autres liens" do
  it "refuse un lien dont la cible remonte à travers un autre lien" do
    with_tempdir do |dir|
      info = build(dir) do |writer, _|
        writer.add_dir("app/a")
        writer.add_dir("app/b")
        writer.add_symlink("app/a/S", "../b")
        writer.add_symlink("app/a/T", "S/../../x")
      end
      expect_raises(Crystalize::Error, /lien refusé.*traverse le lien app\/a\/S/) { extract(info, dir) }
    end
  end

  it "le refuse aussi quand le lien traversé vient après dans l'archive" do
    with_tempdir do |dir|
      info = build(dir) do |writer, _|
        writer.add_dir("app/a")
        writer.add_symlink("app/a/T", "S/../../x")
        writer.add_symlink("app/a/S", "../b")
      end
      expect_raises(Crystalize::Error, /traverse le lien/) { extract(info, dir) }
    end
  end

  it "accepte une chaîne de liens qui ne traverse aucun lien comme dossier" do
    with_tempdir do |dir|
      info = build(dir) do |writer, d|
        add_file(writer, d, "app/cible.txt", "ok")
        writer.add_symlink("app/l1", "cible.txt")
        writer.add_symlink("app/l2", "l1")
      end
      File.read(File.join(extract(info, dir), "app", "l2")).should eq("ok")
    end
  end

  it "refuse un fichier puis un lien du même nom" do
    with_tempdir do |dir|
      info = build(dir) do |writer, d|
        add_file(writer, d, "app/x", "1")
        writer.add_symlink("app/x", "y")
      end
      expect_raises(Crystalize::Error, /traverse un lien/) { extract(info, dir) }
    end
  end

  it "refuse une entrée de compiled.txt qui est un lien" do
    with_tempdir do |dir|
      info = build(dir) do |writer, d|
        add_file(writer, d, ".crystalize/compiled.txt", "app/lnk\n")
        add_file(writer, d, "app/cible", "x")
        writer.add_symlink("app/lnk", "cible")
      end
      expect_raises(Crystalize::Error, /compiled\.txt \(traverse un lien\)/) { extract(info, dir) }
    end
  end

  it "refuse une entrée de compiled.txt avec « .. » ou absolue" do
    ["app/../../x", "/etc/passwd"].each do |rel|
      with_tempdir do |dir|
        info = build(dir) { |writer, d| add_file(writer, d, ".crystalize/compiled.txt", "#{rel}\n") }
        expect_raises(Crystalize::Error, /chemin refusé/) { extract(info, dir) }
      end
    end
  end
end

describe Crystalize::Tar do
  it "juge les liens comme à l'extraction" do
    links = Set{"a/S", "a/T"}
    Crystalize::Tar.link_error("a/T", "S/../../x", links).should match(/traverse le lien a\/S/)
    Crystalize::Tar.link_error("a/T", "/usr/lib", links).should eq("cible absolue")
    Crystalize::Tar.link_error("a/T", "../../x", links).should eq("sort de l'archive")
    Crystalize::Tar.link_error("a/T", "", links).should eq("cible vide")
    Crystalize::Tar.link_error("a/T", "S", links).should be_nil
    Crystalize::Tar.link_error("a/T", "../b/./c", links).should be_nil
  end

  it "fait échouer la construction sur un lien refusé" do
    writer = Crystalize::Tar::Writer.new(IO::Memory.new, 0_i64)
    writer.add_symlink("ruby/lib/x", "/usr/lib/x")
    expect_raises(Crystalize::Error, /lien refusé dans l'archive \(cible absolue\)/) { writer.check_links }
  end
end
