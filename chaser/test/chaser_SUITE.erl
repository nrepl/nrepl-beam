%% Integration: chaser_conn against a real dialtone server, and the built
%% escript driven as a port program (the non-tty pipe path).
-module(chaser_SUITE).

-compile(export_all).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

suite() ->
    [{timetrap, {seconds, 60}}].

all() ->
    [conn_request_collects_until_done,
     conn_stream_delivers_messages_and_done,
     conn_interrupt_while_streaming,
     pipe_end_to_end].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(dialtone),
    {ok, Server} = dialtone:start_server(#{port => 0, port_file => false}),
    [{server, Server}, {port, dialtone:port(Server)} | Config].

end_per_suite(Config) ->
    ok = dialtone:stop_server(?config(server, Config)),
    ok = application:stop(dialtone).

clone(Conn) ->
    {ok, [Resp]} = chaser_conn:request(Conn, #{<<"op">> => <<"clone">>}),
    maps:get(<<"new-session">>, Resp).

conn_request_collects_until_done(Config) ->
    {ok, Conn} = chaser_conn:connect("127.0.0.1", ?config(port, Config)),
    {ok, [Describe]} = chaser_conn:request(Conn, #{<<"op">> => <<"describe">>}),
    ?assertMatch(#{<<"ops">> := _}, Describe),
    Session = clone(Conn),
    {ok, Msgs} = chaser_conn:request(Conn, #{<<"op">> => <<"eval">>,
                                             <<"session">> => Session,
                                             <<"code">> => <<"1 + 2.">>}),
    ?assertEqual([<<"3">>], [V || #{<<"value">> := V} <- Msgs]),
    ok = chaser_conn:close(Conn).

conn_stream_delivers_messages_and_done(Config) ->
    {ok, Conn} = chaser_conn:connect("127.0.0.1", ?config(port, Config)),
    Session = clone(Conn),
    {ok, Id} = chaser_conn:request_stream(
                 Conn, #{<<"op">> => <<"eval">>,
                         <<"session">> => Session,
                         <<"code">> => <<"io:format(\"a\"), ok.">>},
                 self()),
    Msgs = collect_stream(Id, []),
    ?assertEqual(<<"a">>, iolist_to_binary([O || #{<<"out">> := O} <- Msgs])),
    ?assertEqual([<<"ok">>], [V || #{<<"value">> := V} <- Msgs]),
    ok = chaser_conn:close(Conn).

conn_interrupt_while_streaming(Config) ->
    {ok, Conn} = chaser_conn:connect("127.0.0.1", ?config(port, Config)),
    Session = clone(Conn),
    {ok, Id} = chaser_conn:request_stream(
                 Conn, #{<<"op">> => <<"eval">>,
                         <<"session">> => Session,
                         <<"code">> => <<"timer:sleep(60000).">>},
                 self()),
    timer:sleep(100),
    {ok, _} = chaser_conn:request(Conn, #{<<"op">> => <<"interrupt">>,
                                          <<"session">> => Session}),
    Msgs = collect_stream(Id, []),
    Statuses = lists:append([maps:get(<<"status">>, M, []) || M <- Msgs]),
    ?assert(lists:member(<<"interrupted">>, Statuses)),
    ok = chaser_conn:close(Conn).

collect_stream(Id, Acc) ->
    receive
        {chaser_msg, Id, Msg} -> collect_stream(Id, [Msg | Acc]);
        {chaser_done, Id, _Statuses} -> lists:reverse(Acc)
    after 10000 ->
            error({timeout, lists:reverse(Acc)})
    end.

%% Drive the real escript over a pipe: banner + values + errors on stdout,
%% no prompts (non-tty mode), clean exit on EOF.
pipe_end_to_end(Config) ->
    Escript = escript_path(),
    PortNum = ?config(port, Config),
    Port = open_port({spawn_executable, Escript},
                     [{args, ["--port", integer_to_list(PortNum)]},
                      binary, use_stdio, exit_status, stderr_to_stdout]),
    true = port_command(Port, <<"io:format(\"printed\"), 6 * 7.\n">>),
    Out1 = read_port_until(Port, <<"=> 42">>, []),
    ?assertMatch({_, _}, binary:match(Out1, <<"chaser">>)),   %% banner
    ?assertMatch({_, _}, binary:match(Out1, <<"printed">>)),
    %% non-tty mode prints no "host:port> " prompts
    PromptMarker = <<(integer_to_binary(PortNum))/binary, "> ">>,
    ?assertEqual(nomatch, binary:match(Out1, PromptMarker)),
    true = port_command(Port, <<"1 div 0.\n">>),
    Out2 = read_port_until(Port, <<"!! error:badarith">>, []),
    ?assertMatch({_, _}, binary:match(Out2, <<"arithmetic">>)),
    port_close(Port),
    ok.

read_port_until(Port, Marker, Acc) ->
    receive
        {Port, {data, Data}} ->
            Acc2 = [Data | Acc],
            Bin = iolist_to_binary(lists:reverse(Acc2)),
            case binary:match(Bin, Marker) of
                {_, _} -> Bin;
                nomatch -> read_port_until(Port, Marker, Acc2)
            end;
        {Port, {exit_status, Status}} ->
            error({unexpected_exit, Status, iolist_to_binary(lists:reverse(Acc))})
    after 15000 ->
            error({timeout_waiting_for, Marker,
                   iolist_to_binary(lists:reverse(Acc))})
    end.

escript_path() ->
    %% _build/test/lib/chaser/ebin is 5 components below the project root
    Ebin = filename:dirname(code:which(chaser_conn)),
    Root = filename:join(lists:sublist(filename:split(Ebin),
                                       length(filename:split(Ebin)) - 5)),
    Escript = filename:join([Root, "_build", "default", "bin", "chaser"]),
    %% Always rebuild: a stale escript silently tests yesterday's code.
    _ = os:cmd("cd " ++ Root ++ " && rebar3 escriptize"),
    true = filelib:is_regular(Escript),
    Escript.
