defmodule FlezhaHttp.DocsTest do
  use ExUnit.Case, async: true

  alias Flezha.Plugin.ProviderBehaviour.Options

  @docs Path.join(Mix.Project.deps_paths()[:flezha], "docs/plugins")

  for {provider, page} <- [
        {FlezhaHttp.Provider, "http_server.md"},
        {FlezhaHttp.ApiProvider, "http_api.md"}
      ] do
    test "#{page} carries the option table #{inspect(provider)}'s declaration renders" do
      page = Path.join(@docs, unquote(page))
      rendered = Options.render_options_table(unquote(provider))

      documented =
        page
        |> File.read!()
        |> String.split("<!-- provider-options:begin -->\n")
        |> Enum.at(1, "")
        |> String.split("<!-- provider-options:end -->")
        |> hd()

      assert documented == rendered,
             "#{page}'s option table has drifted from #{inspect(unquote(provider))}'s declaration.\n" <>
               "Replace the block between the provider-options markers with:\n\n" <> rendered
    end
  end
end
