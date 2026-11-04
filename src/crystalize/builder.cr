module Crystalize
  # Chaîne de construction : branche git → bundle → commandes → pseudo-code
  # → archive déterministe → exécutable.
  class Builder
    getter config : Config

    # `dist` : archive source extraite (`crystalize port`) ; la construction
    # se fait alors sans git ni réseau.
    def initialize(@config : Config, @base_dir : String, @branch : String? = nil, @output : String? = nil,
                   @dist : String? = nil)
    end

    def run : String
      app = config.app
      work = File.join(Crystalize.cache_dir, "work", app.name)
      stage = File.join(work, "stage")
      app_dir = File.join(stage, "app")
      meta_dir = File.join(stage, ".crystalize")
      FileUtils.rm_rf(work)
      Dir.mkdir_p(app_dir)
      Dir.mkdir_p(File.join(meta_dir, "lib", "active_storage", "service"))
      Dir.mkdir_p(File.join(meta_dir, "lib", "crystalize"))

      if dist = @dist
        info = DistInfo.load(dist)
        branch, commit, commit_time = info.branch, info.commit, info.commit_time
        Crystalize.step "Sources de #{branch} (#{commit[0, 12]}) depuis #{dist}"
        Shell.run("cp", ["-R", File.join(dist, "app") + "/.", app_dir])
        ruby_builder = RubyBuilder.new(info.ruby_version, config.ruby, File.join(dist, info.ruby_tarball))
      else
        branch = @branch || app.branch
        source = Source.new(app, @base_dir)
        commit, commit_time = source.resolve(branch)
        source.export(commit, app_dir)
        ruby_builder = RubyBuilder.new(ruby_version(app_dir), config.ruby)
      end
      ruby = ruby_builder.ensure!
      env = build_env(ruby, commit_time)

      bundle(ruby, app_dir, env, local: !@dist.nil?)
      config.build.commands.each do |command|
        Crystalize.step "Commande : #{command}"
        Shell.sh(command, env: env, chdir: app_dir)
      end

      inject(app_dir, meta_dir)
      prune(app_dir)
      strip_native(app_dir)
      compiled = compile(ruby, work, app_dir, meta_dir, env)

      manifest = Manifest.new(
        app: app.name, branch: branch, commit: commit, commit_time: commit_time,
        ruby_version: ruby_builder.version, platform: Platform.name,
        crystalize_version: VERSION, placeholder: PLACEHOLDER, compiled: compiled,
        bundle_without: config.bundle.without, runtime: config.runtime)
      File.write(File.join(stage, Manifest::PATH), manifest.to_yaml)

      payload = File.join(work, "payload.tar.gz")
      pack(stage, ruby, payload, commit_time)

      output = File.expand_path(@output || config.output || File.join("build", app.name), @base_dir)
      launcher = Process.executable_path || raise Error.new("chemin de l'exécutable crystalize introuvable")
      Payload.write(output, launcher, payload)
      Crystalize.step "Exécutable : #{output} (#{(File.size(output) / 1_048_576.0).round(1)} Mo)"
      output
    end

    def ruby_version(app_dir : String) : String
      if version = config.ruby.version
        return version
      end
      dotfile = File.join(app_dir, ".ruby-version")
      if File.exists?(dotfile)
        return File.read(dotfile).strip.lchop("ruby-")
      end
      lockfile = File.join(app_dir, "Gemfile.lock")
      if File.exists?(lockfile) && (match = File.read(lockfile).match(/^RUBY VERSION\n\s+ruby (\d+\.\d+\.\d+)/m))
        return match[1]
      end
      raise Error.new("version de Ruby inconnue : renseignez ruby.version dans la configuration")
    end

    def build_env(ruby : String, commit_time : Int64) : Hash(String, String?)
      env = {
        "PATH"              => "#{File.join(ruby, "bin")}:#{ENV["PATH"]?}",
        "SOURCE_DATE_EPOCH" => commit_time.to_s,
        "LANG"              => "en_US.UTF-8",
        "LC_ALL"            => "en_US.UTF-8",
        "DISABLE_BOOTSNAP"  => "1",
        # ld64 (macOS) : pas de date des .o dans les extensions natives.
        "ZERO_AR_DATE" => "1",
      }
      env = env.merge(config.build.env)
      config.build.pass_env.each do |name|
        if value = ENV[name]?
          env[name] = value
        else
          Crystalize.warn "build.pass_env : #{name} absente de l'environnement"
        end
      end
      Shell.clean_env(env)
    end

    # `local` : gems prises dans `vendor/cache` seulement (pas de réseau).
    private def bundle(ruby : String, app_dir : String, env : Hash(String, String?), local : Bool = false) : Nil
      Crystalize.step "Installation des gems (sans : #{config.bundle.without.join(", ")})"
      bundler = File.join(ruby, "bin", "bundle")
      settings = {
        "deployment" => "true",
        "path"       => "vendor/bundle",
        "without"    => config.bundle.without.join(' '),
      }
      config.bundle.build_config.each { |gem, flags| settings["build.#{gem}"] = flags }
      settings.each { |key, value| Shell.run(bundler, ["config", "set", "--local", key, value], env: env, chdir: app_dir) }
      args = ["install", "--jobs", config.bundle.jobs.to_s]
      args << "--local" if local
      Shell.run(bundler, args, env: env, chdir: app_dir)
    end

    private def inject(app_dir : String, meta_dir : String) : Nil
      File.write(File.join(meta_dir, "lib", "crystalize", "boot.rb"), Support::BOOT)
      File.write(File.join(meta_dir, "lib", "active_storage", "service", "encrypted_disk_service.rb"),
        Support::ENCRYPTED_DISK_SERVICE)
      initializers = File.join(app_dir, "config", "initializers")
      if config.runtime.rails && Dir.exists?(initializers)
        File.write(File.join(initializers, "zzz_crystalize.rb"), Support::INITIALIZER)
      end
    end

    private def prune(app_dir : String) : Nil
      Crystalize.step "Élagage"
      patterns = Config::DEFAULT_PRUNE + config.prune + config.runtime.writable
      patterns.each do |pattern|
        Dir.glob(File.join(app_dir, pattern), match: File::MatchOptions::DotFiles).each do |path|
          FileUtils.rm_rf(path)
        end
      end
    end

    # Retire les symboles de débogage des extensions natives : ils citent des
    # fichiers objets temporaires (noms aléatoires) et rendraient la
    # construction non reproductible.
    private def strip_native(app_dir : String) : Nil
      return unless config.bundle.strip_native
      libraries = Dir.glob(File.join(app_dir, "vendor", "bundle", "**", "*.{bundle,so}"))
        .select { |path| File.info(path, follow_symlinks: false).file? }
      return if libraries.empty?
      Crystalize.step "Allègement de #{libraries.size} extensions natives"
      Shell.run("strip", ["-S"] + libraries.sort)
      # macOS tue tout processus qui charge du code à signature invalide.
      Shell.run("codesign", ["--force", "--sign", "-"] + libraries.sort) if Platform.os == "darwin"
    end

    # Compile les sources retenues ; renvoie le nombre de fichiers compilés.
    private def compile(ruby : String, work : String, app_dir : String, meta_dir : String,
                        env : Hash(String, String?)) : Int32
      list = File.join(meta_dir, "compiled.txt")
      unless config.compile.enabled
        File.write(list, "")
        return 0
      end

      Crystalize.step "Compilation en pseudo-code YARV"
      script = File.join(work, "compile.rb")
      input = File.join(work, "compile-in.txt")
      output = File.join(work, "compile-out.txt")
      File.write(script, Support::COMPILE)
      File.write(input, collect(app_dir, config.compile.patterns, config.compile.exclude).join('\n') + "\n")
      Shell.run(File.join(ruby, "bin", "ruby"),
        ["--disable-gems", "--external-encoding=UTF-8", script, app_dir, "#{PLACEHOLDER}/app", input, output,
         config.compile.strip_sources ? "1" : "0"], env: env)
      lines = File.read_lines(output).reject(&.empty?).map { |line| "app/#{line}" }
      File.write(list, lines.join('\n') + "\n")
      lines.size
    end

    private def collect(root : String, patterns : Array(String), exclude : Array(String)) : Array(String)
      files = Set(String).new
      patterns.each do |pattern|
        Dir.glob(File.join(root, pattern), match: File::MatchOptions::DotFiles).each do |path|
          next unless File.info(path, follow_symlinks: false).file?
          rel = path.lchop(root + "/")
          files << rel unless exclude.any? { |ex| File.match?(ex, rel) }
        end
      end
      files.to_a.sort!
    end

    private def pack(stage : String, ruby : String, payload : String, mtime : Int64) : Nil
      Crystalize.step "Archive de la charge utile"
      File.open(payload, "w") do |file|
        gzip = Compress::Gzip::Writer.new(file, level: Compress::Gzip::BEST_COMPRESSION)
        gzip.header.modification_time = Time.unix(0)
        tar = Tar::Writer.new(gzip, mtime)
        # `.crystalize/` d'abord : le manifeste se lit sans tout décompresser.
        tar.add_dir(".crystalize")
        tar.add_tree(File.join(stage, ".crystalize"), ".crystalize") { false }
        tar.add_dir("app")
        tar.add_tree(File.join(stage, "app"), "app") { false }
        tar.add_dir("ruby")
        tar.add_tree(ruby, "ruby") { |rel| skip_ruby?(rel) }
        tar.check_links
        tar.finish
        gzip.close
      end
    end

    # Le Ruby embarqué n'a besoin ni des en-têtes, ni des bibliothèques
    # statiques, ni de la documentation.
    private def skip_ruby?(rel : String) : Bool
      rel == ".complete" || rel == "include" || rel == "share" || rel == "lib/pkgconfig" ||
        rel.ends_with?(".a") || File.match?("lib/ruby/gems/*/cache", rel)
    end
  end
end
