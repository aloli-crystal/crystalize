# Composant testé : Crystalize::Payload (remorque, Info#id, Info#manifest,
# charges utiles tronquées ou incohérentes).
# Cas couverts : fichier trop court, absence de remorque, remorque tronquée,
# taille déclarée trop grande, contenu vide, id, manifeste présent / absent,
# archive gzip altérée à la lecture du manifeste.
# Dépendances : aucune (spec_helper uniquement).
require "./spec_helper"
require "compress/gzip"

private def manifest_yaml : String
  Crystalize::Manifest.new("demo", "main", "a" * 40, 1_i64, "3.4.2", "x86_64-linux",
    "0.0.0", "/@p@", 0, %w[test], Crystalize::Config::Runtime.new).to_yaml
end

private def targz(path : String, entries : Hash(String, String)) : Nil
  File.open(path, "w") do |file|
    Compress::Gzip::Writer.open(file) do |gzip|
      writer = Crystalize::Tar::Writer.new(gzip, 0_i64)
      entries.each do |name, content|
        source = "#{path}.src"
        File.write(source, content)
        writer.add_file(name, source, false)
        File.delete(source)
      end
      writer.finish
    end
  end
end

private def assemble(dir : String, entries : Hash(String, String)) : String
  File.write(File.join(dir, "launcher"), "LAUNCHER")
  targz(File.join(dir, "archive"), entries)
  output = File.join(dir, "app")
  Crystalize::Payload.write(output, File.join(dir, "launcher"), File.join(dir, "archive"))
  output
end

describe Crystalize::Payload do
  describe ".locate" do
    it "renvoie nil pour un fichier plus court que la remorque" do
      with_tempdir do |dir|
        File.write(File.join(dir, "tiny"), "x" * 47)
        Crystalize::Payload.locate(File.join(dir, "tiny")).should be_nil
      end
    end

    it "renvoie nil pour un fichier vide" do
      with_tempdir do |dir|
        File.write(File.join(dir, "empty"), "")
        Crystalize::Payload.locate(File.join(dir, "empty")).should be_nil
      end
    end

    it "renvoie nil sans MAGIC, même avec 48 octets ou plus" do
      with_tempdir do |dir|
        File.write(File.join(dir, "plain"), "y" * 500)
        Crystalize::Payload.locate(File.join(dir, "plain")).should be_nil
      end
    end

    it "renvoie nil quand la remorque est amputée de quelques octets" do
      with_tempdir do |dir|
        output = assemble(dir, {"a" => "1"})
        data = File.read(output).to_slice
        File.write(output, data[0, data.size - 3])
        Crystalize::Payload.locate(output).should be_nil
      end
    end

    it "gère une charge utile d'archive vide" do
      with_tempdir do |dir|
        File.write(File.join(dir, "l"), "L")
        File.write(File.join(dir, "a"), "")
        Crystalize::Payload.write(File.join(dir, "o"), File.join(dir, "l"), File.join(dir, "a"))
        info = Crystalize::Payload.locate(File.join(dir, "o")).not_nil!
        info.size.should eq(0)
        info.offset.should eq(1)
        info.sha256.hexstring.should eq(Digest::SHA256.hexdigest(""))
      end
    end

    it "refuse une remorque dont la taille déclarée dépasse le fichier" do
      with_tempdir do |dir|
        output = assemble(dir, {"a" => "1"})
        size = File.size(output)
        File.open(output, "r+") do |file|
          file.seek(size - 16)
          file.write_bytes(1_000_000_i64, IO::ByteFormat::LittleEndian)
        end
        expect_raises(Crystalize::Error, /incohérente/) { Crystalize::Payload.locate(output) }
      end
    end
  end

  describe "Info" do
    it "expose un identifiant de 16 caractères hexadécimaux, préfixe de l'empreinte" do
      with_tempdir do |dir|
        info = Crystalize::Payload.locate(assemble(dir, {"a" => "1"})).not_nil!
        info.id.size.should eq(16)
        info.id.should match(/\A[0-9a-f]{16}\z/)
        info.sha256.hexstring.should start_with(info.id)
      end
    end

    it "calcule l'empreinte du contenu exact de l'archive" do
      with_tempdir do |dir|
        output = assemble(dir, {"a" => "1"})
        info = Crystalize::Payload.locate(output).not_nil!
        info.sha256.hexstring.should eq(Digest::SHA256.hexdigest(File.read(File.join(dir, "archive"))))
      end
    end

    it "lit le manifeste sans extraire" do
      with_tempdir do |dir|
        output = assemble(dir, {Crystalize::Manifest::PATH => manifest_yaml, "autre" => "x"})
        manifest = Crystalize::Payload.locate(output).not_nil!.manifest
        manifest.app.should eq("demo")
        manifest.ruby_version.should eq("3.4.2")
        manifest.runtime.default_command.should eq("serve")
      end
    end

    it "lève une erreur quand le manifeste est absent" do
      with_tempdir do |dir|
        output = assemble(dir, {"autre" => "x"})
        expect_raises(Crystalize::Error, /manifeste absent/) do
          Crystalize::Payload.locate(output).not_nil!.manifest
        end
      end
    end

    it "échoue à la lecture du manifeste quand l'archive gzip est altérée" do
      with_tempdir do |dir|
        output = assemble(dir, {Crystalize::Manifest::PATH => manifest_yaml})
        info = Crystalize::Payload.locate(output).not_nil!
        bytes = File.read(output).to_slice.dup
        bytes[info.offset + 2] = bytes[info.offset + 2] ^ 0xff_u8 # méthode de compression invalide
        File.write(output, bytes)
        expect_raises(Exception) { Crystalize::Payload.locate(output).not_nil!.manifest }
      end
    end
  end

  describe ".launcher_size" do
    it "vaut la taille du fichier sans charge utile, et l'offset avec" do
      with_tempdir do |dir|
        File.write(File.join(dir, "bare"), "12345")
        Crystalize::Payload.launcher_size(File.join(dir, "bare")).should eq(5)
        output = assemble(dir, {"a" => "1"})
        Crystalize::Payload.launcher_size(output).should eq(8)
      end
    end
  end
end
