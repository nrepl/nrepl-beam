# repartee

> A REPL's whole job is the instant witty reply.

An [nREPL](https://nrepl.org) server for Elixir, built on
[dialtone](../dialtone), the nREPL core for the BEAM. Use it to get a
Clojure-grade interactive development experience against a live Elixir
system from any nREPL client - such as [neat](https://github.com/nrepl/neat)
in Emacs.

## Quick start

Inside a Mix project:

```
$ mix repartee.server
nREPL server started on port 51234 on host 127.0.0.1 - nrepl://127.0.0.1:51234
```

The task boots your project (`app.start`), so evaluations see your
modules, deps and running processes. The chosen port lands in
`.nrepl-port` at the project root, where editors auto-discover it.

```
M-x neat RET localhost RET 51234 RET
localhost:51234> x = 6 * 7
42
localhost:51234> defmodule Hello do def hi, do: :hi end
{:module, Hello, ...}
localhost:51234> Hello.hi()
:hi
```

## Embedding

```elixir
# mix.exs
{:repartee, "~> 0.1"}

# in your supervision tree
children = [
  {Repartee.Server, port: 7888}
]

# or ad hoc
{:ok, server} = Repartee.start(port: 0)
Repartee.port(server)
```

## What works

- Sessions with persistent state: variables, aliases, imports and
  requires all survive across evals (the same
  `Code.eval_quoted_with_env` mechanism IEx and Livebook use), and
  sessions survive dropped connections.
- Streaming IO: `IO.puts` output arrives as it happens; `IO.gets`
  parks the eval and asks the client for input.
- Interrupts: a hung eval dies, the session's state doesn't.
- `completions` knows your session - variables from the binding,
  aliases and imports from the env, modules from the code server,
  `:erlang` modules too.
- `lookup` resolves aliases and bare imported names, then serves docs,
  arglists and source locations from the doc chunks - enough for
  eldoc, doc popups and jump-to-definition.

## Known limitations

- `Logger` output and writes to `:standard_error` go to the server's
  console, not the client (eval errors are reported to the client in
  full).
- Values are rendered with `inspect/2` (IEx-style options,
  customizable via `:inspect_opts`).

## Development

```
mix test
mix format --check-formatted
```

## License

Apache License 2.0.
