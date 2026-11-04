# frozen_string_literal: true

require "openssl"
require "securerandom"
require "active_storage/service/disk_service"

module ActiveStorage
  # Service disque (livré par crystalize) dont les fichiers sont chiffrés en
  # AES-256-GCM, par blocs de 64 Kio pour permettre lectures partielles et
  # flux sans tout déchiffrer :
  #
  #   "CZE1" | préfixe de nonce (8 o) | bloc chiffré + étiquette (16 o) | …
  #
  # Nonce d'un bloc = préfixe + numéro (u32 BE) ; les données authentifiées
  # lient chaque bloc à sa clé de blob, à son rang et au fait qu'il soit le
  # dernier (troncature et permutation détectées).
  class Service::EncryptedDiskService < Service::DiskService
    MAGIC = "CZE1".b
    PREFIX = 8
    HEADER = MAGIC.bytesize + PREFIX
    CHUNK = 64 * 1024
    TAG = 16

    def initialize(root:, key:, public: false, **options)
      super(root: root, public: public, **options)
      @secret = key.unpack1("m0")
      raise ArgumentError, "EncryptedDisk : la clé doit faire 32 octets (Base64)" unless @secret.bytesize == 32
    end

    def upload(key, io, checksum: nil, **)
      instrument :upload, key: key, checksum: checksum do
        md5 = OpenSSL::Digest::MD5.new
        begin
          write_sealed(key, io, md5)
        rescue StandardError
          # Pas de fichier partiel (source illisible ou altérée en cours de
          # compose, disque plein…).
          delete key
          raise
        end

        if checksum && md5.base64digest != checksum
          delete key
          raise ActiveStorage::IntegrityError
        end
      end
    end

    def download(key, &block)
      if block_given?
        instrument :streaming_download, key: key do
          each_plain_chunk(key, &block)
        end
      else
        instrument :download, key: key do
          String.new(encoding: Encoding::BINARY).tap { |data| each_plain_chunk(key) { |chunk| data << chunk } }
        end
      end
    end

    def download_chunk(key, range)
      instrument :download_chunk, key: key, range: range do
        String.new(encoding: Encoding::BINARY).tap { |data| each_range_chunk(key, range) { |chunk| data << chunk } }
      end
    end

    # Le résultat est rechiffré bloc par bloc, sans copie en clair sur disque.
    def compose(source_keys, destination_key, **)
      chunks = Enumerator.new do |output|
        source_keys.each { |source_key| each_plain_chunk(source_key) { |chunk| output << chunk } }
      end
      upload(destination_key, ChunkReader.new(chunks))
    end

    # Taille du contenu en clair.
    def plain_size(key)
      with_file(key) { |_file, _prefix, layout| layout[:size] }
    end

    # Cède en clair, bloc par bloc, les octets de `range` (bornes incluses ou
    # non, fin éventuellement absente) ; seuls les blocs concernés sont lus.
    def each_range_chunk(key, range)
      with_file(key) do |file, prefix, layout|
        first = range.begin || 0
        last = range.end.nil? ? layout[:size] - 1 : (range.exclude_end? ? range.end - 1 : range.end)
        last = [ last, layout[:size] - 1 ].min
        next if first > last

        (first / CHUNK..last / CHUNK).each do |index|
          chunk = open_chunk(file, key, prefix, layout, index)
          start = index * CHUNK
          from = [ first - start, 0 ].max
          to = [ last - start, chunk.bytesize - 1 ].min
          yield chunk.byteslice(from, to - from + 1)
        end
      end
    end

    # Lecteur paresseux (`read`) sur une suite de blocs en clair.
    class ChunkReader
      def initialize(chunks)
        @chunks = chunks
        @buffer = String.new(encoding: Encoding::BINARY)
      end

      def read(length)
        begin
          @buffer << @chunks.next while @buffer.bytesize < length
        rescue StopIteration
        end
        @buffer.empty? ? nil : @buffer.slice!(0, length)
      end
    end

    private
      def write_sealed(key, io, md5)
        File.open(make_path_for(key), "wb") do |file|
          prefix = SecureRandom.random_bytes(PREFIX)
          file.write(MAGIC, prefix)
          index = 0
          current = read_chunk(io)
          loop do
            following = read_chunk(io)
            md5 << current
            file.write(seal(key, prefix, index, current, following.empty?))
            break if following.empty?

            current = following
            index += 1
          end
        end
      end

      def read_chunk(io)
        buffer = String.new(encoding: Encoding::BINARY)
        while buffer.bytesize < CHUNK && (data = io.read(CHUNK - buffer.bytesize))
          buffer << data
        end
        buffer
      end

      def seal(key, prefix, index, plain, final)
        cipher = OpenSSL::Cipher.new("aes-256-gcm").encrypt
        cipher.key = @secret
        cipher.iv = prefix + [ index ].pack("N")
        cipher.auth_data = associated(key, index, final)
        (plain.empty? ? "".b : cipher.update(plain)) + cipher.final + cipher.auth_tag
      end

      def associated(key, index, final)
        "#{key}\0".b + [ index, final ? 1 : 0 ].pack("NC")
      end

      def each_plain_chunk(key)
        with_file(key) do |file, prefix, layout|
          layout[:count].times { |index| yield open_chunk(file, key, prefix, layout, index) }
        end
      end

      def with_file(key)
        File.open(path_for(key), "rb") do |file|
          raise ActiveStorage::IntegrityError, "EncryptedDisk : en-tête invalide (#{key})" unless file.read(MAGIC.bytesize) == MAGIC

          prefix = file.read(PREFIX)
          yield file, prefix, layout_for(file.size)
        end
      rescue Errno::ENOENT
        raise ActiveStorage::FileNotFoundError
      end

      def layout_for(file_size)
        body = file_size - HEADER
        full, rest = body.divmod(CHUNK + TAG)
        raise ActiveStorage::IntegrityError, "EncryptedDisk : fichier tronqué" if rest.between?(1, TAG - 1) || body < TAG

        count = full + (rest.zero? ? 0 : 1)
        { count: count, size: full * CHUNK + (rest.zero? ? 0 : rest - TAG) }
      end

      def open_chunk(file, key, prefix, layout, index)
        final = index == layout[:count] - 1
        file.seek(HEADER + index * (CHUNK + TAG))
        sealed = file.read(final ? layout[:size] - index * CHUNK + TAG : CHUNK + TAG)
        cipher = OpenSSL::Cipher.new("aes-256-gcm").decrypt
        cipher.key = @secret
        cipher.iv = prefix + [ index ].pack("N")
        cipher.auth_tag = sealed.byteslice(-TAG, TAG)
        cipher.auth_data = associated(key, index, final)
        body = sealed.byteslice(0, sealed.bytesize - TAG)
        (body.empty? ? "".b : cipher.update(body)) + cipher.final
      rescue OpenSSL::Cipher::CipherError
        raise ActiveStorage::IntegrityError, "EncryptedDisk : bloc #{index} de #{key} altéré ou mauvaise clé"
      end
  end

  # `DiskController#show` sert le fichier directement depuis le disque : pour
  # un service chiffré, on diffuse le contenu déchiffré bloc par bloc, en
  # honorant une requête `Range` d'une seule plage. Comme `Rack::Files` :
  # plusieurs plages donnent le contenu entier (200), sauf si leur somme
  # dépasse la taille du fichier (416, `get_byte_ranges` renvoyant `[]`).
  module EncryptedDiskStreaming
    def show
      key = decode_verified_key
      service = key && named_disk_service(key[:service_name])
      return super unless service.is_a?(Service::EncryptedDiskService)

      size = service.plain_size(key[:key])
      ranges = Rack::Utils.get_byte_ranges(request.get_header("HTTP_RANGE"), size)
      response.headers["Accept-Ranges"] = "bytes"
      if ranges&.empty?
        response.headers["Content-Range"] = "bytes */#{size}"
        return head(:range_not_satisfiable)
      end

      range = 0..(size - 1)
      if ranges&.one?
        range = ranges.first
        self.status = :partial_content
        response.headers["Content-Range"] = "bytes #{range.begin}-#{range.end}/#{size}"
      end
      response.headers["Content-Type"] = key[:content_type] || "application/octet-stream"
      response.headers["Content-Disposition"] = key[:disposition] if key[:disposition]
      response.headers["Content-Length"] = range.size.to_s
      self.response_body = Enumerator.new { |output| service.each_range_chunk(key[:key], range) { |chunk| output << chunk } }
    rescue ActiveStorage::FileNotFoundError
      head :not_found
    end
  end
end
