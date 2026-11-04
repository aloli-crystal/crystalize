require "./spec_helper"

private def entries(archive : Bytes) : Array(Tuple(String, Char, Int32, String, String))
  list = [] of Tuple(String, Char, Int32, String, String)
  Crystalize::Tar::Reader.new(IO::Memory.new(archive)).each do |entry|
    list << {entry.name, entry.type, entry.mode, entry.link, entry.io.gets_to_end}
  end
  list
end

describe Crystalize::Tar do
  it "relit fichiers, dossiers, liens et noms longs (PAX)" do
    with_tempdir do |dir|
      long = "a" * 60 + "/" + "b" * 70 + ".rb"
      Dir.mkdir_p(File.join(dir, "src", File.dirname(long)))
      File.write(File.join(dir, "src", long), "long")
      File.write(File.join(dir, "src", "run"), "#!/bin/sh\n")
      File.chmod(File.join(dir, "src", "run"), 0o755)
      File.symlink("run", File.join(dir, "src", "link"))

      io = IO::Memory.new
      writer = Crystalize::Tar::Writer.new(io, 1_700_000_000_i64)
      writer.add_tree(File.join(dir, "src"), "root") { false }
      writer.finish

      list = entries(io.to_slice)
      list.map(&.[0]).should eq(["root/#{"a" * 60}/", "root/#{long}", "root/link", "root/run"])
      list.find!(&.[0].==("root/#{long}"))[4].should eq("long")
      list.find!(&.[0].==("root/link")).should eq({"root/link", '2', 0o777, "run", ""})
      list.find!(&.[0].==("root/run"))[2].should eq(0o755)
    end
  end

  it "est déterministe" do
    with_tempdir do |dir|
      File.write(File.join(dir, "x"), "x")
      archives = 2.times.map do
        io = IO::Memory.new
        writer = Crystalize::Tar::Writer.new(io, 0_i64)
        writer.add_tree(dir, "p") { false }
        writer.finish
        io.to_slice
      end.to_a
      archives[0].should eq(archives[1])
    end
  end

  it "laisse de côté ce que le filtre refuse" do
    with_tempdir do |dir|
      Dir.mkdir_p(File.join(dir, "keep"))
      Dir.mkdir_p(File.join(dir, "drop", "deep"))
      File.write(File.join(dir, "drop", "deep", "f"), "")
      io = IO::Memory.new
      writer = Crystalize::Tar::Writer.new(io, 0_i64)
      writer.add_tree(dir, "") { |rel| rel == "drop" }
      writer.finish
      entries(io.to_slice).map(&.[0]).should eq(["keep/"])
    end
  end
end
