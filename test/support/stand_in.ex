defmodule FlezhaHttp.StandIn do
  @moduledoc """
  A process standing in for the host relay's Overwatch: it answers the outside
  call `Flezha.Plugin.Host.inject/5` sends in `:call` mode with what `answer`
  returns for the payload, and reports each call to the test process.
  """

  use GenServer

  @doc "Start one answering with `answer.(payload)`, reporting calls to `test`."
  def start(test, answer), do: GenServer.start(__MODULE__, {test, answer})

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:call, message, metadata, deadline_ms}, from, {test, answer} = state) do
    send(test, {:called, message, metadata, deadline_ms})

    # An answer may take its time without holding the stand-in up.
    spawn(fn ->
      case answer.(message) do
        :none -> :ok
        reply -> GenServer.reply(from, reply)
      end
    end)

    {:noreply, state}
  end

  @doc "An answer envelope as the host's sink output hands it back."
  def ok(envelope) when is_map(envelope),
    do: {:ok, Jason.encode!(envelope), %{"channel" => "out"}}

  def ok(payload) when is_binary(payload), do: {:ok, payload, %{"channel" => "out"}}

  @doc "The handler's config for a server in front of `overwatch`, with `overrides`."
  def config(overwatch, overrides \\ %{}) do
    Map.merge(
      %{
        overwatch: overwatch,
        namespace: "default",
        relay: "gateway",
        source_plugin_id: "web",
        entry_channel: "http",
        deadline_ms: 1_000,
        max_body_bytes: 1_048_576,
        max_waiting: 1_000,
        max_streams: 1_000,
        max_connections: 1_000,
        pass_headers: [],
        heartbeat_ms: 15_000,
        stream_wait_ms: 0,
        body_timeout_ms: 15_000,
        counters: :atomics.new(3, signed: true),
        listen: fn _ns, _op, _opts, _handler -> {:ok, :done} end
      },
      Map.new(overrides)
    )
  end
end
