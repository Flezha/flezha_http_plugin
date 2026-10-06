defmodule FlezhaHttp.ApiTest do
  # Not async: the log test lowers the module's level for a moment.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Plug.Test

  alias Flezha.Error
  alias FlezhaHttp.Api
  alias FlezhaHttp.Client
  alias FlezhaHttp.Server

  @token "flzt_test_secret_7f3a"
  @viewer %{source: :http, principal: "ann", namespace: "default", role: :viewer}
  @ops %{@viewer | role: :ops}

  # A token is `@token` and resolves to `context`; every door call is reported
  # to the test and answered with `answer`.
  defp config(overrides \\ %{}) do
    overrides = Map.new(overrides)
    test = self()
    context = Map.get(overrides, :context, @viewer)
    answer = Map.get(overrides, :answer, fn _name, _args -> {:ok, "[]"} end)

    %{
      allowed_origins: [],
      deadline_ms: 1_000,
      max_body_bytes: 1_024,
      max_waiting: 4,
      body_timeout_ms: 1_000,
      source_plugin_id: "api",
      counters: :atomics.new(3, signed: true),
      verify: fn
        @token -> {:ok, context}
        _other -> {:error, Error.new("authz.token_unknown")}
      end,
      admin: fn name, args, caller, :given ->
        send(test, {:door, name, args, caller})
        answer.(name, args)
      end
    }
    |> Map.merge(Map.drop(overrides, [:context, :answer]))
    |> Api.init()
  end

  defp request(method, path, body \\ "", headers \\ [], config \\ config()),
    do:
      send_request(method, path, body, [{"authorization", "Bearer " <> @token} | headers], config)

  # A request with only `headers`, and a body larger than any cap: a refusal
  # before the body is read answers without it.
  defp anonymous(method, path, headers, config \\ config()),
    do: send_request(method, path, String.duplicate("a", 4_096), headers, config)

  defp send_request(method, path, body, headers, config) do
    Enum.reduce(headers, conn(method, path, body), fn {name, value}, conn ->
      Plug.Conn.put_req_header(conn, name, value)
    end)
    |> Api.call(config)
  end

  defp json(conn), do: Jason.decode!(conn.resp_body)

  @modern "2026-07-28"

  defp mcp(method, params \\ %{}, opts \\ []) do
    meta = %{
      "io.modelcontextprotocol/protocolVersion" => @modern,
      "io.modelcontextprotocol/clientCapabilities" => %{}
    }

    body = %{jsonrpc: "2.0", id: 1, method: method, params: Map.put(params, "_meta", meta)}

    headers =
      [{"mcp-protocol-version", @modern}, {"mcp-method", method}] ++
        if(params["name"], do: [{"mcp-name", params["name"]}], else: [])

    request(:post, "/mcp", Jason.encode!(body), headers, Keyword.get(opts, :config, config()))
  end

  defp legacy(message, config \\ config()),
    do: request(:post, "/mcp", Jason.encode!(Map.put(message, :jsonrpc, "2.0")), [], config)

  describe "the bearer token" do
    test "missing, or not a bearer, is a 401 asking for one, before the body is read" do
      for {headers, code} <- [
            {[], "authz.principal_not_bound"},
            {[{"authorization", "Basic YTpi"}], "authz.token_malformed"},
            {[{"authorization", "Bearer flzt_nobody"}], "authz.token_unknown"}
          ] do
        conn = anonymous(:post, "/mcp", headers)
        assert conn.status == 401, inspect(headers)
        assert Plug.Conn.get_resp_header(conn, "www-authenticate") == ["Bearer"]
        assert json(conn)["error"]["code"] == code
      end

      refute_received {:door, _, _, _}
    end

    test "an expired, revoked or malformed token answers its own code" do
      for code <- ~w(authz.token_expired authz.token_revoked authz.token_malformed) do
        config = config(verify: fn _ -> {:error, Error.new(code)} end)
        conn = request(:get, "/v1/catalogue", "", [], config)
        assert conn.status == 401
        assert json(conn)["error"]["code"] == code
      end
    end

    test "a missing header's hint names the header" do
      conn = anonymous(:get, "/v1/catalogue", [])
      assert json(conn)["error"]["hint"] =~ "Authorization: Bearer"
    end

    test "a registry not open yet is a 503, not a 401" do
      config = config(verify: fn _ -> {:error, Error.new("authz.registry_unavailable")} end)
      assert request(:get, "/v1/catalogue", "", [], config).status == 503
    end

    test "the scheme is read without regard to case" do
      conn = request(:get, "/v1/catalogue", "", [{"authorization", "bearer " <> @token}])
      assert conn.status == 200
    end
  end

  describe "the origin guard" do
    test "a page on another origin is refused before anything runs" do
      conn =
        request(:post, "/v1/call/Relay.list", ~s(["default"]), [
          {"origin", "https://evil.test"}
        ])

      assert conn.status == 403
      assert json(conn)["error"]["code"] == "http.origin_refused"
      refute_received {:door, _, _, _}
    end

    test "a listed origin and no origin pass" do
      config = config(allowed_origins: ["https://ops.test"])

      assert request(:get, "/v1/catalogue", "", [{"origin", "https://ops.test"}], config).status ==
               200

      assert request(:get, "/v1/catalogue").status == 200
    end
  end

  describe "limits" do
    test "a body over the cap is a 413" do
      conn = request(:post, "/v1/call/Relay.list", String.duplicate("a", 2_048))
      assert conn.status == 413
      assert json(conn)["error"]["code"] == "http.body_too_large"
    end

    test "a call past the waiting cap is a 503 naming the plugin" do
      config = config(max_waiting: 1)
      :atomics.put(config.counters, 1, 1)
      conn = request(:post, "/v1/call/Relay.list", ~s(["default"]), [], config)
      assert conn.status == 503
      assert %{"code" => "http.busy", "details" => %{"plugin" => "api"}} = json(conn)["error"]
      refute_received {:door, _, _, _}
    end

    # Fails when: an abandoned call frees its slot, so calls pile up unbounded.
    test "a call past its deadline keeps its waiting slot until it ends" do
      test = self()

      slow = fn _, _ ->
        send(test, {:running, self()})
        receive(do: (:finish -> {:ok, "[]"}))
      end

      config = config(max_waiting: 1, deadline_ms: 50, answer: slow)
      assert request(:post, "/v1/call/Relay.list", "[]", [], config).status == 503
      assert_receive {:running, running}

      conn = request(:post, "/v1/call/Relay.list", "[]", [], config)
      assert json(conn)["error"]["code"] == "http.busy"

      send(running, :finish)
      Process.sleep(50)

      assert request(:post, "/v1/call/Relay.list", "[]", [], config(max_waiting: 1)).status ==
               200
    end

    test "a call past its deadline answers control.timeout" do
      slow = fn _, _ -> Process.sleep(500) && {:ok, "[]"} end

      conn =
        request(:post, "/v1/call/Relay.list", "[]", [], config(deadline_ms: 100, answer: slow))

      assert conn.status == 503
      assert json(conn)["error"]["code"] == "control.timeout"
    end
  end

  describe "routes" do
    test "the wrong method is a 405 naming the right one, an unknown path a 404" do
      for {method, path, allowed} <- [
            {:get, "/mcp", "POST"},
            {:delete, "/mcp", "POST"},
            {:post, "/v1/catalogue", "GET"},
            {:get, "/v1/call/Relay.list", "POST"}
          ] do
        conn = request(method, path)
        assert conn.status == 405
        assert Plug.Conn.get_resp_header(conn, "allow") == [allowed]
      end

      assert request(:get, "/nothing").status == 404
    end
  end

  describe "a relay's channel" do
    @app %{@viewer | role: :app}

    defp relay_call(channel, body, answer, headers \\ []) do
      config = config(context: @app, answer: fn "Relay.call_channel", _args -> answer end)
      request(:post, "/v1/relays/orders-eu/" <> channel, body, headers, config)
    end

    test "a JSON call answers 200 with the relay's JSON answer" do
      body = ~s({"pair":"EUR/USD","amount":1000})

      conn =
        relay_call("place", body, {:ok, ~s({"answer":{"status":"placed"},"answer_codec":"json"})})

      assert conn.status == 200
      assert ["application/json"] = Plug.Conn.get_resp_header(conn, "content-type")
      assert json(conn) == %{"status" => "placed"}

      assert_received {:door, "Relay.call_channel",
                       ["default", "orders-eu", "place", encoded, %{"payload" => "base64"}], @app}

      assert Base.decode64!(encoded) == body
    end

    test "a channel that does not answer is a 202" do
      conn = relay_call("audit", "checked", {:ok, ~s({"accepted":true})})

      assert conn.status == 202
      assert json(conn) == %{"accepted" => true}
      assert_received {:door, "Relay.call_channel", [_, _, "audit", encoded, _], _}
      assert Base.decode64!(encoded) == "checked"
    end

    test "a text answer is text, and bytes travel as they are both ways" do
      conn = relay_call("note", "hi", {:ok, ~s({"answer":"ok","answer_codec":"text"})})
      assert conn.status == 200
      assert ["text/plain; charset=utf-8"] = Plug.Conn.get_resp_header(conn, "content-type")
      assert conn.resp_body == "ok"

      conn = relay_call("blob", <<1, 2, 3>>, {:ok, ~s({"answer":"/wA=","answer_codec":"bytes"})})
      assert ["application/octet-stream"] = Plug.Conn.get_resp_header(conn, "content-type")
      assert conn.resp_body == <<255, 0>>
      assert_received {:door, "Relay.call_channel", [_, _, "note", _, _], _}
      assert_received {:door, "Relay.call_channel", [_, _, "blob", encoded, _], _}
      assert Base.decode64!(encoded) == <<1, 2, 3>>
    end

    test "a wrong channel answers api.channel_unknown with its class's status" do
      unknown =
        Error.new("api.channel_unknown",
          relay: "orders-eu",
          channel: "plce",
          channels: "place, audit"
        )

      conn = relay_call("plce", "{}", {:error, unknown})

      assert conn.status == 404
      assert json(conn)["error"]["code"] == "api.channel_unknown"
    end

    # The door judges the token's own context, as `Relay.call_channel` under a
    # viewer is refused in `Flezha.Service.RelayCallTest`; the route answers
    # that refusal with its class's status.
    test "a viewer's call carries the viewer's context and its refusal is a 403" do
      denied = Error.new("authz.role_insufficient")
      config = config(answer: fn "Relay.call_channel", _args -> {:error, denied} end)
      conn = request(:post, "/v1/relays/orders-eu/place", ~s({"pair":"EUR/USD"}), [], config)

      assert conn.status == 403
      assert json(conn)["error"]["code"] == "authz.role_insufficient"
      assert_received {:door, "Relay.call_channel", _args, @viewer}
    end

    test "only POST reaches it" do
      conn = request(:get, "/v1/relays/orders-eu/place")
      assert conn.status == 405
      assert Plug.Conn.get_resp_header(conn, "allow") == ["POST"]
    end

    test "an app token's tools/list holds its namespace's relay tools beside the catalogue's" do
      api = [
        %{
          "factory" => "orders",
          "description" => nil,
          "channels" => [
            %{
              "channel" => "place",
              "codec" => "json",
              "schema" => nil,
              "description" => "Places an order",
              "answer_codec" => "json",
              "answer_schema" => nil,
              "tool" => "orders_place",
              "tool_taken" => false
            }
          ]
        }
      ]

      answer = fn "Relay.api", ["default"] -> {:ok, Jason.encode!(api)} end
      listed = json(mcp("tools/list", %{}, config: config(context: @app, answer: answer)))
      names = for tool <- listed["result"]["tools"], do: tool["name"]
      viewer = for tool <- json(mcp("tools/list"))["result"]["tools"], do: tool["name"]

      assert "relay_list" in names
      assert "flezha_guide" in names
      assert List.last(names) == "orders_place"
      refute "orders_place" in viewer
    end
  end

  describe "the plain JSON form" do
    test "a call is the door's, with the token's context and the array as written" do
      answer = fn "Relay.list", _ -> {:ok, ~s([{"id":"echo"}])} end
      conn = request(:post, "/v1/call/Relay.list", ~s(["default"]), [], config(answer: answer))

      assert conn.status == 200
      assert json(conn) == [%{"id" => "echo"}]
      assert_received {:door, "Relay.list", ~s(["default"]), @viewer}
    end

    test "a failure answers its error object with the status of its class" do
      missing = fn _, _ -> {:error, Error.new("dlq.not_found", entry: "e1")} end
      conn = request(:post, "/v1/call/Dlq.get", ~s(["e1"]), [], config(answer: missing))
      assert conn.status == 404
      assert %{"code" => "dlq.not_found", "class" => "not_found"} = json(conn)["error"]
    end

    test "a name that is not text is an unknown operation, its bytes never echoed" do
      conn = request(:post, "/v1/call/Op" <> <<0xFF, 0xFE>> <> ".list", "[]")
      assert conn.status == 404
      assert json(conn)["error"]["code"] == "control.unknown_function"
      refute_received {:door, _, _, _}
    end

    test "a verb kept off the network is an unknown operation, whatever the role" do
      admin = %{@viewer | role: :admin, namespace: "_system"}
      config = config(context: admin, admin: &Flezha.Service.Admin.call/4)
      conn = request(:post, "/v1/call/Controller.stop", "[]", [], config)
      assert conn.status == 404
      assert json(conn)["error"]["code"] == "control.unknown_function"
    end

    test "the catalogue lists what the role grants, in the catalogue's form" do
      names = for op <- json(request(:get, "/v1/catalogue"))["operations"], do: op["name"]

      assert "Relay.list" in names
      refute "Relay.start" in names
      refute "Dlq.list" in names

      ops = json(request(:get, "/v1/catalogue", "", [], config(context: @ops)))["operations"]
      refute Enum.any?(ops, &(&1["name"] in ["Controller.stop", "Relay.listen"]))

      assert %{"name" => "Dlq.list", "args" => [%{"name" => "relay_class"}]} =
               Enum.find(ops, &(&1["name"] == "Dlq.list"))
    end
  end

  describe "MCP, revision 2026-07-28" do
    test "server/discover lists the revisions, the tools capability and the server" do
      conn = mcp("server/discover")
      assert conn.status == 200
      result = json(conn)["result"]
      assert result["supportedVersions"] == ["2026-07-28", "2025-11-25"]
      assert result["capabilities"] == %{"tools" => %{"listChanged" => false}}
      assert result["_meta"]["io.modelcontextprotocol/serverInfo"]["name"] == "flezha"
      assert result["resultType"] == "complete"
      assert %{"ttlMs" => ttl, "cacheScope" => "public"} = result
      assert is_integer(ttl) and ttl >= 0
      assert Plug.Conn.get_resp_header(conn, "mcp-session-id") == []
    end

    test "headers that do not repeat the body are a 400 HeaderMismatch" do
      body =
        Jason.encode!(%{
          jsonrpc: "2.0",
          id: 1,
          method: "tools/list",
          params: %{
            "_meta" => %{
              "io.modelcontextprotocol/protocolVersion" => @modern,
              "io.modelcontextprotocol/clientCapabilities" => %{}
            }
          }
        })

      for headers <- [
            [],
            [{"mcp-protocol-version", @modern}],
            [{"mcp-protocol-version", @modern}, {"mcp-method", "tools/call"}]
          ] do
        conn = request(:post, "/mcp", body, headers)
        assert conn.status == 400
        assert json(conn)["error"]["code"] == -32_020
      end
    end

    test "an unsupported revision is a 400 listing the supported ones" do
      body =
        Jason.encode!(%{
          jsonrpc: "2.0",
          id: 7,
          method: "tools/list",
          params: %{"_meta" => %{"io.modelcontextprotocol/protocolVersion" => "1900-01-01"}}
        })

      conn = request(:post, "/mcp", body, [{"mcp-protocol-version", "1900-01-01"}])
      assert conn.status == 400

      assert %{"code" => -32_022, "data" => %{"requested" => "1900-01-01", "supported" => [_, _]}} =
               json(conn)["error"]
    end

    test "a request with no client capabilities is invalid params" do
      body =
        Jason.encode!(%{
          jsonrpc: "2.0",
          id: 1,
          method: "ping",
          params: %{"_meta" => %{"io.modelcontextprotocol/protocolVersion" => @modern}}
        })

      conn =
        request(:post, "/mcp", body, [{"mcp-protocol-version", @modern}, {"mcp-method", "ping"}])

      assert {conn.status, json(conn)["error"]["code"]} == {400, -32_602}
    end

    test "an unknown method is a 404 Method not found" do
      conn = mcp("resources/list")
      assert {conn.status, json(conn)["error"]["code"]} == {404, -32_601}
    end

    test "ping answers an empty result" do
      assert %{"resultType" => "complete"} = json(mcp("ping"))["result"]
    end

    test "tools/list holds the role's tools, each with its schema" do
      listed = json(mcp("tools/list", %{}, config: config(context: @ops)))["result"]
      assert %{"ttlMs" => 60_000, "cacheScope" => "private"} = listed
      tools = listed["tools"]
      by_name = Map.new(tools, &{&1["name"], &1})
      viewer = for tool <- json(mcp("tools/list"))["result"]["tools"], do: tool["name"]

      assert %{
               "inputSchema" => %{
                 "type" => "object",
                 "properties" => %{"relay_class" => %{"type" => "string"}},
                 "additionalProperties" => false
               },
               "annotations" => %{"readOnlyHint" => true}
             } = by_name["dlq_list"]

      refute Map.has_key?(by_name["dlq_list"]["inputSchema"], "required")
      assert "relay_list" in viewer
      refute Enum.any?(viewer, &(&1 in ["relay_start", "dlq_list"]))
      refute Map.has_key?(by_name, "controller_stop")
      refute Map.has_key?(by_name, "relay_listen")
    end

    test "the knowledge tools are listed for every role and answer without the door" do
      listed = for tool <- json(mcp("tools/list"))["result"]["tools"], do: tool["name"]

      assert Enum.take(listed, 5) ==
               ~w(flezha_guide flezha_sdk_example flezha_error flezha_docs flezha_new_project)

      conn =
        mcp("tools/call", %{"name" => "flezha_error", "arguments" => %{"code" => "dlq.not_found"}})

      assert json(conn)["result"]["structuredContent"]["code"] == "dlq.not_found"
      refute_received {:door, _, _, _}
    end

    test "tools/call maps the named arguments onto the door's array" do
      answer = fn "Relay.list", ["default"] -> {:ok, ~s([{"id":"echo"}])} end

      conn =
        mcp(
          "tools/call",
          %{"name" => "relay_list", "arguments" => %{"namespace" => "default"}},
          config: config(answer: answer)
        )

      result = json(conn)["result"]
      assert result["isError"] == false
      assert result["structuredContent"] == %{"result" => [%{"id" => "echo"}]}
      assert [%{"type" => "text", "text" => ~s([{"id":"echo"}])}] = result["content"]
    end

    test "a failure is a tool result with isError and the whole error object" do
      missing = fn _, _ -> {:error, Error.new("dlq.not_found", entry: "e1")} end

      conn =
        mcp("tools/call", %{"name" => "dlq_get", "arguments" => %{"entry_ref" => "e1"}},
          config: config(answer: missing)
        )

      result = json(conn)["result"]
      assert result["isError"] == true

      assert %{"code" => "dlq.not_found", "class" => "not_found", "message" => _, "details" => _} =
               result["structuredContent"]["error"]

      assert Jason.decode!(hd(result["content"])["text"])["error"]["code"] == "dlq.not_found"
    end

    test "an argument the tool does not take is a tool error naming it" do
      conn = mcp("tools/call", %{"name" => "dlq_list", "arguments" => %{"nope" => 1}})
      result = json(conn)["result"]
      assert result["isError"]
      assert result["structuredContent"]["error"]["code"] == "control.unknown_parameter"
      refute_received {:door, _, _, _}
    end

    test "an unknown tool, a verb kept off the network and arguments that are no object are protocol errors" do
      admin = %{@viewer | role: :admin, namespace: "_system"}
      config = config(context: admin, admin: &Flezha.Service.Admin.call/4)

      for params <- [
            %{"name" => "no_such_tool"},
            %{"name" => "controller_stop", "arguments" => %{}},
            %{"name" => "dlq_list", "arguments" => [1]}
          ] do
        conn = mcp("tools/call", params, config: config)
        assert json(conn)["error"]["code"] == -32_602, inspect(params)
        refute Map.has_key?(json(conn), "result")
      end
    end

    test "Mcp-Name may carry its value in Base64" do
      body =
        Jason.encode!(%{
          jsonrpc: "2.0",
          id: 1,
          method: "tools/call",
          params: %{
            "name" => "dlq_list",
            "arguments" => %{},
            "_meta" => %{
              "io.modelcontextprotocol/protocolVersion" => @modern,
              "io.modelcontextprotocol/clientCapabilities" => %{}
            }
          }
        })

      headers = [
        {"mcp-protocol-version", @modern},
        {"mcp-method", "tools/call"},
        {"mcp-name", "=?base64?" <> Base.encode64("dlq_list") <> "?="}
      ]

      assert json(request(:post, "/mcp", body, headers))["result"]["isError"] == false
    end
  end

  describe "MCP, the handshake revision" do
    test "initialize answers 2025-11-25, the tools capability and the server, and no session" do
      conn = legacy(%{id: 0, method: "initialize", params: %{protocolVersion: "2025-11-25"}})
      result = json(conn)["result"]
      assert result["protocolVersion"] == "2025-11-25"
      assert result["capabilities"] == %{"tools" => %{"listChanged" => false}}
      assert result["serverInfo"]["name"] == "flezha"
      assert Plug.Conn.get_resp_header(conn, "mcp-session-id") == []
    end

    test "initialize asking for another revision is answered with the one served" do
      conn = legacy(%{id: 0, method: "initialize", params: %{protocolVersion: "2024-11-05"}})
      assert json(conn)["result"]["protocolVersion"] == "2025-11-25"
    end

    test "a notification is a 202 with no body" do
      conn = legacy(%{method: "notifications/initialized"})
      assert {conn.status, conn.resp_body} == {202, ""}
    end

    test "tools/list and an unknown method need no metadata" do
      assert [_ | _] = json(legacy(%{id: 2, method: "tools/list"}))["result"]["tools"]
      conn = legacy(%{id: 3, method: "nope"})
      assert {conn.status, json(conn)["error"]["code"]} == {200, -32_601}
    end

    test "a header naming an unsupported revision is a 400, echoing it only as text" do
      body = Jason.encode!(%{jsonrpc: "2.0", id: 1, method: "tools/list"})
      conn = request(:post, "/mcp", body, [{"mcp-protocol-version", "2023-01-01"}])
      assert conn.status == 400
      assert json(conn)["error"]["data"]["requested"] == "2023-01-01"

      conn = request(:post, "/mcp", body, [{"mcp-protocol-version", <<0xFF, 0xFE>>}])
      assert conn.status == 400
      refute Map.has_key?(json(conn)["error"]["data"], "requested")
    end

    test "a header naming the pinned revision needs the metadata it requires" do
      body = Jason.encode!(%{jsonrpc: "2.0", id: 1, method: "ping"})
      conn = request(:post, "/mcp", body, [{"mcp-protocol-version", @modern}])
      assert {conn.status, json(conn)["error"]["code"]} == {400, -32_602}
    end

    test "a body that is no JSON, or a batch, is refused" do
      assert json(request(:post, "/mcp", "{not json"))["error"]["code"] == -32_700
      assert json(request(:post, "/mcp", "[]"))["error"]["code"] == -32_600
    end
  end

  test "TLS: the server answers HTTPS with the two files it names" do
    dir = Path.join(System.tmp_dir!(), "flezha_api_tls_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {cert, key} = {Path.join(dir, "cert.pem"), Path.join(dir, "key.pem")}

    {_, 0} =
      System.cmd(
        "openssl",
        ~w(req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=localhost -keyout) ++
          [key, "-out", cert],
        stderr_to_stdout: true
      )

    port = Client.free_port()
    {:ok, host} = Agent.start_link(fn -> nil end)

    config =
      config()
      |> Map.merge(%{
        name: {:global, make_ref()},
        port: port,
        bind: "127.0.0.1",
        max_connections: 4,
        overwatcher_pid: host,
        source_namespace: "_system",
        source_relay_id: nil,
        plug: Api,
        tls_certfile: cert,
        tls_keyfile: key
      })

    start_supervised!({Server, config}, restart: :temporary)

    {:ok, conn} =
      Mint.HTTP1.connect(:https, "127.0.0.1", port,
        mode: :passive,
        transport_opts: [verify: :verify_none]
      )

    {:ok, conn, ref} = Mint.HTTP1.request(conn, "GET", "/v1/catalogue", [], nil)
    {:ok, _conn, responses} = Mint.HTTP1.recv(conn, 0, 5_000)
    assert {:status, ^ref, 401} = List.keyfind(responses, :status, 0)
  end

  test "nothing secret reaches the log, at debug, on any route" do
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: :info) end)
    secret_body = ~s(["secret-body-value-91c2"])

    log =
      capture_log([level: :debug], fn ->
        request(:post, "/v1/call/Relay.list", secret_body)
        request(:get, "/v1/catalogue")
        request(:get, "/mcp")

        request(
          :post,
          "/mcp",
          ~s({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"x":"secret-body-value-91c2"}})
        )

        mcp("tools/call", %{
          "name" => "dlq_list",
          "arguments" => %{"relay_class" => "secret-body-value-91c2"}
        })

        anonymous(:post, "/mcp", [{"authorization", "Bearer " <> @token <> "x"}])
        request(:get, "/nothing", "", [{"origin", "https://secret-origin.test"}])
      end)

    assert log =~ "[FlezhaHttp] POST /v1/call/Relay.list 200"
    assert log =~ "tool=Dlq.list"
    refute log =~ @token
    refute log =~ "secret-body-value-91c2"
    refute log =~ "secret-origin"
    refute log =~ "Bearer"
  end
end
