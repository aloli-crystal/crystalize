require "./spec_helper"

describe Crystalize::RuntimeConfig do
  it "analyse le modèle généré" do
    config = Crystalize::RuntimeConfig.from_yaml(Crystalize::RuntimeConfig.sample("smsi"))
    config.state_dir.should eq("/var/db/smsi")
    config.storage.mode.should eq("encrypted")
    config.env_strings["PORT"].should eq("3000")
    config.secrets.not_nil!.file.should eq("/usr/local/etc/smsi/secrets.age")
  end

  it "résout les chemins relatifs au fichier" do
    with_tempdir do |dir|
      path = File.join(dir, "app.yml")
      File.write(path, "state_dir: state\n")
      Crystalize::RuntimeConfig.load(path).state_path("app").should eq(File.join(dir, "state"))
    end
  end
end

describe Crystalize::SecretsData do
  it "analyse le modèle généré" do
    secrets = Crystalize::SecretsData.from_yaml(Crystalize::SecretsData.sample)
    Base64.decode(secrets.storage_key.not_nil!).size.should eq(32)
    secrets.env_strings.has_key?("SECRET_KEY_BASE").should be_true
  end
end
