# Composant testé : Crystalize::Runtime#run("extract") — refus d'un state_dir
# contenant un blanc ou « : » (testable sans exec : la commande « extract »
# n'appelle pas Process.exec).
# Cas couverts : espace, tabulation, « : » refusés avant toute extraction ;
# state_dir valide extrait la version.
# Dépendances : aucune. La sortie standard de « extract » est capturée par
# l'exécution (puts), non vérifiée ici.
require "./spec_helper"
require "compress/gzip"

private def payload_with_manifest(dir : String) : Crystalize::Payload::Info
  manifest = Crystalize::Manifest.new("demo", "main", "a" * 40, 1_i64, "3.4.2", "x86_64-linux",
    "0.0.0", Crystalize::PLACEHOLDER, 0, %w[test], Crystalize::Config::Runtime.new)
  archive = File.join(dir, "archive")
  File.open(archive, "w") do |file|
    Compress::Gzip::Writer.open(file) do |gzip|
      writer = Crystalize::Tar::Writer.new(gzip, 0_i64)
      {Crystalize::Manifest::PATH => manifest.to_yaml, ".crystalize/compiled.txt" => ""}.each do |name, content|
        source = File.join(dir, "src")
        File.write(source, content)
        writer.add_file(name, source, false)
      end
      writer.add_dir("app")
      writer.finish
    end
  end
  File.write(File.join(dir, "launcher"), "L")
  output = File.join(dir, "exe")
  Crystalize::Payload.write(output, File.join(dir, "launcher"), archive)
  Crystalize::Payload.locate(output).not_nil!
end

private def run_extract(dir : String, state_dir : String) : Nil
  config = File.join(dir, "demo.yml")
  File.write(config, "state_dir: #{state_dir.inspect}\n")
  Crystalize::Runtime.new(payload_with_manifest(dir)).run(["-c", config, "extract"])
end

describe "Runtime : contrôle de state_dir" do
  {"avec espace" => "mon etat", "avec deux-points" => "a:b", "avec tabulation" => "a\tb"}.each do |label, name|
    it "refuse un state_dir #{label}" do
      with_tempdir do |dir|
        target = File.join(dir, name)
        expect_raises(Crystalize::Error, /state_dir ne doit contenir ni/) { run_extract(dir, target) }
        Dir.exists?(File.join(target, "releases")).should be_false
      end
    end
  end

  it "accepte un state_dir ordinaire et extrait la version" do
    with_tempdir do |dir|
      target = File.join(dir, "etat")
      run_extract(dir, target)
      Dir.children(File.join(File.realpath(target), "releases")).size.should eq(1)
    end
  end
end
