defmodule FlezhaHttp.ApiProvider do
  @moduledoc """
  The `http_api` provider: the controller's published operations over HTTP, as
  MCP tools at `POST /mcp` and as plain JSON under `/v1`, each call made as the
  principal of the bearer token it carries (`FlezhaHttp.Api`).

  A controller plugin enabled only in `_system`, with no hook: it runs one
  listener on every controller holding `_system`. The page is the core's
  `docs/public/plugins/http_api.md`.
  """

  require Logger

  alias Flezha.Plugin.ProviderBehaviour

  use ProviderBehaviour,
    name: "http_api",
    type: :controller,
    namespace: "_system",
    options: [
      port: [
        type: :int,
        default: 8765,
        min: 1,
        max: 65_535,
        doc: "The TCP port the API listens on, 1 to 65535"
      ],
      bind: [
        type: :string,
        default: "127.0.0.1",
        doc:
          "The address it listens on: an IPv4 or IPv6 literal. Any but loopback needs TLS or `plain_http`"
      ],
      tls_certfile: [
        type: :string,
        doc: "The PEM certificate it serves HTTPS with; given with `tls_keyfile`"
      ],
      tls_keyfile: [
        type: :string,
        doc: "The PEM private key of `tls_certfile`"
      ],
      tls_client_cacertfile: [
        type: :string,
        doc:
          "The PEM authority every client certificate must chain to; with it a client without one is refused at the TLS handshake"
      ],
      require_client_cert: [
        type: :bool,
        default: true,
        doc:
          "Set false to serve TLS off loopback without `tls_client_cacertfile`; warned on every enable and boot"
      ],
      plain_http: [
        type: :bool,
        default: false,
        doc: "Serve plain HTTP on an address that is not loopback, where TLS ends in front of it"
      ],
      allowed_origins: [
        type: :names,
        default: [],
        doc:
          "The browser origins a request may come from; a request naming any other is answered 403"
      ],
      deadline_ms: [
        type: :int,
        default: 30_000,
        min: 100,
        max: 600_000,
        doc: "How long a call waits for the controller's answer, 100 to 600000"
      ],
      max_body_bytes: [
        type: :int,
        default: 1_048_576,
        min: 1,
        max: 16_777_216,
        doc: "The largest request body accepted, up to 16777216; a larger one is answered 413"
      ],
      max_waiting: [
        type: :int,
        default: 64,
        min: 1,
        max: 10_000,
        doc: "Calls waiting for an answer at once, up to 10000; one more is answered 503"
      ],
      max_streams: [
        type: :int,
        default: 64,
        min: 1,
        max: 10_000,
        doc: "Event streams open at once, up to 10000; one more is answered 503"
      ],
      max_pending_events: [
        type: :int,
        default: 1_000,
        min: 1,
        max: 100_000,
        doc:
          "Events a stream may hold unwritten, up to 100000; one more ends it with an `overrun` event"
      ],
      max_connections: [
        type: :int,
        default: 128,
        min: 1,
        max: 10_000,
        doc: "Connections open at once, up to 10000; one more is closed at once"
      ]
    ],
    worker: [
      module: FlezhaHttp.Server,
      restart: :transient,
      reusable: {FlezhaHttp.Server, :reusable?}
    ]

  @doc """
  Validate without I/O: the address is parsed, never resolved, and one that is
  not loopback is refused without TLS or `plain_http`, since a bearer token sent
  in the clear can be replayed, and its TLS without `tls_client_cacertfile`
  unless `require_client_cert` is false. The certificates are read when the
  worker binds.
  """
  @impl true
  def init_provider(opts) do
    with {:ok, address} <- FlezhaHttp.Provider.address(opts.bind),
         :ok <- paired_tls(opts),
         :ok <- secured(address, opts),
         :ok <- client_certs(address, opts) do
      {:ok, opts}
    end
  end

  defp paired_tls(%{tls_certfile: nil, tls_keyfile: key}) when is_binary(key),
    do: ProviderBehaviour.refuse_value(:tls_certfile, nil)

  defp paired_tls(%{tls_certfile: cert, tls_keyfile: nil}) when is_binary(cert),
    do: ProviderBehaviour.refuse_value(:tls_keyfile, nil)

  defp paired_tls(%{tls_certfile: nil, tls_client_cacertfile: ca}) when is_binary(ca),
    do: ProviderBehaviour.refuse_value(:tls_certfile, nil)

  defp paired_tls(_opts), do: :ok

  defp secured(address, opts) do
    if loopback?(address) or opts.plain_http or is_binary(opts.tls_certfile),
      do: :ok,
      else: {:error, {:http_tls_required, opts.bind}}
  end

  # A host off this machine proves itself with a client certificate as well as
  # a token. `plain_http` ends TLS in front of the listener, where client
  # certificates are the proxy's to ask for.
  defp client_certs(address, opts) do
    cond do
      loopback?(address) or not is_binary(opts.tls_certfile) or
          is_binary(opts.tls_client_cacertfile) ->
        :ok

      opts.require_client_cert ->
        {:error, {:http_client_cert_required, opts.bind}}

      true ->
        Logger.warning(
          "[FlezhaHttp] http_api plugin '#{opts.source_plugin_id}' on #{opts.bind} serves TLS " <>
            "without client certificates (require_client_cert is false)"
        )
    end
  end

  defp loopback?({127, _, _, _}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback?(_address), do: false

  # One listener per controller: the copy that runs it is the one on this node.
  @impl true
  def worker_specs(opts),
    do: [
      {{opts.source_namespace, opts.source_plugin_id},
       Map.merge(opts, %{plug: FlezhaHttp.Api, http_2: true})}
    ]

  @impl true
  defdelegate inspect_state(opts), to: FlezhaHttp.Provider
end
