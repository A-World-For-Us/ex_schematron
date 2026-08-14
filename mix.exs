defmodule ExSchematron.MixProject do
  use Mix.Project

  def project do
    [
      app: :ex_schematron,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:saxy, "~> 1.6"},
      {:decimal, "~> 2.0"}
    ]
  end
end
