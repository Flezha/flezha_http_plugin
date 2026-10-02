defmodule Chat.MixProject do
  use Mix.Project

  # The end-to-end fixture: an Elixir SDK runner serving a chat gateway behind the
  # plugin, its per-session agents, a pinger that runs in steps and an echo. It is a test,
  # not an example: `test/e2e/run.sh` builds and starts it. The SDK is the one in
  # the core checkout beside this repository.
  def project do
    [
      app: :chat,
      version: "0.1.0",
      elixir: "~> 1.17",
      deps: [{:flezha_sdk, path: "../../../../../sdk/elixir"}]
    ]
  end

  def application do
    [mod: {Chat.Application, []}, extra_applications: [:logger]]
  end
end
