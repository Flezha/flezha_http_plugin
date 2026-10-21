defmodule FlezhaHttp.ProviderTest do
  # Not async: "validation starts nothing" counts every process of the node.
  use ExUnit.Case, async: false

  alias Flezha.Plugin.ProviderBehaviour.Options
  alias FlezhaHttp.Provider

  @host %{source_namespace: "default", source_relay_id: "gateway", source_plugin_id: "web"}

  defp prepare(opts) do
    with {:ok, opts} <- Options.normalise_opts(Provider, opts) do
      Provider.init_provider(Map.merge(opts, @host))
    end
  end

  test "port and channel alone take every default, loopback first" do
    assert {:ok, opts} = prepare(%{port: 18_080, channel: "http"})

    assert %{
             bind: "127.0.0.1",
             entry_channel: "http",
             deadline_ms: 30_000,
             max_body_bytes: 1_048_576,
             max_waiting: 1_000,
             max_streams: 1_000,
             pass_headers: [],
             heartbeat_ms: 15_000,
             stream_wait_ms: 5_000
           } = opts
  end

  test "each rule refuses its option by name" do
    assert {:error, {:invalid_option_value, :bind, "localhost"}} =
             prepare(%{port: 18_080, channel: "http", bind: "localhost"})

    assert {:error, {:invalid_option_value, :pass_headers, "X-Api-Key"}} =
             prepare(%{port: 18_080, channel: "http", pass_headers: "X-Api-Key"})

    assert {:error, {:option_above_maximum, :port, 70_000, 65_535}} =
             prepare(%{port: 70_000, channel: "http"})

    assert {:error, _both} = prepare(%{port: 18_080, channel: "http", channel_in: "http"})

    assert {:error, {:option_below_minimum, :heartbeat_ms, 10, 1_000}} =
             prepare(%{port: 18_080, channel: "http", heartbeat_ms: 10})
  end

  test "an IPv6 literal and lower-case header names are accepted" do
    assert {:ok, %{bind: "::1", pass_headers: ["x-api-key", "cookie"]}} =
             prepare(%{
               port: 18_080,
               channel: "http",
               bind: "::1",
               pass_headers: "x-api-key,cookie"
             })
  end

  test "one worker per relay and plugin, keyed by namespace, relay and plugin" do
    {:ok, opts} = prepare(%{port: 18_080, channel: "http"})
    assert [{{"default", "gateway", "web"}, ^opts}] = Provider.worker_specs(opts)
  end

  test "validation starts nothing and opens no port" do
    port = FlezhaHttp.Client.free_port()
    before = Process.list()

    assert {:ok, _opts} = prepare(%{port: port, channel: "http"})

    assert Process.list() -- before == []
    assert {:error, :econnrefused} = :gen_tcp.connect({127, 0, 0, 1}, port, [], 1_000)
  end
end
