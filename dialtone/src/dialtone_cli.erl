%% @private Entry point for running a standalone server (see bin/dialtone):
%% parses plain arguments, starts a server, and blocks forever.
-module(dialtone_cli).

-export([main/0]).

-spec main() -> no_return().
main() ->
    Opts = parse_args(init:get_plain_arguments(), #{port => 0}),
    {ok, _} = application:ensure_all_started(dialtone),
    case dialtone:start_server(Opts) of
        {ok, _Server} ->
            timer:sleep(infinity);
        {error, Reason} ->
            io:format(standard_error, "dialtone: failed to start: ~0tp~n", [Reason]),
            halt(1)
    end.

parse_args([], Opts) ->
    Opts;
parse_args(["--port", Port | Rest], Opts) ->
    parse_args(Rest, Opts#{port => list_to_integer(Port)});
parse_args(["--bind", Addr | Rest], Opts) ->
    case inet:parse_address(Addr) of
        {ok, Parsed} -> parse_args(Rest, Opts#{bind => Parsed});
        {error, _} -> usage("invalid bind address: " ++ Addr)
    end;
parse_args(["--port-file", Path | Rest], Opts) ->
    parse_args(Rest, Opts#{port_file => Path});
parse_args(["--no-port-file" | Rest], Opts) ->
    parse_args(Rest, Opts#{port_file => false});
parse_args([Arg | _], _Opts) ->
    usage("unknown argument: " ++ Arg).

-spec usage(string()) -> no_return().
usage(Problem) ->
    io:format(standard_error,
              "dialtone: ~s~n"
              "usage: dialtone [--port N] [--bind ADDR] "
              "[--port-file PATH | --no-port-file]~n",
              [Problem]),
    halt(2).
