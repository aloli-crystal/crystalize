require "./spec_helper"

describe Crystalize::Payload do
  it "ajoute une charge utile et la retrouve" do
    with_tempdir do |dir|
      launcher = File.join(dir, "launcher")
      archive = File.join(dir, "payload")
      output = File.join(dir, "app")
      File.write(launcher, "LAUNCHER")
      File.write(archive, "PAYLOAD-DATA")

      Crystalize::Payload.locate(launcher).should be_nil
      Crystalize::Payload.write(output, launcher, archive)

      info = Crystalize::Payload.locate(output).not_nil!
      info.offset.should eq(8)
      info.size.should eq(12)
      info.sha256.hexstring.should eq(Digest::SHA256.hexdigest("PAYLOAD-DATA"))
      info.open(&.gets_to_end).should eq("PAYLOAD-DATA")
      File.info(output).permissions.owner_execute?.should be_true
    end
  end

  it "ne réempile pas une charge utile existante" do
    with_tempdir do |dir|
      File.write(File.join(dir, "launcher"), "L")
      File.write(File.join(dir, "one"), "1")
      File.write(File.join(dir, "two"), "22")
      Crystalize::Payload.write(File.join(dir, "first"), File.join(dir, "launcher"), File.join(dir, "one"))
      Crystalize::Payload.write(File.join(dir, "second"), File.join(dir, "first"), File.join(dir, "two"))
      info = Crystalize::Payload.locate(File.join(dir, "second")).not_nil!
      info.offset.should eq(1)
      info.open(&.gets_to_end).should eq("22")
    end
  end
end
