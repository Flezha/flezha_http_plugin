defmodule FlezhaHttp.MixProject do
  use Mix.Project

  # The HTTP server plugin, packaged with `mix flezha.plugin.package` and loaded
  # by a Flezha controller at boot. `flezha` is the core this package is a
  # submodule of, two directories up, until it is published.
  def project do
    [
      app: :flezha_http,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      aliases: [test: "test --no-start"],
      # The e2e fixture is a project of its own, run by test/e2e/run.sh.
      test_ignore_filters: [&String.starts_with?(&1, "test/e2e/")],
      package: [licenses: ["Apache-2.0"]]
    ]
  end

  # No `mod`: each provider's declared worker is its plugin's one process, and
  # the controller supervises it.
  def application do
    [
      env: [
        flezha_providers: %{
          "http_server" => FlezhaHttp.Provider,
          "http_api" => FlezhaHttp.ApiProvider
        }
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:flezha, path: "../.."},
      {:bandit, "~> 1.10"},
      {:plug, "~> 1.18"}
    ]
  end
end
