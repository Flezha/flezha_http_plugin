defmodule FlezhaHttp.ServerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias FlezhaHttp.Client
  alias FlezhaHttp.Server
  alias FlezhaHttp.StandIn

  setup do
    {:ok, overwatch} = StandIn.start(self(), fn _ -> StandIn.ok(%{status: 200, body: "pong"}) end)
    %{overwatch: overwatch, port: Client.free_port()}
  end

  defp opts(ctx, overrides \\ %{}) do
    ctx.overwatch
    |> StandIn.config(overrides)
    |> Map.merge(%{
      name: {:global, make_ref()},
      port: ctx.port,
      bind: "127.0.0.1",
      overwatcher_pid: ctx.overwatch,
      source_namespace: "default",
      source_relay_id: "gateway"
    })
  end

  defp start(ctx, overrides \\ %{}),
    do: start_supervised!({Server, opts(ctx, overrides)}, id: make_ref(), restart: :temporary)

  # A closed port refuses at once; the timeout only gives a loaded machine its
  # answer rather than reading a slow connect as an open port.
  defp refused?(address \\ {127, 0, 0, 1}, port),
    do: :gen_tcp.connect(address, port, [], 5_000) == {:error, :econnrefused}

  test "a request is answered end to end", ctx do
    start(ctx)
    assert {200, headers, "pong"} = Client.request(ctx.port, "GET", "/ping")
    assert {"content-type", "text/plain; charset=utf-8"} in headers
    assert_received {:called, payload, %{"channel" => "http"}, 1_000}
    assert %{"method" => "GET", "path" => "/ping"} = Jason.decode!(payload)
  end

  test "a stop frees the port, and a new server binds it at once", ctx do
    server = start(ctx)
    :ok = GenServer.stop(server)
    assert refused?(ctx.port)

    start(ctx)
    assert {200, _, "pong"} = Client.request(ctx.port, "GET", "/ping")
  end

  test "the host going away stops the server, closes the port, and it is not reused", ctx do
    server = start(ctx)
    assert Server.reusable?(server)
    ref = Process.monitor(server)

    Process.exit(ctx.overwatch, :kill)

    assert_receive {:DOWN, ^ref, :process, _, :normal}
    refute Server.reusable?(server)
    assert refused?(ctx.port)
  end

  test "a port already taken stops the second server with http_listen_failed", ctx do
    start(ctx)
    Process.flag(:trap_exit, true)

    log =
      capture_log(fn ->
        assert {:error, {:http_listen_failed, details}} = Server.start_link(opts(ctx))
        send(self(), {:details, details})
      end)

    assert_received {:details, details}
    assert log =~ "port #{ctx.port} already in use"

    assert details == %{
             plugin: "web",
             address: "127.0.0.1",
             port: ctx.port,
             reason: :eaddrinuse
           }

    assert %Flezha.Error{code: "http.listen_failed"} =
             Flezha.Error.from_reason({:http_listen_failed, details}, nil)

    assert {200, _, "pong"} = Client.request(ctx.port, "GET", "/ping")
  end

  test "the default bind listens on loopback alone", ctx do
    start(ctx)

    case for(
           {_name, flags} <- elem(:inet.getifaddrs(), 1),
           {:addr, {a, _, _, _} = address} <- flags,
           a != 127,
           do: address
         ) do
      [address | _] -> assert refused?(address, ctx.port)
      [] -> IO.puts("skipped: this host has no non-loopback IPv4 address")
    end
  end

  test "the probe counts the waiting requests, the open streams and the refusals", ctx do
    test = self()

    {:ok, overwatch} =
      StandIn.start(test, fn _ ->
        send(test, {:waiting, self()})
        receive(do: (:release -> StandIn.ok(%{status: 200})))
      end)

    server = start(%{ctx | overwatch: overwatch}, max_waiting: 1)

    assert Server.probe(server) ==
             {:ok, %{address: "127.0.0.1:#{ctx.port}", waiting: 0, streams: 0, refused: 0}}

    task = Task.async(fn -> Client.request(ctx.port, "GET", "/slow") end)
    assert_receive {:waiting, answering}, 5_000
    assert {503, _, _} = Client.request(ctx.port, "GET", "/slow")
    assert {:ok, %{waiting: 1, streams: 0, refused: 1}} = Server.probe(server)

    send(answering, :release)
    assert {200, _, _} = Task.await(task)
    assert {:ok, %{waiting: 0, refused: 1}} = Server.probe(server)
  end

  describe "the body on the wire" do
    test "a chunked body is refused 411 before it is read, a sized one is served", ctx do
      start(ctx)
      {conn, ref} = Client.open(ctx.port, "POST", "/", [], :stream)
      {:ok, conn} = Mint.HTTP1.stream_request_body(conn, ref, "hello")
      {:ok, conn} = Mint.HTTP1.stream_request_body(conn, ref, :eof)

      {_conn, response} =
        Client.read(conn, ref, %{status: nil, headers: [], body: []}, &Map.get(&1, :done, false))

      assert response.status == 411

      assert %{"error" => %{"code" => "http.length_required"}} =
               Jason.decode!(IO.iodata_to_binary(response.body))

      refute_received {:called, _, _, _}
      assert {200, _, "pong"} = Client.request(ctx.port, "POST", "/", [], "hello")
    end

    test "a body the client stops sending is answered 408", ctx do
      start(ctx, body_timeout_ms: 300)
      {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, ctx.port, [:binary, active: false])
      :ok = :gen_tcp.send(socket, "POST / HTTP/1.1\r\nhost: x\r\ncontent-length: 10\r\n\r\nab")

      {:ok, response} = :gen_tcp.recv(socket, 0, 5_000)
      assert response =~ "HTTP/1.1 408 "
      [_head, body] = String.split(response, "\r\n\r\n", parts: 2)

      assert %{"error" => %{"code" => "http.body_timeout", "details" => %{"timeout_ms" => 300}}} =
               Jason.decode!(body)

      :gen_tcp.close(socket)
      refute_received {:called, _, _, _}
    end
  end

  test "a body sent slower than its one deadline is answered 408", ctx do
    start(ctx, body_timeout_ms: 500)
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, ctx.port, [:binary, active: false])
    :ok = :gen_tcp.send(socket, "POST / HTTP/1.1\r\nhost: x\r\ncontent-length: 1048576\r\n\r\n")

    # 1 KiB every 100 ms: every read sees data well inside 500 ms, and the body
    # takes over a minute, so however late the handler starts reading, only
    # the one deadline over the whole body can end it.
    sender =
      spawn(fn ->
        for _ <- 1..1_024,
            do: :gen_tcp.send(socket, :binary.copy("a", 1_024)) && Process.sleep(100)
      end)

    {:ok, response} = :gen_tcp.recv(socket, 0, 5_000)
    Process.exit(sender, :kill)
    :gen_tcp.close(socket)

    assert response =~ "HTTP/1.1 408 "
    assert response =~ "http.body_timeout"
    refute_received {:called, _, _, _}
  end

  test "a connection past max_connections is closed, and the one it holds is served", ctx do
    start(ctx, max_connections: 1)
    {:ok, first} = :gen_tcp.connect({127, 0, 0, 1}, ctx.port, [:binary, active: false])
    {:ok, second} = :gen_tcp.connect({127, 0, 0, 1}, ctx.port, [:binary, active: false])
    _ = :gen_tcp.send(second, "GET /ping HTTP/1.1\r\nhost: x\r\n\r\n")

    assert {:error, :closed} = :gen_tcp.recv(second, 0, 5_000)

    :ok = :gen_tcp.send(first, "GET /ping HTTP/1.1\r\nhost: x\r\n\r\n")
    assert {:ok, "HTTP/1.1 200 " <> _} = :gen_tcp.recv(first, 0, 5_000)
    :gen_tcp.close(first)
  end

  test "a client that stops sending its request head is answered 408 and frees its slot", ctx do
    start(ctx, max_connections: 1, body_timeout_ms: 300)
    {:ok, slow} = :gen_tcp.connect({127, 0, 0, 1}, ctx.port, [:binary, active: false])
    :ok = :gen_tcp.send(slow, "GET /ping HTTP/1.1\r\n")

    # Bandit logs the error before it sends the 408.
    log =
      capture_log(fn -> assert {:ok, "HTTP/1.0 408 " <> _} = :gen_tcp.recv(slow, 0, 2_000) end)

    assert log =~ "Read timeout"
    assert {:error, :closed} = :gen_tcp.recv(slow, 0, 2_000)
    assert {200, _, "pong"} = Client.request(ctx.port, "GET", "/ping")
  end

  describe "a stream on the wire" do
    setup ctx do
      test = self()
      {:ok, overwatch} = StandIn.start(test, fn _ -> StandIn.ok(%{stream: "anna-42"}) end)

      # Three parts, then quiet: an idle tick every `idle_ms`, counted, until a
      # write fails.
      ticks = :counters.new(1, [])

      listen = fn _namespace, _target, opts, handler ->
        Keyword.fetch!(opts, :before).()

        for n <- 0..2,
            do:
              :continue =
                handler.(
                  {:part, "w#{n}",
                   %{"channel" => "events", "flz.part" => "#{n}", "flz.part_attempt" => "1"}}
                )

        idle(handler, Keyword.fetch!(opts, :idle_ms), {test, ticks})
      end

      %{ctx | overwatch: overwatch} |> Map.merge(%{listen: listen, ticks: ticks})
    end

    defp idle(handler, idle_ms, {test, ticks} = report) do
      receive do
      after
        idle_ms ->
          :counters.add(ticks, 1, 1)

          case handler.(:idle) do
            :continue ->
              idle(handler, idle_ms, report)

            :done ->
              send(test, {:done, :counters.get(ticks, 1)})
              {:ok, :done}
          end
      end
    end

    test "arrives as it is written, and a client that left is noticed", ctx do
      start(ctx, listen: ctx.listen, heartbeat_ms: 1_000)
      {conn, ref} = Client.open(ctx.port, "GET", "/sessions/anna-42/events")

      {conn, response} =
        Client.read(conn, ref, %{status: nil, headers: [], body: []}, fn acc ->
          IO.iodata_to_binary(acc.body) |> String.split("\n\n", trim: true) |> length() >= 5
        end)

      assert response.status == 200
      assert {"content-type", "text/event-stream"} in response.headers

      assert [
               ":",
               "event: part\ndata: " <> p0,
               "event: part\ndata: " <> p1,
               "event: part\ndata: " <> p2,
               ":"
             ] =
               response.body |> IO.iodata_to_binary() |> String.split("\n\n", trim: true)

      assert Enum.map([p0, p1, p2], &Jason.decode!(&1)["payload"]) == ["w0", "w1", "w2"]

      {:ok, _conn} = Mint.HTTP1.close(conn)
      closed_at = :counters.get(ctx.ticks, 1)

      # Noticed at the latest at the second heartbeat after the client left.
      assert_receive {:done, done_at}, 5_000
      assert done_at - closed_at <= 2
    end
  end
end
