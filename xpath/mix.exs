defmodule ExSchematron.XPath.MixProject do
  use Mix.Project

  def project do
    [
      app: :ex_schematron_xpath,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      # Share the parent project's deps, lock and build: the sub-package is
      # developed inside the ex_schematron repository.
      deps_path: "../deps",
      lockfile: "../mix.lock",
      build_path: "../_build",
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
      {:decimal, "~> 2.0 or ~> 3.0"}
    ]
  end
end
