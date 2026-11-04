module Crystalize
  # Dépôt git de l'application : chemin local, ou URL distante dont un
  # miroir est tenu à jour dans le cache (`repos/`). L'authentification
  # reste celle de git : agent SSH, alias de `~/.ssh/config`, gestionnaire
  # d'identifiants HTTPS, ou clé dédiée (`app.ssh_key`).
  class Source
    def initialize(@app : Config::App, @base_dir : String)
    end

    # `git@hôte:org/app.git`, `hôte:chemin`, `ssh://…`, `https://…`,
    # `file://…` ; tout le reste est un chemin local.
    def self.remote?(repository : String) : Bool
      repository.includes?("://") || repository.matches?(/\A[^\/:\s]+:/)
    end

    def remote? : Bool
      Source.remote?(@app.repository)
    end

    # Dépôt à interroger (miroir mis à jour pour une URL).
    def repository : String
      @repository ||= remote? ? mirror : File.expand_path(@app.repository, @base_dir)
    end

    # Commit et date (epoch) de la pointe de `branch`.
    def resolve(branch : String) : {String, Int64}
      commit = git("rev-parse", "--verify", "#{branch}^{commit}")
      {commit, git("show", "-s", "--format=%ct", commit).to_i64}
    end

    # Arbre du commit, extrait dans `target`.
    def export(commit : String, target : String) : Nil
      Crystalize.step "Extraction de #{commit[0, 12]} depuis #{@app.repository}"
      archive = File.join(File.dirname(target), "source.tar")
      Shell.run("git", ["-C", repository, "archive", "--format=tar", "-o", archive, commit], env: env)
      Shell.run("tar", ["-xf", archive, "-C", target])
      File.delete(archive)
    end

    def env : Hash(String, String?)
      Source.ssh_env(@app.ssh_key, @base_dir, "app.ssh_key")
    end

    # Clé SSH dédiée (`ssh_key`), relative à `base_dir` : chemin absolu
    # vérifié, ou nil pour s'en remettre à l'agent SSH.
    def self.ssh_key_path(key : String?, base_dir : String, label : String) : String?
      return unless key
      path = File.expand_path(key, base_dir, home: true)
      raise Error.new("#{label} introuvable : #{path}") unless File.exists?(path)
      raise Error.new("#{label} ne doit pas contenir d'apostrophe : #{path}") if path.includes?('\'')
      path
    end

    def self.ssh_env(key : String?, base_dir : String, label : String) : Hash(String, String?)
      extra = {} of String => String
      if path = ssh_key_path(key, base_dir, label)
        extra["GIT_SSH_COMMAND"] = "ssh -i '#{path}' -o IdentitiesOnly=yes"
      end
      Shell.clean_env(extra)
    end

    private def mirror : String
      url = @app.repository
      path = File.join(Crystalize.cache_dir, "repos", "#{@app.name}-#{Digest::SHA256.hexdigest(url)[0, 8]}.git")
      if File.exists?(File.join(path, "HEAD"))
        Crystalize.step "Mise à jour du miroir de #{url}"
        Shell.run("git", ["-C", path, "remote", "set-url", "origin", url], env: env)
        Shell.run("git", ["-C", path, "fetch", "--prune", "--tags", "origin"], env: env)
      else
        Crystalize.step "Miroir de #{url}"
        FileUtils.rm_rf(path)
        Dir.mkdir_p(File.dirname(path))
        Shell.run("git", ["clone", "--mirror", url, path], env: env)
      end
      path
    end

    private def git(*args : String) : String
      Shell.capture("git", ["-C", repository] + args.to_a, env: env).strip
    end
  end
end
