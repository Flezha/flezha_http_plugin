defmodule FlezhaHttp.EnvelopeTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias FlezhaHttp.Envelope

  describe "the request envelope" do
    test "carries the method, the raw path and query, the passed headers and the body" do
      conn =
        conn(:post, "/sessions/anna%2042/messages?user=anna&x=%20")
        |> Plug.Conn.put_req_header("x-api-key", "k1")
        |> Plug.Conn.put_req_header("authorization", "Bearer t")

      assert Envelope.request(conn, ~s({"text":"hi"}), ["x-api-key"]) == %{
               "method" => "POST",
               "path" => "/sessions/anna%2042/messages",
               "query" => "user=anna&x=%20",
               "headers" => %{"x-api-key" => "k1"},
               "body" => ~s({"text":"hi"})
             }
    end

    test "has an empty query, no headers and an empty body by default" do
      assert Envelope.request(conn(:get, "/ping"), "", []) ==
               %{
                 "method" => "GET",
                 "path" => "/ping",
                 "query" => "",
                 "headers" => %{},
                 "body" => ""
               }
    end

    test "joins repeated fields, cookies with a semicolon" do
      conn = %{
        conn(:get, "/")
        | req_headers: [{"accept", "a"}, {"cookie", "a=1"}, {"accept", "b"}, {"cookie", "b=2"}]
      }

      assert %{"headers" => %{"accept" => "a, b", "cookie" => "a=1; b=2"}} =
               Envelope.request(conn, "", ["accept", "cookie", "absent"])
    end

    test "carries bytes that are not UTF-8 in base64 and no body" do
      bytes = <<0xFF, 0xFE, 0x00, 0x81>>
      envelope = Envelope.request(conn(:post, "/"), bytes, [])
      assert envelope["body_base64"] == Base.encode64(bytes)
      refute Map.has_key?(envelope, "body")
    end
  end

  describe "a plain answer" do
    test "a JSON body is encoded and typed application/json" do
      assert {:ok, {:plain, 202, [{"content-type", "application/json"}], body}} =
               Envelope.answer(~s({"status":202,"body":{"accepted":true}}))

      assert IO.iodata_to_binary(body) == ~s({"accepted":true})
    end

    test "a string body is text, and headers pass" do
      assert {:ok, {:plain, 429, headers, "daily budget spent"}} =
               Envelope.answer(
                 ~s({"status":429,"headers":{"retry-after":"3600"},"body":"daily budget spent"})
               )

      assert Enum.sort(headers) == [
               {"content-type", "text/plain; charset=utf-8"},
               {"retry-after", "3600"}
             ]
    end

    test "body_base64 is bytes, and a content-type header overrides the default" do
      assert {:ok, {:plain, 200, [{"content-type", "application/octet-stream"}], <<1, 2>>}} =
               Envelope.answer(~s({"status":200,"body_base64":"AQI="}))

      assert {:ok, {:plain, 200, [{"content-type", "text/csv"}], "a,b"}} =
               Envelope.answer(
                 ~s({"status":200,"headers":{"content-type":"text/csv"},"body":"a,b"})
               )
    end

    test "no body is an empty body with no content type" do
      assert {:ok, {:plain, 204, [], ""}} = Envelope.answer(~s({"status":204}))
    end
  end

  describe "a stream answer" do
    test "names its target and its headers" do
      assert {:ok, {:stream, "anna-42", [{"access-control-allow-origin", "https://app.example"}]}} =
               Envelope.answer(
                 ~s({"stream":"anna-42","headers":{"access-control-allow-origin":"https://app.example"}})
               )
    end

    test "of 255 bytes is accepted and of 256 refused" do
      assert {:ok, {:stream, _, []}} =
               Envelope.answer(Jason.encode!(%{stream: String.duplicate("a", 255)}))

      assert {:error, reason} =
               Envelope.answer(Jason.encode!(%{stream: String.duplicate("a", 256)}))

      assert reason =~ "255 bytes"
    end
  end

  describe "an answer that is not an envelope" do
    for {name, payload, fragment} <- [
          {"plain text", "hello", "not a JSON object"},
          {"a JSON array", "[1]", "not a JSON object"},
          {"a namespace", ~s({"stream":"anna-42","namespace":"other"}), ~s("namespace")},
          {"neither status nor stream", ~s({"body":"x"}), "neither 'status' nor 'stream'"},
          {"stream beside status", ~s({"stream":"a","status":200}), "cannot stand beside"},
          {"stream beside body", ~s({"stream":"a","body":"x"}), "cannot stand beside"},
          {"an empty stream", ~s({"stream":""}), "non-empty string"},
          {"a stream that is not a string", ~s({"stream":7}), "non-empty string"},
          {"body beside body_base64", ~s({"status":200,"body":"x","body_base64":"eA=="}), "both"},
          {"a status out of range", ~s({"status":700}), "200 to 599"},
          {"a status that is text", ~s({"status":"200"}), "200 to 599"},
          {"a 204 with a body", ~s({"status":204,"body":"x"}), "a 204 answer carries no body"},
          {"a 304 with a body", ~s({"status":304,"body_base64":"eA=="}), "a 304 answer"},
          {"headers that are a list", ~s({"status":200,"headers":[]}), "'headers' must be"},
          {"an upper-case header", ~s({"status":200,"headers":{"X-A":"1"}}), ~s("X-A")},
          {"a CR or LF in a value", ~s({"status":200,"headers":{"x-a":"1\\r\\nx-b: 2"}}),
           "CR, LF"},
          {"a NUL in a value", ~s({"status":200,"headers":{"x-a":"1\\u0000"}}), "CR, LF or NUL"},
          {"a value that is not text", ~s({"status":200,"headers":{"x-a":1}}),
           "must be a string"},
          {"bad base64", ~s({"status":200,"body_base64":"%%"}), "not base64"}
        ] do
      test "#{name} is refused, naming the rule" do
        assert {:error, reason} = Envelope.answer(unquote(payload))
        assert reason =~ unquote(fragment)
      end
    end

    for name <-
          ~w(connection content-length keep-alive proxy-connection te trailer transfer-encoding upgrade) do
      test "the framing header #{name} is refused" do
        assert {:error, reason} =
                 Envelope.answer(Jason.encode!(%{status: 200, headers: %{unquote(name) => "x"}}))

        assert reason =~ ~s("#{unquote(name)}" is framing)
      end
    end
  end
end
