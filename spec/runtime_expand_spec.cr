# Composant testé : Crystalize::Runtime#expand (${VAR} et ${VAR:-défaut}).
# Cas couverts : variable présente, absente, vide, nulle, repli sur ENV du
# processus, valeur par défaut vide ou contenant « :- », plusieurs variables,
# syntaxes non reconnues laissées intactes.
# Dépendances : aucune. La méthode étant privée, la spec rouvre la classe pour
# exposer un accesseur de test (src/ n'est pas modifié).
require "./spec_helper"

class Crystalize::Runtime
  def expand_for_spec(arg : String, env : Hash(String, String?)) : String
    expand(arg, env)
  end
end

private def expand(arg : String, env = {} of String => String?) : String
  info = Crystalize::Payload::Info.new("x", 0_i64, 0_i64, Bytes.new(32))
  Crystalize::Runtime.new(info).expand_for_spec(arg, env)
end

describe "Runtime#expand" do
  it "remplace ${VAR} par la valeur de l'environnement final" do
    expand("-p${PORT}", {"PORT" => "8080"} of String => String?).should eq("-p8080")
  end

  it "utilise le défaut quand la variable est absente" do
    expand("${CRYSTALIZE_SPEC_ABSENT:-3000}").should eq("3000")
  end

  it "utilise le défaut quand la variable est vide ou nulle" do
    expand("${A:-d}", {"A" => ""} of String => String?).should eq("d")
    expand("${A:-d}", {"A" => nil} of String => String?).should eq("d")
  end

  it "préfère la valeur à son défaut" do
    expand("${A:-d}", {"A" => "v"} of String => String?).should eq("v")
  end

  it "renvoie une chaîne vide pour ${VAR} absente sans défaut" do
    expand("[${CRYSTALIZE_SPEC_ABSENT}]").should eq("[]")
  end

  it "accepte un défaut vide" do
    expand("[${CRYSTALIZE_SPEC_ABSENT:-}]").should eq("[]")
  end

  it "garde « :- » dans le défaut" do
    expand("${CRYSTALIZE_SPEC_ABSENT:-a:-b}").should eq("a:-b")
  end

  it "se replie sur l'environnement du processus si la variable n'est pas dans le hash" do
    ENV["CRYSTALIZE_SPEC_PROC"] = "proc"
    begin
      expand("${CRYSTALIZE_SPEC_PROC}").should eq("proc")
    ensure
      ENV.delete("CRYSTALIZE_SPEC_PROC")
    end
  end

  it "donne priorité au hash sur l'environnement du processus (même nul)" do
    ENV["CRYSTALIZE_SPEC_PROC"] = "proc"
    begin
      expand("${CRYSTALIZE_SPEC_PROC:-def}", {"CRYSTALIZE_SPEC_PROC" => nil} of String => String?).should eq("def")
    ensure
      ENV.delete("CRYSTALIZE_SPEC_PROC")
    end
  end

  it "remplace plusieurs variables dans un même argument" do
    expand("${A}-${B:-x}-${A}", {"A" => "1"} of String => String?).should eq("1-x-1")
  end

  it "laisse intactes les syntaxes non reconnues" do
    expand("$A").should eq("$A")
    expand("${}").should eq("${}")
    expand("${A").should eq("${A")
    expand("rien").should eq("rien")
  end

  it "ne réexpanse pas une valeur contenant elle-même ${...}" do
    expand("${A}", {"A" => "${B}"} of String => String?).should eq("${B}")
  end
end
