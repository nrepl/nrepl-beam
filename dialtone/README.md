# dialtone

> The sound of a live line, waiting for your input.

An [nREPL](https://nrepl.org) server for Erlang - and a reusable nREPL
server core for the whole BEAM. dialtone implements the wire protocol
(bencode over TCP), sessions, streamed IO, stdin, and interrupts once;
what varies per language lives behind a small backend behaviour. The
bundled `dialtone_backend_erlang` evaluates Erlang;
[repartee](../repartee) plugs in Elixir the same way.

Named for Erlang's telephony roots: a dialtone is a REPL prompt,
rendered in audio.

## Quick start

```
$ bin/dialtone
nREPL server started on port 51234 on host 127.0.0.1 - nrepl://127.0.0.1:51234
```

Then connect any nREPL client to that port -
[neat](https://github.com/nrepl/neat) in Emacs, for instance:

```
M-x neat RET localhost RET 51234 RET
localhost:51234> 1 + 2.
3
localhost:51234> X = 40.
40
localhost:51234> X + 2.
42
```

The port (`--port 7888`) and bind address (`--bind 0.0.0.0`) are
optional; by default the OS picks a free port and the server announces
it on stdout and in a `.nrepl-port` file, which editors use for
auto-discovery.

## Embedding

Add `dialtone` as a dependency and start a server next to your
application:

```erlang
{ok, Server} = dialtone:start_server(#{port => 7888}),
Port = dialtone:port(Server).
```

The `dialtone` application starts no listener on its own, so it's safe
to include in a release. To start servers from configuration, set the
`listen` app env to a list of option maps.

## Supported operations

`describe`, `clone`, `close`, `ls-sessions`, `eval`, `load-file`,
`stdin`, `interrupt`, `completions`, `lookup`.

The semantics follow the [nREPL spec](https://nrepl.org) draft:

- Sessions hold Erlang bindings that persist across evals; requests in
  a session run serially, sessions run concurrently, and sessions
  survive dropped connections (reconnect and keep working).
- Output from evaluated code streams to the client as it happens;
  reads from stdin park the eval and ask the client for input
  (`need-input`), with EOF signalled by an empty `stdin` payload.
- `interrupt` kills the running eval without touching session state.
- `load-file` compiles module sources (with `debug_info`, attributed
  to the client-side path) and hot-loads them; non-module content is
  evaluated as expressions.
- `completions` covers modules, exported functions, auto-imported BIFs
  and session variables. `lookup` serves EEP-48 docs, arglists and
  source locations for `module`, `module:function` and
  `module:function/arity` symbols.

## Writing a backend

Implement the `dialtone_backend` behaviour - `init/1`, `eval/3` and
`version_info/0` are the required callbacks; `load_file/3`,
`complete/3`, `lookup/3`, `format_exception/4` and `io_opts/0` are
optional (`describe` only advertises what you export). Evals run in a
killable worker process with the session's IO device as group leader,
so streaming output costs a backend nothing and interrupts are safe by
construction. See `dialtone_backend_erlang` and repartee's
`Repartee.Backend` for the two existing implementations.

## Known limitations

- Writes to the global `standard_error` device and `logger` output go
  to the server's console, not the client. Eval errors themselves are
  reported to the client with full stack traces.
- Values are rendered with `~tp` and truncated beyond 8 MB.

## Development

```
rebar3 eunit             # unit tests (bencode, IO protocol)
rebar3 ct                # integration tests over a real socket
rebar3 as test proper    # property tests for the codec
rebar3 dialyzer && rebar3 xref
```

## License

Apache License 2.0.
