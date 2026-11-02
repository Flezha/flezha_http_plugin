defmodule FlezhaHttp.Events do
  @moduledoc """
  A stream answer: the request process attaches a listener
  (`Flezha.Service.Listener.listen/4`) to the relay the answer names, always
  in the host's own namespace, and writes each event as a server-sent event on
  the same connection.

  Nothing is written before the attach succeeds, so a refused attach is a plain
  error response. A target that does not exist yet is attached again every
  250 ms until `stream_wait_ms` has passed. The attach, the wait and the event
  objects stay apart from the SSE writing (`encode/1`, the writes), so another
  writer can reuse them.
  """

  alias Flezha.Error
  alias Flezha.Process.Poll
  alias Flezha.Service.Admin
  alias FlezhaHttp.Server
  alias FlezhaHttp.Status

  # Bandit's `chunk/2` answers the conn the next write must use, and the
  # listener's handler threads no accumulator, so the request process keeps its
  # current conn here, under one key, from the headers to the last write.
  @conn_key {__MODULE__, :conn}
  @retry_ms 250
  # A quiet door stream writes a comment line this often, so a client that
  # left is noticed; `heartbeat_ms` on the config overrides it.
  @heartbeat_ms 15_000

  @doc "Stream `target` of the host's namespace on `conn`, inside the stream cap."
  @spec stream(Plug.Conn.t(), String.t(), [{String.t(), String.t()}], map()) :: Plug.Conn.t()
  def stream(conn, target, headers, config) do
    result =
      Server.occupy(config, :streams, fn ->
        try do
          Process.put(@conn_key, conn)
          attach(target, headers, config, now() + config.stream_wait_ms)
        after
          Process.delete(@conn_key)
        end
      end)

    full(result, conn, config)
  end

  defp full(:full, conn, config) do
    Status.send_error(
      conn,
      Error.new("http.streams_full",
        plugin: config.source_plugin_id,
        max_streams: config.max_streams
      )
    )
  end

  defp full(result, _conn, _config), do: result

  @doc """
  Run the door's stream operation `name` with the JSON argument array `body`
  as `context`, inside the stream cap, and write each event it emits as the
  server-sent event `Flezha.Service.Admin.event/2` names. The operation's
  answer is the last event, `end`; a refusal before the first event is a plain
  error response. More than `max_pending_events` events received and not yet
  written end the stream with `overrun`. The operation runs in a task linked
  to the request process, and is ended with it.
  """
  @spec door(Plug.Conn.t(), String.t(), binary(), map(), map()) :: Plug.Conn.t()
  def door(conn, name, body, context, config) do
    result =
      Server.occupy(config, :streams, fn ->
        holder = self()
        held = Map.put(context, :emit, holder)
        task = Task.async(fn -> config.admin.(name, body, held, :given) end)

        try do
          Process.put(@conn_key, conn)
          relay(task.ref, context, config)
        after
          Task.shutdown(task, :brutal_kill)
          flush()
          Process.delete(@conn_key)
        end
      end)

    full(result, conn, config)
  end

  defp relay(ref, context, config) do
    receive do
      {:flezha_emit, event} ->
        case pending() do
          n when n > config.max_pending_events ->
            opened(fn -> finish("overrun", ~s({"pending":#{n}})) end)

          _n ->
            relayed(write_door(Admin.event(event, context)), ref, context, config)
        end

      {^ref, answer} ->
        Process.demonitor(ref, [:flush])
        ended(answer)

      # An HTTP/2 client that resets the stream has left: the operation ends
      # now rather than at the next write.
      {:bandit, {:rst_stream, _code}} ->
        Process.get(@conn_key)
    after
      quiet(config) -> relayed(send_chunk(":\n\n"), ref, context, config)
    end
  end

  defp relayed(:continue, ref, context, config), do: relay(ref, context, config)
  defp relayed(:done, _ref, _context, _config), do: Process.get(@conn_key)

  # Nothing is written while the response is unopened, so a refusal can still
  # be a plain error.
  defp quiet(config) do
    if unopened?(),
      do: :infinity,
      else: Map.get(config, :heartbeat_ms, @heartbeat_ms)
  end

  # A client that resets the stream while the response opens leaves its reset
  # with the write that opened it, so the open's answer is the attach's.
  defp write_door(:attached),
    do: if(unopened?() and open([]) == :done, do: :done, else: :continue)

  defp write_door(event) do
    opened(fn ->
      case event do
        {name, object} -> send_chunk(frame(name, Jason.encode_to_iodata!(object)))
        :idle -> send_chunk(":\n\n")
      end
    end)
  end

  # Opens the response, if nothing has yet, before `write` writes to it.
  defp opened(write) do
    if unopened?(), do: open([])
    write.()
  end

  defp ended({:error, %Error{} = error}) do
    if unopened?(),
      do: Status.send_error(Process.get(@conn_key), error),
      else: finish("end", Error.render(error, :json))
  end

  defp ended({:ok, json}), do: opened(fn -> finish("end", [~s({"answer":), json, "}"]) end)

  defp unopened?, do: Process.get(@conn_key).state == :unset

  defp pending do
    {:message_queue_len, n} = Process.info(self(), :message_queue_len)
    n
  end

  # The request process may serve the connection's next request: no event of
  # an ended stream stays in its mailbox.
  defp flush do
    receive do
      {:flezha_emit, _event} -> flush()
    after
      0 -> :ok
    end
  end

  defp attach(target, headers, config, until) do
    opts = [window_ms: :infinity, idle_ms: config.heartbeat_ms, before: fn -> open(headers) end]
    attempt = fn -> attached(config.listen.(config.namespace, target, opts, &write/1)) end
    {_attached?, outcome} = Poll.until(until, @retry_ms, attempt)
    answer(outcome, Process.get(@conn_key))
  end

  # Only a target that does not exist yet, refused before anything was written,
  # is attached again.
  defp attached({:error, %Error{code: "relay.not_found"}} = absent) do
    if unopened?(), do: {:error, absent}, else: {:ok, absent}
  end

  defp attached(outcome), do: {:ok, outcome}

  defp answer(outcome, conn) do
    case {outcome, conn.state} do
      {{:error, %Error{} = error}, :unset} ->
        Status.send_error(conn, Status.public(error))

      {{:error, %Error{} = error}, _open} ->
        finish("closed", Error.render(Status.public(error), :json))

      {{:ok, :relay_ended}, _open} ->
        finish("ended", "{}")

      {{:ok, _done}, _open} ->
        conn
    end
  end

  # The listener runs this after the attach and before the first event; `:done`
  # when the client has already left.
  defp open(headers) do
    conn =
      @conn_key
      |> Process.get()
      |> Plug.Conn.merge_resp_headers(headers)
      |> Plug.Conn.put_resp_header("content-type", "text/event-stream")
      |> Plug.Conn.put_resp_header("cache-control", "no-cache")
      |> Plug.Conn.put_resp_header("x-accel-buffering", "no")
      |> Plug.Conn.send_chunked(200)

    Process.put(@conn_key, conn)
    if send_chunk(":\n\n") == :done, do: :done, else: :ok
  end

  defp finish(event, data) do
    _ = send_chunk(frame(event, data))
    Process.get(@conn_key)
  end

  # The listener's handler: one write per event, `:done` once the client left.
  defp write(event), do: send_chunk(encode(event))

  defp send_chunk(data) do
    case Plug.Conn.chunk(Process.get(@conn_key), data) do
      {:ok, conn} ->
        Process.put(@conn_key, conn)
        :continue

      {:error, _gone} ->
        :done
    end
  end

  # One listener event as the SSE text written for it; `:idle` is a comment line.
  defp encode(:idle), do: ":\n\n"

  defp encode(event) do
    [name, data] = object(event)
    frame(name, data)
  end

  @doc """
  The event name and the JSON data of one listener event. No metadata leaves but
  the channel and a part's number and attempt; a dead-letter notice keeps the
  keys its message needs and never the author's text or the entry.
  """
  @spec object(Flezha.Service.Listener.event()) :: [String.t() | iodata()]
  def object({:part, payload, md}) do
    [
      "part",
      json(
        payload(payload, %{
          "channel" => md["channel"],
          "part" => number(md["flz.part"]),
          "attempt" => number(md["flz.part_attempt"])
        })
      )
    ]
  end

  def object({:output, payload, md}),
    do: ["output", json(payload(payload, %{"channel" => md["channel"]}))]

  def object({:dead_lettered, %Error{} = error, _md}),
    do: ["dead_lettered", Error.render(Status.public(error), :json)]

  defp frame(event, data), do: ["event: ", event, "\ndata: ", data, "\n\n"]

  defp payload(payload, data), do: FlezhaHttp.Envelope.put_bytes(data, "payload", payload)

  defp number(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> n
      _ -> value
    end
  end

  defp number(value), do: value

  defp json(data), do: Jason.encode_to_iodata!(data)

  defp now(), do: System.monotonic_time(:millisecond)
end
