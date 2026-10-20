defmodule FlezhaHttp.CatalogueTest do
  @moduledoc """
  The plugin's codes live in the core's one catalogue. Built against a core that
  lacks one, this suite fails, not a user's request.
  """
  use ExUnit.Case, async: true

  @catalogue Mix.Project.deps_paths()[:flezha]
             |> Path.join("flz_transport/errors.json")
             |> File.read!()
             |> Jason.decode!()

  test "every code the plugin's source names is in the catalogue" do
    codes = Map.keys(@catalogue["codes"])
    families = MapSet.new(codes, &hd(String.split(&1, ".")))

    named =
      for file <- Path.wildcard("lib/**/*.ex"),
          [_, code] <- Regex.scan(~r/"([a-z][a-z0-9_]*\.[a-z][a-z0-9_]*)"/, File.read!(file)),
          String.split(code, ".") |> hd() |> then(&MapSet.member?(families, &1)),
          uniq: true,
          do: code

    assert "http.answer_invalid" in named

    assert named -- codes == [],
           "not in flz_transport/errors.json: #{Enum.join(named -- codes, ", ")}"
  end

  test "the tagged reasons map to their codes" do
    code = "http.listen_failed"
    assert Map.has_key?(@catalogue["codes"], code), "#{code} is not in the catalogue"

    assert %Flezha.Error{code: ^code} =
             Flezha.Error.from_reason({:http_listen_failed, %{plugin: "p"}}, nil)

    refute Map.has_key?(@catalogue["codes"], "http.partitioned_host")
  end
end
