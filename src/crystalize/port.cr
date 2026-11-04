module Crystalize
  # Description des sources réunies pour une construction hors ligne
  # (`dist.yml`, à la racine du dossier passé à `build --from-dist`).
  class DistInfo
    include YAML::Serializable

    PATH = "dist.yml"

    property app : String
    property branch : String
    property commit : String
    property commit_time : Int64
    property ruby_version : String
    property ruby_tarball : String
    property crystalize_version : String

    def initialize(@app, @branch, @commit, @commit_time, @ruby_version, @ruby_tarball, @crystalize_version)
    end

    def self.load(dir : String) : DistInfo
      path = File.join(dir, PATH)
      raise Error.new("#{dir} n'est pas un dossier de sources crystalize (#{PATH} absent)") unless File.exists?(path)
      from_yaml(File.read(path))
    end
  end

  # Port FreeBSD d'une application, construit par poudriere puis publié dans
  # le dépôt pkg. Le port ne contient aucun secret :
  #
  # * Ruby et chaque gem du `Gemfile.lock` sont des distfiles publics
  #   (ruby-lang.org, rubygems.org), empreintes dans `distinfo` ;
  # * les sources de l'application (dépôt privé) sont décrites dans
  #   `files/crystalize-source` (URL, commit, nom d'archive, chemin de la
  #   clé) ; le builder les récupère sur l'hôte, avant le bulk, avec la clé
  #   en lecture seule posée par beryl (`crystalize-fetch`), et les dépose
  #   dans les distfiles ; le port vérifie le commit à l'extraction ;
  # * la construction, sans réseau, est `crystalize build --from-dist`.
  class Port
    # Lanceur Crystal (GC, PCRE2) et Ruby (libyaml, libffi) ; OpenSSL vient
    # du système de base (`USES=ssl`).
    LIB_DEPENDS = %w[
      libffi.so:devel/libffi
      libgc-threaded.so:devel/boehm-gc-threaded
      libpcre2-8.so:devel/pcre2
      libyaml-0.so:textproc/libyaml
    ]
    DIST_SUBDIR = "crystalize"

    record Distfile, name : String, sha256 : String, size : Int64

    getter packager : Packager
    getter info : DistInfo
    getter gems = [] of String

    def initialize(@config : Config, @config_path : String, branch : String? = nil)
      @base_dir = File.dirname(File.expand_path(@config_path))
      @source = Source.new(@config.app, @base_dir)
      @branch = branch || @config.app.branch
      commit, commit_time = @source.resolve(@branch)
      @info = DistInfo.new(@config.app.name, @branch, commit, commit_time, "", "", VERSION)
      manifest = Manifest.new(@config.app.name, @branch, commit, commit_time, "", "freebsd",
        VERSION, PLACEHOLDER, 0, @config.bundle.without, @config.runtime)
      @packager = Packager.new(@config.package, "", manifest)
    end

    def category : String
      @config.port.category || raise Error.new("port.category requis dans #{@config_path} (security, www…)")
    end

    def source_url : String
      url = @config.port.source_url || @config.app.repository
      raise Error.new("port.source_url requis : URL du dépôt joignable depuis le builder (git@github.com:…)") unless Source.remote?(url)
      url
    end

    def key : String
      @config.port.key || "/usr/local/etc/poudriere.d/keys/#{packager.name}"
    end

    # Archive des sources de l'application, dans les distfiles du builder.
    def source_archive : String
      "#{packager.name}-#{info.commit}.tar"
    end

    # Écrit le port dans `<tree>/<catégorie>/<nom>` ; renvoie son chemin.
    def run(tree : String) : String
      check_descriptor
      work = File.join(Crystalize.cache_dir, "work", "#{packager.name}-port")
      app_dir = File.join(work, "app")
      FileUtils.rm_rf(work)
      Dir.mkdir_p(app_dir)
      @source.export(info.commit, app_dir)

      ruby_builder = RubyBuilder.new(Builder.new(@config, @base_dir, @branch).ruby_version(app_dir), @config.ruby)
      info.ruby_version = ruby_builder.version
      info.ruby_tarball = "ruby-#{ruby_builder.version}.tar.gz"
      lockfile = File.join(app_dir, "Gemfile.lock")
      raise Error.new("Gemfile.lock absent du commit #{info.commit[0, 12]}") unless File.exists?(lockfile)
      lock = File.read(lockfile)
      @gems = Port.gem_files(lock)
      Port.platform_warning(lock).try { |message| Crystalize.warn(message) }

      Crystalize.step "Distfiles : Ruby #{info.ruby_version} et #{gems.size} gems"
      distfiles = [distfile(ruby_builder.source_tarball, info.ruby_tarball)] +
                  gems.map { |gem| distfile(download_gem(gem), gem) }

      portdir = File.join(tree, category, packager.name)
      FileUtils.rm_rf(portdir)
      files = File.join(portdir, "files")
      Dir.mkdir_p(files)
      File.write(File.join(portdir, "Makefile"), makefile)
      File.write(File.join(portdir, "Makefile.gems"), makefile_gems)
      File.write(File.join(portdir, "distinfo"), distinfo(distfiles))
      File.write(File.join(portdir, "pkg-descr"), pkg_descr)
      File.write(File.join(portdir, "pkg-plist"), plist)
      File.write(File.join(portdir, "pkg-message"), pkg_message)
      File.write(File.join(portdir, "pkg-pre-install"), packager.pre_install)
      File.write(File.join(files, "#{packager.app}.in"), rc_script)
      File.write(File.join(files, "#{packager.app}.yml.sample"), packager.sample_config)
      File.write(File.join(files, "crystalize-source"), descriptor)
      File.write(File.join(files, DistInfo::PATH), info.to_yaml)
      FileUtils.cp(@config_path, File.join(files, "crystalize.yml"))
      FileUtils.rm_rf(work)
      Crystalize.step "Port : #{portdir}"
      portdir
    end

    # Archives `.gem` des gems du verrou, dans leur variante source (celle
    # que Bundler installe sous FreeBSD, où aucune gem n'est précompilée).
    # Seules les gems d'un serveur (section GEM) sont acceptées : une source
    # git ou locale n'est pas téléchargeable par le port.
    def self.gem_files(lock : String) : Array(String)
      %w[GIT PATH PLUGIN].each do |section|
        if lock.matches?(/^#{section}$/m)
          raise Error.new("Gemfile.lock : section #{section} non prise en charge par crystalize port (gems de rubygems.org seulement)")
        end
      end
      specs = lock.match(/^GEM\n(?:  [^\n]*\n)*?  specs:\n((?:    [^\n]*\n)*)/m) || raise Error.new("Gemfile.lock : section GEM introuvable")
      variants = Hash(String, Array(String?)).new { |hash, key| hash[key] = [] of String? }
      specs[1].each_line do |line|
        next unless match = line.match(/^    (\S+) \(([^)]+)\)$/)
        version, _, platform = match[2].partition('-')
        variants["#{match[1]}-#{version}"] << (platform.empty? ? nil : platform)
      end
      variants.map do |gem, platforms|
        unless platforms.includes?(nil)
          raise Error.new("Gemfile.lock : #{gem} n'existe qu'en variantes précompilées (#{platforms.join(", ")}), pas pour FreeBSD")
        end
        "#{gem}.gem"
      end.sort!
    end

    # En mode figé, Bundler refuse une plate-forme absente du verrou.
    def self.platform_warning(lock : String) : String?
      section = lock.match(/^PLATFORMS\n((?:  [^\n]+\n)+)/m)
      platforms = section ? section[1].split : [] of String
      return if platforms.includes?("ruby") || platforms.any?(&.includes?("freebsd"))
      "Gemfile.lock sans plate-forme FreeBSD : bundle lock --add-platform x86_64-freebsd-15"
    end

    def makefile : String
      app = packager.app
      port = @config.port
      lib_depends = (LIB_DEPENDS + port.lib_depends).uniq
      build_depends = ["crystalize:#{port.crystalize_origin}"] + port.build_depends
      <<-MAKE
        # Port produit par crystalize #{VERSION} pour #{app} (#{info.branch} #{info.commit[0, 12]}).
        # Ne pas modifier : relancer « crystalize port ».

        PORTNAME=\t#{packager.name}
        DISTVERSION=\t#{packager.version}
        CATEGORIES=\t#{category}
        DIST_SUBDIR=\t#{DIST_SUBDIR}

        MAINTAINER=\t#{@config.package.maintainer}
        COMMENT=\t#{@config.package.comment || "#{app}, application Ruby empaquetée par crystalize"}
        WWW=\t\t#{@config.package.www || "https://localhost/"}

        BUILD_DEPENDS=\t#{build_depends.join(" \\\n\t\t")}
        LIB_DEPENDS=\t#{lib_depends.join(" \\\n\t\t")}
        #{port.run_depends.empty? ? "" : "RUN_DEPENDS=\t#{port.run_depends.join(" \\\n\t\t")}"}

        USES=\t\tgmake pkgconfig ssl
        USE_RC_SUBR=\t#{app}

        # Ruby et les gems du Gemfile.lock (distfiles publics).
        .include "${.CURDIR}/Makefile.gems"

        # Sources de l'application, dépôt privé : récupérées sur le builder
        # avant le bulk (crystalize-fetch, clé posée par beryl), d'après
        # files/crystalize-source ; le commit est vérifié à l'extraction.
        CRYSTALIZE_COMMIT=\t#{info.commit}
        CRYSTALIZE_SOURCE=\t${DISTDIR}/${DIST_SUBDIR}/#{source_archive}

        EXTRACT_ONLY=
        NO_WRKSUBDIR=\tyes
        WRKSRC=\t\t${WRKDIR}/dist

        # Construction hors ligne : caches dans WRKDIR, gems de vendor/cache.
        MAKE_ENV=\tCRYSTALIZE_CACHE=${WRKDIR}/cache \\
        \t\tHOME=${WRKDIR} \\
        \t\tMAKE=gmake

        post-fetch:
        \t@if [ ! -f ${CRYSTALIZE_SOURCE} ]; then \\
        \t\t${ECHO_MSG} "===> ${CRYSTALIZE_SOURCE} absent : à récupérer sur le builder (crystalize-fetch)"; \\
        \t\t${FALSE}; \\
        \tfi

        do-extract:
        \t@head -c 1024 ${CRYSTALIZE_SOURCE} | ${GREP} -aq "comment=${CRYSTALIZE_COMMIT}" || \\
        \t\t{ ${ECHO_MSG} "===> ${CRYSTALIZE_SOURCE} : commit différent de ${CRYSTALIZE_COMMIT}"; ${FALSE}; }
        \t${MKDIR} ${WRKSRC}/app/vendor/cache
        \t${TAR} -xf ${CRYSTALIZE_SOURCE} -C ${WRKSRC}/app
        \tcd ${DISTDIR}/${DIST_SUBDIR} && ${CP} ${CRYSTALIZE_GEMS} ${WRKSRC}/app/vendor/cache/
        \t${CP} ${DISTDIR}/${DIST_SUBDIR}/#{info.ruby_tarball} ${FILESDIR}/#{DistInfo::PATH} \\
        \t\t${FILESDIR}/crystalize.yml ${WRKSRC}/

        do-build:
        \tcd ${WRKSRC} && ${SETENV} ${MAKE_ENV} ${LOCALBASE}/bin/crystalize build \\
        \t\t--from-dist ${WRKSRC} -c ${WRKSRC}/crystalize.yml -o ${WRKDIR}/#{app}

        # INSTALL_SCRIPT et non INSTALL_PROGRAM : strip effacerait la charge
        # utile ajoutée en fin d'exécutable.
        do-install:
        \t${INSTALL_SCRIPT} ${WRKDIR}/#{app} ${STAGEDIR}${PREFIX}/bin/#{app}
        \t${INSTALL_DATA} ${FILESDIR}/#{app}.yml.sample ${STAGEDIR}${PREFIX}/etc/#{app}.yml.sample
        \t${MKDIR} ${STAGEDIR}${PREFIX}/etc/#{app} ${STAGEDIR}#{packager.state_dir}

        .include <bsd.port.mk>

        MAKE
    end

    def makefile_gems : String
      series = info.ruby_version.split('.')[0, 2].join('.')
      <<-MAKE
        # Produit par crystalize #{VERSION} d'après le Gemfile.lock de #{info.commit[0, 12]}.
        # Ne pas modifier : relancer « crystalize port ».

        MASTER_SITES=\thttps://cache.ruby-lang.org/pub/ruby/#{series}/:ruby \\
        \t\thttps://rubygems.org/downloads/:gems
        DISTFILES=\t#{info.ruby_tarball}:ruby

        CRYSTALIZE_GEMS=\t#{gems.join(" \\\n\t\t\t")}
        DISTFILES+=\t${CRYSTALIZE_GEMS:S/$/:gems/}

        MAKE
    end

    # Une ligne : URL, commit, archive, clé (lue par crystalize-fetch).
    def descriptor : String
      "#{source_url} #{info.commit} #{source_archive} #{key}\n"
    end

    def plist : String
      app = packager.app
      <<-PLIST
        bin/#{app}
        @sample etc/#{app}.yml.sample
        @dir(root,#{packager.group},750) etc/#{app}
        @dir(#{packager.user},#{packager.group},750) #{packager.state_dir}

        PLIST
    end

    # Script rc.d avec `%%PREFIX%%`, remplacé par le port (`USE_RC_SUBR`).
    def rc_script : String
      packager.rc_script.gsub("#{packager.prefix}/", "%%PREFIX%%/")
    end

    def pkg_message : String
      <<-UCL
        [
        { type: install
          message: <<EOM
        #{packager.message}
        EOM
        }
        ]

        UCL
    end

    def pkg_descr : String
      "#{packager.app} : application Ruby empaquetée par crystalize en un exécutable unique\n" \
      "(branche #{info.branch}, commit #{info.commit}, Ruby #{info.ruby_version}).\n"
    end

    private def check_descriptor : Nil
      {source_url, key}.each do |value|
        raise Error.new("port : blanc interdit dans #{value.inspect}") if value.matches?(/\s/)
      end
      raise Error.new("port.key doit être un chemin absolu : #{key}") unless key.starts_with?('/')
    end

    private def download_gem(gem : String) : String
      path = File.join(Crystalize.cache_dir, "distfiles", DIST_SUBDIR, gem)
      return path if File.exists?(path)
      Dir.mkdir_p(File.dirname(path))
      Shell.run("curl", ["-fsSL", "--retry", "3", "-o", "#{path}.part", "https://rubygems.org/downloads/#{gem}"])
      File.rename("#{path}.part", path)
      path
    end

    private def distfile(path : String, name : String) : Distfile
      sha = File.open(path) { |file| Digest::SHA256.new.update(file).hexfinal }
      Distfile.new(name, sha, File.size(path).to_i64)
    end

    private def distinfo(distfiles : Array(Distfile)) : String
      String.build do |str|
        str << "TIMESTAMP = " << info.commit_time << '\n'
        distfiles.each do |file|
          str << "SHA256 (" << DIST_SUBDIR << '/' << file.name << ") = " << file.sha256 << '\n'
          str << "SIZE (" << DIST_SUBDIR << '/' << file.name << ") = " << file.size << '\n'
        end
      end
    end
  end
end
