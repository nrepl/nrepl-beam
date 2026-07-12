defmodule Mix.Tasks.Repartee.Server do
  @shortdoc "Starts an nREPL server for the current Mix project"

  @moduledoc """
  Starts a repartee nREPL server with the current Mix project's code and
  dependencies loaded and its application started, then blocks forever.

      mix repartee.server
      mix repartee.server --port 7888 --bind 0.0.0.0

  ## Options

    * `--port` - port to listen on (defaults to 0, an OS-assigned free port;
      the chosen port is printed and written to the port file)
    * `--bind` - address to bind (defaults to 127.0.0.1)
    * `--port-file` - where to write the port for editor discovery
      (defaults to .nrepl-port in the project root); `--no-port-file`
      disables it

  The server announces itself on stdout in the conventional shape:

      nREPL server started on port 51234 on host 127.0.0.1 - nrepl://127.0.0.1:51234
  """

  use Mix.Task

  @requirements ["app.start"]

  @impl true
  def run(args) do
    Repartee.CLI.run(args)
  end
end
