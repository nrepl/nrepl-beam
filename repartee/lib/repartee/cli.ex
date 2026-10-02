defmodule Repartee.CLI do
  @moduledoc false
  # Shared command-line handling for bin/repartee and mix repartee.server:
  # parse args, start a server, block forever.

  @switches [
    port: :integer,
    bind: :string,
    port_file: :string,
    no_port_file: :boolean
  ]

  @spec run([String.t()]) :: no_return
  def run(argv) do
    {opts, _argv} = OptionParser.parse!(argv, strict: @switches)

    port_file =
      cond do
        opts[:no_port_file] -> false
        path = opts[:port_file] -> path
        true -> Path.join(File.cwd!(), ".nrepl-port")
      end

    start_opts = [
      port: Keyword.get(opts, :port, 0),
      bind: Keyword.get(opts, :bind, "127.0.0.1"),
      port_file: port_file
    ]

    # A standalone server owns the node, so it can take over standard_error
    # and send what evaluated code writes there to the client.
    {:ok, _} = Application.ensure_all_started(:dialtone)
    :ok = :dialtone.capture_stderr()

    case Repartee.start(start_opts) do
      {:ok, _server} ->
        Process.sleep(:infinity)

      {:error, reason} ->
        IO.puts(:stderr, "repartee: failed to start: #{inspect(reason)}")
        System.halt(1)
    end
  end
end
