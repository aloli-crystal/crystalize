# frozen_string_literal: true

# Composant testé : ActiveStorage::Service::EncryptedDiskService
# (src/crystalize/support/encrypted_disk_service.rb) : each_range_chunk,
# plain_size, download_chunk, compose, ChunkReader.
# Cas couverts : plage à fin absente, exclusive, inclusive, au-delà de la
# taille, début au-delà de la taille, fichier vide, plusieurs blocs de 64 Kio
# (frontières exactes), ChunkReader.read jusqu'à épuisement, compose.
# Dépendances : Ruby système + minitest + openssl, sans Rails : le service est
# chargé avec un bouchon d'Active Storage (spec/ruby/stubs). Lancement :
#   ruby -Ispec/ruby/stubs spec/ruby/encrypted_disk_service_test.rb
require "minitest/autorun"
require "stringio"
require "tmpdir"
require "active_storage/service/disk_service"
require_relative "../../src/crystalize/support/encrypted_disk_service"

class EncryptedDiskServiceTest < Minitest::Test
  CHUNK = ActiveStorage::Service::EncryptedDiskService::CHUNK

  def setup
    @root = Dir.mktmpdir("crystalize-eds")
    @service = ActiveStorage::Service::EncryptedDiskService.new(root: @root, key: ["k" * 32].pack("m0"))
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def sample(size)
    Array.new(size) { |i| i % 251 }.pack("C*")
  end

  def store(key, data)
    @service.upload(key, StringIO.new(data))
    data
  end

  def range_of(key, range)
    out = "".b
    @service.each_range_chunk(key, range) { |chunk| out << chunk }
    out
  end

  def test_plain_size_de_fichiers_de_tailles_variees
    [ 0, 1, 100, CHUNK - 1, CHUNK, CHUNK + 1, 2 * CHUNK, 2 * CHUNK + 5 ].each do |size|
      store("k#{size}", sample(size))
      assert_equal size, @service.plain_size("k#{size}"), "taille #{size}"
    end
  end

  def test_fichier_vide
    store("vide", "")
    assert_equal 0, @service.plain_size("vide")
    assert_equal "", range_of("vide", 0..)
    assert_equal "", range_of("vide", 0..10)
    assert_equal "", @service.download("vide")
    assert_equal "", @service.download_chunk("vide", 0..5)
  end

  def test_plage_a_fin_absente
    data = store("a", sample(100))
    assert_equal data, range_of("a", 0..)
    assert_equal data[10..], range_of("a", 10..)
  end

  def test_plage_inclusive_et_exclusive
    data = store("b", sample(100))
    assert_equal data[10..20], range_of("b", 10..20)
    assert_equal data[10...20], range_of("b", 10...20)
    assert_equal 10, range_of("b", 10...20).bytesize
    assert_equal data[0, 1], range_of("b", 0..0)
  end

  def test_plage_exclusive_vide
    store("c", sample(100))
    assert_equal "", range_of("c", 10...10)
  end

  def test_plage_au_dela_de_la_taille_est_tronquee
    data = store("d", sample(100))
    assert_equal data[90..], range_of("d", 90..10_000)
    assert_equal data[90..], range_of("d", 90...10_000)
  end

  def test_debut_au_dela_de_la_taille_ne_renvoie_rien
    store("e", sample(100))
    assert_equal "", range_of("e", 100..200)
    assert_equal "", range_of("e", 5000..)
  end

  def test_plusieurs_blocs_toute_la_plage
    data = store("f", sample(2 * CHUNK + 1234))
    assert_equal data, range_of("f", 0..)
    assert_equal data, @service.download("f")
  end

  def test_plage_a_cheval_sur_une_frontiere_de_bloc
    data = store("g", sample(3 * CHUNK + 10))
    assert_equal data[CHUNK - 5..CHUNK + 4], range_of("g", (CHUNK - 5)..(CHUNK + 4))
    assert_equal data[CHUNK - 5..2 * CHUNK + 4], range_of("g", (CHUNK - 5)..(2 * CHUNK + 4))
  end

  def test_frontieres_exactes
    data = store("h", sample(2 * CHUNK))
    assert_equal data[CHUNK, 1], range_of("h", CHUNK..CHUNK)
    assert_equal data[CHUNK - 1, 1], range_of("h", (CHUNK - 1)..(CHUNK - 1))
    assert_equal data[0, CHUNK], range_of("h", 0...CHUNK)
    assert_equal data[CHUNK..], range_of("h", CHUNK...(2 * CHUNK))
    assert_equal data[-1], range_of("h", (2 * CHUNK - 1)..)
  end

  def test_seuls_les_blocs_concernes_sont_lus
    store("i", sample(3 * CHUNK))
    chunks = []
    @service.each_range_chunk("i", (CHUNK + 1)..(CHUNK + 3)) { |chunk| chunks << chunk }
    assert_equal 1, chunks.size
    assert_equal 3, chunks.first.bytesize
  end

  def test_download_chunk_renvoie_une_chaine_binaire
    data = store("j", sample(CHUNK + 50))
    result = @service.download_chunk("j", 10..(CHUNK + 20))
    assert_equal data[10..CHUNK + 20], result
    assert_equal Encoding::BINARY, result.encoding
  end

  def test_compose_concatene_et_rechiffre
    first = store("p1", sample(CHUNK + 7))
    second = store("p2", sample(100))
    third = store("p3", "")
    @service.compose(%w[p1 p2 p3], "tout")
    assert_equal first + second + third, @service.download("tout")
    assert_equal first.bytesize + second.bytesize, @service.plain_size("tout")
  end

  def test_compose_en_echec_ne_laisse_pas_de_fichier_partiel
    store("p1", sample(3 * CHUNK))
    assert_raises(ActiveStorage::FileNotFoundError) { @service.compose(%w[p1 absent], "tout") }
    refute File.exist?(File.join(@root, "tout"))
  end

  def test_upload_en_echec_ne_laisse_pas_de_fichier_partiel
    source = Object.new
    calls = 0
    source.define_singleton_method(:read) do |length|
      calls += 1
      raise IOError, "source coupée" if calls > 2
      "x" * length
    end
    assert_raises(IOError) { @service.upload("coupe", source) }
    refute File.exist?(File.join(@root, "coupe"))
  end

  def test_compose_de_sources_vides
    store("v1", "")
    @service.compose(%w[v1], "v2")
    assert_equal 0, @service.plain_size("v2")
  end

  def test_fichier_absent
    assert_raises(ActiveStorage::FileNotFoundError) { @service.plain_size("absent") }
  end

  def test_contenu_chiffre_sur_disque
    store("k", "secret en clair")
    refute_includes File.binread(File.join(@root, "k")), "secret en clair"
  end

  def test_bloc_altere_est_detecte
    store("alt", sample(100))
    path = File.join(@root, "alt")
    bytes = File.binread(path)
    bytes.setbyte(20, bytes.getbyte(20) ^ 1)
    File.binwrite(path, bytes)
    assert_raises(ActiveStorage::IntegrityError) { range_of("alt", 0..) }
  end

  class ChunkReaderTest < Minitest::Test
    Reader = ActiveStorage::Service::EncryptedDiskService::ChunkReader

    def reader(*chunks)
      Reader.new(chunks.each)
    end

    def test_lit_par_morceaux_jusqu_a_epuisement
      r = reader("abc", "def", "g")
      assert_equal "ab", r.read(2)
      assert_equal "cdef", r.read(4)
      assert_equal "g", r.read(10)
      assert_nil r.read(10)
      assert_nil r.read(1)
    end

    def test_lecture_plus_grande_que_le_total
      assert_equal "abcdef", reader("abc", "def").read(1000)
    end

    def test_sans_blocs
      assert_nil reader.read(5)
    end

    def test_blocs_vides_ignores
      r = reader("", "ab", "")
      assert_equal "ab", r.read(5)
      assert_nil r.read(5)
    end

    def test_lecture_exacte_puis_nil
      r = reader("abcd")
      assert_equal "abcd", r.read(4)
      assert_nil r.read(4)
    end

    def test_accumule_sur_plusieurs_blocs_de_64_kio
      big = "x".b * (64 * 1024)
      r = reader(big, big, "fin")
      total = 0
      while (data = r.read(50_000))
        total += data.bytesize
      end
      assert_equal 2 * 64 * 1024 + 3, total
    end
  end
end
