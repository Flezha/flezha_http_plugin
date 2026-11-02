defmodule FlezhaHttp.ServerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias FlezhaHttp.Client
  alias FlezhaHttp.Server
  alias FlezhaHttp.StandIn

  # Two authorities, as an operator keeps them: `api` signs the listener and
  # its clients, `other` stands for any authority the listener does not name.
  setup_all do
    dir = Path.join(System.tmp_dir!(), "flz_http_tls_#{System.unique_integer([:positive])}")
    script = Path.expand("../../../../deploy/dist-tls/make-certs.sh", __DIR__)

    for {ca, nodes} <- [{"api", ["server", "client"]}, {"other", ["stranger"]}] do
      {_, 0} = System.cmd(script, ["ca", Path.join(dir, ca)], stderr_to_stdout: true)

      for node <- nodes,
          do:
            {_, 0} =
              System.cmd(script, ["node", Path.join(dir, ca), node, "--ip", "127.0.0.1"],
                stderr_to_stdout: true
              )
    end

    on_exit(fn -> File.rm_rf!(dir) end)
    %{certs: dir}
  end

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
        for _ <- 1..1_024 do
          :gen_tcp.send(socket, :binary.copy("a", 1_024))
          Process.sleep(100)
        end
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

  describe "the API's stream route" do
    # Fails when: a door stream waits for its end before writing, or outlives
    # the client that asked for it.
    test "pushes each event while open, and a client that left ends it", ctx do
      test = self()

      admin = fn "Relay.listen", "[]", caller, :given ->
        send(test, {:running, self()})
        send(caller.emit, {:flezha_emit, {:output, "p1", %{"channel" => "out"}}})
        receive(do: (:never -> {:ok, "[]"}))
      end

      start(ctx,
        plug: FlezhaHttp.Api,
        verify: fn "t" -> {:ok, %{source: :http}} end,
        admin: admin,
        allowed_origins: [],
        max_pending_events: 10,
        heartbeat_ms: 100
      )

      {conn, ref} =
        Client.open(
          ctx.port,
          "POST",
          "/v1/stream/Relay.listen",
          [{"authorization", "Bearer t"}],
          "[]"
        )

      {conn, response} =
        Client.read(conn, ref, %{status: nil, headers: [], body: []}, fn acc ->
          IO.iodata_to_binary(acc.body) =~ "event: output"
        end)

      assert response.status == 200
      refute Map.get(response, :done)
      assert IO.iodata_to_binary(response.body) =~ ~s("payload":"p1")

      assert_receive {:running, running}
      monitor = Process.monitor(running)
      {:ok, _conn} = Mint.HTTP1.close(conn)
      assert_receive {:DOWN, ^monitor, :process, ^running, _reason}, 5_000
    end
  end

  describe "the API over TLS" do
    defp tls_api(ctx, admin) do
      start(ctx,
        plug: FlezhaHttp.Api,
        verify: fn "t" -> {:ok, %{source: :http}} end,
        admin: admin,
        allowed_origins: [],
        max_pending_events: 10,
        http_2: true,
        tls_certfile: Path.join(ctx.certs, "api/server/node.pem"),
        tls_keyfile: Path.join(ctx.certs, "api/server/node.key"),
        tls_client_cacertfile: Path.join(ctx.certs, "api/ca.pem")
      )
    end

    defp client_tls(ctx, nil), do: [cacertfile: Path.join(ctx.certs, "api/ca.pem")]

    defp client_tls(ctx, who) do
      [
        cacertfile: Path.join(ctx.certs, "api/ca.pem"),
        certfile: Path.join(ctx.certs, "#{who}/node.pem"),
        keyfile: Path.join(ctx.certs, "#{who}/node.key")
      ]
    end

    # One call over `protocol`, read to its end: `{:ok, status, body}`, or the
    # error the connection failed with.
    defp tls_call(ctx, protocol, who) do
      with {:ok, conn} <-
             Mint.HTTP.connect(:https, "127.0.0.1", ctx.port,
               mode: :passive,
               protocols: [protocol],
               transport_opts: client_tls(ctx, who)
             ),
           {:ok, conn, ref} <-
             Mint.HTTP.request(conn, "POST", "/v1/call/Relay.list", bearer(), "[]") do
        drain(conn, [ref], %{})
        |> case do
          {:ok, conn, %{^ref => response}} ->
            Mint.HTTP.close(conn)
            {:ok, response.status, IO.iodata_to_binary(response.body)}

          {:error, reason} ->
            {:error, reason}
        end
      else
        # Under TLS 1.3 a refused client learns it on its first write, not at
        # connect.
        {:error, _conn, reason} -> {:error, reason}
        {:error, reason} -> {:error, reason}
      end
    end

    defp bearer, do: [{"authorization", "Bearer t"}, {"content-type", "application/json"}]

    # Reads every response of `refs` to its end, each as `%{status:, body:}`.
    defp drain(conn, refs, acc) do
      if Enum.all?(refs, &get_in(acc, [&1, :done])) do
        {:ok, conn, acc}
      else
        case Mint.HTTP.recv(conn, 0, 5_000) do
          {:ok, conn, responses} -> drain(conn, refs, Enum.reduce(responses, acc, &response/2))
          {:error, _conn, reason, _responses} -> {:error, reason}
        end
      end
    end

    defp response({:status, ref, status}, acc),
      do: Map.put(acc, ref, %{status: status, body: [], done: false})

    defp response({:data, ref, data}, acc), do: update_in(acc, [ref, :body], &[&1 | data])
    defp response({:done, ref}, acc), do: put_in(acc, [ref, :done], true)
    defp response(_other, acc), do: acc

    test "a client with a certificate from the listener's authority and a token is served",
         ctx do
      tls_api(ctx, fn "Relay.list", "[]", _caller, :given -> {:ok, ~s(["r1"])} end)
      assert {:ok, 200, ~s(["r1"])} = tls_call(ctx, :http1, "api/client")
    end

    test "a client without a certificate, or with another authority's, is refused at the handshake",
         ctx do
      test = self()

      tls_api(ctx, fn name, _args, _caller, :given ->
        send(test, {:door, name})
        {:ok, "[]"}
      end)

      capture_log(fn ->
        for who <- [nil, "other/stranger"] do
          assert {:error, %Mint.TransportError{}} = tls_call(ctx, :http1, who)
        end
      end)

      refute_received {:door, _}
    end

    test "two streams and a call share one HTTP/2 connection, each stream its own events", ctx do
      admin = fn
        "Relay.listen", args, caller, :given ->
          [relay] = Jason.decode!(args)
          send(caller.emit, {:flezha_emit, {:output, relay, %{"channel" => "out"}}})
          {:ok, ~s("#{relay} ended")}

        "Relay.list", "[]", _caller, :given ->
          {:ok, ~s(["r1"])}
      end

      tls_api(ctx, admin)

      {:ok, conn} =
        Mint.HTTP.connect(:https, "127.0.0.1", ctx.port,
          mode: :passive,
          protocols: [:http2],
          transport_opts: client_tls(ctx, "api/client")
        )

      assert Mint.HTTP.protocol(conn) == :http2

      {:ok, conn, a} =
        Mint.HTTP.request(conn, "POST", "/v1/stream/Relay.listen", bearer(), ~s(["a"]))

      {:ok, conn, b} =
        Mint.HTTP.request(conn, "POST", "/v1/stream/Relay.listen", bearer(), ~s(["b"]))

      {:ok, conn, call} = Mint.HTTP.request(conn, "POST", "/v1/call/Relay.list", bearer(), "[]")

      {:ok, conn, responses} = drain(conn, [a, b, call], %{})
      Mint.HTTP.close(conn)

      for {ref, relay} <- [{a, "a"}, {b, "b"}] do
        body = IO.iodata_to_binary(responses[ref].body)
        assert responses[ref].status == 200
        assert body =~ ~s("payload":"#{relay}")
        assert body =~ ~s(event: end\ndata: {"answer":"#{relay} ended"})
        refute body =~ ~s("payload":"#{if relay == "a", do: "b", else: "a"}")
      end

      assert %{status: 200, body: body} = responses[call]
      assert IO.iodata_to_binary(body) == ~s(["r1"])
    end

    test "a stream the client resets ends its operation at once", ctx do
      test = self()

      tls_api(ctx, fn "Relay.listen", _args, caller, :given ->
        send(test, {:listening, self()})
        send(caller.emit, {:flezha_emit, :attached})
        Process.sleep(:infinity)
      end)

      {:ok, conn} =
        Mint.HTTP.connect(:https, "127.0.0.1", ctx.port,
          mode: :passive,
          protocols: [:http2],
          transport_opts: client_tls(ctx, "api/client")
        )

      {:ok, conn, ref} =
        Mint.HTTP.request(conn, "POST", "/v1/stream/Relay.listen", bearer(), ~s(["a"]))

      assert_receive {:listening, operation}, 5_000
      monitor = Process.monitor(operation)

      {:ok, conn} = Mint.HTTP2.cancel_request(conn, ref)

      # The heartbeat is 15 s, so only the reset itself can end it this soon.
      assert_receive {:DOWN, ^monitor, :process, ^operation, _reason}, 2_000
      Mint.HTTP.close(conn)
    end
  end
end
