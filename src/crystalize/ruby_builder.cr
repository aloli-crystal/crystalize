require "http/client"

module Crystalize
  # Construit (une fois, en cache) un Ruby relocatable
  # (`--enable-load-relative`) pour la plate-forme courante.
  class RubyBuilder
    getter version : String

    # `source` : archive des sources déjà présente (construction hors ligne).
    def initialize(@version : String, @config : Config::Ruby, @source : String? = nil)
    end

    def configure_opts : Array(String)
      @config.configure_opts || Platform.default_configure_opts
    end

    def prefix : String
      tag = Digest::SHA256.hexdigest(configure_opts.join(' '))[0, 8]
      File.join(Crystalize.cache_dir, "rubies", "#{version}-#{Platform.name}-#{tag}")
    end

    def ensure! : String
      return prefix if File.exists?(File.join(prefix, ".complete"))
      Crystalize.step "Construction de Ruby #{version} (#{Platform.name}) dans #{prefix}"
      build(source_tarball)
      prefix
    end

    private def url : String
      @config.url || begin
        series = version.split('.')[0, 2].join('.')
        "https://cache.ruby-lang.org/pub/ruby/#{series}/ruby-#{version}.tar.gz"
      end
    end

    # Archive des sources, téléchargée au besoin, somme vérifiée.
    def source_tarball : String
      path = @source || File.join(Crystalize.cache_dir, "sources", "ruby-#{version}.tar.gz")
      unless File.exists?(path)
        raise Error.new("sources de Ruby absentes : #{path}") if @source
        Crystalize.step "Téléchargement de #{url}"
        Dir.mkdir_p(File.dirname(path))
        download(url, "#{path}.part")
        File.rename("#{path}.part", path)
      end
      actual = File.open(path) { |file| Digest::SHA256.new.update(file).hexfinal }
      if expected = @config.sha256
        raise Error.new("somme SHA-256 inattendue pour #{path} : #{actual}") unless actual == expected.downcase
      else
        Crystalize.warn "ruby.sha256 non renseigné ; somme obtenue : #{actual}"
      end
      path
    end

    private def download(location : String, target : String, redirects = 5) : Nil
      HTTP::Client.get(location) do |response|
        if response.status.redirection? && (next_location = response.headers["Location"]?) && redirects > 0
          return download(next_location, target, redirects - 1)
        end
        raise Error.new("téléchargement impossible (#{response.status_code}) : #{location}") unless response.success?
        File.open(target, "w") { |file| IO.copy(response.body_io, file) }
      end
    end

    private def build(tarball : String) : Nil
      work = File.join(Crystalize.cache_dir, "build")
      source = File.join(work, "ruby-#{version}")
      FileUtils.rm_rf(source)
      Dir.mkdir_p(work)
      Shell.run("tar", ["-xzf", tarball, "-C", work])
      FileUtils.rm_rf(prefix)

      env = Shell.clean_env
      # dtrace est inutile ici et échoue dans les environnements confinés.
      Shell.run("./configure", ["--prefix=#{prefix}", "--enable-load-relative", "--disable-install-doc",
                                "--disable-dtrace"] + configure_opts, env: env, chdir: source)
      make = ENV["MAKE"]? || "make"
      Shell.run(make, ["-j#{System.cpu_count}"], env: env, chdir: source)
      Shell.run(make, ["install"], env: env, chdir: source)
      File.touch(File.join(prefix, ".complete"))
      FileUtils.rm_rf(source)
    end
  end
end
