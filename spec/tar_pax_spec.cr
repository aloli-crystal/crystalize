# Composant testé : Crystalize::Tar::Writer / Reader (noms longs PAX, déterminisme,
# alignement, en-têtes normalisés, archives tronquées).
# Cas couverts : noms de 100/101/300 octets, noms multi-octets, cibles de lien
# longues, ordre de création indifférent, dates des fichiers indifférentes,
# propriétaire/date/droits normalisés, taille multiple de 512, archive tronquée,
# en-tête GNU « L », préfixe ustar, chemins `..`/absolus transmis tels quels
# par le Reader (le refus est fait par l'Extractor, voir extractor_spec.cr).
# Dépendances : aucune (spec_helper uniquement).
require "./spec_helper"

private alias Row = NamedTuple(name: String, type: Char, mode: Int32, link: String, body: String)

private def rows(archive : Bytes) : Array(Row)
  list = [] of Row
  Crystalize::Tar::Reader.new(IO::Memory.new(archive)).each do |entry|
    list << {name: entry.name, type: entry.type, mode: entry.mode, link: entry.link, body: entry.io.gets_to_end}
  end
  list
end

private def pack(source : String, prefix : String = "", mtime : Int64 = 0_i64) : Bytes
  io = IO::Memory.new
  writer = Crystalize::Tar::Writer.new(io, mtime)
  writer.add_tree(source, prefix) { false }
  writer.finish
  io.to_slice
end

describe Crystalize::Tar::Writer do
  describe "noms longs (PAX)" do
    it "n'émet pas d'en-tête PAX pour un nom de 100 octets exactement" do
      with_tempdir do |dir|
        name = "n" * 100
        File.write(File.join(dir, name), "x")
        archive = pack(dir)
        archive.size.should eq(512 * 4)
        rows(archive).map(&.[:name]).should eq([name])
      end
    end

    it "relit des noms de 101 à 250 octets (frontières de la longueur PAX)" do
      with_tempdir do |dir|
        (101..250).step(7) do |length|
          sub = File.join(dir, length.to_s)
          Dir.mkdir_p(sub)
          name = "f" * length
          File.write(File.join(sub, name), "c#{length}")
          list = rows(pack(sub, "p"))
          list.map(&.[:name]).should eq(["p/#{name}"])
          list.first[:body].should eq("c#{length}")
        end
      end
    end

    it "relit un nom de moins de 100 caractères mais de plus de 100 octets" do
      with_tempdir do |dir|
        name = "é" * 60
        File.write(File.join(dir, name), "ok")
        rows(pack(dir)).map(&.[:name]).should eq([name])
      end
    end

    it "relit une cible de lien symbolique de plus de 100 octets" do
      with_tempdir do |dir|
        target = "t" * 150
        File.symlink(target, File.join(dir, "ln"))
        list = rows(pack(dir))
        list.size.should eq(1)
        list.first[:type].should eq('2')
        list.first[:link].should eq(target)
      end
    end

    it "relit un nom ET une cible longs sur la même entrée" do
      io = IO::Memory.new
      writer = Crystalize::Tar::Writer.new(io, 0_i64)
      writer.add_symlink("d" * 130, "e" * 130)
      writer.finish
      list = rows(io.to_slice)
      list.size.should eq(1)
      list.first[:name].should eq("d" * 130)
      list.first[:link].should eq("e" * 130)
    end

    it "n'applique pas un en-tête PAX à l'entrée suivante" do
      io = IO::Memory.new
      writer = Crystalize::Tar::Writer.new(io, 0_i64)
      writer.add_dir("l" * 150)
      writer.add_dir("court")
      writer.finish
      rows(io.to_slice).map(&.[:name]).should eq(["#{"l" * 150}/", "court/"])
    end
  end

  describe "déterminisme" do
    it "ne dépend ni de l'ordre de création ni des dates des fichiers" do
      with_tempdir do |dir|
        one = File.join(dir, "one")
        two = File.join(dir, "two")
        Dir.mkdir_p(one)
        Dir.mkdir_p(two)
        %w[c a b].each { |n| File.write(File.join(one, n), n) }
        %w[b c a].each { |n| File.write(File.join(two, n), n) }
        File.touch(File.join(one, "a"), Time.utc(2001, 1, 1))
        File.touch(File.join(two, "a"), Time.utc(2020, 6, 6))
        pack(one, "p").should eq(pack(two, "p"))
        rows(pack(one, "p")).map(&.[:name]).should eq(%w[p/a p/b p/c])
      end
    end

    it "change quand le contenu change" do
      with_tempdir do |dir|
        File.write(File.join(dir, "f"), "1")
        before = pack(dir)
        File.write(File.join(dir, "f"), "2")
        pack(dir).should_not eq(before)
      end
    end

    it "normalise propriétaire, groupe et date" do
      with_tempdir do |dir|
        File.write(File.join(dir, "f"), "x")
        header = pack(dir, "", 1_700_000_000_i64)[0, 512]
        String.new(header[265, 4]).should eq("root")
        String.new(header[297, 5]).should eq("wheel")
        String.new(header[108, 7]).should eq("0000000")
        String.new(header[136, 11]).to_i64(8).should eq(1_700_000_000_i64)
        String.new(header[257, 5]).should eq("ustar")
      end
    end

    it "calcule une somme de contrôle valide" do
      with_tempdir do |dir|
        File.write(File.join(dir, "f"), "x")
        header = pack(dir)[0, 512].dup
        declared = String.new(header[148, 6]).to_i(8)
        (148...156).each { |i| header[i] = ' '.ord.to_u8 }
        header.sum(0).should eq(declared)
      end
    end

    it "normalise les droits à 0644 / 0755 selon le bit d'exécution du propriétaire" do
      with_tempdir do |dir|
        File.write(File.join(dir, "plain"), "")
        File.write(File.join(dir, "exec"), "")
        File.chmod(File.join(dir, "plain"), 0o600)
        File.chmod(File.join(dir, "exec"), 0o700)
        list = rows(pack(dir))
        list.find!(&.[:name].==("plain"))[:mode].should eq(0o644)
        list.find!(&.[:name].==("exec"))[:mode].should eq(0o755)
      end
    end
  end

  describe "structure" do
    it "produit une taille multiple de 512 terminée par deux blocs nuls" do
      with_tempdir do |dir|
        File.write(File.join(dir, "f"), "x" * 513)
        archive = pack(dir)
        (archive.size % 512).should eq(0)
        archive[archive.size - 1024, 1024].all?(&.zero?).should be_true
      end
    end

    it "relit le contenu exact de fichiers de taille 0, 511, 512 et 513" do
      with_tempdir do |dir|
        [0, 511, 512, 513].each { |n| File.write(File.join(dir, "f#{n}"), "z" * n) }
        rows(pack(dir)).each do |row|
          row[:body].should eq("z" * row[:name][1..].to_i)
        end
      end
    end

    it "relit une archive vide" do
      io = IO::Memory.new
      Crystalize::Tar::Writer.new(io, 0_i64).finish
      rows(io.to_slice).should be_empty
    end

    it "ajoute le préfixe et un « / » final aux dossiers" do
      with_tempdir do |dir|
        Dir.mkdir_p(File.join(dir, "sub"))
        rows(pack(dir, "pre")).map(&.[:name]).should eq(["pre/sub/"])
      end
    end

    it "ne suit pas les liens symboliques vers des dossiers" do
      with_tempdir do |dir|
        Dir.mkdir_p(File.join(dir, "real"))
        File.write(File.join(dir, "real", "secret"), "s")
        File.symlink("real", File.join(dir, "ln"))
        rows(pack(dir)).map { |r| {r[:name], r[:type]} }.should eq([{"ln", '2'}, {"real/", '5'}, {"real/secret", '0'}])
      end
    end
  end
end

describe Crystalize::Tar::Reader do
  it "lève une erreur sur une archive tronquée au milieu des données" do
    with_tempdir do |dir|
      File.write(File.join(dir, "f"), "x" * 2000)
      cut = pack(dir)[0, 512 + 600]
      expect_raises(IO::EOFError) { rows(cut) }
    end
  end

  it "lève une erreur sur une archive tronquée au milieu d'un en-tête" do
    with_tempdir do |dir|
      File.write(File.join(dir, "f"), "x")
      expect_raises(IO::EOFError) { rows(pack(dir)[0, 200]) }
    end
  end

  it "transmet tels quels les noms avec « .. » ou absolus (le refus incombe à l'Extractor)" do
    io = IO::Memory.new
    writer = Crystalize::Tar::Writer.new(io, 0_i64)
    writer.add_dir("../evil")
    writer.add_dir("/abs")
    writer.finish
    rows(io.to_slice).map(&.[:name]).should eq(["../evil/", "/abs/"])
  end

  it "comprend le champ « prefix » ustar" do
    block = Bytes.new(512)
    "file.txt".to_slice.copy_to(block[0, 8])
    "0000644".to_slice.copy_to(block[100, 7])
    "00000000003".to_slice.copy_to(block[124, 11])
    block[156] = '0'.ord.to_u8
    "ustar".to_slice.copy_to(block[257, 5])
    "some/dir".to_slice.copy_to(block[345, 8])
    io = IO::Memory.new
    io.write(block)
    io.write("abc".to_slice)
    io.write(Bytes.new(509))
    io.write(Bytes.new(1024))
    list = rows(io.to_slice)
    list.map(&.[:name]).should eq(["some/dir/file.txt"])
    list.first[:body].should eq("abc")
  end

  it "comprend l'en-tête GNU « L » (nom long)" do
    long = "g" * 150
    name_data = long + "\0"
    ln = Bytes.new(512)
    "././@LongLink".to_slice.copy_to(ln[0, 13])
    name_data.size.to_s(8).rjust(11, '0').to_slice.copy_to(ln[124, 11])
    ln[156] = 'L'.ord.to_u8
    real = Bytes.new(512)
    "truncated".to_slice.copy_to(real[0, 9])
    real[156] = '0'.ord.to_u8
    io = IO::Memory.new
    io.write(ln)
    io.write(name_data.to_slice)
    io.write(Bytes.new(512 - name_data.bytesize))
    io.write(real)
    io.write(Bytes.new(1024))
    rows(io.to_slice).map(&.[:name]).should eq([long])
  end
end
