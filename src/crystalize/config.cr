module Crystalize
  # Configuration de construction (`crystalize.yml`), propre à chaque
  # application. Les chemins relatifs le sont au dossier du fichier.
  class Config
    include YAML::Serializable

    class App
      include YAML::Serializable

      property name : String
      # Dépôt git d'où la branche est extraite : chemin local, ou URL
      # (`git@hôte:org/app.git`, `https://…`) dont un miroir est tenu en
      # cache. L'authentification est celle de git (agent SSH, alias de
      # `~/.ssh/config`, gestionnaire d'identifiants).
      property repository : String = "."
      property branch : String = "production"
      # Clé SSH dédiée (clé de déploiement) pour un dépôt distant.
      property ssh_key : String? = nil
    end

    class Ruby
      include YAML::Serializable

      # À défaut : `.ruby-version` de la branche, puis `RUBY VERSION` du
      # `Gemfile.lock`.
      property version : String? = nil
      property sha256 : String? = nil
      property url : String? = nil
      property configure_opts : Array(String)? = nil

      def initialize
      end
    end

    class Bundle
      include YAML::Serializable

      property without : Array(String) = %w[development test]
      # Options de compilation des extensions natives (`bundle config build.<gem>`).
      property build_config : Hash(String, String) = {} of String => String
      property jobs : Int32 = 4
      # `strip -S` sur les extensions natives (reproductibilité, taille).
      property strip_native : Bool = true

      def initialize
      end
    end

    class Build
      include YAML::Serializable

      property env : Hash(String, String) = {} of String => String
      # Variables reprises de l'environnement de l'appelant, sans que leur
      # valeur soit écrite ici (identifiants de gems privées :
      # `BUNDLE_GITHUB__COM`, `BUNDLE_GEMS__EXAMPLE__COM`…).
      property pass_env : Array(String) = [] of String
      # Commandes shell lancées dans l'application après `bundle install`.
      property commands : Array(String) = [] of String

      def initialize
      end
    end

    class Compile
      include YAML::Serializable

      DEFAULT_PATTERNS = %w[
        app/**/*.rb lib/**/*.rb config/**/*.rb
        vendor/bundle/ruby/*/gems/**/*.rb
      ]
      # Fichiers DSL relus par `instance_eval(File.read(…))` : ils doivent
      # rester en source.
      DEFAULT_EXCLUDE = %w[
        config/puma.rb config/importmap.rb config/ci.rb
        **/templates/** **/test/** **/spec/**
      ]

      property enabled : Bool = true
      # Remplace chaque source compilée par un bouchon : seul le pseudo-code
      # est livré.
      property strip_sources : Bool = true
      @[YAML::Field(key: "include")]
      property patterns : Array(String) = DEFAULT_PATTERNS.dup
      property exclude : Array(String) = DEFAULT_EXCLUDE.dup

      def initialize
      end
    end

    # Ce que le lanceur sait faire une fois l'application extraite ; copié
    # tel quel dans le manifeste de la charge utile.
    class Runtime
      include YAML::Serializable

      property env : Hash(String, String) = {"RAILS_ENV" => "production"}
      # Commande nommée → arguments ; `${VAR}` et `${VAR:-défaut}` sont
      # remplacés depuis l'environnement final. Un premier argument relatif
      # contenant `/` (`bin/rails`) est un script lancé par le Ruby embarqué.
      property commands : Hash(String, Array(String)) = {
        "serve"   => ["bin/rails", "server", "-b", "${BIND:-127.0.0.1}", "-p", "${PORT:-3000}"],
        "console" => ["bin/rails", "console"],
        "migrate" => ["bin/rails", "db:prepare"],
        "rails"   => ["bin/rails"],
        "rake"    => ["bin/rails"],
      }
      property default_command : String = "serve"
      # Dossiers de l'application redirigés vers le dossier d'état.
      property writable : Array(String) = %w[log tmp storage]
      # Injecte l'initialiseur Active Storage (GED en clair ou chiffrée).
      property rails : Bool = true

      def initialize
      end
    end

    # Paquet FreeBSD (`crystalize package`) : binaire, script rc.d, modèle de
    # configuration, utilisateur et dossiers du service.
    class Package
      include YAML::Serializable

      # À défaut : `app.name`.
      property name : String? = nil
      # À défaut : date du commit (`AAAA.MM.JJ.HHMMSS`), croissante d'une
      # construction à l'autre.
      property version : String? = nil
      property comment : String? = nil
      property maintainer : String = "root@localhost"
      property www : String? = nil
      property origin : String? = nil
      property prefix : String = "/usr/local"
      # Utilisateur et groupe du service (à défaut : le nom du paquet).
      property user : String? = nil
      property group : String? = nil
      property uid : Int32? = nil
      property gid : Int32? = nil
      # À défaut : `/var/db/<nom>`.
      property state_dir : String? = nil
      # Paquets requis en plus de ceux détectés (bibliothèques partagées du
      # lanceur, de Ruby et des extensions natives).
      property depends : Array(String) = %w[age]
      property detect_depends : Bool = true
      # Services à démarrer avant (`# REQUIRE:` du script rc.d).
      property rc_require : Array(String) = %w[LOGIN]
      property rc_command : String? = nil

      def initialize
      end
    end

    # Port FreeBSD (`crystalize port`) construit par poudriere : gems et Ruby
    # sont des distfiles publics ; les sources de l'application (dépôt
    # privé) sont récupérées sur le builder, avant le bulk, avec une clé en
    # lecture seule qui ne figure pas dans le port.
    class Port
      include YAML::Serializable

      # Catégorie du port (`security`, `www`…) : propre à chaque application.
      property category : String? = nil
      # Dépôt de l'application tel que le builder le joint
      # (`git@github.com:aloli/smsi.git`) ; à défaut `app.repository`.
      property source_url : String? = nil
      # Clé de déploiement sur le builder (posée par beryl depuis le coffre) ;
      # à défaut `/usr/local/etc/poudriere.d/keys/<nom>`.
      property key : String? = nil
      # `bibliothèque:origine` en plus de celles de Ruby et du lanceur
      # (`libpq.so.5:databases/postgresql18-client`).
      property lib_depends : Array(String) = [] of String
      property build_depends : Array(String) = [] of String
      property run_depends : Array(String) = %w[age:security/age]
      property crystalize_origin : String = "devel/crystalize"

      def initialize
      end
    end

    property app : App
    property ruby : Ruby = Ruby.new
    property bundle : Bundle = Bundle.new
    property build : Build = Build.new
    property compile : Compile = Compile.new
    property runtime : Runtime = Runtime.new
    property package : Package = Package.new
    property port : Port = Port.new
    # Chemins (motifs, relatifs à l'application) retirés de la charge utile.
    property prune : Array(String) = [] of String
    property output : String? = nil

    DEFAULT_PRUNE = %w[
      .git .github .gitattributes .idea .vscode **/.DS_Store
      test spec node_modules config/master.key config/credentials/*.key
      vendor/cache vendor/bundle/ruby/*/cache
      vendor/bundle/ruby/*/gems/*/ext/**/*.o
      vendor/bundle/ruby/*/gems/*/ext/**/Makefile
      vendor/bundle/ruby/*/gems/*/ext/**/mkmf.log
      vendor/bundle/ruby/*/extensions/**/gem_make.out
      vendor/bundle/ruby/*/extensions/**/mkmf.log
      **/*.dSYM
    ]

    def self.load(path : String) : Config
      from_yaml(File.read(path))
    rescue ex : YAML::ParseException
      raise Error.new("#{path} : #{ex.message}")
    end
  end
end
