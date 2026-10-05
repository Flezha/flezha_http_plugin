defmodule FlezhaHttp.Envelope do
  @moduledoc """
  The two JSON envelopes between HTTP and the host relay: the request a call
  carries in, and the answer its sink output gives back.

  The request is `method`, `path` and `query` as received, the `headers` the
  plugin was told to pass, and the body as text (`body`) or bytes
  (`body_base64`); the plugin never decodes the body. The answer is either a
  plain one (`status`, optional `headers`, one of `body` and `body_base64`) or a
  stream one (`stream`, optional `headers`). Anything else is refused with the
  rule it broke.
  """

  @plain_keys ~w(status headers body body_base64)
  @framing ~w(connection content-length keep-alive proxy-connection te trailer transfer-encoding upgrade)
  @max_stream_bytes 255

  @type answer ::
          {:plain, 200..599, [{String.t(), String.t()}], iodata()}
          | {:stream, String.t(), [{String.t(), String.t()}]}

  @doc "The request envelope of `conn` with its read `body`, passing only `pass_headers`."
  @spec request(Plug.Conn.t(), binary(), [String.t()]) :: map()
  def request(%Plug.Conn{} = conn, body, pass_headers) do
    put_bytes(
      %{
        "method" => String.upcase(conn.method),
        "path" => conn.request_path,
        "query" => conn.query_string,
        "headers" => passed(conn.req_headers, pass_headers)
      },
      "body",
      body
    )
  end

  @doc """
  Put `bytes` under `key` as text when they are valid UTF-8, otherwise under
  `<key>_base64`, the rule `flz relay listen --json` follows.
  """
  @spec put_bytes(map(), String.t(), binary()) :: map()
  def put_bytes(map, key, bytes) do
    if String.valid?(bytes),
      do: Map.put(map, key, bytes),
      else: Map.put(map, key <> "_base64", Base.encode64(bytes))
  end

  defp passed(req_headers, names) do
    for name <- names,
        values = for({^name, value} <- req_headers, do: value),
        values != [],
        into: %{},
        do: {name, Enum.join(values, if(name == "cookie", do: "; ", else: ", "))}
  end

  @doc """
  The answer `payload` names, or `{:error, reason}` naming the rule it broke.
  Plain answers carry their default content type unless a `content-type`
  header names one.
  """
  @spec answer(binary()) :: {:ok, answer()} | {:error, String.t()}
  def answer(payload) do
    case Jason.decode(payload) do
      {:ok, %{} = answer} -> decode(answer)
      _ -> {:error, "the answer is not a JSON object"}
    end
  end

  defp decode(answer) do
    with :ok <- known_keys(answer),
         {:ok, headers} <- headers(Map.get(answer, "headers", %{})) do
      if Map.has_key?(answer, "stream"),
        do: stream(answer, headers),
        else: plain(answer, headers)
    end
  end

  defp known_keys(answer) do
    case Enum.sort(Map.keys(answer) -- ["stream" | @plain_keys]) do
      [] -> :ok
      unknown -> {:error, "the answer carries the unknown key(s) #{quote_all(unknown)}"}
    end
  end

  defp stream(answer, headers) do
    cond do
      Enum.any?(~w(status body body_base64), &Map.has_key?(answer, &1)) ->
        {:error, "'stream' cannot stand beside 'status', 'body' or 'body_base64'"}

      stream_id?(answer["stream"]) ->
        {:ok, {:stream, answer["stream"], headers}}

      true ->
        {:error, "'stream' must be a non-empty string of at most #{@max_stream_bytes} bytes"}
    end
  end

  defp stream_id?(id), do: is_binary(id) and id != "" and byte_size(id) <= @max_stream_bytes

  defp plain(answer, headers) do
    status = answer["status"]

    cond do
      not Map.has_key?(answer, "status") ->
        {:error, "the answer has neither 'status' nor 'stream'"}

      not (is_integer(status) and status in 200..599) ->
        {:error, "'status' must be an integer from 200 to 599"}

      Map.has_key?(answer, "body") and Map.has_key?(answer, "body_base64") ->
        {:error, "the answer carries both 'body' and 'body_base64'"}

      status in [204, 304] and
          (Map.has_key?(answer, "body") or Map.has_key?(answer, "body_base64")) ->
        {:error, "a #{status} answer carries no body"}

      true ->
        with {:ok, body, default_type} <- body(answer) do
          {:ok, {:plain, status, content_type(headers, default_type), body}}
        end
    end
  end

  defp body(%{"body" => body}) when is_binary(body), do: {:ok, body, "text/plain; charset=utf-8"}
  defp body(%{"body" => body}), do: {:ok, Jason.encode_to_iodata!(body), "application/json"}

  defp body(%{"body_base64" => encoded}) when is_binary(encoded) do
    case Base.decode64(encoded) do
      {:ok, bytes} -> {:ok, bytes, "application/octet-stream"}
      :error -> {:error, "'body_base64' is not base64"}
    end
  end

  defp body(%{"body_base64" => _}), do: {:error, "'body_base64' is not base64"}
  defp body(_answer), do: {:ok, "", nil}

  defp content_type(headers, nil), do: headers

  defp content_type(headers, default) do
    if List.keymember?(headers, "content-type", 0),
      do: headers,
      else: [{"content-type", default} | headers]
  end

  defp headers(%{} = headers) do
    Enum.reduce_while(headers, {:ok, []}, fn {name, value}, {:ok, acc} ->
      case header(name, value) do
        :ok -> {:cont, {:ok, [{name, value} | acc]}}
        {:error, _} = refused -> {:halt, refused}
      end
    end)
  end

  defp headers(_headers), do: {:error, "'headers' must be a JSON object"}

  defp header(name, value) do
    cond do
      not FlezhaHttp.Provider.token?(name) ->
        {:error, "the header name #{inspect(name)} is not a lower-case HTTP token"}

      name in @framing ->
        {:error, "the header #{inspect(name)} is framing, which is the server's"}

      not is_binary(value) or String.contains?(value, ["\r", "\n", <<0>>]) ->
        {:error, "the header #{inspect(name)} must be a string without CR, LF or NUL"}

      true ->
        :ok
    end
  end

  # Names the answer carried, escaped: they reach a log line.
  defp quote_all(names), do: Enum.map_join(names, ", ", &inspect/1)
end
