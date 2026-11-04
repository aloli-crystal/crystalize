require "json"

module Crystalize
  # Paquet FreeBSD d'un exécutable produit : binaire, script rc.d (service
  # supervisé par daemon(8)), modèle de configuration, utilisateur et
  # dossiers du service, dépendances vers les bibliothèques partagées.
  #
  # L'arbre et le manifeste sont écrits partout ; `pkg create` n'est lancé
  # que là où `pkg` existe (FreeBSD), comme la détection des dépendances.
  class Packager
    record Dependency, name : String, origin : String, version : String

    getter app : String
    getter name : String
    getter version : String
    getter user : String
    getter group : String
    getter prefix : String
    getter state_dir : String

    def initialize(@config : Config::Package, @binary : String, @manifest : Manifest)
      @app = @manifest.app
      @name = @config.name || @app
      @version = @config.version || Time.unix(@manifest.commit_time).to_utc.to_s("%Y.%m.%d.%H%M%S")
      @user = @config.user || @name
      @group = @config.group || @user
      @prefix = @config.prefix.rstrip('/')
      @state_dir = @config.state_dir || "/var/db/#{@name}"
      check
    end

    # Écrit l'arbre du paquet dans `output` et renvoie le chemin du `.pkg`
    # (ou de l'arbre, si `pkg` est absent).
    def run(output : String) : String
      unless @manifest.platform.starts_with?("freebsd")
        Crystalize.warn("#{@binary} a été construit pour #{@manifest.platform}, pas pour FreeBSD")
      end
      work = File.join(output, "#{name}-#{version}")
      root = File.join(work, "root")
      FileUtils.rm_rf(work)
      Crystalize.step "Arbre du paquet #{name}-#{version}"
      binary = File.join(root, prefix.lchop('/'), "bin", app)
      Dir.mkdir_p(File.dirname(binary))
      FileUtils.cp(@binary, binary)
      File.chmod(binary, 0o755)
      install(File.join(root, prefix.lchop('/'), "etc", "rc.d", app), rc_script, 0o755)
      install(File.join(root, prefix.lchop('/'), "etc", "#{app}.yml.sample"), sample_config, 0o644)
      Dir.mkdir_p(File.join(root, prefix.lchop('/'), "etc", app))
      Dir.mkdir_p(File.join(root, state_dir.lchop('/')))

      pkg = Process.find_executable("pkg")
      dependencies = pkg ? dependencies(pkg) : [] of Dependency
      if !pkg && (!@config.depends.empty? || @config.detect_depends)
        Crystalize.warn("pkg absent : dépendances non renseignées (#{@config.depends.join(", ")})")
      end
      File.write(File.join(work, "+MANIFEST"), manifest_json(dependencies))
      File.write(File.join(work, "pkg-plist"), plist)

      args = ["create", "-M", File.join(work, "+MANIFEST"), "-p", File.join(work, "pkg-plist"), "-r", root, "-o", output]
      unless pkg
        Crystalize.step "pkg absent : arbre prêt dans #{work}, à empaqueter sous FreeBSD par : pkg #{args.join(' ')}"
        return work
      end
      Crystalize.step "Paquet"
      Shell.run(pkg, args)
      path = File.join(output, "#{name}-#{version}.pkg")
      Crystalize.step "Paquet : #{path}"
      path
    end

    # Variable rc.conf : `<nom>_enable`, etc.
    def rcvar_prefix : String
      app.gsub(/[^A-Za-z0-9_]/, '_')
    end

    def rc_script : String
      var = rcvar_prefix
      command = @config.rc_command || @manifest.runtime.default_command
      <<-SH
        #!/bin/sh
        #
        # PROVIDE: #{app}
        # REQUIRE: #{@config.rc_require.join(' ')}
        # KEYWORD: shutdown
        #
        # Script produit par crystalize. Variables de /etc/rc.conf :
        #
        # #{var}_enable (bool) : YES pour lancer #{app} au démarrage (défaut : NO)
        # #{var}_config (str)  : configuration d'exécution
        #                        (défaut : #{prefix}/etc/#{app}.yml)
        # #{var}_user (str)    : utilisateur du service (défaut : #{user})
        # #{var}_command (str) : commande lancée (défaut : #{command})
        # #{var}_env (str)     : environnement (défaut : HOME=#{state_dir})
        #
        # Le service est supervisé par daemon(8) (relancé s'il meurt, sortie
        # vers syslog). « service #{app} migrate » lance les migrations.

        . /etc/rc.subr

        name=#{app}
        rcvar=#{var}_enable

        load_rc_config $name

        : ${#{var}_enable:="NO"}
        : ${#{var}_config:="#{prefix}/etc/#{app}.yml"}
        : ${#{var}_user:="#{user}"}
        : ${#{var}_command:="#{command}"}
        : ${#{var}_env:="HOME=#{state_dir}"}

        # Le lanceur se remplace par Ruby : on suit le superviseur daemon(8).
        pidfile="/var/run/${name}.pid"
        procname="/usr/sbin/daemon"
        command="/usr/sbin/daemon"
        command_args="-r -S -T ${name} -P ${pidfile} -u ${#{var}_user} #{prefix}/bin/#{app} -c ${#{var}_config} ${#{var}_command}"

        extra_commands="migrate"
        migrate_cmd="#{var}_migrate"

        #{var}_migrate()
        {
        \tenv ${#{var}_env} su -m ${#{var}_user} -c "#{prefix}/bin/#{app} -c ${#{var}_config} migrate"
        }

        run_rc_command "$1"

        SH
    end

    def sample_config : String
      RuntimeConfig.sample(app, state_dir, "#{prefix}/etc")
    end

    # Liste du paquet, relative à `prefix` sauf chemins absolus ; droits
    # explicites (l'arbre est construit sans être root).
    def plist : String
      <<-PLIST
        @(root,wheel,555) bin/#{app}
        @(root,wheel,555) etc/rc.d/#{app}
        @sample(root,#{group},640) etc/#{app}.yml.sample
        @dir(root,#{group},750) etc/#{app}
        @dir(#{user},#{group},750) #{state_dir}

        PLIST
    end

    def pre_install : String
      group_id = @config.gid.try { |gid| " -g #{gid}" } || ""
      user_id = @config.uid.try { |uid| " -u #{uid}" } || ""
      <<-SH
        if ! pw groupshow #{group} >/dev/null 2>&1; then
          pw groupadd #{group}#{group_id}
        fi
        if ! pw usershow #{user} >/dev/null 2>&1; then
          pw useradd #{user}#{user_id} -g #{group} -d #{state_dir} -s /usr/sbin/nologin -c "#{app} (crystalize)"
        fi
        SH
    end

    def message : String
      var = rcvar_prefix
      <<-TEXT
        #{app} est installé. Avant de le lancer :

        1. Configuration : #{prefix}/etc/#{app}.yml (modèle : #{app}.yml.sample).
        2. Secrets, lisibles par #{user} seulement :
             #{app} secrets-template > secrets.yml   # à remplir
             age-keygen -o #{prefix}/etc/#{app}/age.key
             age -e -r "$(age-keygen -y #{prefix}/etc/#{app}/age.key)" \\
                 -o #{prefix}/etc/#{app}/secrets.age secrets.yml && rm secrets.yml
             chown root:#{group} #{prefix}/etc/#{app}/age.key #{prefix}/etc/#{app}/secrets.age
             chmod 640 #{prefix}/etc/#{app}/age.key #{prefix}/etc/#{app}/secrets.age
           (une phrase de passe age n'est pas utilisable par un service).
        3. Base de données : service #{app} migrate
        4. Service : sysrc #{var}_enable=YES && service #{app} start

        À chaque mise à jour : service #{app} migrate && service #{app} restart
        TEXT
    end

    def manifest_json(dependencies : Array(Dependency)) : String
      JSON.build(2) do |json|
        json.object do
          json.field "name", name
          json.field "version", version
          json.field "origin", @config.origin || "local/#{name}"
          json.field "comment", @config.comment || "#{app} (#{@manifest.branch} #{@manifest.commit[0, 12]}), empaqueté par crystalize"
          json.field "desc", "#{app} : branche #{@manifest.branch}, commit #{@manifest.commit}, Ruby #{@manifest.ruby_version}, crystalize #{@manifest.crystalize_version}."
          json.field "maintainer", @config.maintainer
          json.field "www", @config.www || "https://localhost/"
          json.field "prefix", prefix
          json.field "categories", ["local"]
          json.field "licenselogic", "single"
          json.field "licenses", ["NONE"]
          json.field "deps" do
            json.object do
              dependencies.each do |dep|
                json.field dep.name do
                  json.object do
                    json.field "origin", dep.origin
                    json.field "version", dep.version
                  end
                end
              end
            end
          end
          json.field "scripts" do
            json.object { json.field "pre-install", pre_install }
          end
          json.field "messages" do
            json.array do
              json.object do
                json.field "message", message
                json.field "type", "install"
              end
            end
          end
        end
      end
    end

    # Chemins des bibliothèques résolues dans une sortie de ldd(1).
    def self.parse_ldd(output : String) : Array(String)
      output.scan(/=>\s+(\/\S+)/).map(&.[1]).uniq!
    end

    # Paquets nommés dans la configuration, plus ceux détectés ; versions
    # et origines lues dans la base pkg de la machine de construction.
    private def dependencies(pkg : String) : Array(Dependency)
      named = @config.depends.map do |dep|
        query(pkg, dep) || raise Error.new("dépendance #{dep} absente de cette machine (pkg install #{dep})")
      end
      detected = @config.detect_depends ? detect_dependencies(pkg) : [] of Dependency
      (named + detected).uniq!(&.name).sort_by!(&.name)
    end

    # Bibliothèques partagées hors système de base (lanceur, Ruby et
    # extensions natives de la charge utile) → paquets qui les fournissent.
    private def detect_dependencies(pkg : String) : Array(Dependency)
      Crystalize.step "Dépendances (ldd)"
      ldd = Process.find_executable("ldd") || raise Error.new("ldd introuvable")
      temp = File.join(Crystalize.cache_dir, "work", "#{name}-elf")
      FileUtils.rm_rf(temp)
      Dir.mkdir_p(temp)
      begin
        files = [@binary] + extract_elf(temp)
        libraries = files.flat_map { |file| Packager.parse_ldd(quiet(ldd, [file]) || "") }.uniq!
        libraries
          .reject { |path| path.starts_with?("/lib/") || path.starts_with?("/usr/lib/") || path.starts_with?(temp) }
          .compact_map { |path| quiet(pkg, ["which", "-q", path]).try(&.strip).presence }
          .uniq!
          .compact_map { |package| query(pkg, package) }
      ensure
        FileUtils.rm_rf(temp)
      end
    end

    # Copie à plat (noms neutres) des fichiers ELF de la charge utile.
    private def extract_elf(temp : String) : Array(String)
      payload = Payload.locate(@binary) || raise Error.new("#{@binary} ne contient pas de charge utile crystalize")
      files = [] of String
      payload.open do |io|
        Compress::Gzip::Reader.open(io) do |gzip|
          Tar::Reader.new(gzip).each do |entry|
            next unless entry.type == '0' || entry.type == '\0'
            magic = Bytes.new(4)
            next unless entry.io.read_fully?(magic) && magic == Bytes[0x7f, 'E'.ord, 'L'.ord, 'F'.ord]
            path = File.join(temp, "#{files.size}.elf")
            File.open(path, "w") do |file|
              file.write(magic)
              IO.copy(entry.io, file)
            end
            File.chmod(path, 0o755)
            files << path
          end
        end
      end
      files
    end

    private def query(pkg : String, package : String) : Dependency?
      line = quiet(pkg, ["query", "%n\t%o\t%v", package]).try(&.lines.first?)
      return unless line
      dep_name, origin, dep_version = line.split('\t')
      Dependency.new(dep_name, origin, dep_version)
    end

    # Sortie de la commande, ou nil si elle échoue (bibliothèque non
    # fournie par un paquet, fichier que ldd ne sait pas lire…).
    private def quiet(command : String, args : Array(String)) : String?
      output = IO::Memory.new
      status = Process.run(command, args, output: output, error: Process::Redirect::Close)
      status.success? ? output.to_s : nil
    end

    private def install(path : String, content : String, mode : Int32) : Nil
      Dir.mkdir_p(File.dirname(path))
      File.write(path, content)
      File.chmod(path, mode)
    end

    private def check : Nil
      {"nom" => name, "utilisateur" => user, "groupe" => group, "application" => app}.each do |label, value|
        unless value.matches?(/\A[A-Za-z0-9][A-Za-z0-9_.+-]*\z/)
          raise Error.new("#{label} de paquet invalide : #{value.inspect}")
        end
      end
      raise Error.new("version de paquet invalide (ni « - » ni blanc) : #{version.inspect}") unless version.matches?(/\A[0-9A-Za-z._,+]+\z/)
      {"prefix" => prefix, "state_dir" => state_dir}.each do |label, value|
        raise Error.new("package.#{label} doit être absolu, sans blanc : #{value.inspect}") unless value.matches?(/\A\/[^\s:"'$`\\\\]+\z/)
      end
    end
  end
end
