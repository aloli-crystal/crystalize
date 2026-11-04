require "spec"
require "../src/crystalize"

def with_tempdir(&)
  dir = File.join(Dir.tempdir, "crystalize-spec-#{Random::Secure.hex(6)}")
  Dir.mkdir_p(dir)
  begin
    yield dir
  ensure
    FileUtils.rm_rf(dir)
  end
end
