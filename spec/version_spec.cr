require "./spec_helper"

describe Crystalize do
  it "lit sa version dans shard.yml" do
    version = File.read_lines(File.join(__DIR__, "..", "shard.yml")).find!(&.starts_with?("version:")).split(':', 2)[1].strip
    Crystalize::VERSION.should eq(version)
  end
end
