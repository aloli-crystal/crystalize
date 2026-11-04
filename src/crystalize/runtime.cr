require "digest/io_digest"

module Crystalize
  # Mode « lanceur » : l'exécutable porte une charge utile. Il l'extrait (une
  # fois par version) dans le dossier d'état, prépare l'environnement puis se
  # remplace par le Ruby embarqué.
  class Runtime
    getter payload : Payload::Info

    def initialize(@payload : Payload::Info)
    end

    def run(argv : Array(String)) : Nil
      args = argv.dup
      config_path = nil
      while (first = args.first?) && first.starts_with?('-')
        args.shift
        case first
        when "-c", "--config"  then config_path = args.shift? || raise Error.new("#{first} attend un fichier")
        when "-h", "--help"    then args.unshift("help")
        when "-v", "--version" then args.unshift("version")
        when "--"              then break
        else                        raise Error.new("option inconnue : #{first}")
        end
        break if {"help", "version"}.includes?(args.first?)
      end

      manifest = payload.manifest
      command = args.shift? || manifest.runtime.default_command
      case command
      when "help"             then puts usage(manifest)
      when "version"          then puts version(manifest)
      when "config"           then puts RuntimeConfig.sample(manifest.app)
      when "secrets-template" then puts SecretsData.sample
      when "storage-key"      then puts Base64.strict_encode(Random::Secure.random_bytes(32))
      when "extract"          then puts prepare(manifest, config_path)[:release]
      when "exec"
        raise Error.new("exec attend une commande") if args.empty?
        launch(manifest, config_path, [] of String, args)
      else
        definition = manifest.runtime.commands[command]? ||
                     raise Error.new("commande inconnue : #{command} (voir « #{manifest.app} help »)")
        launch(manifest, config_path, definition, args)
      end
    end

    # Seule la définition du manifeste est étendue (`${VAR}`) : les arguments
    # saisis passent tels quels.
    private def launch(manifest : Manifest, config_path : String?, definition : Array(String), args : Array(String)) : NoReturn
      context = prepare(manifest, config_path)
      env = context[:env]
      expanded = definition.map { |arg| expand(arg, env) } + args
      ruby_bin = File.join(context[:release], "ruby", "bin")
      first = expanded.first?
      raise Error.new("commande vide") if first.nil? || first.empty?
      command, rest =
        if first.includes?('/') && !first.starts_with?('/')
          {File.join(ruby_bin, "ruby"), [File.join(context[:app], first)] + expanded[1..]}
        elsif !first.includes?('/') && File.exists?(File.join(ruby_bin, first))
          {File.join(ruby_bin, first), expanded[1..]}
        else
          {first, expanded[1..]}
        end
      Process.exec(command, rest, env: env, chdir: context[:app])
    end

    # Extrait la version au besoin et construit l'environnement d'exécution.
    private def prepare(manifest : Manifest, config_path : String?)
      config = RuntimeConfig.locate(manifest.app, config_path)
      state = check_state_dir(config.state_path(manifest.app))
      Dir.mkdir_p(state)
      # Contrôlé avant création, puis une fois les liens résolus.
      state = check_state_dir(File.realpath(state))
      release = Extractor.new(payload, manifest).ensure(state)
      app_dir = File.join(release, "app")
      manifest.runtime.writable.each { |dir| Dir.mkdir_p(File.join(state, dir)) }

      secrets = config.secrets.try { |ref| SecretsData.load(ref, config) } || SecretsData.new
      env = Shell.clean_env(manifest.runtime.env)
      config.env_strings.each { |key, value| env[key] = value }
      secrets.env_strings.each { |key, value| env[key] = value }
      env.merge!({
        "CRYSTALIZE_ROOT"   => release,
        "CRYSTALIZE_STATE"  => state,
        "PATH"              => [File.join(release, "ruby", "bin"), ENV["PATH"]?].compact.join(':'),
        "RUBYLIB"           => File.join(release, ".crystalize", "lib"),
        "RUBYOPT"           => "-rcrystalize/boot",
        "DISABLE_BOOTSNAP"  => "1",
        "BUNDLE_GEMFILE"    => File.join(app_dir, "Gemfile"),
        "BUNDLE_APP_CONFIG" => File.join(app_dir, ".bundle"),
        "BUNDLE_PATH"       => File.join(app_dir, "vendor", "bundle"),
        "BUNDLE_DEPLOYMENT" => "1",
        "BUNDLE_FROZEN"     => "1",
        "BUNDLE_WITHOUT"    => manifest.bundle_without.join(':'),
      })
      storage_env(config, secrets, state).each { |key, value| env[key] = value }
      {release: release, app: app_dir, env: env}
    end

    # RUBYLIB et PATH sont découpés sur « : », RUBYOPT sur les blancs (où
    # Bundler inscrit lui-même le chemin absolu de bundler/setup).
    private def check_state_dir(state : String) : String
      if state.matches?(/[:\s]/)
        raise Error.new("state_dir ne doit contenir ni « : » ni blanc : #{state}")
      end
      state
    end

    private def storage_env(config : RuntimeConfig, secrets : SecretsData, state : String) : Hash(String, String)
      storage = config.storage
      unless RuntimeConfig::Storage::MODES.includes?(storage.mode)
        raise Error.new("storage.mode inconnu : #{storage.mode} (#{RuntimeConfig::Storage::MODES.join(", ")})")
      end
      env = {"CRYSTALIZE_STORAGE_MODE" => storage.mode}
      return env if storage.mode == "none"

      path = storage.path.try { |dir| config.resolve(dir) } || File.join(state, "ged")
      Dir.mkdir_p(path)
      env["CRYSTALIZE_STORAGE_PATH"] = path
      if storage.mode == "encrypted"
        key = secrets.storage_key || raise Error.new("storage.mode encrypted : storage_key absent des secrets")
        raise Error.new("storage_key doit faire 32 octets en Base64") unless Base64.decode(key).size == 32
        env["CRYSTALIZE_STORAGE_KEY"] = key
      end
      env
    end

    # `${NOM}` et `${NOM:-défaut}`.
    private def expand(arg : String, env : Hash(String, String?)) : String
      arg.gsub(/\$\{(\w+)(?::-([^}]*))?\}/) do
        name, fallback = $1, $2?
        value = env.has_key?(name) ? env[name] : ENV[name]?
        value.nil? || value.empty? ? (fallback || "") : value
      end
    end

    private def version(manifest : Manifest) : String
      <<-TEXT
        #{manifest.app} — branche #{manifest.branch}, commit #{manifest.commit[0, 12]} du #{Time.unix(manifest.commit_time).to_local.to_s("%Y-%m-%d %H:%M")}
        Ruby #{manifest.ruby_version} (#{manifest.platform}), #{manifest.compiled} fichiers en pseudo-code
        crystalize #{manifest.crystalize_version}, charge utile #{payload.id}
        TEXT
    end

    private def usage(manifest : Manifest) : String
      app = manifest.app
      commands = manifest.runtime.commands.map do |name, argv|
        marker = name == manifest.runtime.default_command ? " (défaut)" : ""
        "  #{name.ljust(18)} #{argv.join(' ')}#{marker}"
      end
      <<-TEXT
        Usage : #{app} [-c FICHIER] [COMMANDE] [arguments…]

        Commandes de l'application :
        #{commands.join('\n')}

        Commandes du lanceur :
          exec CMD [ARGS…]   lance CMD dans l'environnement de l'application
          extract            extrait la version courante et affiche son chemin
          config             affiche un modèle de configuration d'exécution
          secrets-template   affiche un modèle de secrets (à chiffrer avec age)
          storage-key        génère une clé de GED chiffrée
          version            affiche la version empaquetée
          help               affiche cette aide

        Options :
          -c, --config FICHIER   configuration d'exécution
          -h, --help             aide
          -v, --version          version
        TEXT
    end
  end

  # Extraction d'une version dans `<état>/releases/`, vérification de son
  # empreinte et réécriture des chemins dans le pseudo-code.
  class Extractor
    def initialize(@payload : Payload::Info, @manifest : Manifest)
    end

    def ensure(state : String) : String
      releases = File.join(state, "releases")
      Dir.mkdir_p(releases)
      final = release_path(File.realpath(releases))
      return final if File.exists?(File.join(final, ".crystalize", ".complete"))

      Crystalize.step "Extraction de #{@manifest.app} (#{@payload.id})"
      temporary = File.join(releases, ".tmp-#{@payload.id}-#{Process.pid}")
      FileUtils.rm_rf(temporary)
      Dir.mkdir_p(temporary)
      begin
        extract(temporary)
        relocate(temporary, final)
        @manifest.runtime.writable.each do |dir|
          link = File.join(temporary, "app", dir)
          FileUtils.rm_rf(link)
          File.symlink(File.join(state, dir), link)
        end
        File.touch(File.join(temporary, ".crystalize", ".complete"))
        File.rename(temporary, final)
      rescue ex
        FileUtils.rm_rf(temporary)
        raise ex unless File.exists?(File.join(final, ".crystalize", ".complete"))
      end
      prune(releases, final)
      final
    end

    # Le chemin réel du dossier de version a la longueur du préfixe fictif.
    private def release_path(releases : String) : String
      length = @manifest.placeholder.bytesize - releases.bytesize - 1
      if length < @payload.id.size
        raise Error.new("dossier d'état trop long : #{releases} (#{@manifest.placeholder.bytesize - @payload.id.size - 1} octets au plus)")
      end
      File.join(releases, @payload.id.ljust(length, '_'))
    end

    private def extract(target : String) : Nil
      digest = Digest::SHA256.new
      links = {} of String => String
      @payload.open do |io|
        hashing = IO::Digest.new(io, digest)
        Compress::Gzip::Reader.open(hashing) do |gzip|
          Tar::Reader.new(gzip).each { |entry| write(target, entry, links) }
        end
        hashing.skip_to_end
      end
      raise Error.new("charge utile corrompue (SHA-256)") unless digest.final == @payload.sha256
      create_links(target, links)
    end

    # Les liens ne sont créés qu'en fin d'extraction : aucune écriture ne
    # peut donc les traverser, et chacun est jugé connaissant tous les autres.
    private def write(target : String, entry : Tar::Entry, links : Hash(String, String)) : Nil
      name = entry.name.rstrip('/')
      check_relative(name)
      parts = name.split('/')
      parts.each_index do |index|
        if links.has_key?(parts[0..index].join('/'))
          raise Error.new("chemin refusé dans la charge utile (traverse un lien) : #{name}")
        end
      end
      path = File.join(target, name)
      case entry.type
      when '5'
        Dir.mkdir_p(path)
      when '2'
        links[name] = entry.link
      when '0', '\0'
        Dir.mkdir_p(File.dirname(path))
        File.open(path, "w") { |file| IO.copy(entry.io, file) }
        File.chmod(path, entry.mode & 0o777)
      end
    end

    private def create_links(target : String, links : Hash(String, String)) : Nil
      names = links.keys.to_set
      links.each do |name, link|
        if reason = Tar.link_error(name, link, names)
          raise Error.new("lien refusé dans la charge utile (#{reason}) : #{name} -> #{link}")
        end
        path = File.join(target, name)
        if File.exists?(path) || File.symlink?(path)
          raise Error.new("chemin refusé dans la charge utile (traverse un lien) : #{name}")
        end
        Dir.mkdir_p(File.dirname(path))
        File.symlink(link, path)
      end
    end

    private def check_relative(name : String) : Nil
      if name.empty? || name.starts_with?('/') || name.split('/').includes?("..")
        raise Error.new("chemin refusé dans la charge utile : #{name}")
      end
    end

    private def relocate(target : String, final : String) : Nil
      from = @manifest.placeholder.to_slice
      to = final.to_slice
      File.each_line(File.join(target, ".crystalize", "compiled.txt")) do |rel|
        next if rel.empty?
        check_relative(rel)
        # Seul un fichier ordinaire, atteint sans passer par un lien, est
        # réécrit.
        parts = rel.split('/')
        parts.each_index do |index|
          if File.symlink?(File.join(target, parts[0..index].join('/')))
            raise Error.new("chemin refusé dans compiled.txt (traverse un lien) : #{rel}")
          end
        end
        path = File.join(target, rel)
        raise Error.new("chemin refusé dans compiled.txt (pas un fichier) : #{rel}") unless File.file?(path)
        data = File.open(path, &.getb_to_end)
        File.write(path, data) if substitute(data, from, to) > 0
      end
    end

    private def substitute(data : Bytes, from : Bytes, to : Bytes) : Int32
      count = 0
      index = 0
      first = from[0]
      while index <= data.size - from.size
        if data[index] == first && data[index, from.size] == from
          to.copy_to(data[index, to.size])
          count += 1
          index += from.size
        else
          index += 1
        end
      end
      count
    end

    # Garde la version courante et la précédente (processus encore en cours).
    private def prune(releases : String, current : String) : Nil
      others = Dir.children(releases)
        .reject(&.starts_with?(".tmp-"))
        .map { |name| File.join(releases, name) }
        .reject { |path| path == current }
        .sort_by! { |path| File.info(path).modification_time }
      others[0...-1].each { |path| FileUtils.rm_rf(path) } if others.size > 1
    end
  end
end
