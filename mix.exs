defmodule MobSpeech.MixProject do
  use Mix.Project

  @source_url "https://github.com/GenericJam/mob_speech"

  def project do
    [
      app: :mob_speech,
      version: "0.1.1",
      elixir: "~> 1.17",
      deps: deps(),
      aliases: aliases(),
      description:
        "Speech-to-text for Mob apps: Android SpeechRecognizer / iOS SFSpeechRecognizer, " <>
          "pluggable engines, scriptable fake for tests",
      package: package(),
      docs: [
        main: "readme",
        extras: ["README.md", "CHANGELOG.md"]
      ],
      source_url: @source_url
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp aliases do
    # `mix setup` after cloning installs deps and activates the shared git
    # hooks (.githooks): format / Credo --strict / compile run on every push
    # and the full suite when mix.exs changes — the same gate CI enforces.
    [setup: ["deps.get", "cmd git config core.hooksPath .githooks"]]
  end

  defp deps do
    # :mob_dev is test-only (the manifest tests run the real pre-publish
    # validator; CI's release job signs with `mix mob.plugin.sign`) and never
    # ships.
    [
      {:ex_ast, "~> 0.12", only: [:dev, :test], runtime: false},
      {:reach, "~> 2.7", only: [:dev, :test], runtime: false},
      {:recon, "~> 2.5", only: [:dev, :test]},
      {:mob, "~> 0.9 and >= 0.9.15"},
      {:mob_dev, "~> 0.7.17", only: [:dev, :test], runtime: false},
      # Code quality — Credo + ex_slop (AI-pattern checks) + jump_credo_checks,
      # mirroring mob core's pre-commit gate.
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.4.2", only: [:dev, :test], runtime: false},
      {:jump_credo_checks, "~> 0.1.0", only: [:dev, :test], runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      # The native sources + manifest must ship in the package — the host's
      # native build compiles them from deps/<plugin>/priv.
      files: ~w(lib src priv mix.exs README* CHANGELOG*)
    ]
  end
end
