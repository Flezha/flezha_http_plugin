defmodule FlezhaHttp.Server do
  @moduledoc """
  The declared worker of both providers: it owns the Bandit listener and the
  counters its caps are kept in. It serves the Plug its worker options name
  (`plug`, `FlezhaHttp.Handler` by default), over TLS when they name a
  `tls_certfile` and a `tls_keyfile`.

  It follows its host: it stops when the host (a relay's Overwatch, or a
  controller plugin's running copy) goes away,
  stops Bandit before its own stop returns so a replacement can bind the port at
  once, and is not reused by a new Overwatch while its own host is gone. A port
  it cannot bind stops it with `{:http_listen_failed, details}`.
  """

  alias Flezha.Plugin.Provider.Worker
  alias Flezha.Plugin.ProviderBehaviour

  use Worker

  # Each slot: its counter and the option capping it.
  @slots %{waiting: {1, :max_waiting}, streams: {2, :max_streams}}
  @refused 3

  # Plug's own default for one body read.
  @body_timeout_ms 15_000

  @doc "Whether the table may hand this worker to an Overwatch: never once its own host is gone."
  @spec reusable?(pid()) :: boolean()
  def reusable?(pid) do
    Process.alive?(pid) and
      case ProviderBehaviour.ask(pid, :host) do
        {:ok, host} -> Process.alive?(host)
        :timeout -> false
      end
  end

  @doc "The address, the requests waiting, the streams open and the cap refusals since start."
  @spec probe(pid()) :: {:ok, map()} | :timeout
  def probe(pid), do: ProviderBehaviour.ask(pid, :inspect)

  @doc """
  Run `fun` holding one slot of `slot` (`:waiting` or `:streams`) under the cap
  `config` names for it, and give the slot back however `fun` ends. `:full`
  counts a refusal and runs nothing.
  """
  @spec occupy(map(), :waiting | :streams, (-> result)) :: result | :full when result: term()
  def occupy(%{counters: counters} = config, slot, fun) do
    {index, cap} = Map.fetch!(@slots, slot)

    if :atomics.add_get(counters, index, 1) > Map.fetch!(config, cap) do
      :atomics.sub(counters, index, 1)
      :atomics.add(counters, @refused, 1)
      :full
    else
      try do
        fun.()
      after
        :atomics.sub(counters, index, 1)
      end
    end
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    host = Map.fetch!(opts, :overwatcher_pid)
    {:ok, ip} = FlezhaHttp.Provider.address(opts.bind)
    counters = :atomics.new(3, signed: true)
    config = handler_config(opts, host, counters)

    bandit = [
      plug: {Map.get(opts, :plug, FlezhaHttp.Handler), config},
      ip: ip,
      port: opts.port,
      startup_log: false,
      http_2_options: [enabled: false],
      # One acceptor holding at most `max_connections`, and a connection past it
      # closed at once: ThousandIsland's defaults (100 x 16 384) bound nothing.
      # Each read of a request head, and an idle keep-alive, waits the body
      # timeout instead of ThousandIsland's 60 s.
      thousand_island_options: [
        shutdown_timeout: 1_000,
        num_acceptors: 1,
        num_connections: opts.max_connections,
        max_connections_retry_count: 0,
        read_timeout: config.body_timeout_ms
      ]
    ]

    case Bandit.start_link(bandit ++ tls(opts)) do
      {:ok, bandit} ->
        {:ok,
         %{
           bandit: bandit,
           host: host,
           watch: Worker.host(opts),
           counters: counters,
           address: address_text(opts.bind, opts.port)
         }}

      {:error, reason} ->
        {:stop,
         {:http_listen_failed,
          %{
            plugin: opts.source_plugin_id,
            address: opts.bind,
            port: opts.port,
            reason: cause(reason)
          }}}
    end
  end

  # What a request needs, fixed for the worker's life: the options and the host.
  # `listen` and `body_timeout_ms` are not options: tests set them on the opts.
  defp handler_config(opts, host, counters) do
    Map.merge(opts, %{
      overwatch: host,
      namespace: opts.source_namespace,
      relay: opts.source_relay_id,
      counters: counters,
      body_timeout_ms: Map.get(opts, :body_timeout_ms, @body_timeout_ms),
      listen: Map.get(opts, :listen, &Flezha.Service.Listener.listen/4)
    })
  end

  defp tls(%{tls_certfile: certfile, tls_keyfile: keyfile})
       when is_binary(certfile) and is_binary(keyfile),
       do: [scheme: :https, certfile: certfile, keyfile: keyfile]

  defp tls(_opts), do: []

  @impl true
  def handle_info({:EXIT, bandit, reason}, %{bandit: bandit} = state),
    do: {:stop, {:bandit_exited, reason}, %{state | bandit: nil}}

  def handle_info({:host, from, ref}, state) do
    send(from, {ref, state.host})
    {:noreply, state}
  end

  def handle_info({:inspect, from, ref}, state) do
    send(from, {ref, report(state)})
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{bandit: bandit}) when is_pid(bandit) do
    ThousandIsland.stop(bandit)
  end

  def terminate(_reason, _state), do: :ok

  defp report(state) do
    %{
      address: state.address,
      waiting: :atomics.get(state.counters, elem(@slots.waiting, 0)),
      streams: :atomics.get(state.counters, elem(@slots.streams, 0)),
      refused: :atomics.get(state.counters, @refused)
    }
  end

  defp address_text(bind, port) do
    if String.contains?(bind, ":"), do: "[#{bind}]:#{port}", else: "#{bind}:#{port}"
  end

  # Bandit wraps the listener's refusal in its supervisor's; the socket's own
  # reason (`:eaddrinuse`, `:eaddrnotavail`, `:eacces`) is what a user can act on.
  defp cause({:shutdown, {:failed_to_start_child, _child, reason}}), do: cause(reason)
  defp cause({:listen_error, reason}), do: cause(reason)
  defp cause(reason) when is_atom(reason), do: reason
  defp cause(reason), do: inspect(reason)
end
