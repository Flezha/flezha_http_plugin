defmodule FlezhaHttp.McpTest do
  use ExUnit.Case, async: true

  alias FlezhaHttp.Mcp

  @types ~w(string integer boolean object array)
  @keywords ~w(type description enum minimum maximum)

  test "every catalogue entry has its own tool name, one a model API accepts" do
    names = Enum.map(Flezha.Service.catalogue(), &Mcp.tool_name(&1.name))

    assert length(Enum.uniq(names)) == length(names)
    assert Enum.all?(names, &Regex.match?(~r/\A[a-zA-Z0-9_-]{1,64}\z/, &1))
    assert Mcp.tool_name("PluginManager.enable") == "plugin_manager_enable"
    assert Mcp.tool_name("Dlq.list") == "dlq_list"
  end

  # The keywords a schema uses are checked against JSON Schema 2020-12's own
  # rules for them: an object schema, typed properties, required names that are
  # properties, bounds that are integers.
  test "every tool's input schema is a valid JSON Schema object" do
    for entry <- Flezha.Service.catalogue() do
      schema =
        entry |> Mcp.tool() |> Map.fetch!(:inputSchema) |> Jason.encode!() |> Jason.decode!()

      assert schema["type"] == "object"
      assert schema["additionalProperties"] == false
      assert is_map(schema["properties"])
      assert Map.get(schema, "required", ["x"]) != []
      assert Enum.all?(Map.get(schema, "required", []), &Map.has_key?(schema["properties"], &1))

      for {name, property} <- schema["properties"] do
        assert Map.keys(property) -- @keywords == [], "#{entry.name}.#{name}"
        assert Map.get(property, "type", "string") in @types, "#{entry.name}.#{name}"
        assert is_binary(property["description"])

        for bound <- ~w(minimum maximum),
            Map.has_key?(property, bound),
            do: assert(is_integer(property[bound]))

        if enum = property["enum"], do: assert(enum != [] and Enum.all?(enum, &is_binary/1))
      end
    end
  end

  test "readOnlyHint holds only for an operation whose row writes no audit" do
    tools = Map.new(Flezha.Service.catalogue(), &{&1.name, Mcp.tool(&1)})

    assert tools["Dlq.list"].annotations.readOnlyHint
    refute tools["Operator.start"].annotations.readOnlyHint
    refute tools["AuditLog.read"].annotations.readOnlyHint
    assert tools["Dlq.drop"].annotations.destructiveHint
    refute tools["Dlq.replay"].annotations.destructiveHint
    assert tools["Operator.start"].description =~ "`operator.start`"
  end
end
