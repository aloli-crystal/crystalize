module Crystalize
  # Métadonnées écrites en tête de charge utile (`.crystalize/manifest.yml`).
  class Manifest
    include YAML::Serializable

    PATH = ".crystalize/manifest.yml"

    property app : String
    property branch : String
    property commit : String
    property commit_time : Int64
    property ruby_version : String
    property platform : String
    property crystalize_version : String
    property placeholder : String
    property compiled : Int32
    property bundle_without : Array(String)
    property runtime : Config::Runtime

    def initialize(@app, @branch, @commit, @commit_time, @ruby_version, @platform,
                   @crystalize_version, @placeholder, @compiled, @bundle_without, @runtime)
    end
  end
end
