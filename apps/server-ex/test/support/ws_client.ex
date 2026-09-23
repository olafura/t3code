defmodule T3.Test.WsClient do
  @moduledoc "Minimal blocking WebSocket client for tests, speaking JSON text frames."

  def connect(port, path) do
    {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", port)
    {:ok, conn, ref} = Mint.WebSocket.upgrade(:ws, conn, path, [])
    {conn, [{:status, ^ref, status}, {:headers, ^ref, headers} | rest]} = recv_http(conn, [])

    if status == 101 do
      {:ok, conn, ws} = Mint.WebSocket.new(conn, ref, status, headers)
      # The server's first frame can arrive in the same packet as the upgrade response.
      early = for {:data, ^ref, data} <- rest, into: "", do: data
      {:ok, ws, frames} = Mint.WebSocket.decode(ws, early)

      {:ok,
       %{
         conn: conn,
         ws: ws,
         ref: ref,
         inbox: for({:text, text} <- frames, do: JSON.decode!(text))
       }}
    else
      {:error, status}
    end
  end

  def send_json(client, message) do
    {:ok, ws, data} =
      Mint.WebSocket.encode(
        client.ws,
        {:text, IO.iodata_to_binary(JSON.encode_to_iodata!(message))}
      )

    {:ok, conn} = Mint.WebSocket.stream_request_body(client.conn, client.ref, data)
    %{client | conn: conn, ws: ws}
  end

  @doc "Receives the next decoded JSON frame."
  def recv(%{inbox: [frame | rest]} = client, _timeout), do: {frame, %{client | inbox: rest}}

  def recv(client, timeout) do
    socket = Mint.HTTP.get_socket(client.conn)

    # Only this connection's socket messages; several clients may share a test process.
    receive do
      {tag, ^socket, _} = message when tag in [:tcp, :ssl] ->
        {:ok, conn, [{:data, _, data}]} = Mint.WebSocket.stream(client.conn, message)
        {:ok, ws, frames} = Mint.WebSocket.decode(client.ws, data)
        decoded = for {:text, text} <- frames, do: JSON.decode!(text)
        recv(%{client | conn: conn, ws: ws, inbox: client.inbox ++ decoded}, timeout)
    after
      timeout -> raise "no frame within #{timeout} ms"
    end
  end

  @doc "Receives frames until one matches `fun`, returning it and the frames skipped."
  def recv_until(client, fun, timeout \\ 2_000, skipped \\ []) do
    {frame, client} = recv(client, timeout)

    if fun.(frame),
      do: {frame, Enum.reverse(skipped), client},
      else: recv_until(client, fun, timeout, [frame | skipped])
  end

  defp recv_http(conn, acc) do
    receive do
      message ->
        {:ok, conn, responses} = Mint.WebSocket.stream(conn, message)
        acc = acc ++ responses
        if Enum.any?(acc, &match?({:done, _}, &1)), do: {conn, acc}, else: recv_http(conn, acc)
    end
  end
end
