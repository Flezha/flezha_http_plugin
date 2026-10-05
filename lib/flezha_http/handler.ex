defmodule FlezhaHttp.Handler do
  @moduledoc """
  The one Plug: every request is read, turned into the request envelope and made
  one outside call of the host relay, whose answer becomes the response or a
  stream. It has no routes; the host's graph routes.

  It logs the method, the path, the status and the duration at debug level, and
  never a header, a body or a query.
  """

  @behaviour Plug

  require Logger

  alias Flezha.Error
  alias FlezhaHttp.Envelope
  alias FlezhaHttp.Events
  alias FlezhaHttp.Server
  alias FlezhaHttp.Status

  # One read of a body: one recv, bounded by the deadline.
  @read_bytes 65_536

  @impl true
  def init(config), do: config

  @impl true
  def call(conn, config),
    do: logged(conn, &serve(&1, config), fn _conn -> " relay=#{config.relay}" end)

  @doc """
  `serve` `conn`, then log its method, path, status, duration and `detail` of
  the answered conn, at debug level: the one request line of the package.
  """
  @spec logged(Plug.Conn.t(), (Plug.Conn.t() -> Plug.Conn.t()), (Plug.Conn.t() -> String.t())) ::
          Plug.Conn.t()
  def logged(conn, serve, detail) do
    started = System.monotonic_time(:millisecond)
    conn = serve.(conn)

    Logger.debug(fn ->
      "[FlezhaHttp] #{conn.method} #{conn.request_path} #{conn.status} " <>
        "#{System.monotonic_time(:millisecond) - started}ms" <> detail.(conn)
    end)

    conn
  end

  # The waiting slot is taken before the body is read, so at most `max_waiting`
  # bodies are held at once; a stream gives it back before it starts, since it is
  # bounded by its own cap.
  defp serve(conn, config) do
    case Server.occupy(config, :waiting, fn -> exchange(conn, config) end) do
      :full -> Status.send_error(conn, busy(config))
      {:ok, answer, conn} -> respond(conn, answer, config)
      {:error, %Error{} = error, conn} -> Status.send_error(conn, error)
    end
  end

  defp exchange(conn, config) do
    with {:ok, body, conn} <- read_body(conn, config),
         {:ok, answer} <- inject(conn, body, config) do
      {:ok, answer, conn}
    end
  end

  defp inject(conn, body, config) do
    envelope = Envelope.request(conn, body, config.pass_headers)

    case Flezha.Plugin.Host.inject(
           config.overwatch,
           Jason.encode!(envelope),
           %{"channel" => config.entry_channel},
           :call,
           config.deadline_ms
         ) do
      {:ok, payload, _metadata} -> decode(payload, conn, config)
      {:error, %Error{} = error} -> {:error, Status.public(error), conn}
    end
  end

  defp decode(payload, conn, config) do
    case Envelope.answer(payload) do
      {:ok, answer} ->
        {:ok, answer}

      {:error, reason} ->
        Logger.warning(
          "[FlezhaHttp] relay #{config.relay} answered an invalid envelope: #{reason}"
        )

        {:error, Error.new("http.answer_invalid", relay: config.relay, reason: reason), conn}
    end
  end

  defp respond(conn, {:plain, status, headers, body}, _config) do
    conn
    |> Plug.Conn.merge_resp_headers(headers)
    |> Plug.Conn.send_resp(status, body)
  end

  defp respond(conn, {:stream, target, headers}, config),
    do: Events.stream(conn, target, headers, config)

  @doc """
  Read `conn`'s body within `config`'s `max_body_bytes` and `body_timeout_ms`.

  A body must say its length: a `content-length` over the limit is refused
  before a byte is read, and a body sent without one (chunked) is refused
  unread, since its reads could not be held to the deadline. The whole read has
  one deadline, each read being given what is left of it for one recv.
  """
  @spec read_body(Plug.Conn.t(), map()) ::
          {:ok, binary(), Plug.Conn.t()} | {:error, Error.t(), Plug.Conn.t()}
  def read_body(conn, config) do
    until = System.monotonic_time(:millisecond) + config.body_timeout_ms

    case {Plug.Conn.get_req_header(conn, "content-length"),
          Plug.Conn.get_req_header(conn, "transfer-encoding")} do
      {[], [_ | _]} ->
        {:error, Error.new("http.length_required"), conn}

      {[length | _], _} ->
        if too_long?(length, config.max_body_bytes),
          do: {:error, too_large(config), conn},
          else: read(conn, config, {[], 0}, until)

      {[], []} ->
        read(conn, config, {[], 0}, until)
    end
  rescue
    error in Bandit.HTTPError ->
      if error.plug_status == :request_timeout,
        do: {:error, body_timeout(config), conn},
        else: reraise(error, __STACKTRACE__)
  end

  defp too_long?(length, max) do
    case Integer.parse(length) do
      {n, ""} -> n > max
      _ -> false
    end
  end

  defp read(conn, config, {acc, size}, until) do
    left = until - System.monotonic_time(:millisecond)
    unread = config.max_body_bytes - size + 1
    opts = [length: min(@read_bytes, unread), read_length: unread, read_timeout: max(left, 0)]

    case left > 0 && Plug.Conn.read_body(conn, opts) do
      {:ok, data, conn} ->
        within(conn, config, {[acc | data], size + byte_size(data)}, :done, until)

      {:more, data, conn} ->
        within(conn, config, {[acc | data], size + byte_size(data)}, :more, until)

      _timed_out ->
        {:error, body_timeout(config), conn}
    end
  end

  defp within(conn, config, {_acc, size}, _more, _until) when size > config.max_body_bytes,
    do: {:error, too_large(config), conn}

  defp within(conn, _config, {acc, _size}, :done, _until),
    do: {:ok, IO.iodata_to_binary(acc), conn}

  defp within(conn, config, body, :more, until), do: read(conn, config, body, until)

  defp too_large(config), do: Error.new("http.body_too_large", limit: config.max_body_bytes)

  defp body_timeout(config),
    do: Error.new("http.body_timeout", timeout_ms: config.body_timeout_ms)

  @doc "The refusal of a request past `config`'s `max_waiting`."
  @spec busy(map()) :: Error.t()
  def busy(config),
    do: Error.new("http.busy", plugin: config.source_plugin_id, max_waiting: config.max_waiting)
end
