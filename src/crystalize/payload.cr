require "compress/gzip"

module Crystalize
  # Charge utile ajoutée en fin d'exécutable :
  #
  #   [lanceur][tar.gz][sha256 : 32 o][taille : u64 LE][MAGIC : 8 o]
  module Payload
    MAGIC   = "CRYSTLZ1"
    TRAILER = 48

    record Info, executable : String, offset : Int64, size : Int64, sha256 : Bytes do
      # Identifiant de version, nom du dossier d'extraction.
      def id : String
        sha256.hexstring[0, 16]
      end

      def open(& : IO ->)
        File.open(executable) do |file|
          file.seek(offset)
          yield IO::Sized.new(file, size)
        end
      end

      # Lit le manifeste sans extraire : il est la première entrée de l'archive.
      def manifest : Manifest
        open do |io|
          Compress::Gzip::Reader.open(io) do |gzip|
            Tar::Reader.new(gzip).each do |entry|
              return Manifest.from_yaml(entry.io.gets_to_end) if entry.name == Manifest::PATH
            end
          end
        end
        raise Error.new("manifeste absent de la charge utile")
      end
    end

    def self.locate(executable : String) : Info?
      File.open(executable) do |file|
        total = file.size.to_i64
        return nil if total < TRAILER
        file.seek(total - TRAILER)
        trailer = Bytes.new(TRAILER)
        file.read_fully(trailer)
        return nil unless String.new(trailer[40, 8]) == MAGIC
        size = IO::ByteFormat::LittleEndian.decode(Int64, trailer[32, 8])
        unless 0 <= size <= total - TRAILER
          raise Error.new("#{executable} : remorque crystalize incohérente (charge utile de #{size} octets)")
        end
        Info.new(executable, total - TRAILER - size, size, trailer[0, 32].dup)
      end
    end

    # Taille du lanceur seul (sans charge utile éventuelle).
    def self.launcher_size(executable : String) : Int64
      locate(executable).try(&.offset) || File.size(executable).to_i64
    end

    # Écrit `output` = lanceur + `archive` + bande-annonce.
    def self.write(output : String, launcher : String, archive : String) : Nil
      digest = Digest::SHA256.new
      File.open(archive) do |file|
        buffer = Bytes.new(64 * 1024)
        while (read = file.read(buffer)) > 0
          digest.update(buffer[0, read])
        end
      end
      size = File.size(archive).to_i64

      Dir.mkdir_p(File.dirname(output))
      File.open(output, "w") do |target|
        File.open(launcher) { |file| IO.copy(file, target, launcher_size(launcher)) }
        File.open(archive) { |file| IO.copy(file, target) }
        target.write(digest.final)
        target.write_bytes(size, IO::ByteFormat::LittleEndian)
        target << MAGIC
      end
      File.chmod(output, 0o755)
    end
  end
end
