%% Drives dialtone_io_server through the raw Erlang I/O protocol (via the io
%% module, pointed at the device pid) - no TCP, no sessions.
-module(dialtone_io_server_tests).

-include_lib("eunit/include/eunit.hrl").

setup() ->
    %% EUnit runs the module's tests in one process; drop {sent, _} leftovers
    %% from earlier tests (e.g. repeated need-input asks) before starting.
    flush_sent(),
    {ok, Io} = dialtone_io_server:start_link(),
    Stub = conn_stub(self()),
    ok = dialtone_io_server:set_sink(Io, Stub, #{<<"id">> => <<"1">>,
                                                 <<"session">> => <<"s">>}),
    Io.

%% Minimal stand-in for dialtone_conn's {send, Msg} call interface.
conn_stub(Parent) ->
    spawn_link(fun() -> conn_stub_loop(Parent) end).

conn_stub_loop(Parent) ->
    receive
        {'$gen_call', From, {send, Msg}} ->
            Parent ! {sent, Msg},
            gen_server:reply(From, ok),
            conn_stub_loop(Parent)
    end.

sent() ->
    receive {sent, Msg} -> Msg
    after 1000 -> error(no_message)
    end.

flush_sent() ->
    receive {sent, _} -> flush_sent()
    after 0 -> ok
    end.

out_forwarding_test() ->
    Io = setup(),
    ok = io:put_chars(Io, "hi"),
    ?assertMatch(#{<<"out">> := <<"hi">>, <<"id">> := <<"1">>,
                   <<"session">> := <<"s">>}, sent()).

format_test() ->
    Io = setup(),
    ok = io:format(Io, "~b bottles of ~ts~n", [99, "ουζο"]),
    ?assertMatch(#{<<"out">> := <<"99 bottles of ουζο\n"/utf8>>}, sent()).

no_sink_drops_output_test() ->
    {ok, Io} = dialtone_io_server:start_link(),
    ?assertEqual(ok, io:put_chars(Io, "into the void")).

get_line_roundtrip_test() ->
    Io = setup(),
    Self = self(),
    spawn_link(fun() -> Self ! {line, io:get_line(Io, "> ")} end),
    ?assertMatch(#{<<"out">> := <<"> ">>}, sent()),
    ?assertMatch(#{<<"status">> := ['need-input']}, sent()),
    ok = dialtone_io_server:stdin(Io, <<"42\n">>),
    receive {line, Line} -> ?assertEqual("42\n", Line)
    after 1000 -> error(no_line)
    end.

type_ahead_test() ->
    Io = setup(),
    ok = dialtone_io_server:stdin(Io, <<"already here\n">>),
    %% prompt still goes out, but no need-input: the buffer satisfies the read
    Self = self(),
    spawn_link(fun() -> Self ! {line, io:get_line(Io, "> ")} end),
    ?assertMatch(#{<<"out">> := <<"> ">>}, sent()),
    receive {line, Line} -> ?assertEqual("already here\n", Line)
    after 1000 -> error(no_line)
    end,
    receive {sent, Unexpected} -> error({unexpected, Unexpected})
    after 50 -> ok
    end.

eof_test() ->
    Io = setup(),
    ok = dialtone_io_server:stdin(Io, <<>>),
    ?assertEqual(eof, io:get_line(Io, "")).

eof_flushes_partial_line_test() ->
    Io = setup(),
    ok = dialtone_io_server:stdin(Io, <<"no newline">>),
    ok = dialtone_io_server:stdin(Io, <<>>),
    ?assertEqual("no newline", io:get_line(Io, "")),
    ?assertEqual(eof, io:get_line(Io, "")).

split_utf8_stdin_test() ->
    Io = setup(),
    Self = self(),
    spawn_link(fun() -> Self ! {line, io:get_line(Io, "")} end),
    ?assertMatch(#{<<"status">> := ['need-input']}, sent()),
    <<Half:1/binary, Rest/binary>> = <<"λ\n"/utf8>>,
    ok = dialtone_io_server:stdin(Io, Half),
    %% still blocked (half a character) - the server asks again
    ?assertMatch(#{<<"status">> := ['need-input']}, sent()),
    ok = dialtone_io_server:stdin(Io, Rest),
    receive {line, Line} -> ?assertEqual([955, $\n], Line)
    after 1000 -> error(no_line)
    end.

get_chars_test() ->
    Io = setup(),
    ok = dialtone_io_server:stdin(Io, <<"abcdef">>),
    ?assertEqual("abc", io:get_chars(Io, "", 3)),
    ?assertEqual("def", io:get_chars(Io, "", 3)).

binary_mode_test() ->
    Io = setup(),
    ok = io:setopts(Io, [binary]),
    ok = dialtone_io_server:stdin(Io, <<"bin\n">>),
    ?assertEqual(<<"bin\n">>, io:get_line(Io, "")).

reset_fails_parked_reads_test() ->
    Io = setup(),
    Self = self(),
    spawn(fun() -> Self ! {line, io:get_line(Io, "")} end),
    ?assertMatch(#{<<"status">> := ['need-input']}, sent()),
    ok = dialtone_io_server:reset(Io),
    receive {line, Result} -> ?assertEqual({error, terminated}, Result)
    after 1000 -> error(no_reply)
    end.

fread_get_until_test() ->
    %% io:fread exercises the get_until continuation loop across chunks.
    Io = setup(),
    Self = self(),
    spawn_link(fun() -> Self ! {fread, io:fread(Io, "", "~d ~d")} end),
    ?assertMatch(#{<<"status">> := ['need-input']}, sent()),
    ok = dialtone_io_server:stdin(Io, <<"17 ">>),
    ok = dialtone_io_server:stdin(Io, <<"25\n">>),
    receive {fread, Result} -> ?assertEqual({ok, [17, 25]}, Result)
    after 1000 -> error(no_fread)
    end.
