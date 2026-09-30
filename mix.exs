defmodule ExSchematron.MixProject do
  use Mix.Project

  def project do
    [
      app: :ex_schematron,
      version: "0.1.0",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  def cli do
    [preferred_envs: ["test.conformance": :test]]
  end

  defp aliases do
    ["test.conformance": ["test --only conformance"]]
  end

  # xpath/ compiles into this app instead of being a path dependency: when ex_schematron is itself
  # a git dependency, Mix recompiles it after every `mix deps.get` because of the path dependency.
  defp elixirc_paths(:test), do: ["lib", "xpath/lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib", "xpath/lib"]

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      # Generated validators embed Decimal literals directly; the conformance
      # suite drives Saxy itself to write testcase fixtures.
      {:decimal, "~> 2.0 or ~> 3.0"},
      {:saxy, "~> 1.6"}
    ]
  end
end
