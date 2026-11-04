require "base64"

module Crystalize
  # Secrets d'exécution : YAML chiffré par age (ou en clair, droits 0600).
  #
  #   env:          variables d'environnement secrètes
  #   storage_key:  clé AES-256 (Base64) de la GED chiffrée
  class SecretsData
    include YAML::Serializable

    property env : Hash(String, YAML::Any) = {} of String => YAML::Any
    property storage_key : String? = nil

    def initialize
    end

    def self.load(ref : RuntimeConfig::SecretsRef, config : RuntimeConfig) : SecretsData
      path = config.resolve(ref.file)
      raise Error.new("fichier de secrets introuvable : #{path}") unless File.exists?(path)
      text =
        if path.ends_with?(".age")
          args = ["--decrypt"]
          if identity = ref.identity.try { |id| config.resolve(id) } || ENV["CRYSTALIZE_AGE_IDENTITY"]?
            args.push("--identity", identity)
          end
          Shell.capture("age", args + [path], env: {} of String => String?)
        else
          if File.info(path).permissions.value & 0o077 != 0
            Crystalize.warn "#{path} est lisible par d'autres utilisateurs (chmod 600)"
          end
          File.read(path)
        end
      from_yaml(text)
    rescue ex : YAML::ParseException
      raise Error.new("secrets illisibles (#{path}) : #{ex.message}")
    end

    def env_strings : Hash(String, String)
      env.transform_values { |value| value.raw.nil? ? "" : value.raw.to_s }
    end

    def self.sample : String
      <<-YAML
        # Secrets d'exécution. À chiffrer :
        #   age --encrypt --recipient age1… --output secrets.age secrets.yml && rm secrets.yml
        env:
          SECRET_KEY_BASE: "#{Random::Secure.hex(64)}"
          RAILS_MASTER_KEY: ""
          DATABASE_URL: "postgres://user:password@localhost/base"

        # Clé de la GED chiffrée (storage.mode: encrypted). Ne JAMAIS la perdre.
        storage_key: "#{Base64.strict_encode(Random::Secure.random_bytes(32))}"
        YAML
    end
  end
end
