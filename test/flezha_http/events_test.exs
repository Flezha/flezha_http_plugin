defmodule FlezhaHttp.EventsTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias Flezha.Error
  alias FlezhaHttp.Handler
  alias FlezhaHttp.StandIn

  @part_md %{
    "channel" => "events",
    "flz.part" => "0",
    "flz.part_attempt" => "1",
    "flz.cell" => "anna-42/turn/",
    "flz.key" => "k"
  }

  # A stream request whose host answers `envelope` and whose listener is `listen`.
  defp stream(envelope, listen, overrides \\ %{}) do
    {:ok, overwatch} = StandIn.start(self(), fn _ -> StandIn.ok(envelope) end)

    Handler.call(
      conn(:get, "/sessions/anna-42/events"),
      StandIn.config(overwatch, Map.merge(%{listen: listen}, Map.new(overrides)))
    )
  end

  # A listener that attaches, hands over `events` and ends with `outcome`.
  defp listener(events, outcome) do
    test = self()

    fn namespace, target, opts, handler ->
      send(test, {:listen, namespace, target, opts})
      Keyword.fetch!(opts, :before).()
      Enum.each(events, &(:continue = handler.(&1)))
      outcome
    end
  end

  # The events as the client reads them: `{event, data}`, or `:comment`.
  defp events(conn) do
    assert conn.status == 200

    conn.resp_body
    |> String.split("\n\n", trim: true)
    |> Enum.map(fn
      ":" ->
        :comment

      frame ->
        ["event: " <> event, "data: " <> data] = String.split(frame, "\n")
        {event, Jason.decode!(data)}
    end)
  end

  test "the listener attaches in the host's namespace, however the target is named" do
    conn = stream(%{stream: "anna-42"}, listener([], {:ok, :done}), heartbeat_ms: 1_000)

    assert_received {:listen, "default", "anna-42", opts}
    assert opts[:window_ms] == :infinity
    assert opts[:idle_ms] == 1_000
    assert conn.status == 200
    assert Plug.Conn.get_resp_header(conn, "content-type") == ["text/event-stream"]
    assert Plug.Conn.get_resp_header(conn, "cache-control") == ["no-cache"]
    assert Plug.Conn.get_resp_header(conn, "x-accel-buffering") == ["no"]
  end

  test "the envelope's headers are sent with the stream" do
    conn =
      stream(
        %{stream: "anna-42", headers: %{"access-control-allow-origin" => "https://app.example"}},
        listener([], {:ok, :done})
      )

    assert Plug.Conn.get_resp_header(conn, "access-control-allow-origin") == [
             "https://app.example"
           ]
  end

  test "each event has its name and data, and nothing else of the metadata leaves" do
    notice =
      Error.new("input.dead_lettered",
        operator: "anna-42",
        channel: "turn",
        entry: "dlq-7",
        tasklet: "Chat.Agent.Turn",
        attempts: 1,
        error: "upstream key sk-123 rejected"
      )

    events = [
      {:part, "Hel", @part_md},
      {:output, "héllo", %{"channel" => "events", "flz.cell" => "c"}},
      {:output, <<0xFF, 0x00>>, %{"channel" => "events"}},
      {:dead_lettered, notice, %{"channel" => "turn"}},
      :idle
    ]

    conn = stream(%{stream: "anna-42"}, listener(events, {:ok, :operator_ended}))

    assert [
             :comment,
             {"part",
              %{"channel" => "events", "part" => 0, "attempt" => 1, "payload" => "Hel"} = part},
             {"output", %{"channel" => "events", "payload" => "héllo"} = output},
             {"output", %{"channel" => "events", "payload_base64" => "/wA="}},
             {"dead_lettered", %{"error" => dead}},
             :comment,
             {"ended", %{}}
           ] = events(conn)

    assert map_size(part) == 4
    assert map_size(output) == 2
    assert %{"code" => "input.dead_lettered", "hint" => nil} = dead
    assert dead["details"] == %{"operator" => "anna-42", "channel" => "turn", "attempts" => 1}

    assert dead["message"] ==
             "an input of operator 'anna-42' on channel 'turn' was dead-lettered after 1 attempt(s)"

    refute conn.resp_body =~ "sk-123"
    refute conn.resp_body =~ "dlq-7"
  end

  test "a listener ended with an error is told as closed, carrying the error" do
    overrun = Error.new("listener.overrun", operator: "anna-42", bytes: 1, frames: 1)
    conn = stream(%{stream: "anna-42"}, listener([], {:error, overrun}))

    assert [:comment, {"closed", %{"error" => %{"code" => "listener.overrun"}}}] = events(conn)
  end

  test "a refused attach writes nothing and answers the error's status" do
    refused = Error.new("listener.detached", operator: "anna-42")
    conn = stream(%{stream: "anna-42"}, fn _, _, _, _ -> {:error, refused} end)

    assert conn.status == 409
    assert conn.state == :sent
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "listener.detached"
  end

  describe "a target that does not exist yet" do
    setup do
      test = self()
      not_found = Error.new("operator.not_found", namespace: "default", operator: "ghost")

      %{
        not_found: not_found,
        absent: fn _, _, _, _ ->
          send(test, :attempt)
          {:error, not_found}
        end
      }
    end

    test "is attached again until stream_wait_ms has passed, then answered 404", ctx do
      started = System.monotonic_time(:millisecond)
      conn = stream(%{stream: "ghost"}, ctx.absent, stream_wait_ms: 1_000)
      waited = System.monotonic_time(:millisecond) - started

      assert conn.status == 404
      assert Jason.decode!(conn.resp_body)["error"]["code"] == "operator.not_found"
      assert waited >= 1_000
      assert length(drain(:attempt)) >= 2
    end

    test "is answered 404 at once with a wait of 0", ctx do
      conn = stream(%{stream: "ghost"}, ctx.absent, stream_wait_ms: 0)

      assert conn.status == 404
      assert length(drain(:attempt)) == 1
    end

    test "streams once it exists", ctx do
      attempts = :counters.new(1, [])

      listen = fn ns, target, opts, handler ->
        :counters.add(attempts, 1, 1)

        if :counters.get(attempts, 1) < 3,
          do: {:error, ctx.not_found},
          else: listener([], {:ok, :done}).(ns, target, opts, handler)
      end

      conn = stream(%{stream: "later"}, listen, stream_wait_ms: 3_000)
      assert conn.status == 200
      assert :counters.get(attempts, 1) == 3
    end
  end

  test "the stream cap refuses, attaching nothing" do
    {:ok, overwatch} = StandIn.start(self(), fn _ -> StandIn.ok(%{stream: "anna-42"}) end)
    config = StandIn.config(overwatch, max_streams: 1, listen: listener([], {:ok, :done}))
    :atomics.put(config.counters, 2, 1)

    conn = Handler.call(conn(:get, "/events"), config)

    assert conn.status == 503
    assert Plug.Conn.get_resp_header(conn, "retry-after") == ["1"]

    assert %{"code" => "http.streams_full", "details" => %{"max_streams" => 1}} =
             Jason.decode!(conn.resp_body)["error"]

    refute_received {:listen, _, _, _}
    assert :atomics.get(config.counters, 2) == 1
    assert :atomics.get(config.counters, 3) == 1
  end

  defp drain(message) do
    receive do
      ^message -> [message | drain(message)]
    after
      0 -> []
    end
  end
end
