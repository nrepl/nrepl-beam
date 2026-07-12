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

Early days. The wire protocol, sessions, and Erlang eval work; see the
issue tracker and per-package READMEs for details.

## License

Distributed under the Apache License 2.0.
