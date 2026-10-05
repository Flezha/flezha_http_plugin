defmodule FlezhaHttp.StatusTest do
  use ExUnit.Case, async: true

  alias Flezha.Error
  alias FlezhaHttp.Status

  @details %{
    "relay" => "gateway",
    "deadline_ms" => 1,
    "limit" => 1,
    "timeout_ms" => 1,
    "max_waiting" => 1,
    "max_streams" => 1,
    "reason" => "r"
  }

  for {code, status} <- [
        {"call.timeout", 504},
        {"call.busy", 503},
        {"call.unavailable", 503},
        {"call.callee_ended", 503},
        {"call.failed", 500},
        {"call.absorbed", 409},
        {"call.not_accepted", 409},
        {"http.body_too_large", 413},
        {"http.body_timeout", 408},
        {"http.length_required", 411},
        {"http.busy", 503},
        {"http.streams_full", 503},
        {"http.answer_invalid", 502},
        {"relay.not_found", 404}
      ] do
    test "#{code} is #{status}" do
      error = Error.new(unquote(code), @details)
      assert error.code == unquote(code), "#{unquote(code)} is not in the catalogue"
      assert Status.of(error) == unquote(status)
    end
  end

  for {class, status} <- [
        invalid: 400,
        denied: 403,
        not_found: 404,
        conflict: 409,
        unavailable: 503,
        unreachable: 502,
        internal: 500
      ] do
    test "a code the table does not name, of class #{class}, is #{status}" do
      assert Status.of(%Error{code: "made.up", class: unquote(class), message: "m"}) ==
               unquote(status)
    end
  end

  test "an error is answered with its document, and retry-after where a retry helps" do
    conn = Status.send_error(Plug.Test.conn(:get, "/"), Error.new("http.busy", @details))

    assert conn.status == 503
    assert Plug.Conn.get_resp_header(conn, "retry-after") == ["1"]
    assert Plug.Conn.get_resp_header(conn, "content-type") == ["application/json"]

    assert %{"error" => %{"code" => "http.busy", "class" => "unavailable"}} =
             Jason.decode!(conn.resp_body)

    conn = Status.send_error(Plug.Test.conn(:get, "/"), Error.new("call.timeout", @details))
    assert Plug.Conn.get_resp_header(conn, "retry-after") == []
  end
end
