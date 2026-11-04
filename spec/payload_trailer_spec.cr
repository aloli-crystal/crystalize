# Composant testé : Crystalize::Payload.locate (validation de la taille déclarée).
# Cas couverts : taille négative (bit de poids fort), taille exactement égale à
# total - 48 (acceptée, offset 0), total - 47 refusée, total - 49 acceptée.
# Dépendances : aucune (spec_helper uniquement).
require "./spec_helper"

# Fichier de `total` octets dont la remorque déclare `size`.
private def with_trailer(dir : String, total : Int32, size : Int64, & : String ->) : Nil
  bytes = Bytes.new(total, 0x41_u8)
  trailer = bytes[total - 48, 48]
  trailer[0, 32].fill(0x07_u8)
  IO::ByteFormat::LittleEndian.encode(size, trailer[32, 8])
  trailer[40, 8].copy_from("CRYSTLZ1".to_slice)
  path = File.join(dir, "exe")
  File.write(path, bytes)
  yield path
end

describe "Payload.locate : taille déclarée" do
  it "refuse une taille négative (bit de poids fort)" do
    with_tempdir do |dir|
      with_trailer(dir, 200, Int64::MIN) do |path|
        expect_raises(Crystalize::Error, /incohérente/) { Crystalize::Payload.locate(path) }
      end
    end
  end

  it "refuse -1" do
    with_tempdir do |dir|
      with_trailer(dir, 200, -1_i64) do |path|
        expect_raises(Crystalize::Error, /incohérente/) { Crystalize::Payload.locate(path) }
      end
    end
  end

  it "accepte une taille égale à total - 48 (offset 0)" do
    with_tempdir do |dir|
      with_trailer(dir, 200, 152_i64) do |path|
        info = Crystalize::Payload.locate(path).not_nil!
        info.offset.should eq(0)
        info.size.should eq(152)
        info.sha256.should eq(Bytes.new(32, 0x07_u8))
      end
    end
  end

  it "refuse une taille égale à total - 47" do
    with_tempdir do |dir|
      with_trailer(dir, 200, 153_i64) do |path|
        expect_raises(Crystalize::Error, /incohérente/) { Crystalize::Payload.locate(path) }
      end
    end
  end

  it "accepte total - 49 (offset 1)" do
    with_tempdir do |dir|
      with_trailer(dir, 200, 151_i64) do |path|
        Crystalize::Payload.locate(path).not_nil!.offset.should eq(1)
      end
    end
  end

  it "accepte un fichier de 48 octets exactement avec une taille nulle" do
    with_tempdir do |dir|
      with_trailer(dir, 48, 0_i64) do |path|
        info = Crystalize::Payload.locate(path).not_nil!
        info.offset.should eq(0)
        info.size.should eq(0)
      end
    end
  end
end
