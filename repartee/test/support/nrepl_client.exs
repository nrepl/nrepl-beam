defmodule Repartee.NreplClient do
  @moduledoc false
  # Minimal nREPL test client, reusing dialtone's bencode codec.

  defstruct [:sock, buffer: <<>>, next_id: 1]

  def connect(port) do
    {:ok, sock} =
      :gen_tcp.connect(~c"127.0.0.1", port, [:binary, packet: :raw, active: false])

    %__MODULE__{sock: sock}
  end

  def close(%{sock: sock}), do: :gen_tcp.close(sock)

  def send_msg(client, msg) do
    :ok = :gen_tcp.send(client.sock, :dialtone_bencode.encode(msg))
    client
  end

  @doc "Send a request with a fresh id; collect responses until done."
  def request(client, msg, timeout \\ 5_000) do
    id = Integer.to_string(client.next_id)
    client = send_msg(%{client | next_id: client.next_id + 1}, Map.put(msg, "id", id))
    recv_until_done(client, id, timeout)
  end

  def recv_until_done(client, id, timeout \\ 5_000, acc \\ []) do
    {msg, client} = recv_msg(client, timeout)

    case msg do
      %{"id" => ^id} ->
        if "done" in Map.get(msg, "status", []) do
          {Enum.reverse([msg | acc]), client}
        else
          recv_until_done(client, id, timeout, [msg | acc])
        end

      _other ->
        raise "unexpected response #{inspect(msg)} while waiting for id #{id}"
    end
  end

  def recv_msg(%{sock: sock, buffer: buffer} = client, timeout) do
    case :dialtone_bencode.decode(buffer) do
      {:ok, msg, rest} ->
        {msg, %{client | buffer: rest}}

      {:more, ^buffer} ->
        {:ok, data} = :gen_tcp.recv(sock, 0, timeout)
        recv_msg(%{client | buffer: buffer <> data}, timeout)
    end
  end

  def value_of(msgs) do
    [value] = for %{"value" => v} <- msgs, do: v
    value
  end

  def out_of(msgs) do
    Enum.map_join(for(%{"out" => o} <- msgs, do: o), "", & &1)
  end

  def statuses_of(msgs) do
    msgs |> Enum.flat_map(&Map.get(&1, "status", [])) |> Enum.uniq()
  end
end
