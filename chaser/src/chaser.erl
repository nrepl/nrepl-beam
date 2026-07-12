%% @doc chaser - a terminal nREPL client, taken neat.
%%
%% Escript entry point: parse arguments, find the server (explicit
%% host/port or .nrepl-port discovery), connect, then hand off to
%% chaser_shell - through shell:start_interactive/1 when we own a terminal
%% (edlin line editing, TAB completion, history), or as a plain loop when
%% piped.
-module(chaser).

-export([main/1]).

-define(DEFAULT_HOST, "127.0.0.1").

-spec main([string()]) -> no_return().
main(Args) ->
    Opts = parse_args(Args, #{}),
    Host = maps:get(host, Opts, ?DEFAULT_HOST),
    Port = case maps:get(port, Opts, undefined) of
               undefined -> discover_port();
               P -> P
           end,
    {ok, _} = application:ensure_all_started(chaser),
    Conn = connect(Host, Port),
    {Lang, ServerLabel} = describe(Conn, Opts),
    Session = clone(Conn),
    Interactive = is_tty() andalso not maps:get(pipe, Opts, false),
    Color = use_color(Opts, Interactive),
    Banner = #{url => io_lib:format("nrepl://~s:~b", [Host, Port]),
               server => ServerLabel},
    ShellOpts = #{conn => Conn,
                  session => Session,
                  lang => Lang,
                  color => Color,
                  host => unicode:characters_to_binary(Host),
                  port => Port,
                  interactive => Interactive},
    case Interactive of
        true ->
            enable_history(),
            %% Our banner replaces the stock "Erlang/OTP N [erts-...]" slogan.
            {BannerIo, _} = chaser_render:banner(
                              Banner, chaser_render:new(#{color => Color})),
            application:set_env(stdlib, shell_slogan,
                                string:trim(unicode:characters_to_list(BannerIo),
                                            trailing, "\n")),
            ok = shell:start_interactive({chaser_shell, start, [ShellOpts]}),
            timer:sleep(infinity);
        false ->
            chaser_shell:run(ShellOpts#{banner => Banner})
    end.

%%% Arguments

parse_args([], Opts) ->
    Opts;
parse_args(["--port", P | Rest], Opts) ->
    parse_args(Rest, Opts#{port => parse_int(P)});
parse_args(["--host", H | Rest], Opts) ->
    parse_args(Rest, Opts#{host => H});
parse_args(["--lang", L | Rest], Opts) ->
    Lang = case L of
               "erlang" -> erlang;
               "elixir" -> elixir;
               "none" -> none;
               _ -> usage("unknown --lang " ++ L)
           end,
    parse_args(Rest, Opts#{lang => Lang});
parse_args(["--no-color" | Rest], Opts) ->
    parse_args(Rest, Opts#{color => false});
parse_args(["--pipe" | Rest], Opts) ->
    parse_args(Rest, Opts#{pipe => true});
parse_args(["--help" | _], _Opts) ->
    io:put_chars(usage_text()),
    halt(0);
parse_args([Positional | Rest], Opts) ->
    case string:split(Positional, ":") of
        [HostPart, PortPart] when HostPart =/= [] ->
            parse_args(Rest, Opts#{host => HostPart,
                                   port => parse_int(PortPart)});
        [":" ++ PortPart] ->
            parse_args(Rest, Opts#{port => parse_int(PortPart)});
        [Single] ->
            try list_to_integer(Single) of
                Port -> parse_args(Rest, Opts#{port => Port})
            catch
                error:badarg -> parse_args(Rest, Opts#{host => Single})
            end;
        _ ->
            usage("cannot parse " ++ Positional)
    end.

parse_int(Str) ->
    try list_to_integer(Str)
    catch error:badarg -> usage("not a number: " ++ Str)
    end.

-spec usage(string()) -> no_return().
usage(Problem) ->
    io:format(standard_error, "chaser: ~s~n~s", [Problem, usage_text()]),
    halt(2).

usage_text() ->
    "usage: chaser [HOST][:PORT] [--host HOST] [--port PORT]\n"
    "              [--lang erlang|elixir|none] [--no-color] [--pipe]\n"
    "\n"
    "Without a port, chaser looks for an .nrepl-port file in the current\n"
    "directory and its ancestors.\n".

%%% Discovery & connection

discover_port() ->
    discover_port(filename:absname("")).

discover_port(Dir) ->
    Candidate = filename:join(Dir, ".nrepl-port"),
    case file:read_file(Candidate) of
        {ok, Contents} ->
            case string:to_integer(string:trim(Contents)) of
                {Port, <<>>} when is_integer(Port) -> Port;
                _ -> die("malformed ~s", [Candidate])
            end;
        {error, _} ->
            case filename:dirname(Dir) of
                Dir -> die("no port given and no .nrepl-port found", []);
                Parent -> discover_port(Parent)
            end
    end.

connect(Host, Port) ->
    case chaser_conn:connect(Host, Port) of
        {ok, Conn} -> Conn;
        {error, Reason} -> die("cannot connect to ~s:~b (~0tp)",
                               [Host, Port, Reason])
    end.

describe(Conn, Opts) ->
    Versions = case chaser_conn:request(Conn, #{<<"op">> => <<"describe">>}) of
                   {ok, Msgs} ->
                       lists:foldl(fun(M, Acc) ->
                                           maps:merge(Acc, maps:get(<<"versions">>, M, #{}))
                                   end, #{}, Msgs);
                   {error, _} ->
                       #{}
               end,
    Lang = maps:get(lang, Opts, infer_lang(Versions)),
    {Lang, server_label(Versions)}.

infer_lang(Versions) ->
    case {maps:is_key(<<"elixir">>, Versions), maps:is_key(<<"erlang">>, Versions)} of
        {true, _} -> elixir;
        {false, true} -> erlang;
        _ -> none
    end.

server_label(Versions) when map_size(Versions) =:= 0 ->
    "unknown server";
server_label(Versions) ->
    Interesting = [K || K <- maps:keys(Versions), K =/= <<"nrepl">>],
    Parts = [[K, " ", version_string(maps:get(K, Versions))]
             || K <- lists:sort(Interesting)],
    lists:join(" / ", Parts).

version_string(#{<<"version-string">> := V}) when is_binary(V) -> V;
version_string(V) when is_binary(V) -> V;
version_string(_) -> "?".

clone(Conn) ->
    case chaser_conn:request(Conn, #{<<"op">> => <<"clone">>}) of
        {ok, Msgs} ->
            case [S || #{<<"new-session">> := S} <- Msgs] of
                [Session | _] -> Session;
                [] -> die("server did not return a session from clone", [])
            end;
        {error, Reason} ->
            die("clone failed: ~0tp", [Reason])
    end.

%%% Environment

is_tty() ->
    try
        prim_tty:isatty(stdin) =:= true andalso
            prim_tty:isatty(stdout) =:= true
    catch
        _:_ -> false
    end.

use_color(Opts, Interactive) ->
    maps:get(color, Opts,
             Interactive andalso
             os:getenv("NO_COLOR") =:= false andalso
             os:getenv("TERM") =/= "dumb").

%% Persistent up-arrow history, kept apart from the Erlang shell's own.
enable_history() ->
    Dir = filename:basedir(user_cache, "chaser"),
    case filelib:ensure_path(Dir) of
        ok ->
            application:set_env(kernel, shell_history, enabled),
            application:set_env(kernel, shell_history_path, Dir),
            ok;
        {error, _} ->
            ok
    end.

-spec die(io:format(), [term()]) -> no_return().
die(Fmt, Args) ->
    io:format(standard_error, "chaser: " ++ Fmt ++ "~n", Args),
    halt(1).
