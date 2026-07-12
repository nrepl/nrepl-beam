defmodule Repartee.IntegrationTest do
  use ExUnit.Case

  import Repartee.NreplClient,
    only: [value_of: 1, out_of: 1, statuses_of: 1]

  alias Repartee.NreplClient, as: Client

  setup_all do
    {:ok, server} = Repartee.start(port: 0, port_file: false)
    on_exit(fn -> Repartee.stop(server) end)
    %{port: Repartee.port(server)}
  end

  setup %{port: port} do
    client = Client.connect(port)
    on_exit(fn -> Client.close(client) end)
    %{client: client}
  end

  defp clone(client) do
    {[resp], client} = Client.request(client, %{"op" => "clone"})
    {resp["new-session"], client}
  end

  defp eval(client, session, code) do
    Client.request(client, %{"op" => "eval", "session" => session, "code" => code})
  end

  test "describe reports elixir versions and full op set", %{client: client} do
    {[resp], _} = Client.request(client, %{"op" => "describe"})
    assert %{"versions" => %{"elixir" => _}, "ops" => ops} = resp

    for op <- ~w(clone eval load-file stdin interrupt completions lookup) do
      assert Map.has_key?(ops, op), "missing op #{op}"
    end
  end

  test "evaluates elixir with persistent state", %{client: client} do
    {session, client} = clone(client)
    {msgs, client} = eval(client, session, "x = 6 * 7")
    assert value_of(msgs) == "42"
    {msgs, _} = eval(client, session, "x + 1")
    assert value_of(msgs) == "43"
  end

  test "streams stdout", %{client: client} do
    {session, client} = clone(client)
    {msgs, _} = eval(client, session, ~s|IO.puts("здравей")\n:ok|)
    assert out_of(msgs) == "здравей\n"
    assert value_of(msgs) == ":ok"
  end

  test "stdin roundtrip via IO.gets", %{client: client} do
    {session, client} = clone(client)

    client =
      Client.send_msg(client, %{
        "op" => "eval",
        "id" => "reader",
        "session" => session,
        "code" => ~s|IO.gets("name? ")|
      })

    {msg, client} = await_status(client, "need-input")
    assert msg["session"] == session

    {stdin_msgs, client} =
      Client.request(client, %{
        "op" => "stdin",
        "session" => session,
        "stdin" => "Bozhidar\n"
      })

    assert statuses_of(stdin_msgs) == ["done"]

    {msgs, _} = Client.recv_until_done(client, "reader")
    assert value_of(msgs) == ~s("Bozhidar\\n")
  end

  test "interrupt kills the eval but not the session", %{client: client} do
    {session, client} = clone(client)
    {_, client} = eval(client, session, "kept = 13")

    client =
      Client.send_msg(client, %{
        "op" => "eval",
        "id" => "hang",
        "session" => session,
        "code" => "Process.sleep(60_000)"
      })

    Process.sleep(100)

    {_, client} =
      Client.request(client, %{"op" => "interrupt", "session" => session})

    {hang_msgs, client} = Client.recv_until_done(client, "hang")
    assert "interrupted" in statuses_of(hang_msgs)

    {msgs, _} = eval(client, session, "kept")
    assert value_of(msgs) == "13"
  end

  test "exceptions produce err, ex and eval-error", %{client: client} do
    {session, client} = clone(client)
    {msgs, _} = eval(client, session, "1 = 2")
    assert "eval-error" in statuses_of(msgs)
    [err_msg] = for %{"err" => _} = m <- msgs, do: m
    assert err_msg["ex"] == "MatchError"
    assert err_msg["err"] =~ "no match of right hand side value"
    assert err_msg["err"] =~ "(MatchError)"
  end

  test "completions over the wire", %{client: client} do
    {session, client} = clone(client)

    {[resp], _} =
      Client.request(client, %{
        "op" => "completions",
        "session" => session,
        "prefix" => "Enum.take_w"
      })

    assert %{"candidate" => "Enum.take_while", "type" => "function"} in resp["completions"]
  end

  test "lookup over the wire", %{client: client} do
    {session, client} = clone(client)

    {[resp], _} =
      Client.request(client, %{
        "op" => "lookup",
        "session" => session,
        "sym" => "Enum.map/2"
      })

    assert %{"info" => %{"name" => "map", "ns" => "Enum", "line" => line}} = resp
    assert is_integer(line)
  end

  defp await_status(client, status) do
    {msg, client} = Client.recv_msg(client, 5_000)

    if status in Map.get(msg, "status", []) do
      {msg, client}
    else
      await_status(client, status)
    end
  end
end
