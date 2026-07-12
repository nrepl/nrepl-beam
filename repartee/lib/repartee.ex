defmodule Repartee do
  @moduledoc """
  An nREPL server for Elixir.

  repartee plugs an Elixir evaluation backend into
  [dialtone](https://github.com/nrepl/nrepl-beam), the nREPL server core for
  the BEAM. Every session keeps its own binding and environment (aliases,
  imports, requires), evaluations stream their output to the client, and
  hung evaluations can be interrupted without losing session state.

  Start a server from a Mix project with:

      mix repartee.server

  or embed one in your supervision tree:

      children = [
        {Repartee.Server, port: 7888}
      ]

  or start one ad hoc:

      {:ok, server} = Repartee.start(port: 0)
      Repartee.port(server)
  """

  @type option ::
          {:port, :inet.port_number()}
          | {:bind, :inet.ip_address() | String.t()}
          | {:port_file, Path.t() | false}
          | {:inspect_opts, keyword()}

  @doc """
  Starts an nREPL server serving Elixir.

  Options:

    * `:port` - TCP port to listen on; `0` (the default) picks a free port
    * `:bind` - address to bind, as a tuple or string (default `"127.0.0.1"`)
    * `:port_file` - where to write the `.nrepl-port` file editors use for
      discovery, or `false` to skip it (default `".nrepl-port"`)
    * `:inspect_opts` - options passed to `inspect/2` when rendering values
      (default `[pretty: true, limit: 50, width: 80]`)
  """
  @spec start([option]) :: {:ok, pid} | {:error, term}
  def start(opts \\ []) do
    with {:ok, _} = Application.ensure_all_started(:dialtone) do
      :dialtone.start_server(server_opts(opts))
    end
  end

  @doc "Stops a server started with `start/1`."
  @spec stop(pid) :: :ok | {:error, term}
  def stop(server), do: :dialtone.stop_server(server)

  @doc "The TCP port a running server listens on."
  @spec port(pid) :: :inet.port_number()
  def port(server), do: :dialtone.port(server)

  @doc false
  def server_opts(opts) do
    bind =
      case Keyword.get(opts, :bind, {127, 0, 0, 1}) do
        addr when is_tuple(addr) ->
          addr

        addr when is_binary(addr) ->
          {:ok, parsed} = :inet.parse_address(String.to_charlist(addr))
          parsed
      end

    backend_opts = %{inspect_opts: Keyword.get(opts, :inspect_opts, [])}

    %{
      port: Keyword.get(opts, :port, 0),
      bind: bind,
      backend: {Repartee.Backend, backend_opts},
      port_file: Keyword.get(opts, :port_file, ~c".nrepl-port"),
      max_frame: Keyword.get(opts, :max_frame, 16 * 1024 * 1024)
    }
  end
end
