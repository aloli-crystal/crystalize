module Crystalize
  # Fichiers Ruby livrés avec chaque application (lus à la compilation).
  module Support
    BOOT                   = {{ read_file("#{__DIR__}/support/boot.rb") }}
    COMPILE                = {{ read_file("#{__DIR__}/support/compile.rb") }}
    INITIALIZER            = {{ read_file("#{__DIR__}/support/initializer.rb") }}
    ENCRYPTED_DISK_SERVICE = {{ read_file("#{__DIR__}/support/encrypted_disk_service.rb") }}
  end
end
