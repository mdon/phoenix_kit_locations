defmodule PhoenixKitLocations.MixProject do
  use Mix.Project

  @version "0.2.0"
  @source_url "https://github.com/BeamLabEU/phoenix_kit_locations"

  def project do
    [
      app: :phoenix_kit_locations,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description:
        "Locations module for PhoenixKit — manage physical locations with custom types.",
      package: package(),
      dialyzer: [plt_add_apps: [:phoenix_kit]],
      name: "PhoenixKitLocations",
      source_url: @source_url,
      docs: docs(),
      aliases: aliases()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :phoenix_kit]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp aliases do
    [
      quality: ["format", "credo --strict", "dialyzer"],
      "quality.ci": ["format --check-formatted", "credo --strict", "dialyzer"],
      precommit: [
        "compile --force --warnings-as-errors",
        "deps.unlock --check-unused",
        "quality.ci"
      ],
      # Schema is applied by `test_helper.exs` on every `mix test` run
      # via `PhoenixKit.Migration.ensure_current/2` — no `ecto.migrate`
      # step here.
      "test.setup": [
        "ecto.create --quiet -r PhoenixKitLocations.Test.Repo"
      ],
      "test.reset": [
        "ecto.drop --quiet -r PhoenixKitLocations.Test.Repo",
        "test.setup"
      ]
    ]
  end

  defp deps do
    [
      # 1.7.125 first shipped migration V122 (`phoenix_kit_location_spaces`),
      # the table the Spaces feature reads and writes. Older cores miss the
      # table entirely; 1.7.105 also introduced
      # `PhoenixKit.Migration.ensure_current/2` (consumed by
      # `test/test_helper.exs`), so 1.7.125 covers both floors.
      {:phoenix_kit, "~> 1.7.125"},
      {:phoenix_live_view, "~> 1.1"},
      {:ex_doc, "~> 0.39", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:lazy_html, ">= 0.1.0", only: :test}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib .formatter.exs mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "PhoenixKitLocations",
      source_ref: "v#{@version}"
    ]
  end
end
