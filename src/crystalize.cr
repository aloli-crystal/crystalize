require "digest/sha256"
require "file_utils"
require "yaml"
require "./crystalize/version"
require "./crystalize/shell"
require "./crystalize/platform"
require "./crystalize/config"
require "./crystalize/manifest"
require "./crystalize/tar"
require "./crystalize/payload"
require "./crystalize/support"
require "./crystalize/ruby_builder"
require "./crystalize/source"
require "./crystalize/builder"
require "./crystalize/runtime_config"
require "./crystalize/secrets"
require "./crystalize/runtime"
require "./crystalize/packager"
require "./crystalize/port"

# Empaquette une application Ruby (Rails) en un exécutable unique :
# lanceur Crystal + charge utile (Ruby relocatable, gems, code de
# l'application précompilé en pseudo-code YARV).
module Crystalize
  # Préfixe fictif sous lequel les fichiers sont compilés. Le lanceur
  # extrait chaque version dans un dossier dont le chemin réel a exactement
  # cette longueur, et l'y substitue octet pour octet dans les `.yarb` :
  # `__FILE__` et `__dir__` désignent alors de vrais chemins.
  PLACEHOLDER = "/@crystalize-root@".ljust(160, '@')

  def self.cache_dir : String
    ENV["CRYSTALIZE_CACHE"]? || File.join(ENV["XDG_CACHE_HOME"]? || File.join(Path.home.to_s, ".cache"), "crystalize")
  end

  def self.step(message : String) : Nil
    STDERR.puts "==> #{message}"
  end

  def self.warn(message : String) : Nil
    STDERR.puts "crystalize : attention : #{message}"
  end
end
