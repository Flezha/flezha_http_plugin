defmodule FlezhaHttp.Provider do
  @moduledoc """
  The `http_server` provider: an HTTP/1.1 server in front of the relay it is
  enabled on. Every request becomes one outside call of that relay on its
  entry channel, and the first sink output the call causes becomes the HTTP
  response, or a stream of another relay's events (`FlezhaHttp.Events`).

  The contract, the envelopes and the option table are the core's
  `docs/plugins/http_server.md`.
  """

  alias Flezha.Plugin.Extension.Ctx
  alias Flezha.Plugin.ProviderBehaviour

  use ProviderBehaviour,
    name: "http_server",
    feeds: true,
    options: [
      port: [
        type: :int,
        required: true,
        min: 1,
        max: 65_535,
        doc: "The TCP port the server listens on, 1 to 65535"
      ],
      bind: [
        type: :string,
        default: "127.0.0.1",
        doc: "The address it listens on: an IPv4 or IPv6 literal, never a name"
      ],
      channel: [
        type: :names,
        doc:
          "The entry channel every request is injected on, one name. Required, unless `channel_in` names it"
      ],
      channel_in: [
        type: :names,
        doc: "The explicit spelling of `channel`. Required, unless `channel` names it"
      ],
      answer_channel: [
        type: :string,
        doc:
          "The relay's channel whose output answers a request; the first output on a sink when unset"
      ],
      deadline_ms: [
        type: :int,
        default: 30_000,
        min: 100,
        max: 600_000,
        doc: "How long a request waits for the relay's answer, 100 to 600000"
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
        default: 1_000,
        min: 1,
        max: 100_000,
        doc: "Requests waiting for an answer at once, up to 100000; one more is answered 503"
      ],
      max_streams: [
        type: :int,
        default: 1_000,
        min: 1,
        max: 100_000,
        doc: "Event streams open at once, up to 100000; one more is answered 503"
      ],
      pass_headers: [
        type: :names,
        default: [],
        doc: "Request headers copied into the request envelope, lower-case names; none by default"
      ],
      max_connections: [
        type: :int,
        default: 1_000,
        min: 1,
        max: 100_000,
        doc:
          "Connections open at once, streams and waiting requests included; one more is closed at once"
      ],
      heartbeat_ms: [
        type: :int,
        default: 15_000,
        min: 1_000,
        max: 300_000,
        doc: "How long a quiet stream waits before it writes a comment line, 1000 to 300000"
      ],
      stream_wait_ms: [
        type: :int,
        default: 5_000,
        min: 0,
        max: 60_000,
        doc:
          "How long a stream waits for the relay it names to exist, up to 60000; 0 answers 404 at once"
      ]
    ],
    worker: [
      module: FlezhaHttp.Server,
      restart: :transient,
      reusable: {FlezhaHttp.Server, :reusable?}
    ]

  # An HTTP token (RFC 9110), lower case: what a header name can be.
  @token ~r/\A[!#$%&'*+.^_`|~0-9a-z-]+\z/

  @doc "Whether `name` is an HTTP token in lower case, as header names here must be."
  @spec token?(term()) :: boolean()
  def token?(name), do: is_binary(name) and Regex.match?(@token, name)

  @doc """
  Validate without I/O: the address is parsed, never resolved, and nothing is
  opened or started; the worker binds at activation.
  """
  @impl true
  def init_provider(opts) do
    # A client cannot address a port per member of a group without knowing the key.
    with :ok <- ProviderBehaviour.refuse_partitioned(opts, __MODULE__),
         :ok <- ProviderBehaviour.require_entry_channel(opts, __MODULE__),
         {:ok, _address} <- address(opts.bind),
         :ok <- check_pass_headers(opts.pass_headers) do
      {:ok, opts}
    end
  end

  @doc "The address `bind` names, parsed, never looked up."
  @spec address(term()) :: {:ok, :inet.ip_address()} | {:error, term()}
  def address(bind) when is_binary(bind) do
    case :inet.parse_address(String.to_charlist(bind)) do
      {:ok, address} -> {:ok, address}
      {:error, _} -> ProviderBehaviour.refuse_value(:bind, bind)
    end
  end

  def address(bind), do: ProviderBehaviour.refuse_value(:bind, bind)

  defp check_pass_headers(names) do
    if Enum.all?(names, &token?/1),
      do: :ok,
      else: ProviderBehaviour.refuse_value(:pass_headers, Enum.join(names, ","))
  end

  # Two relays on one node never share a server.
  @impl true
  def worker_specs(opts),
    do: [{{opts.source_namespace, opts.source_relay_id, opts.source_plugin_id}, opts}]

  @doc "The server drives itself; the hook is there because a plugin spec must name one."
  @impl true
  def on_terminate(%Ctx.Terminate{}, _opts), do: :ok

  @impl true
  def inspect_state(opts) do
    with pid when is_pid(pid) <- ProviderBehaviour.worker_pid(opts),
         {:ok, report} <- FlezhaHttp.Server.probe(pid) do
      report
    else
      _ -> nil
    end
  end
end
