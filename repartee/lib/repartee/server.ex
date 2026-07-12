defmodule Repartee.Server do
  @moduledoc """
  A supervisable wrapper around a repartee nREPL server, for embedding in an
  application's supervision tree:

      children = [
        {Repartee.Server, port: 7888}
      ]

  Accepts the same options as `Repartee.start/1`.
  """

  use GenServer

  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc "The TCP port the wrapped server listens on."
  def port(pid), do: GenServer.call(pid, :port)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    case Repartee.start(opts) do
      {:ok, server} -> {:ok, %{server: server}}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:port, _from, state) do
    {:reply, Repartee.port(state.server), state}
  end

  @impl true
  def terminate(_reason, state) do
    Repartee.stop(state.server)
  end
end
