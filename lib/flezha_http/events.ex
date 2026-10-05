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
  alias FlezhaHttp.Server
  alias FlezhaHttp.Status

  # Bandit's `chunk/2` answers the conn the next write must use, and the
  # listener's handler threads no accumulator, so the request process keeps its
  # current conn here, under one key, from the headers to the last write.
  @conn_key {__MODULE__, :conn}
  @retry_ms 250

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

    if result == :full do
      Status.send_error(
        conn,
        Error.new("http.streams_full", relay: config.relay, max_streams: config.max_streams)
      )
    else
      result
    end
  end

  defp attach(target, headers, config, until) do
    opts = [window_ms: :infinity, idle_ms: config.heartbeat_ms, before: fn -> open(headers) end]
    outcome = config.listen.(config.namespace, target, opts, &write/1)
    conn = Process.get(@conn_key)

    case {outcome, conn.state} do
      {{:error, %Error{code: "relay.not_found"}}, :unset} ->
        case until - now() do
          left when left > 0 ->
            Process.sleep(min(left, @retry_ms))
            attach(target, headers, config, until)

          _passed ->
            Status.send_error(conn, Status.public(elem(outcome, 1)))
        end

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

  # The listener runs this after the attach and before the first event.
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
    _ = send_chunk(":\n\n")
    :ok
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
