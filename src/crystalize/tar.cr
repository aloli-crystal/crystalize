module Crystalize
  # Archive tar (ustar + en-têtes PAX pour les noms longs), écrite de façon
  # déterministe : ordre trié, date, propriétaire et droits normalisés.
  module Tar
    BLOCK = 512

    # Motif de refus d'un lien `name -> target` de l'archive, ou nil s'il
    # reste dedans. La cible est suivie composant par composant : passer
    # par un autre lien de l'archive (`links`) est refusé, car le « .. »
    # qui suit ne serait plus résolu là où le texte le laisse croire.
    def self.link_error(name : String, target : String, links : Set(String)) : String?
      return "cible vide" if target.empty?
      return "cible absolue" if target.starts_with?('/')
      parts = name.split('/')[0...-1]
      components = target.split('/').reject { |part| part.empty? || part == "." }
      components.each_with_index do |component, index|
        if component == ".."
          return "sort de l'archive" if parts.empty?
          parts.pop
        else
          parts << component
          if index < components.size - 1 && links.includes?(parts.join('/'))
            return "traverse le lien #{parts.join('/')}"
          end
        end
      end
      nil
    end

    class Writer
      @links = {} of String => String

      def initialize(@io : IO, @mtime : Int64)
      end

      def add_dir(name : String) : Nil
        header(name.ends_with?('/') ? name : "#{name}/", 0, 0o755, '5')
      end

      def add_file(name : String, source : String, executable : Bool) : Nil
        size = File.size(source)
        header(name, size, executable ? 0o755 : 0o644, '0')
        File.open(source) { |file| IO.copy(file, @io) }
        pad(size)
      end

      def add_symlink(name : String, target : String) : Nil
        header(name, 0, 0o777, '2', target)
        @links[name] = target
      end

      # Ajoute récursivement `source` sous le nom `prefix`, en ignorant les
      # chemins (relatifs à `source`) pour lesquels `skip` est vrai.
      def add_tree(source : String, prefix : String, &skip : String -> Bool) : Nil
        walk(source, "") do |rel|
          next true if skip.call(rel)
          name = prefix.empty? ? rel : "#{prefix}/#{rel}"
          path = File.join(source, rel)
          info = File.info(path, follow_symlinks: false)
          case info.type
          when .directory? then add_dir(name)
          when .symlink?   then add_symlink(name, File.readlink(path))
          when .file?      then add_file(name, path, info.permissions.owner_execute?)
          end
          false
        end
      end

      # Même contrôle qu'à l'extraction : un lien refusé fait échouer la
      # construction plutôt que le premier lancement.
      def check_links : Nil
        names = @links.keys.to_set
        @links.each do |name, target|
          if reason = Tar.link_error(name, target, names)
            raise Error.new("lien refusé dans l'archive (#{reason}) : #{name} -> #{target}")
          end
        end
      end

      def finish : Nil
        @io.write(Bytes.new(BLOCK * 2))
      end

      private def walk(base : String, rel : String, &visit : String -> Bool) : Nil
        Dir.children(rel.empty? ? base : File.join(base, rel)).sort!.each do |child|
          child_rel = rel.empty? ? child : "#{rel}/#{child}"
          next if visit.call(child_rel)
          full = File.join(base, child_rel)
          walk(base, child_rel, &visit) if File.info(full, follow_symlinks: false).directory?
        end
      end

      private def header(name : String, size : Int64 | Int32, mode : Int32, type : Char, link : String = "") : Nil
        if name.bytesize > 100 || link.bytesize > 100
          records = String.build do |str|
            str << pax_record("path", name) if name.bytesize > 100
            str << pax_record("linkpath", link) if link.bytesize > 100
          end
          raw_header("././@PaxHeader", records.bytesize, 0o644, 'x', "")
          @io << records
          pad(records.bytesize)
        end
        raw_header(name, size, mode, type, link)
      end

      private def raw_header(name : String, size : Int64 | Int32, mode : Int32, type : Char, link : String) : Nil
        block = Bytes.new(BLOCK)
        put(block, 0, 100, name)
        put(block, 100, 8, octal(mode, 7))
        put(block, 108, 8, octal(0, 7))
        put(block, 116, 8, octal(0, 7))
        put(block, 124, 12, octal(size, 11))
        put(block, 136, 12, octal(@mtime, 11))
        block[156] = type.ord.to_u8
        put(block, 157, 100, link)
        put(block, 257, 6, "ustar")
        put(block, 263, 2, "00")
        put(block, 265, 32, "root")
        put(block, 297, 32, "wheel")
        (148...156).each { |i| block[i] = ' '.ord.to_u8 }
        sum = block.sum(0)
        put(block, 148, 8, octal(sum, 6) + "\0 ")
        @io.write(block)
      end

      private def put(block : Bytes, offset : Int32, length : Int32, value : String) : Nil
        bytes = value.to_slice
        bytes = bytes[0, length] if bytes.size > length
        bytes.copy_to(block[offset, bytes.size])
      end

      private def octal(value, width : Int32) : String
        value.to_s(8).rjust(width, '0')
      end

      private def pax_record(key : String, value : String) : String
        body = " #{key}=#{value}\n"
        length = body.bytesize
        while length.to_s.bytesize + body.bytesize != length
          length += 1
        end
        "#{length}#{body}"
      end

      private def pad(size) : Nil
        rest = (BLOCK - size % BLOCK) % BLOCK
        @io.write(Bytes.new(rest)) if rest > 0
      end
    end

    record Entry, name : String, type : Char, mode : Int32, size : Int64, link : String, io : IO

    class Reader
      def initialize(@io : IO)
      end

      def each(& : Entry ->) : Nil
        pending = {} of String => String
        block = Bytes.new(BLOCK)
        loop do
          @io.read_fully(block)
          break if block.all?(&.zero?)
          name = field(block, 0, 100)
          prefix = field(block, 345, 155)
          name = "#{prefix}/#{name}" if field(block, 257, 5) == "ustar" && !prefix.empty?
          size = number(block, 124, 12)
          type = block[156].chr
          link = field(block, 157, 100)
          data = IO::Sized.new(@io, size)
          case type
          when 'x'
            parse_pax(data.gets_to_end, pending)
          when 'L'
            pending["path"] = data.gets_to_end.rstrip('\0')
          when 'g'
            # en-tête PAX global : sans effet ici
          else
            name = pending.delete("path") || name
            link = pending.delete("linkpath") || link
            pending.clear
            yield Entry.new(name, type, number(block, 100, 8).to_i32, size, link, data)
          end
          data.skip_to_end
          rest = (BLOCK - size % BLOCK) % BLOCK
          @io.skip(rest) if rest > 0
        end
      end

      private def field(block : Bytes, offset : Int32, length : Int32) : String
        bytes = block[offset, length]
        stop = bytes.index(0_u8) || length
        String.new(bytes[0, stop])
      end

      private def number(block : Bytes, offset : Int32, length : Int32) : Int64
        text = field(block, offset, length).strip
        text.empty? ? 0_i64 : text.to_i64(8)
      end

      private def parse_pax(text : String, into : Hash(String, String)) : Nil
        rest = text
        until rest.empty?
          space = rest.index(' ') || break
          length = rest[0, space].to_i
          record = rest.byte_slice(space + 1, length - space - 2)
          key, _, value = record.partition('=')
          into[key] = value
          rest = rest.byte_slice(length, rest.bytesize - length)
        end
      end
    end
  end
end
