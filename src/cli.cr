require "option_parser"
require "./crystalize"

# Un seul exécutable : sans charge utile, c'est l'outil de construction ;
# avec, c'est le lanceur de l'application qu'il contient.
module Crystalize
  module CLI
    SUBCOMMANDS = %w[build package port ruby inspect init version help]

    def self.run(argv : Array(String)) : Nil
      if (path = Process.executable_path) && (payload = Payload.locate(path))
        Runtime.new(payload).run(argv)
      else
        builder(argv)
      end
    rescue ex : Error
      STDERR.puts "erreur : #{ex.message}"
      exit 1
    end

    def self.builder(argv : Array(String)) : Nil
      config_path = "crystalize.yml"
      branch = nil
      output = nil
      name = nil
      dist = nil
      positional = [] of String
      parser = OptionParser.new do |op|
        op.banner = <<-BANNER
          Usage : crystalize SOUS-COMMANDE [options]

          Sous-commandes :
            build              construit l'exécutable de l'application
            package [BINAIRE]  construit le paquet FreeBSD (pkg) de l'exécutable
            port               écrit le port FreeBSD (poudriere) dans l'arbre -o DOSSIER
            ruby               construit (en cache) le Ruby relocatable et affiche son chemin
            inspect BINAIRE    affiche le manifeste d'un exécutable produit
            init               écrit un crystalize.yml d'exemple
            version            affiche la version
            help [SOUS-CMD]    affiche cette aide

          Options :
          BANNER
        op.on("-c FICHIER", "--config FICHIER", "Configuration (défaut : crystalize.yml)") { |value| config_path = value }
        op.on("-b BRANCHE", "--branch BRANCHE", "Branche git (remplace app.branch)") { |value| branch = value }
        op.on("-o SORTIE", "--output SORTIE", "Exécutable (build), dossier du paquet (package), arbre des ports (port)") { |value| output = value }
        op.on("-n NOM", "--name NOM", "Nom de l'application (init)") { |value| name = value }
        op.on("--from-dist DOSSIER", "Construit depuis un dossier de sources réunies (build, hors ligne)") { |value| dist = value }
        op.on("-v", "--version", "Affiche la version") do
          puts "crystalize #{VERSION}"
          exit 0
        end
        op.on("-h", "--help", "Affiche cette aide") do
          puts op
          exit 0
        end
        op.invalid_option { |flag| raise Error.new("option inconnue : #{flag}") }
        op.unknown_args { |args| positional = args }
      end
      parser.parse(argv.dup)

      case subcommand = positional.first? || "help"
      when "build"
        config = Config.load(config_path)
        Builder.new(config, File.dirname(File.expand_path(config_path)), branch, output, dist.try(&.itself)).run
      when "package"
        config = Config.load(config_path)
        base_dir = File.dirname(File.expand_path(config_path))
        binary = positional[1]? || File.expand_path(config.output || File.join("build", config.app.name), base_dir)
        payload = Payload.locate(binary) || raise Error.new("#{binary} ne contient pas de charge utile crystalize (lancez d'abord « crystalize build »)")
        Packager.new(config.package, binary, payload.manifest).run(output.try(&.itself) || File.dirname(binary))
      when "port"
        config = Config.load(config_path)
        base_dir = File.dirname(File.expand_path(config_path))
        port = Port.new(config, config_path, branch.try(&.itself))
        port.run(File.expand_path(output.try(&.itself) || File.join(base_dir, "build", "ports")))
      when "ruby"
        config = Config.load(config_path)
        version = config.ruby.version || raise Error.new("ruby.version requis pour « crystalize ruby »")
        puts RubyBuilder.new(version, config.ruby).ensure!
      when "inspect"
        target = positional[1]? || raise Error.new("inspect attend le chemin d'un exécutable")
        payload = Payload.locate(target) || raise Error.new("#{target} ne contient pas de charge utile crystalize")
        puts payload.manifest.to_yaml
        puts "payload: #{payload.id} (#{payload.size} octets)"
      when "init"
        raise Error.new("#{config_path} existe déjà") if File.exists?(config_path)
        File.write(config_path, sample(name.try(&.itself) || File.basename(Dir.current)))
        puts "#{config_path} écrit"
      when "version"
        puts "crystalize #{VERSION}"
      when "help"
        if (sub = positional[1]?) && !SUBCOMMANDS.includes?(sub)
          raise Error.new("sous-commande inconnue : #{sub} (#{SUBCOMMANDS.join(", ")})")
        end
        puts parser
      else
        raise Error.new("sous-commande inconnue : #{subcommand} (#{SUBCOMMANDS.join(", ")})")
      end
    end

    def self.sample(name : String) : String
      <<-YAML
        # crystalize : empaquetage de #{name} en un exécutable unique.
        app:
          name: #{name}
          repository: .                # ou git@hôte:org/#{name}.git (dépôt privé)
          branch: production
          # ssh_key: ~/.ssh/deploy_#{name}   # clé de déploiement, sinon agent SSH

        ruby:
          version: 3.4.10
          # sha256: …   # recommandé : vérifie l'archive des sources

        bundle:
          without: [development, test]
          # build_config:
          #   pg: --with-pg-config=/usr/local/bin/pg_config

        build:
          env:
            RAILS_ENV: production
            SECRET_KEY_BASE_DUMMY: "1"
          # pass_env: [BUNDLE_GITHUB__COM]   # identifiants de gems privées (valeurs hors fichier)
          commands:
            - bin/rails assets:precompile

        runtime:
          env:
            RAILS_ENV: production
          default_command: serve
          commands:
            serve: [bin/rails, server, -b, "${BIND:-127.0.0.1}", -p, "${PORT:-3000}"]
            console: [bin/rails, console]
            migrate: [bin/rails, "db:prepare"]
            rails: [bin/rails]

        # Paquet FreeBSD (crystalize package) : toutes les clés sont facultatives.
        # package:
        #   maintainer: admin@example.org
        #   user: #{name}                # créé à l'installation (uid/gid : facultatifs)
        #   state_dir: /var/db/#{name}
        #   depends: [age]               # en plus des bibliothèques détectées
        #   rc_require: [LOGIN, postgresql]

        # Port FreeBSD pour poudriere (crystalize port -o ~/prod-aloli/aloli-freebsd-ports).
        # port:
        #   category: www
        #   source_url: git@github.com:org/#{name}.git    # dépôt vu du builder
        #   lib_depends: ["libpq.so.5:databases/postgresql18-client"]

        # Chemins retirés de la charge utile (en plus des valeurs par défaut).
        prune: []

        output: build/#{name}
        YAML
    end
  end
end

Crystalize::CLI.run(ARGV)
