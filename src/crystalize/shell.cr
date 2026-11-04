module Crystalize
  class Error < Exception
  end

  # Lancement de commandes externes dans un environnement assaini.
  module Shell
    # Variables héritées (chruby, rbenv, bundler…) qui détourneraient le
    # Ruby embarqué vers un autre interpréteur ou d'autres gems.
    POLLUTING = %w[
      GEM_HOME GEM_PATH GEM_ROOT RUBYOPT RUBYLIB RUBY_ROOT RUBY_ENGINE
      RUBY_VERSION RUBY_PATCHLEVEL BUNDLER_VERSION BUNDLER_SETUP
    ]

    # Environnement à passer à `Process` : variables polluantes retirées,
    # puis `extra` appliqué par-dessus.
    def self.clean_env(extra : Hash(String, String) = {} of String => String) : Hash(String, String?)
      env = {} of String => String?
      POLLUTING.each { |key| env[key] = nil }
      ENV.keys.each { |key| env[key] = nil if key.starts_with?("BUNDLE_") }
      extra.each { |key, value| env[key] = value }
      env
    end

    def self.run(command : String, args : Array(String) = [] of String, *,
                 env : Hash(String, String?) = clean_env, chdir : String? = nil) : Nil
      STDERR.puts "    $ #{command} #{args.join(' ')}"
      status = Process.run(command, args, env: env, chdir: chdir,
        input: Process::Redirect::Inherit, output: Process::Redirect::Inherit, error: Process::Redirect::Inherit)
      raise Error.new("échec (code #{status.exit_code}) : #{command} #{args.join(' ')}") unless status.success?
    rescue ex : File::NotFoundError
      raise Error.new("commande introuvable : #{command}")
    end

    # Exécute un script `sh -c`, pour les commandes de construction écrites
    # en clair dans la configuration (le `PATH` de `env` y est honoré).
    def self.sh(script : String, *, env : Hash(String, String?), chdir : String) : Nil
      run("/bin/sh", ["-c", script], env: env, chdir: chdir)
    end

    def self.capture(command : String, args : Array(String), *,
                     env : Hash(String, String?) = clean_env, chdir : String? = nil) : String
      output = IO::Memory.new
      status = Process.run(command, args, env: env, chdir: chdir,
        input: Process::Redirect::Inherit, output: output, error: Process::Redirect::Inherit)
      raise Error.new("échec (code #{status.exit_code}) : #{command} #{args.join(' ')}") unless status.success?
      output.to_s
    rescue ex : File::NotFoundError
      raise Error.new("commande introuvable : #{command}")
    end
  end
end
