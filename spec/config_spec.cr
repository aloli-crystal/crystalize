# Composant testé : Crystalize::Config (crystalize.yml).
# Cas couverts : valeurs par défaut de chaque section, surcharges, clé
# « include », DEFAULT_EXCLUDE / DEFAULT_PRUNE, erreurs (nom manquant, YAML
# invalide), absence de partage des tableaux par défaut entre instances.
# Dépendances : aucune.
require "./spec_helper"

private def minimal : Crystalize::Config
  Crystalize::Config.from_yaml("app:\n  name: demo\n")
end

describe Crystalize::Config do
  it "applique les valeurs par défaut" do
    config = minimal
    config.app.name.should eq("demo")
    config.app.repository.should eq(".")
    config.app.branch.should eq("production")
    config.ruby.version.should be_nil
    config.ruby.sha256.should be_nil
    config.bundle.without.should eq(%w[development test])
    config.bundle.jobs.should eq(4)
    config.bundle.strip_native.should be_true
    config.build.env.should be_empty
    config.build.commands.should be_empty
    config.compile.enabled.should be_true
    config.compile.strip_sources.should be_true
    config.compile.patterns.should eq(Crystalize::Config::Compile::DEFAULT_PATTERNS)
    config.compile.exclude.should eq(Crystalize::Config::Compile::DEFAULT_EXCLUDE)
    config.runtime.env.should eq({"RAILS_ENV" => "production"})
    config.runtime.default_command.should eq("serve")
    config.runtime.writable.should eq(%w[log tmp storage])
    config.runtime.rails.should be_true
    config.prune.should be_empty
    config.output.should be_nil
  end

  it "définit les commandes par défaut avec expansion ${VAR:-défaut}" do
    commands = minimal.runtime.commands
    commands.keys.should contain("serve")
    commands["serve"].should eq(["bin/rails", "server", "-b", "${BIND:-127.0.0.1}", "-p", "${PORT:-3000}"])
    commands[minimal.runtime.default_command]?.should_not be_nil
  end

  it "exclut par défaut les fichiers DSL relus en source" do
    exclude = Crystalize::Config::Compile::DEFAULT_EXCLUDE
    %w[config/puma.rb config/importmap.rb config/ci.rb **/templates/** **/test/** **/spec/**].each do |pattern|
      exclude.should contain(pattern)
    end
  end

  it "retire par défaut les clés et dossiers sensibles (DEFAULT_PRUNE)" do
    prune = Crystalize::Config::DEFAULT_PRUNE
    %w[.git config/master.key config/credentials/*.key node_modules test spec].each do |pattern|
      prune.should contain(pattern)
    end
  end

  it "lit les surcharges, dont la clé « include »" do
    yaml = <<-YAML
      app:
        name: demo
        branch: main
      ruby:
        version: 3.4.2
      bundle:
        jobs: 8
        without: [test]
      compile:
        include: ["app/**/*.rb"]
        exclude: ["app/skip.rb"]
        enabled: false
      runtime:
        default_command: console
        commands:
          console: [bin/rails, console]
      prune: [tmp]
      output: build/demo
      YAML
    config = Crystalize::Config.from_yaml(yaml)
    config.app.branch.should eq("main")
    config.ruby.version.should eq("3.4.2")
    config.bundle.jobs.should eq(8)
    config.bundle.without.should eq(%w[test])
    config.compile.patterns.should eq(["app/**/*.rb"])
    config.compile.exclude.should eq(["app/skip.rb"])
    config.compile.enabled.should be_false
    config.runtime.commands.keys.should eq(["console"])
    config.runtime.default_command.should eq("console")
    config.prune.should eq(%w[tmp])
    config.output.should eq("build/demo")
  end

  it "lit un fichier avec Config.load" do
    with_tempdir do |dir|
      path = File.join(dir, "crystalize.yml")
      File.write(path, "app:\n  name: fromfile\n")
      Crystalize::Config.load(path).app.name.should eq("fromfile")
    end
  end

  it "signale un YAML invalide avec le chemin du fichier" do
    with_tempdir do |dir|
      path = File.join(dir, "crystalize.yml")
      File.write(path, "app: [unclosed\n")
      expect_raises(Crystalize::Error, /crystalize\.yml/) { Crystalize::Config.load(path) }
    end
  end

  it "signale l'absence de app.name" do
    with_tempdir do |dir|
      path = File.join(dir, "crystalize.yml")
      File.write(path, "app:\n  branch: x\n")
      expect_raises(Crystalize::Error, /name/) { Crystalize::Config.load(path) }
    end
  end

  it "ne partage pas les tableaux par défaut entre instances (ni avec la constante)" do
    one = minimal
    two = minimal
    one.compile.patterns << "zzz/**/*.rb"
    two.compile.patterns.should_not contain("zzz/**/*.rb")
    Crystalize::Config::Compile::DEFAULT_PATTERNS.should_not contain("zzz/**/*.rb")
  end
end
