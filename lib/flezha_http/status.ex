defmodule FlezhaHttp.Status do
  @moduledoc """
  The HTTP status of every failure the plugin answers, and the one way it
  answers one: the error model's JSON document.

  A code the table does not name takes its class's status, so a code added to
  the catalogue later needs no plugin release.
  """

  alias Flezha.Error

  @codes %{
    "call.timeout" => 504,
    "call.busy" => 503,
    "call.unavailable" => 503,
    "call.callee_ended" => 503,
    # A request its host failed on is a server error, whatever its class says.
    "call.failed" => 500,
    "call.absorbed" => 409,
    "call.not_accepted" => 409,
    "http.body_too_large" => 413,
    "http.body_timeout" => 408,
    "http.length_required" => 411,
    "http.busy" => 503,
    "http.streams_full" => 503,
    "http.answer_invalid" => 502,
    "operator.not_found" => 404
  }

  @classes %{
    invalid: 400,
    denied: 403,
    not_found: 404,
    conflict: 409,
    unavailable: 503,
    unreachable: 502,
    internal: 500
  }

  @retry_after ~w(call.busy call.unavailable http.busy http.streams_full)

  @doc "The status `error` is answered with."
  @spec of(Error.t()) :: 400..599
  def of(%Error{code: code, class: class}),
    do: Map.get(@codes, code) || Map.fetch!(@classes, class)

  # The details a client may read of an error the plugin did not build: the ones
  # naming the operator, the channel and the call's bounds, never the author's
  # text, an entry or a reason.
  @public_details ~w(operator namespace channel attempts deadline_ms pending_max status bytes frames)

  @doc """
  What a client may read of an error the controller answered: its code, its class,
  its catalogue message filled only from the public details, and no hint. The
  full error stays with the controller (`flz operator listen`, `flz dlq`, its log).
  """
  @spec public(Error.t()) :: Error.t()
  def public(%Error{code: code, details: details} = error) do
    public = Map.take(details, @public_details)

    case Error.new(code, public) do
      %Error{code: ^code} = rebuilt ->
        %{rebuilt | message: unfilled_out(rebuilt.message), hint: nil}

      _unknown ->
        %{error | details: public, hint: nil}
    end
  end

  # The catalogue message without the clauses whose details were withheld:
  # "dead-lettered as '{entry}' after 1 attempt(s): {error}" reads
  # "dead-lettered after 1 attempt(s)".
  defp unfilled_out(message),
    do: Regex.replace(~r/ as '\{[a-z_]+\}'|:? '?\{[a-z_]+\}'?/, message, "")

  @doc """
  Answer `conn` with `error`: `status`, or its own, `retry-after` where a retry
  helps, and its document.
  """
  @spec send_error(Plug.Conn.t(), Error.t(), 400..599 | nil) :: Plug.Conn.t()
  def send_error(conn, %Error{code: code} = error, status \\ nil) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json", nil)
    |> then(
      &if code in @retry_after, do: Plug.Conn.put_resp_header(&1, "retry-after", "1"), else: &1
    )
    |> Plug.Conn.send_resp(status || of(error), Error.render(error, :json))
  end
end
