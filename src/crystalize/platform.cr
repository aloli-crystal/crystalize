module Crystalize
  # Plate-forme courante. Le Ruby et les extensions natives ne sont pas
  # portables : un binaire se construit sur le système qui l'exécutera.
  module Platform
    def self.os : String
      {% if flag?(:darwin) %}
        "darwin"
      {% elsif flag?(:freebsd) %}
        "freebsd"
      {% elsif flag?(:linux) %}
        "linux"
      {% else %}
        "unknown"
      {% end %}
    end

    def self.arch : String
      {% if flag?(:aarch64) %}
        "arm64"
      {% elsif flag?(:x86_64) %}
        "x86_64"
      {% else %}
        "unknown"
      {% end %}
    end

    def self.name : String
      "#{os}-#{arch}"
    end

    # Options `./configure` par défaut pour trouver OpenSSL, libyaml et
    # libffi hors du système de base.
    def self.default_configure_opts : Array(String)
      case os
      when "darwin"
        base = {"/opt/homebrew/opt", "/usr/local/opt"}.find { |dir| Dir.exists?(dir) }
        return [] of String unless base
        {"openssl" => "openssl@3", "libyaml" => "libyaml", "libffi" => "libffi"}
          .select { |_, formula| Dir.exists?(File.join(base, formula)) }
          .map { |option, formula| "--with-#{option}-dir=#{File.join(base, formula)}" }
      when "freebsd"
        ["--with-opt-dir=/usr/local"]
      else
        [] of String
      end
    end
  end
end
