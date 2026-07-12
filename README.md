# nREPL on the BEAM

> operator: "number, please"

nREPL servers for Erlang and Elixir, built to follow the
[nREPL specification](https://nrepl.org) faithfully and work with any
conformant client - such as [neat](https://github.com/nrepl/neat) in Emacs.

Two packages live here:

- [`dialtone/`](dialtone/) - the core nREPL server, written in Erlang
  (rebar3). Implements the wire protocol, sessions, IO streaming and
  interrupts, plus an Erlang evaluation backend. The name is a nod to
  Erlang's telephony roots: a dialtone is the sound of a live line waiting
  for your input, which is about as close as audio gets to a REPL prompt.
- [`repartee/`](repartee/) - the Elixir package. Depends on `dialtone` and
  plugs an Elixir evaluation backend into it, wrapped in an Elixir-first API
  and a `mix repartee.server` task. A REPL's whole job is the instant witty
  reply, hence the name.

A small terminal client (working title `chaser` - the drink names stay on
the client side of the nREPL family, next to CIDER, Port and neat) is
planned once the servers settle.

## Status

Early days, but both servers implement the full op set (describe, clone,
close, ls-sessions, eval, load-file, stdin, interrupt, completions,
lookup) and pass neat's cross-implementation integration suite alongside
Clojure, Babashka, and Basilisp. See the per-package READMEs for details
and current limitations.

## Development

You'll need Erlang/OTP 26+ with [rebar3](https://rebar3.org) for
dialtone, plus Elixir 1.15+ for repartee (both are one `brew install
rebar3 elixir` away on macOS).

Run the test suites:

```
cd dialtone
rebar3 eunit            # unit tests: bencode codec, I/O protocol server
rebar3 ct               # integration tests over a real TCP socket
rebar3 as test proper   # property tests for the codec
rebar3 dialyzer         # success typing
rebar3 xref             # cross-reference checks

cd ../repartee
mix test                # backend/completer/lookup units + full-stack tests
mix format --check-formatted
```

Start a server to poke at from an editor:

```
dialtone/bin/dialtone                  # Erlang, ephemeral port + banner
cd repartee && mix repartee.server     # Elixir, inside any Mix project
repartee/bin/repartee                  # Elixir, standalone (no project)
```

All three print the standard `nREPL server started on port N ...`
banner and write the port to `.nrepl-port`, so `M-x neat` (or any
other nREPL client) can find them.

### Running neat's integration suite against these servers

neat's parameterised integration suite can drive dialtone and repartee
as real subprocesses; you just need the launchers on PATH:

```
cd ~/projects/neat
NEAT_INTEGRATION=1 \
  PATH="$HOME/projects/nrepl-beam/dialtone/bin:$HOME/projects/nrepl-beam/repartee/bin:$PATH" \
  eldev test
```

Each server that's found on PATH gets its own `integration against ...`
describe block; missing ones are skipped silently.

## License

Distributed under the Apache License 2.0.
