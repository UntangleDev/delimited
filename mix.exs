defmodule Delimited.MixProject do
  use Mix.Project

  @source_url "https://github.com/UntangleDev/delimited"
  @version "0.3.0"

  def project do
    [
      app: :delimited,
      version: @version,
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      description: description(),
      package: package(),
      name: "Delimited",
      source_url: @source_url,
      homepage_url: @source_url,
      docs: docs()
    ]
  end

  defp deps do
    [
      {:decimal, "~> 2.0 or ~> 3.0", optional: true},
      {:benchee, "~> 1.5", only: :dev},
      {:credo, "~> 1.7", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: :dev, runtime: false},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      {:stream_data, "~> 1.1", only: :test}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp description do
    "Declarative schemas for reading and writing CSV, TSV, fixed-width, and other flat files"
  end

  defp package do
    [
      maintainers: ["Billy Grant"],
      licenses: ["MIT"],
      links: %{
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md",
        "GitHub" => @source_url,
        "HexDocs" => "https://hexdocs.pm/delimited"
      },
      files: ~w(lib mix.exs README.md CHANGELOG.md LICENSE .formatter.exs)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      source_url: @source_url,
      extras: ["README.md", "CHANGELOG.md", "LICENSE"],
      groups_for_modules: [
        Schemas: [Delimited.Schema, Delimited.Field],
        Formats: [Delimited.Dialect],
        Types: [Delimited.Type],
        Errors: [Delimited.Error]
      ]
    ]
  end
end
