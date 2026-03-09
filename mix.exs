defmodule PgInspect.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :pg_inspect,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      package: package(),
      description: description(),
      test_coverage: [tool: ExCoveralls],
      # Docs
      name: "PgInspect",
      source_url: "https://github.com/hlindset/pg_inspect",
      docs: &docs/0
    ]
  end

  defp package do
    [
      name: "pg_inspect",
      licenses: ["MIT", "Apache-2.0"],
      source_url: "https://github.com/hlindset/pg_inspect",
      homepage_url: "https://github.com/hlindset/pg_inspect",
      links: %{
        "GitHub" => "https://github.com/hlindset/pg_inspect"
      },
      files: ~w(lib libpg_query checksum.exs .formatter.exs mix.exs README* LICENSE*
        CHANGELOG*)
    ]
  end

  defp description do
    """
    Elixir library with a Zigler NIF (backed by libpg_query) for parsing,
    fingerprinting, normalizing and truncating PostgreSQL queries.
    """
  end

  defp docs do
    [
      # The main page in the docs
      main: "README",
      extras: ["README.md"]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp preferred_cli_env do
    %{
      coveralls: :test,
      "coveralls.detail": :test,
      "coveralls.post": :test,
      "coveralls.html": :test,
      "coveralls.json": :test,
      "coveralls.lcov": :test,
      "coveralls.cobertura": :test,
      "test.watch": :test
    }
  end

  def cli do
    [
      preferred_envs: preferred_cli_env()
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:protox, "~> 2.0"},
      {:zigler, "~> 0.15.2", runtime: false},
      {:benchee, "~> 1.3", only: :dev, runtime: false},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:mix_test_watch, "~> 1.4", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18", only: :test},
      {:junit_formatter, "~> 3.4", only: :test}
    ]
  end
end
