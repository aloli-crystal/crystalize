# Composant testé : Crystalize::SecretsData.load (fichier en clair, chemin « age »).
# Cas couverts : YAML en clair (valeurs, droits 0600 et 0644), fichier absent,
# YAML invalide, chemin relatif au fichier de configuration, env_strings,
# déchiffrement .age via un faux exécutable `age` placé dans PATH (arguments
# --decrypt / --identity), et vrai `age` si présent (sinon sauté).
# Dépendances : /bin/sh pour le faux `age`.
require "./spec_helper"

private def config_in(dir : String) : Crystalize::RuntimeConfig
  config = Crystalize::RuntimeConfig.new
  config.base_dir = dir
  config
end

private def ref(file : String, identity : String? = nil) : Crystalize::RuntimeConfig::SecretsRef
  yaml = "file: #{file}\n"
  yaml += "identity: #{identity}\n" if identity
  Crystalize::RuntimeConfig::SecretsRef.from_yaml(yaml)
end

private def with_path(prefix : String, &)
  saved = ENV["PATH"]?
  saved_identity = ENV["CRYSTALIZE_AGE_IDENTITY"]?
  ENV["PATH"] = "#{prefix}:#{saved}"
  ENV.delete("CRYSTALIZE_AGE_IDENTITY")
  begin
    yield
  ensure
    saved ? (ENV["PATH"] = saved) : ENV.delete("PATH")
    saved_identity ? (ENV["CRYSTALIZE_AGE_IDENTITY"] = saved_identity) : ENV.delete("CRYSTALIZE_AGE_IDENTITY")
  end
end

describe Crystalize::SecretsData do
  describe ".load (YAML en clair)" do
    it "lit env et storage_key" do
      with_tempdir do |dir|
        path = File.join(dir, "secrets.yml")
        File.write(path, "env:\n  TOKEN: abc\n  N: 42\nstorage_key: S0VZ\n")
        File.chmod(path, 0o600)
        secrets = Crystalize::SecretsData.load(ref("secrets.yml"), config_in(dir))
        secrets.env_strings.should eq({"TOKEN" => "abc", "N" => "42"})
        secrets.storage_key.should eq("S0VZ")
      end
    end

    it "lit aussi un fichier lisible par d'autres (avertissement seulement)" do
      with_tempdir do |dir|
        path = File.join(dir, "secrets.yml")
        File.write(path, "env:\n  A: b\n")
        File.chmod(path, 0o644)
        Crystalize::SecretsData.load(ref(path), config_in(dir)).env_strings["A"].should eq("b")
      end
    end

    it "utilise des valeurs par défaut pour un fichier ne contenant que storage_key" do
      with_tempdir do |dir|
        path = File.join(dir, "s.yml")
        File.write(path, "storage_key: K\n")
        File.chmod(path, 0o600)
        secrets = Crystalize::SecretsData.load(ref(path), config_in(dir))
        secrets.env.should be_empty
        secrets.storage_key.should eq("K")
      end
    end

    it "signale un fichier introuvable" do
      with_tempdir do |dir|
        expect_raises(Crystalize::Error, /introuvable/) do
          Crystalize::SecretsData.load(ref("absent.yml"), config_in(dir))
        end
      end
    end

    it "signale un YAML illisible avec le chemin" do
      with_tempdir do |dir|
        path = File.join(dir, "bad.yml")
        File.write(path, "env: [oops\n")
        File.chmod(path, 0o600)
        expect_raises(Crystalize::Error, /bad\.yml/) { Crystalize::SecretsData.load(ref(path), config_in(dir)) }
      end
    end

    it "convertit une valeur nulle en chaîne vide" do
      Crystalize::SecretsData.from_yaml("env:\n  A: ~\n").env_strings.should eq({"A" => ""})
    end
  end

  describe ".load (age)" do
    it "appelle `age --decrypt --identity <id> <fichier>` et lit sa sortie" do
      with_tempdir do |dir|
        bin = File.join(dir, "bin")
        Dir.mkdir_p(bin)
        fake = File.join(bin, "age")
        File.write(fake, "#!/bin/sh\necho \"$@\" > \"#{dir}/args\"\nfor last; do :; done\ncat \"$last\"\n")
        File.chmod(fake, 0o755)
        File.write(File.join(dir, "s.age"), "env:\n  FROM: age\n")
        File.write(File.join(dir, "id.key"), "AGE-SECRET-KEY-FAKE")
        with_path(bin) do
          secrets = Crystalize::SecretsData.load(ref("s.age", "id.key"), config_in(dir))
          secrets.env_strings.should eq({"FROM" => "age"})
        end
        File.read(File.join(dir, "args")).strip.should eq("--decrypt --identity #{File.join(dir, "id.key")} #{File.join(dir, "s.age")}")
      end
    end

    it "n'ajoute pas --identity sans identité configurée ni CRYSTALIZE_AGE_IDENTITY" do
      with_tempdir do |dir|
        bin = File.join(dir, "bin")
        Dir.mkdir_p(bin)
        fake = File.join(bin, "age")
        File.write(fake, "#!/bin/sh\necho \"$@\" > \"#{dir}/args\"\nfor last; do :; done\ncat \"$last\"\n")
        File.chmod(fake, 0o755)
        File.write(File.join(dir, "s.age"), "storage_key: K\n")
        with_path(bin) { Crystalize::SecretsData.load(ref("s.age"), config_in(dir)) }
        File.read(File.join(dir, "args")).strip.should eq("--decrypt #{File.join(dir, "s.age")}")
      end
    end

    it "signale un échec d'age" do
      with_tempdir do |dir|
        bin = File.join(dir, "bin")
        Dir.mkdir_p(bin)
        File.write(File.join(bin, "age"), "#!/bin/sh\nexit 3\n")
        File.chmod(File.join(bin, "age"), 0o755)
        File.write(File.join(dir, "s.age"), "x")
        with_path(bin) do
          expect_raises(Crystalize::Error, /échec \(code 3\)/) do
            Crystalize::SecretsData.load(ref("s.age"), config_in(dir))
          end
        end
      end
    end

    it "déchiffre avec le vrai `age` (sauté si absent)" do
      age = Process.find_executable("age")
      keygen = Process.find_executable("age-keygen")
      if age.nil? || keygen.nil?
        pending!("age / age-keygen absents du PATH")
      end
      with_tempdir do |dir|
        key = File.join(dir, "id.key")
        output = IO::Memory.new
        Process.run(keygen.not_nil!, ["-o", key], output: output, error: output)
        recipient = File.read(key).lines.find!(&.starts_with?("# public key:")).split(": ").last
        File.write(File.join(dir, "s.yml"), "env:\n  REAL: age\n")
        Process.run(age.not_nil!, ["--encrypt", "--recipient", recipient, "--output", File.join(dir, "s.age"), File.join(dir, "s.yml")])
        secrets = Crystalize::SecretsData.load(ref("s.age", "id.key"), config_in(dir))
        secrets.env_strings.should eq({"REAL" => "age"})
      end
    end
  end
end
