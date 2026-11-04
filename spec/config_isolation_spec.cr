# Composant testé : Crystalize::Config::Compile (valeurs par défaut non partagées).
# Cas couverts : modifier patterns / exclude d'une instance ne change ni une
# autre instance ni les constantes DEFAULT_PATTERNS / DEFAULT_EXCLUDE.
# Dépendances : aucune.
require "./spec_helper"

private def minimal : Crystalize::Config
  Crystalize::Config.from_yaml("app:\n  name: demo\n")
end

describe Crystalize::Config::Compile do
  it "isole patterns entre instances et par rapport à la constante" do
    patterns = Crystalize::Config::Compile::DEFAULT_PATTERNS.dup
    one = minimal
    two = minimal
    one.compile.patterns << "zzz/**/*.rb"
    one.compile.patterns.clear
    two.compile.patterns.should eq(patterns)
    minimal.compile.patterns.should eq(patterns)
    Crystalize::Config::Compile::DEFAULT_PATTERNS.should eq(patterns)
  end

  it "isole exclude entre instances et par rapport à la constante" do
    exclude = Crystalize::Config::Compile::DEFAULT_EXCLUDE.dup
    one = minimal
    two = minimal
    one.compile.exclude << "zzz/**"
    one.compile.exclude.delete("config/puma.rb")
    two.compile.exclude.should eq(exclude)
    minimal.compile.exclude.should eq(exclude)
    Crystalize::Config::Compile::DEFAULT_EXCLUDE.should eq(exclude)
  end

  it "renvoie des tableaux distincts de la constante" do
    config = minimal
    config.compile.patterns.same?(Crystalize::Config::Compile::DEFAULT_PATTERNS).should be_false
    config.compile.exclude.same?(Crystalize::Config::Compile::DEFAULT_EXCLUDE).should be_false
  end

  it "isole aussi une instance construite directement" do
    one = Crystalize::Config::Compile.new
    two = Crystalize::Config::Compile.new
    one.patterns << "x"
    one.exclude << "y"
    two.patterns.should_not contain("x")
    two.exclude.should_not contain("y")
  end
end
