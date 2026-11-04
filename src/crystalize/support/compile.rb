# frozen_string_literal: true

# Lancé par `crystalize build` avec le Ruby embarqué : compile chaque
# source listée en pseudo-code YARV (`<source>.yarb`).
#
#   ruby compile.rb RACINE BASE LISTE SORTIE STRIP
#
# Les fichiers sont compilés sous le chemin BASE/<relatif> (préfixe fictif
# réécrit par le lanceur à l'extraction), pour que `__FILE__`, `__dir__`
# et `require_relative` désignent l'emplacement réel à l'exécution.
root, base, list, output, strip = ARGV
# Bouchon : `require`/`load` passent par le crochet `load_iseq` et ne le
# lisent jamais. S'il est relu comme source (`eval(File.read(f), …, f)`,
# cas des locales I18n), il exécute lui-même son pseudo-code ; seul un
# `instance_eval` (DSL) échoue, avec un message explicite.
stub = <<~'RUBY'
  # crystalize : source livrée en pseudo-code YARV (<fichier>.yarb)
  ::File.exist?("#{__FILE__}.yarb") ? ::RubyVM::InstructionSequence.load_from_binary(::File.binread("#{__FILE__}.yarb")).eval : ::Kernel.raise(::LoadError, "crystalize : #{__FILE__} est relu comme source ; ajoutez-le à compile.exclude")
RUBY
compiled = []
skipped = 0

File.foreach(list, chomp: true) do |rel|
  source = File.join(root, rel)
  code = File.read(source, mode: "r:UTF-8")
  # `DATA`/`__END__` relit le fichier source : il doit rester en clair.
  if code.b.match?(/^__END__\r?$/)
    skipped += 1
    next
  end

  path = File.join(base, rel)
  iseq = RubyVM::InstructionSequence.compile(code, path, path, 1)
  File.binwrite("#{source}.yarb", iseq.to_binary)
  if strip == "1"
    File.chmod(File.stat(source).mode | 0o200, source) # certaines gems sont livrées en 0444
    File.write(source, stub)
  end
  compiled << "#{rel}.yarb"
rescue SyntaxError, StandardError => e
  skipped += 1
  warn "crystalize : #{rel} laissé en source (#{e.class} : #{e.message.lines.first&.strip})"
end

File.write(output, compiled.join("\n") << "\n")
warn "crystalize : #{compiled.size} fichiers compilés, #{skipped} laissés en source"
