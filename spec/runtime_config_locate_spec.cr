# Composant testé : Crystalize::RuntimeConfig (.locate, .load, state_path,
# env_strings, resolve).
# Cas couverts : ordre de recherche (explicite > $<APP>_CONFIG > ./<app>.yml),
# fichier explicite absent, valeurs par défaut, YAML invalide, XDG_DATA_HOME,
# conversion des valeurs d'environnement, chemins relatifs et « ~ ».
# Dépendances : aucune. Les chemins /usr/local/etc et /etc ne sont pas testés
# (hors du dossier temporaire).
require "./spec_helper"

private def with_env(values : Hash(String, String?), &)
  saved = values.keys.to_h { |key| {key, ENV[key]?} }
  values.each { |key, value| value ? (ENV[key] = value) : ENV.delete(key) }
  begin
    yield
  ensure
    saved.each { |key, value| value ? (ENV[key] = value) : ENV.delete(key) }
  end
end

private def app_name : String
  "crystalize-spec-#{Random::Secure.hex(4)}"
end

describe Crystalize::RuntimeConfig do
  describe ".locate" do
    it "renvoie les valeurs par défaut quand aucun fichier n'existe" do
      with_tempdir do |dir|
        app = app_name
        variable = "#{app.upcase.gsub(/[^A-Z0-9]/, '_')}_CONFIG"
        with_env({variable => nil}) do
          Dir.cd(dir) do
            config = Crystalize::RuntimeConfig.locate(app, nil)
            config.state_dir.should be_nil
            config.source.should be_nil
            config.secrets.should be_nil
            config.storage.mode.should eq("none")
            config.storage.path.should be_nil
            config.env.should be_empty
          end
        end
      end
    end

    it "charge le fichier explicite et refuse un fichier explicite introuvable" do
      with_tempdir do |dir|
        path = File.join(dir, "x.yml")
        File.write(path, "state_dir: /srv/x\n")
        Crystalize::RuntimeConfig.locate("app", path).state_dir.should eq("/srv/x")
        expect_raises(Crystalize::Error, /introuvable/) do
          Crystalize::RuntimeConfig.locate("app", File.join(dir, "absent.yml"))
        end
      end
    end

    it "préfère le fichier explicite à la variable d'environnement et au fichier local" do
      with_tempdir do |dir|
        app = app_name
        variable = "#{app.upcase.gsub(/[^A-Z0-9]/, '_')}_CONFIG"
        File.write(File.join(dir, "explicit.yml"), "state_dir: /explicit\n")
        File.write(File.join(dir, "env.yml"), "state_dir: /env\n")
        File.write(File.join(dir, "#{app}.yml"), "state_dir: /local\n")
        with_env({variable => File.join(dir, "env.yml")}) do
          Dir.cd(dir) do
            Crystalize::RuntimeConfig.locate(app, File.join(dir, "explicit.yml")).state_dir.should eq("/explicit")
          end
        end
      end
    end

    it "préfère $<APP>_CONFIG au fichier ./<app>.yml" do
      with_tempdir do |dir|
        app = app_name
        variable = "#{app.upcase.gsub(/[^A-Z0-9]/, '_')}_CONFIG"
        File.write(File.join(dir, "env.yml"), "state_dir: /env\n")
        File.write(File.join(dir, "#{app}.yml"), "state_dir: /local\n")
        with_env({variable => File.join(dir, "env.yml")}) do
          Dir.cd(dir) { Crystalize::RuntimeConfig.locate(app, nil).state_dir.should eq("/env") }
        end
      end
    end

    it "retombe sur ./<app>.yml quand la variable pointe vers un fichier absent" do
      with_tempdir do |dir|
        app = app_name
        variable = "#{app.upcase.gsub(/[^A-Z0-9]/, '_')}_CONFIG"
        File.write(File.join(dir, "#{app}.yml"), "state_dir: /local\n")
        with_env({variable => File.join(dir, "nope.yml")}) do
          Dir.cd(dir) { Crystalize::RuntimeConfig.locate(app, nil).state_dir.should eq("/local") }
        end
      end
    end

    it "dérive le nom de la variable en remplaçant les caractères non alphanumériques par « _ »" do
      with_tempdir do |dir|
        File.write(File.join(dir, "e.yml"), "state_dir: /viaenv\n")
        with_env({"CRYSTALIZE_SPEC_MY_APP_CONFIG" => File.join(dir, "e.yml")}) do
          Dir.cd(dir) do
            Crystalize::RuntimeConfig.locate("crystalize-spec.my app", nil)
            Crystalize::RuntimeConfig.locate("crystalize-spec-my-app", nil).state_dir.should eq("/viaenv")
          end
        end
      end
    end

    it "renseigne source et base_dir avec le chemin absolu du fichier" do
      with_tempdir do |dir|
        path = File.join(dir, "c.yml")
        File.write(path, "state_dir: rel\n")
        config = Crystalize::RuntimeConfig.locate("app", path)
        config.source.should eq(File.expand_path(path))
        config.base_dir.should eq(File.dirname(File.expand_path(path)))
      end
    end
  end

  describe ".load" do
    it "signale un YAML invalide avec le chemin du fichier" do
      with_tempdir do |dir|
        path = File.join(dir, "bad.yml")
        File.write(path, "env: [oops\n")
        expect_raises(Crystalize::Error, /bad\.yml/) { Crystalize::RuntimeConfig.load(path) }
      end
    end
  end

  describe "#state_path" do
    it "utilise XDG_DATA_HOME/<app> par défaut" do
      with_env({"XDG_DATA_HOME" => "/xdg"}) do
        Crystalize::RuntimeConfig.new.state_path("demo").should eq("/xdg/demo")
      end
    end

    it "utilise ~/.local/share/<app> sans XDG_DATA_HOME" do
      with_env({"XDG_DATA_HOME" => nil}) do
        Crystalize::RuntimeConfig.new.state_path("demo").should eq(File.join(Path.home.to_s, ".local", "share", "demo"))
      end
    end

    it "garde un state_dir absolu et résout « ~ »" do
      config = Crystalize::RuntimeConfig.from_yaml("state_dir: /var/db/x\n")
      config.state_path("demo").should eq("/var/db/x")
      config.state_dir = "~/x"
      config.state_path("demo").should eq(File.join(Path.home.to_s, "x"))
    end
  end

  describe "#env_strings" do
    it "convertit nul, entiers, booléens et flottants en chaînes" do
      config = Crystalize::RuntimeConfig.from_yaml("env:\n  A: 3000\n  B: true\n  C: ~\n  D: 1.5\n  E: texte\n")
      config.env_strings.should eq({"A" => "3000", "B" => "true", "C" => "", "D" => "1.5", "E" => "texte"})
    end
  end

  describe "#storage" do
    it "accepte les trois modes documentés" do
      Crystalize::RuntimeConfig::Storage::MODES.should eq(%w[none clear encrypted])
    end
  end
end
