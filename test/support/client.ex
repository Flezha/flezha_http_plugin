defmodule FlezhaHttp.Client do
  @moduledoc "A small HTTP/1.1 client over Mint for the tests that drive a real server."

  @doc "A loopback port nothing listens on at the moment of asking."
  def free_port() do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  @doc "One request, read to its end: `{status, headers, body}`."
  def request(port, method, path, headers \\ [], body \\ nil) do
    {:ok, conn} = Mint.HTTP1.connect(:http, "127.0.0.1", port, mode: :passive)
    {:ok, conn, ref} = Mint.HTTP1.request(conn, method, path, headers, body)
    {conn, response} = read(conn, ref, %{status: nil, headers: [], body: []}, &done?/1)
    Mint.HTTP1.close(conn)
    {response.status, response.headers, IO.iodata_to_binary(response.body)}
  end

  @doc "Open a request whose response the caller reads as it arrives with `read/4`."
  def open(port, method, path, headers \\ [], body \\ nil) do
    {:ok, conn} = Mint.HTTP1.connect(:http, "127.0.0.1", port, mode: :passive)
    {:ok, conn, ref} = Mint.HTTP1.request(conn, method, path, headers, body)
    {conn, ref}
  end

  @doc "Read responses into `acc` until `enough?` holds of it (or the response is done)."
  def read(conn, ref, acc, enough?) do
    if enough?.(acc) do
      {conn, acc}
    else
      {:ok, conn, responses} = Mint.HTTP1.recv(conn, 0, 5_000)
      read(conn, ref, Enum.reduce(responses, acc, &collect(&1, ref, &2)), enough?)
    end
  end

  defp collect({:status, ref, status}, ref, acc), do: %{acc | status: status}
  defp collect({:headers, ref, headers}, ref, acc), do: %{acc | headers: acc.headers ++ headers}
  defp collect({:data, ref, data}, ref, acc), do: %{acc | body: [acc.body | data]}
  defp collect({:done, ref}, ref, acc), do: Map.put(acc, :done, true)
  defp collect(_other, _ref, acc), do: acc

  defp done?(acc), do: Map.get(acc, :done, false)
end
