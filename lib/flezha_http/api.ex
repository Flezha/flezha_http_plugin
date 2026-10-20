defmodule FlezhaHttp.Api do
  @moduledoc """
  The `http_api` provider's Plug: the controller's published operations, each
  call made through `Flezha.Service.Admin` as the principal of the bearer token
  the request carries. It keeps no list of operations, no policy and no
  dispatch of its own.

  - `POST /mcp`: MCP over Streamable HTTP (`Flezha.Mcp`).
  - `GET /v1/catalogue`: the operations the token's role may call, in the
    catalogue's own form.
  - `POST /v1/call/<Name>`: one operation with a JSON array of arguments,
    answered with its JSON or its error object.
  - `POST /v1/relays/<id>/<channel>[?key=<key>]`: a relay's channel called
    with the body as its payload (`Relay.call_channel`), a partition group's
    member chosen by `key`, answered in the answer's format, or `202` for a
    channel that does not answer.

  A request is judged in this order: its `Origin`, its token, its route, a
  waiting slot, its body, then the call within `deadline_ms`. It logs the
  method, the path, the status, the duration and the tool called, at debug
  level, and never a header, a body or a token.
  """

  @behaviour Plug

  alias Flezha.Config.Durations
  alias Flezha.Error
  alias Flezha.Service.Admin
  alias Flezha.Service.CallerContext
  alias FlezhaHttp.Handler
  alias FlezhaHttp.Server
  alias FlezhaHttp.Status

  # `verify` and `admin` are not options: tests set them on the config.
  @bearer_hint "send the header Authorization: Bearer <token>"

  @impl true
  def init(config) do
    Map.merge(
      %{verify: &CallerContext.from_token(:http, &1), admin: &Admin.call/4},
      config
    )
  end

  @impl true
  def call(conn, config), do: Handler.logged(conn, &serve(&1, config), &tool/1)

  defp tool(%{private: %{flezha_tool: name}}), do: " tool=#{name}"
  defp tool(_conn), do: ""

  defp serve(conn, config) do
    with :ok <- origin(conn, config),
         {:ok, context} <- identity(conn, config) do
      route(conn, context, config)
    else
      {:error, %Error{} = error} -> refuse(conn, error)
    end
  end

  # A browser sends `Origin`; a page on another site must not reach a listener
  # on this machine through DNS rebinding. A client that is not a browser sends
  # none.
  defp origin(conn, config) do
    case Plug.Conn.get_req_header(conn, "origin") do
      [] -> :ok
      [origin] -> if origin in config.allowed_origins, do: :ok, else: origin_refused()
      _several -> origin_refused()
    end
  end

  defp origin_refused, do: {:error, Error.new("http.origin_refused")}

  defp identity(conn, config) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      [] -> {:error, %{Error.new("authz.principal_not_bound") | hint: @bearer_hint}}
      [header] -> with {:ok, token} <- bearer(header), do: config.verify.(token)
      _several -> {:error, Error.new("authz.token_malformed")}
    end
  end

  defp bearer(header) do
    case String.split(header, " ", parts: 2) do
      [scheme, token] ->
        if String.downcase(scheme) == "bearer", do: {:ok, String.trim(token)}, else: malformed()

      _other ->
        malformed()
    end
  end

  defp malformed, do: {:error, Error.new("authz.token_malformed")}

  # An identity refusal is a 401 inviting a bearer token; the registry being
  # unavailable keeps its own status.
  defp refuse(conn, %Error{code: "authz." <> _, class: class} = error)
       when class in [:invalid, :denied] do
    conn
    |> Plug.Conn.put_resp_header("www-authenticate", "Bearer")
    |> Status.send_error(error, 401)
  end

  defp refuse(conn, error), do: Status.send_error(conn, error)

  defp route(conn, context, config) do
    case {conn.method, conn.path_info} do
      {"POST", ["mcp"]} ->
        held(conn, config, &mcp(&1, &2, context, config))

      {_method, ["mcp"]} ->
        not_allowed(conn, "POST")

      {"GET", ["v1", "catalogue"]} ->
        held(conn, config, fn conn, _ -> catalogue(conn, context) end)

      {_method, ["v1", "catalogue"]} ->
        not_allowed(conn, "GET")

      {"POST", ["v1", "call", name]} ->
        held(conn, config, &call_one(&1, name, &2, context, config))

      {_method, ["v1", "call", _name]} ->
        not_allowed(conn, "POST")

      {"POST", ["v1", "relays", relay, channel]} ->
        held(conn, config, &call_relay(&1, relay, channel, &2, context, config))

      {_method, ["v1", "relays", _relay, _channel]} ->
        not_allowed(conn, "POST")

      _unknown ->
        Plug.Conn.send_resp(conn, 404, "")
    end
  end

  # A waiting slot is held while the body is read, and again by each door
  # call for as long as it runs, so `max_waiting` bounds both.
  defp held(conn, config, answer) do
    case Server.occupy(config, :waiting, fn -> Handler.read_body(conn, config) end) do
      :full -> Status.send_error(conn, Handler.busy(config))
      {:error, %Error{} = error, conn} -> Status.send_error(conn, error)
      {:ok, body, conn} -> answer.(conn, body)
    end
  end

  defp mcp(conn, body, context, config) do
    headers = fn name ->
      case Plug.Conn.get_req_header(conn, name) do
        [value] -> value
        _none_or_several -> nil
      end
    end

    case Flezha.Mcp.answer(
           body,
           headers,
           fn -> Admin.catalogue(context) end,
           door(context, config),
           namespace(context)
         ) do
      {status, nil, _tool} -> Plug.Conn.send_resp(conn, status, "")
      {status, answer, nil} -> send_json(conn, status, Jason.encode!(answer))
      {status, answer, tool} -> conn |> named(tool) |> send_json(status, Jason.encode!(answer))
    end
  end

  defp named(conn, operation), do: Plug.Conn.put_private(conn, :flezha_tool, operation)

  defp catalogue(conn, context) do
    operations = Enum.map(Admin.catalogue(context), &Flezha.Service.describe/1)
    send_json(conn, 200, Jason.encode!(%{operations: operations}))
  end

  # A name that is not text names nothing, and is not echoed: its bytes could
  # not be encoded as JSON.
  defp call_one(conn, name, body, context, config) do
    answer =
      if String.valid?(name),
        do: door(context, config).(name, body),
        else: {:error, Error.new("control.unknown_function", function: inspect(name))}

    case answer do
      {:ok, json} -> conn |> named(name) |> send_json(200, json)
      {:error, error} -> Status.send_error(conn, error)
    end
  end

  # A relay's channel, called with the body as its payload and `?key=` as the
  # key whose partition answers; the answer is sent in its own format. The
  # call's deadline leaves the door `call_grace_ms` (the caller's wait past
  # it), so a relay that does not answer is `call.timeout`, not the door's.
  defp call_relay(conn, relay, channel, body, context, config) do
    key = Plug.Conn.fetch_query_params(conn).query_params["key"]
    door = config.deadline_ms
    deadline_ms = max(door - Durations.get(:call_grace_ms), div(door, 2))
    opts = %{"payload" => "base64", "deadline_ms" => deadline_ms}
    opts = if is_binary(key), do: Map.put(opts, "key", key), else: opts
    args = [namespace(context), relay, channel, Base.encode64(body), opts]

    case door(context, config).("Relay.call_channel", args) do
      {:ok, json} -> conn |> named("Relay.call_channel") |> send_answer(Jason.decode!(json))
      {:error, error} -> Status.send_error(conn, error)
    end
  end

  defp send_answer(conn, %{"accepted" => true}),
    do: send_json(conn, 202, ~s({"accepted":true}))

  defp send_answer(conn, %{"answer_codec" => "json", "answer" => answer}),
    do: send_json(conn, 200, Jason.encode!(answer))

  defp send_answer(conn, %{"answer_codec" => "text", "answer" => answer}) do
    conn
    |> Plug.Conn.put_resp_content_type("text/plain")
    |> Plug.Conn.send_resp(200, answer)
  end

  defp send_answer(conn, %{"answer" => answer}) do
    conn
    |> Plug.Conn.put_resp_content_type("application/octet-stream", nil)
    |> Plug.Conn.send_resp(200, Base.decode64!(answer))
  end

  # The namespace the token is bound to; a caller bound to none acts in the
  # default one.
  defp namespace(context), do: Map.get(context, :namespace) || ""

  # The door, answered within the deadline. A call past it is answered
  # `control.timeout` and left to finish, holding its waiting slot until it does:
  # stopping an act halfway is worse than an answer the caller no longer waits
  # for.
  defp door(context, config) do
    fn name, args ->
      task =
        Task.async(fn ->
          case Server.occupy(config, :waiting, fn ->
                 config.admin.(name, args, context, :given)
               end) do
            :full -> {:error, Handler.busy(config)}
            answer -> answer
          end
        end)

      case Task.yield(task, config.deadline_ms) do
        {:ok, answer} ->
          answer

        nil ->
          Task.ignore(task)
          {:error, Error.new("control.timeout", seconds: config.deadline_ms / 1000)}
      end
    end
  end

  defp not_allowed(conn, allowed) do
    conn
    |> Plug.Conn.put_resp_header("allow", allowed)
    |> Plug.Conn.send_resp(405, "")
  end

  defp send_json(conn, status, json) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json", nil)
    |> Plug.Conn.send_resp(status, json)
  end
end
