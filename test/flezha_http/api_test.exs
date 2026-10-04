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
        request(:post, "/v1/call/Operator.list", ~s(["default"]), [
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
      conn = request(:post, "/v1/call/Operator.list", String.duplicate("a", 2_048))
      assert conn.status == 413
      assert json(conn)["error"]["code"] == "http.body_too_large"
    end

    test "a call past the waiting cap is a 503 naming the plugin" do
      config = config(max_waiting: 1)
      :atomics.put(config.counters, 1, 1)
      conn = request(:post, "/v1/call/Operator.list", ~s(["default"]), [], config)
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
      assert request(:post, "/v1/call/Operator.list", "[]", [], config).status == 503
      assert_receive {:running, running}

      conn = request(:post, "/v1/call/Operator.list", "[]", [], config)
      assert json(conn)["error"]["code"] == "http.busy"

      send(running, :finish)
      Process.sleep(50)

      assert request(:post, "/v1/call/Operator.list", "[]", [], config(max_waiting: 1)).status ==
               200
    end

    test "a call past its deadline answers admin.timeout" do
      slow = fn _, _ -> Process.sleep(500) && {:ok, "[]"} end

      conn =
        request(:post, "/v1/call/Operator.list", "[]", [], config(deadline_ms: 100, answer: slow))

      assert conn.status == 503
      assert json(conn)["error"]["code"] == "admin.timeout"
    end
  end

  describe "routes" do
    test "the wrong method is a 405 naming the right one, an unknown path a 404" do
      for {method, path, allowed} <- [
            {:get, "/mcp", "POST"},
            {:delete, "/mcp", "POST"},
            {:post, "/v1/catalogue", "GET"},
            {:get, "/v1/call/Operator.list", "POST"}
          ] do
        conn = request(method, path)
        assert conn.status == 405
        assert Plug.Conn.get_resp_header(conn, "allow") == [allowed]
      end

      assert request(:get, "/nothing").status == 404
    end
  end

  describe "the plain JSON form" do
    test "a call is the door's, with the token's context and the array as written" do
      answer = fn "Operator.list", _ -> {:ok, ~s([{"id":"echo"}])} end
      conn = request(:post, "/v1/call/Operator.list", ~s(["default"]), [], config(answer: answer))

      assert conn.status == 200
      assert json(conn) == [%{"id" => "echo"}]
      assert_received {:door, "Operator.list", ~s(["default"]), @viewer}
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
      assert json(conn)["error"]["code"] == "admin.unknown_function"
      refute_received {:door, _, _, _}
    end

    test "a verb kept off the network is an unknown operation, whatever the role" do
      admin = %{@viewer | role: :admin, namespace: "_system"}
      config = config(context: admin, admin: &Flezha.Service.Admin.call/4)
      conn = request(:post, "/v1/call/Controller.stop", "[]", [], config)
      assert conn.status == 404
      assert json(conn)["error"]["code"] == "admin.unknown_function"
    end

    test "the catalogue lists what the role grants, in the catalogue's form" do
      names = for op <- json(request(:get, "/v1/catalogue"))["operations"], do: op["name"]

      assert "Operator.list" in names
      refute "Operator.start" in names
      refute "Dlq.list" in names

      ops = json(request(:get, "/v1/catalogue", "", [], config(context: @ops)))["operations"]
      refute Enum.any?(ops, &(&1["name"] in ["Controller.stop", "Operator.listen"]))

      assert %{"name" => "Dlq.list", "args" => [%{"name" => "operator_class"}]} =
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
                 "properties" => %{"operator_class" => %{"type" => "string"}},
                 "additionalProperties" => false
               },
               "annotations" => %{"readOnlyHint" => true}
             } = by_name["dlq_list"]

      refute Map.has_key?(by_name["dlq_list"]["inputSchema"], "required")
      assert "operator_list" in viewer
      refute Enum.any?(viewer, &(&1 in ["operator_start", "dlq_list"]))
      refute Map.has_key?(by_name, "controller_stop")
      refute Map.has_key?(by_name, "operator_listen")
    end

    test "tools/call maps the named arguments onto the door's array" do
      answer = fn "Operator.list", ["default"] -> {:ok, ~s([{"id":"echo"}])} end

      conn =
        mcp(
          "tools/call",
          %{"name" => "operator_list", "arguments" => %{"namespace" => "default"}},
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
      assert result["structuredContent"]["error"]["code"] == "admin.unknown_parameter"
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
        source_operator_id: nil,
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
        request(:post, "/v1/call/Operator.list", secret_body)
        request(:get, "/v1/catalogue")
        request(:get, "/mcp")

        request(
          :post,
          "/mcp",
          ~s({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"x":"secret-body-value-91c2"}})
        )

        mcp("tools/call", %{
          "name" => "dlq_list",
          "arguments" => %{"operator_class" => "secret-body-value-91c2"}
        })

        anonymous(:post, "/mcp", [{"authorization", "Bearer " <> @token <> "x"}])
        request(:get, "/nothing", "", [{"origin", "https://secret-origin.test"}])
      end)

    assert log =~ "[FlezhaHttp] POST /v1/call/Operator.list 200"
    assert log =~ "tool=Dlq.list"
    refute log =~ @token
    refute log =~ "secret-body-value-91c2"
    refute log =~ "secret-origin"
    refute log =~ "Bearer"
  end
end
