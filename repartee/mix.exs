defmodule Repartee.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/nrepl/nrepl-beam"

  def project do
    [
      app: :repartee,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "A spec-faithful nREPL server for Elixir",
      package: package(),
      docs: [main: "readme", extras: ["README.md"]]
    ]
  end

  # Deliberately no application module: repartee never autostarts a server.
  # Embed Repartee.Server in your supervision tree or run mix repartee.server.
  def application do
    [extra_applications: [:dialtone]]
  end

  defp deps do
    [
      # TODO: switch to {:dialtone, "~> 0.1"} once dialtone is on hex
      {:dialtone, path: "../dialtone", manager: :rebar3}
    ]
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url}
    ]
  end
end
