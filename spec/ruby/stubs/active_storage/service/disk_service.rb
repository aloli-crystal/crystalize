# frozen_string_literal: true

# Bouchon minimal d'Active Storage pour tester EncryptedDiskService sans Rails.
# Fournit seulement ce que le service utilise : DiskService (racine, chemins,
# instrument, delete) et les deux erreurs.
require "fileutils"

module ActiveStorage
  class IntegrityError < StandardError; end
  class FileNotFoundError < StandardError; end

  class Service
    class DiskService
      def initialize(root:, public: false, **)
        @root = root
      end

      def delete(key)
        FileUtils.rm_f(path_for(key))
      end

      private
        def instrument(_operation, **)
          yield
        end

        def path_for(key)
          File.join(@root, key)
        end

        def make_path_for(key)
          path_for(key).tap { |path| FileUtils.mkdir_p(File.dirname(path)) }
        end
    end
  end
end
