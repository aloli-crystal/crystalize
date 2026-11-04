module Crystalize
  # Configuration d'exécution d'une application empaquetée (`<app>.yml`),
  # propre à chaque installation. Les chemins relatifs le sont au dossier
  # du fichier.
  class RuntimeConfig
    include YAML::Serializable

    class SecretsRef
      include YAML::Serializable

      # `.age` : déchiffré par `age` ; sinon YAML en clair (droits 0600).
      property file : String
      # Identité age ; à défaut `CRYSTALIZE_AGE_IDENTITY`, sinon age
      # demande la phrase de passe.
      property identity : String? = nil
    end

    class Storage
      include YAML::Serializable

      MODES = %w[none clear encrypted]

      # none : rien n'est imposé à Active Storage ; clear : dossier en clair ;
      # encrypted : fichiers chiffrés (clé `storage_key` des secrets).
      property mode : String = "none"
      property path : String? = nil

      def initialize
      end
    end

    property state_dir : String? = nil
    property env : Hash(String, YAML::Any) = {} of String => YAML::Any
    property secrets : SecretsRef? = nil
    property storage : Storage = Storage.new

    @[YAML::Field(ignore: true)]
    property base_dir : String = Dir.current

    @[YAML::Field(ignore: true)]
    property source : String? = nil

    def initialize
    end

    # Fichier explicite, sinon `<APP>_CONFIG`, `./<app>.yml`,
    # `/usr/local/etc/<app>.yml`, `/etc/<app>.yml` ; sinon valeurs par défaut.
    def self.locate(app : String, explicit : String?) : RuntimeConfig
      if explicit
        raise Error.new("configuration introuvable : #{explicit}") unless File.exists?(explicit)
        return load(explicit)
      end
      variable = "#{app.upcase.gsub(/[^A-Z0-9]/, '_')}_CONFIG"
      candidates = [ENV[variable]?, "#{app}.yml", "/usr/local/etc/#{app}.yml", "/etc/#{app}.yml"].compact
      if found = candidates.find { |path| File.exists?(path) }
        load(found)
      else
        new
      end
    end

    def self.load(path : String) : RuntimeConfig
      config = from_yaml(File.read(path))
      config.base_dir = File.dirname(File.expand_path(path))
      config.source = File.expand_path(path)
      config
    rescue ex : YAML::ParseException
      raise Error.new("#{path} : #{ex.message}")
    end

    def resolve(path : String) : String
      File.expand_path(path, base_dir, home: true)
    end

    def state_path(app : String) : String
      if dir = state_dir
        resolve(dir)
      else
        File.join(ENV["XDG_DATA_HOME"]? || File.join(Path.home.to_s, ".local", "share"), app)
      end
    end

    def env_strings : Hash(String, String)
      env.transform_values { |value| value.raw.nil? ? "" : value.raw.to_s }
    end

    def self.sample(app : String, state_dir : String = "/var/db/#{app}", etc_dir : String = "/usr/local/etc") : String
      <<-YAML
        # Configuration d'exécution de #{app} (aucun secret ici).
        # Recherchée dans : -c FICHIER, $#{app.upcase.gsub(/[^A-Z0-9]/, '_')}_CONFIG, ./#{app}.yml,
        # /usr/local/etc/#{app}.yml, /etc/#{app}.yml

        # Versions extraites, journaux, fichiers temporaires.
        state_dir: #{state_dir}

        # Variables d'environnement non secrètes.
        env:
          BIND: 127.0.0.1
          PORT: 3000
          RAILS_MAX_THREADS: 5

        secrets:
          file: #{etc_dir}/#{app}/secrets.age   # ou secrets.yml (clair, 0600)
          identity: #{etc_dir}/#{app}/age.key   # facultatif : sinon phrase de passe

        # GED (Active Storage) : none | clear | encrypted
        storage:
          mode: encrypted
          path: #{state_dir}/ged
        YAML
    end
  end
end
