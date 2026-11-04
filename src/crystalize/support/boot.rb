# frozen_string_literal: true

# Chargé par le lanceur crystalize (RUBYOPT=-rcrystalize/boot, trouvé via
# RUBYLIB=<version>/.crystalize/lib) avant tout autre code :
# les fichiers livrés en pseudo-code YARV (`<source>.yarb`, la source
# elle-même n'étant plus qu'un bouchon) sont chargés par `require`/`load`
# via le crochet `RubyVM::InstructionSequence.load_iseq`.
module Crystalize
  ROOT = ENV.fetch("CRYSTALIZE_ROOT").freeze
  ROOT_PREFIX = "#{ROOT}/"
end

class RubyVM::InstructionSequence
  def self.load_iseq(path)
    return unless path.start_with?(Crystalize::ROOT_PREFIX)

    binary = "#{path}.yarb"
    load_from_binary(File.binread(binary)) if File.exist?(binary)
  end
end
