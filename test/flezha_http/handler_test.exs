defmodule FlezhaHttp.HandlerTest do
  # Not async: the log test lowers the handler's module level for a moment.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Plug.Test

  alias Flezha.Error
  alias FlezhaHttp.Handler
  alias FlezhaHttp.StandIn

  defp serve(conn, answer, overrides \\ %{}) do
    {:ok, overwatch} = StandIn.start(self(), answer)
    Handler.call(conn, StandIn.config(overwatch, overrides))
  end

  defp echo(_payload), do: StandIn.ok(%{status: 200, body: "ok"})

  defp error_body(conn), do: Jason.decode!(conn.resp_body)["error"]

  describe "every request becomes one outside call" do
    test "carrying the envelope with only the allowed headers" do
      conn =
        conn(:post, "/sessions/anna-42/messages?user=anna", ~s({"text":"hi"}))
        |> Plug.Conn.put_req_header("x-api-key", "k1")
        |> Plug.Conn.put_req_header("authorization", "Bearer t")
        |> serve(&echo/1, pass_headers: ["x-api-key"])

      assert conn.status == 200
      assert_received {:called, payload, metadata, 1_000}

      assert Jason.decode!(payload) == %{
               "method" => "POST",
               "path" => "/sessions/anna-42/messages",
               "query" => "user=anna",
               "headers" => %{"x-api-key" => "k1"},
               "body" => ~s({"text":"hi"})
             }

      assert metadata == %{"channel" => "http"}
      refute payload =~ "Bearer t"
    end

    test "carrying a body that is not UTF-8 in base64" do
      serve(conn(:post, "/", <<0xFF, 0xFE, 0x00, 0x81>>), &echo/1)
      assert_received {:called, payload, _metadata, _deadline}
      envelope = Jason.decode!(payload)
      assert envelope["body_base64"] == Base.encode64(<<0xFF, 0xFE, 0x00, 0x81>>)
      refute Map.has_key?(envelope, "body")
    end

    test "whose metadata a client cannot reach" do
      conn(:get, "/?flz.msg_id=y")
      |> Plug.Conn.put_req_header("flz.reply_to", "x")
      |> serve(&echo/1, pass_headers: ["flz.reply_to"])

      assert_received {:called, payload, metadata, _deadline}
      assert metadata == %{"channel" => "http"}

      assert %{"query" => "flz.msg_id=y", "headers" => %{"flz.reply_to" => "x"}} =
               Jason.decode!(payload)
    end
  end

  describe "the request body is bounded" do
    test "by its content-length, before a byte is read" do
      conn =
        conn(:post, "/", String.duplicate("a", 2048))
        |> Plug.Conn.put_req_header("content-length", "2048")
        |> serve(&echo/1, max_body_bytes: 1024)

      assert conn.status == 413

      assert %{"code" => "http.body_too_large", "details" => %{"limit" => 1024}} =
               error_body(conn)

      refute_received {:called, _, _, _}
    end

    test "and by what is read when no length is given" do
      conn = serve(conn(:post, "/", String.duplicate("a", 2048)), &echo/1, max_body_bytes: 1024)

      assert conn.status == 413
      assert %{"code" => "http.body_too_large"} = error_body(conn)
      refute_received {:called, _, _, _}
    end

    test "a full waiting cap refuses before the body is read" do
      {:ok, overwatch} = StandIn.start(self(), &echo/1)
      config = StandIn.config(overwatch, max_waiting: 1, max_body_bytes: 1024)
      :atomics.put(config.counters, 1, 1)

      conn = Handler.call(conn(:post, "/", String.duplicate("a", 2048)), config)

      assert conn.status == 503
      assert %{"code" => "http.busy"} = error_body(conn)
      refute_received {:called, _, _, _}
    end

    test "a body at the limit passes" do
      assert serve(conn(:post, "/", String.duplicate("a", 1024)), &echo/1, max_body_bytes: 1024).status ==
               200
    end
  end

  test "the waiting cap refuses at once, and the relay receives only what it admits" do
    test = self()

    answer = fn _ ->
      send(test, {:waiting, self()})
      receive(do: (:release -> echo(nil)))
    end

    {:ok, overwatch} = StandIn.start(test, answer)
    config = StandIn.config(overwatch, max_waiting: 2)

    waiting =
      for _ <- 1..2 do
        task = Task.async(fn -> Handler.call(conn(:get, "/slow"), config) end)
        assert_receive {:waiting, answering}
        {task, answering}
      end

    conn = Handler.call(conn(:get, "/slow"), config)
    assert conn.status == 503
    assert Plug.Conn.get_resp_header(conn, "retry-after") == ["1"]
    assert %{"code" => "http.busy", "details" => %{"max_waiting" => 2}} = error_body(conn)

    for {task, answering} <- waiting do
      send(answering, :release)
      assert Task.await(task).status == 200
    end

    assert [{:called, _, _, _}, {:called, _, _, _}] = drain_calls()
    assert :atomics.get(config.counters, 1) == 0
    assert :atomics.get(config.counters, 3) == 1
  end

  defp drain_calls() do
    receive do
      {:called, _, _, _} = call -> [call | drain_calls()]
    after
      0 -> []
    end
  end

  describe "a plain answer envelope becomes the response" do
    test "202 with a JSON body" do
      conn =
        serve(conn(:post, "/sessions/a/messages"), fn _ ->
          StandIn.ok(%{status: 202, body: %{accepted: true}})
        end)

      assert conn.status == 202
      assert Plug.Conn.get_resp_header(conn, "content-type") == ["application/json"]
      assert conn.resp_body == ~s({"accepted":true})
    end

    test "429 with its retry-after and a text body" do
      conn =
        serve(conn(:post, "/"), fn _ ->
          StandIn.ok(%{
            status: 429,
            headers: %{"retry-after" => "3600"},
            body: "daily budget spent"
          })
        end)

      assert conn.status == 429
      assert Plug.Conn.get_resp_header(conn, "retry-after") == ["3600"]
      assert Plug.Conn.get_resp_header(conn, "content-type") == ["text/plain; charset=utf-8"]
      assert conn.resp_body == "daily budget spent"
    end
  end

  describe "an answer that is not an envelope is answered 502" do
    for {name, payload, fragment} <- [
          {"plain text", "hello", "not a JSON object"},
          {"a namespace", ~s({"stream":"anna-42","namespace":"other"}), ~s("namespace")},
          {"framing", ~s({"status":200,"headers":{"transfer-encoding":"chunked"},"body":"x"}),
           ~s("transfer-encoding")},
          {"a key forging a log line", ~s({"status":200,"x\\n[error] forged":1}),
           ~s("x\\n[error] forged")}
        ] do
      test "#{name}, logged once with the relay and the rule" do
        listen = fn _, _, _, _ -> flunk("no listener may be attached") end

        log =
          capture_log(fn ->
            conn =
              serve(conn(:get, "/"), fn _ -> StandIn.ok(unquote(payload)) end, listen: listen)

            send(self(), {:conn, conn})
          end)

        assert_received {:conn, conn}
        assert conn.status == 502
        assert %{"code" => "http.answer_invalid", "details" => details} = error_body(conn)
        assert details["relay"] == "gateway"
        assert details["reason"] =~ unquote(fragment)
        assert [line] = String.split(log, "\n", trim: true) |> Enum.filter(&(&1 =~ "[warning]"))
        assert line =~ "relay gateway answered an invalid envelope"
        assert line =~ unquote(fragment)
      end
    end
  end

  describe "every failure maps to one status" do
    for {code, status, retry} <- [
          {"call.timeout", 504, []},
          {"call.busy", 503, ["1"]},
          {"call.unavailable", 503, ["1"]},
          {"call.callee_ended", 503, []},
          {"call.failed", 500, []},
          {"call.absorbed", 409, []},
          {"call.not_accepted", 409, []}
        ] do
      test "#{code} is #{status}" do
        error = Error.new(unquote(code), relay: "gateway", deadline_ms: 1_000)
        conn = serve(conn(:get, "/nothing"), fn _ -> {:error, error} end)

        assert conn.status == unquote(status)
        assert Plug.Conn.get_resp_header(conn, "retry-after") == unquote(retry)
        assert Plug.Conn.get_resp_header(conn, "content-type") == ["application/json"]
        assert conn.resp_body == Error.render(FlezhaHttp.Status.public(error), :json)
      end
    end

    test "a failure's body carries neither the author's text, nor the entry, nor a hint" do
      error =
        Error.new("call.failed",
          relay: "gateway",
          dlq_ref: "dlq-9",
          error: "upstream key sk-123 rejected"
        )

      conn = serve(conn(:get, "/"), fn _ -> {:error, error} end)

      assert conn.status == 500
      assert %{"code" => "call.failed", "hint" => nil, "details" => details} = error_body(conn)
      assert details == %{"relay" => "gateway"}
      assert error_body(conn)["message"] == "relay 'gateway' dead-lettered the call's input"
      refute conn.resp_body =~ "sk-123"
      refute conn.resp_body =~ "dlq-9"
    end

    test "a code the plugin does not name is mapped by its class" do
      error = %Error{code: "made.up", class: :denied, message: "not for you", details: %{}}
      conn = serve(conn(:get, "/"), fn _ -> {:error, error} end)

      assert conn.status == 403
      assert conn.resp_body == Error.render(error, :json)
    end
  end

  test "the log holds the method, the path and the status, never a header, a body or a query" do
    Logger.put_module_level(Handler, :debug)
    on_exit(fn -> Logger.delete_module_level(Handler) end)

    log =
      capture_log([level: :debug], fn ->
        conn(:post, "/sessions?token=q-secret", "body-secret")
        |> Plug.Conn.put_req_header("x-api-key", "header-secret")
        |> serve(&echo/1, pass_headers: ["x-api-key"])
      end)

    assert log =~ "POST /sessions 200"
    refute log =~ "secret"
  end
end
