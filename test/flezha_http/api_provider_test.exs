defmodule FlezhaHttp.ApiProviderTest do
  use ExUnit.Case, async: true

  alias Flezha.Plugin.ProviderBehaviour.Options
  alias FlezhaHttp.ApiProvider

  @host %{source_namespace: "_system", source_relay_id: nil, source_plugin_id: "api"}

  defp prepare(opts) do
    with {:ok, opts} <- Options.normalise_opts(ApiProvider, opts) do
      ApiProvider.init_provider(Map.merge(opts, @host))
    end
  end

  defp code({:error, reason}), do: Flezha.Error.from_reason(reason, nil).code

  test "a controller plugin with a worker, bound to _system" do
    decl = ApiProvider.__provider__()
    assert decl.type == :controller
    assert decl.namespace == "_system"
    assert decl.name == "http_api"
    assert decl.worker.module == FlezhaHttp.Server
  end

  test "nothing written takes every default, loopback first" do
    assert {:ok, opts} = prepare(%{})

    assert %{
             port: 8765,
             bind: "127.0.0.1",
             plain_http: false,
             allowed_origins: [],
             deadline_ms: 30_000,
             max_body_bytes: 1_048_576,
             max_waiting: 64,
             max_streams: 64,
             max_pending_events: 1_000,
             require_client_cert: true,
             tls_client_cacertfile: nil,
             max_connections: 128
           } = opts
  end

  test "an address that is not loopback needs TLS or plain_http" do
    assert code(prepare(%{bind: "0.0.0.0"})) == "http.tls_required"
    assert code(prepare(%{bind: "192.0.2.7"})) == "http.tls_required"
    assert {:ok, _} = prepare(%{bind: "::1"})
    assert {:ok, _} = prepare(%{bind: "0.0.0.0", plain_http: true})

    assert {:ok, _} =
             prepare(%{
               bind: "0.0.0.0",
               tls_certfile: "/c.pem",
               tls_keyfile: "/k.pem",
               tls_client_cacertfile: "/ca.pem"
             })
  end

  @tls %{tls_certfile: "/c.pem", tls_keyfile: "/k.pem"}

  # Fails when: a listener off this machine serves anyone holding a token,
  # without proving the client's host.
  test "TLS off loopback needs a client authority, unless the opt-out is set and warned" do
    assert {:error, {:http_client_cert_required, "10.0.0.5"}} =
             prepare(Map.put(@tls, :bind, "10.0.0.5"))

    assert code(prepare(Map.put(@tls, :bind, "10.0.0.5"))) == "http.client_cert_required"

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, _} =
                 prepare(Map.merge(@tls, %{bind: "10.0.0.5", require_client_cert: false}))
      end)

    assert log =~ "http_api plugin 'api' on 10.0.0.5 serves TLS without client certificates"

    quiet =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, _} = prepare(Map.put(@tls, :bind, "127.0.0.1"))
        assert {:ok, _} = prepare(%{bind: "10.0.0.5", plain_http: true})
      end)

    refute quiet =~ "client certificates"
  end

  test "a client authority needs the listener's own certificate" do
    assert {:error, {:invalid_option_value, :tls_certfile, nil}} =
             prepare(%{tls_client_cacertfile: "/ca.pem"})
  end

  test "a certificate without its key, or the reverse, is refused by name" do
    assert {:error, {:invalid_option_value, :tls_keyfile, nil}} =
             prepare(%{tls_certfile: "/c.pem"})

    assert {:error, {:invalid_option_value, :tls_certfile, nil}} =
             prepare(%{tls_keyfile: "/k.pem"})
  end

  test "its worker serves the API's Plug, one per controller" do
    assert {:ok, opts} = prepare(%{})
    assert [{{"_system", "api"}, worker}] = ApiProvider.worker_specs(opts)
    assert worker.http_2
    assert worker.plug == FlezhaHttp.Api
  end
end
