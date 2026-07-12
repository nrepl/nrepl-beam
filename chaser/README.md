# chaser

> A little something to go with your dialtone.

A terminal nREPL client, taken neat. chaser speaks the plain nREPL
protocol, so it works with [dialtone](../dialtone) (Erlang),
[repartee](../repartee) (Elixir), and any other conformant server -
Clojure's included. Following family tradition, the drink name sits on
the client side of the bar, next to CIDER, Port and neat.

## A session

```
$ chaser                       # picks up .nrepl-port automatically
chaser 0.1.0 | nrepl://127.0.0.1:51234 | dialtone 0.1.0 / erlang 29
127.0.0.1:51234> io:format("computing~n"), 6 * 7.
computing
=> 42
127.0.0.1:51234> 1 div 0.
!! error:badarith
   exception error: an error occurred when evaluating an arithmetic expression
     in operator  div/2
        called as 1 div 0
127.0.0.1:51234> F = fun(X) ->
             ..>   X * 2
             ..> end.
=> #Fun<erl_eval.42.39164016>
127.0.0.1:51234> :doc lists:map
lists:map map(Fun, List1)
  ...
127.0.0.1:51234> :quit
```

Printed output streams as the program writes it; values arrive on their
own line behind a green `=>`; errors behind a red `!!` with the trace
indented. The separation survives `NO_COLOR` and pipes.

## The good parts

- **TAB completion, server-side.** Completion candidates come from the
  server's `completions` op, so they know your session: your variables,
  your aliases, the modules actually loaded. Candidates render grouped
  by kind (functions / modules / variables), the way the Erlang shell
  displays them. One TAB extends the common prefix, another lists.
- **Language-aware input.** chaser infers the server's language from
  `describe`: Erlang input submits on a terminating `.`, Elixir when
  brackets and `do/end` balance, anything else on Enter (`--lang`
  overrides). A `..>` prompt continues multi-line forms.
- **Interrupts without ceremony.** A long-running eval prints a hint
  after a second; bare Enter interrupts it. Session state survives -
  that's the server's contract.
- **stdin round-trips.** When evaluated code reads input, the server
  says `need-input` and whatever you type next is fed to the program.
- **Line editing and history for free**: chaser rides OTP's own
  edlin/tty machinery (`shell:start_interactive/1`), with persistent
  history under your user cache directory.
- **Pipes work.** With stdin or stdout not a terminal, chaser drops
  prompts and colors: `echo '1 + 2.' | chaser :51234` prints `=> 3`.

## Usage

```
chaser [HOST][:PORT] [--host HOST] [--port PORT]
       [--lang erlang|elixir|none] [--no-color] [--pipe]
```

Without a port, chaser walks up from the current directory looking for
an `.nrepl-port` file - the convention every nREPL server follows,
dialtone and repartee included.

Build it with `rebar3 escriptize` (OTP 26+); the result is a single
`chaser` file you can put on your PATH. `bin/chaser` builds on demand
during development.

## Commands

| Input      | Effect                                         |
|------------|------------------------------------------------|
| TAB        | complete via the server's `completions` op     |
| `:doc SYM` | documentation via the server's `lookup` op     |
| `:help`    | list commands                                  |
| `:quit`    | leave (Ctrl-D at the prompt does the same)     |
| Enter      | during a running eval: interrupt it            |

## License

Apache License 2.0.
