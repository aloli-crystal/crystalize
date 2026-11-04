# frozen_string_literal: true

# Injecté par crystalize : le service Active Storage (GED) est choisi par la
# configuration d'exécution du lanceur.
#
#   CRYSTALIZE_STORAGE_MODE  none | clear | encrypted
#   CRYSTALIZE_STORAGE_PATH  dossier des fichiers
#   CRYSTALIZE_STORAGE_KEY   clé AES-256 en Base64 (mode encrypted)
mode = ENV.fetch("CRYSTALIZE_STORAGE_MODE", "none")

if mode != "none" && Rails.application.config.respond_to?(:active_storage)
  root = ENV.fetch("CRYSTALIZE_STORAGE_PATH")
  service =
    case mode
    when "clear" then { "service" => "Disk", "root" => root }
    when "encrypted" then { "service" => "EncryptedDisk", "root" => root, "key" => ENV.fetch("CRYSTALIZE_STORAGE_KEY") }
    else raise ArgumentError, "crystalize : mode de stockage inconnu : #{mode.inspect}"
    end

  storage = Rails.application.config.active_storage
  file = Rails.root.join("config/storage.yml")
  base = file.exist? ? ActiveSupport::ConfigurationFile.parse(file) : {}
  storage.service_configurations = base.merge("crystalize" => service)
  storage.service = :crystalize
  if mode == "encrypted"
    # Les fichiers chiffrés ne peuvent pas être servis tels quels depuis le disque.
    require "active_storage/service/encrypted_disk_service"
    storage.resolve_model_to_route = :rails_storage_proxy
    Rails.application.config.to_prepare do
      ActiveStorage::DiskController.prepend(ActiveStorage::EncryptedDiskStreaming)
    end
  end
end
