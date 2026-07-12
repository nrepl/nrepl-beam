%% Integration suite: drives a real dialtone server over TCP with the
%% bencode test client, asserting the wire contract an editor client (neat,
%% CIDER, ...) relies on.
-module(dialtone_SUITE).

-compile(export_all).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

suite() ->
    [{timetrap, {seconds, 30}}].

all() ->
    [describe_capabilities,
     clone_and_eval,
     bindings_persist,
     multi_form_eval,
     syntax_error,
     runtime_error,
     unknown_op,
     missing_code,
     stdout_streaming,
     stdout_before_done,
     stdin_roundtrip,
     stdin_eof,
     ls_sessions_and_close,
     ephemeral_eval,
     clone_inherits_bindings,
     concurrent_sessions,
     interrupt_running_eval,
     interrupt_idle_session,
     interrupt_id_mismatch,
     close_mid_eval,
     load_file_module,
     load_file_expressions,
     load_file_compile_error,
     malformed_frame_closes_connection,
     session_survives_disconnect,
     unicode_roundtrip,
     every_response_echoes_id_and_session,
     port_file_lifecycle].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(dialtone),
    {ok, Server} = dialtone:start_server(#{port => 0, port_file => false}),
    [{server, Server}, {port, dialtone:port(Server)} | Config].

end_per_suite(Config) ->
    ok = dialtone:stop_server(?config(server, Config)),
    ok = application:stop(dialtone).

init_per_testcase(_Case, Config) ->
    [{client, dialtone_client:connect(?config(port, Config))} | Config].

end_per_testcase(_Case, Config) ->
    dialtone_client:close(?config(client, Config)).

%%% Helpers

clone(Client) ->
    {[Resp], Client2} = dialtone_client:request(Client, #{<<"op">> => <<"clone">>}),
    #{<<"new-session">> := Session} = Resp,
    {Session, Client2}.

eval(Client, Session, Code) ->
    dialtone_client:request(Client, #{<<"op">> => <<"eval">>,
                                      <<"code">> => Code,
                                      <<"session">> => Session}).

value_of(Msgs) ->
    [Value] = [V || #{<<"value">> := V} <- Msgs],
    Value.

statuses_of(Msgs) ->
    lists:usort(lists:append([S || #{<<"status">> := S} <- Msgs])).

out_of(Msgs) ->
    iolist_to_binary([O || #{<<"out">> := O} <- Msgs]).

%%% Cases

describe_capabilities(Config) ->
    {[Resp], _} = dialtone_client:request(?config(client, Config),
                                          #{<<"op">> => <<"describe">>}),
    #{<<"ops">> := Ops, <<"versions">> := Versions, <<"status">> := [<<"done">>]} = Resp,
    [?assert(maps:is_key(Op, Ops))
     || Op <- [<<"clone">>, <<"describe">>, <<"eval">>, <<"interrupt">>,
               <<"stdin">>, <<"close">>, <<"ls-sessions">>]],
    ?assertMatch(#{<<"nrepl">> := #{<<"version-string">> := _},
                   <<"erlang">> := _}, Versions).

clone_and_eval(Config) ->
    {Session, Client} = clone(?config(client, Config)),
    ?assert(is_binary(Session) andalso byte_size(Session) > 0),
    {Msgs, _} = eval(Client, Session, <<"1 + 2.">>),
    ?assertEqual(<<"3">>, value_of(Msgs)),
    ?assertEqual([<<"done">>], statuses_of(Msgs)).

bindings_persist(Config) ->
    {Session, Client} = clone(?config(client, Config)),
    {_, Client2} = eval(Client, Session, <<"X = 41.">>),
    {Msgs, _} = eval(Client2, Session, <<"X + 1.">>),
    ?assertEqual(<<"42">>, value_of(Msgs)).

multi_form_eval(Config) ->
    {Session, Client} = clone(?config(client, Config)),
    {Msgs, _} = eval(Client, Session, <<"A = 1. B = A + 1. A + B.">>),
    ?assertEqual(<<"3">>, value_of(Msgs)).

syntax_error(Config) ->
    {Session, Client} = clone(?config(client, Config)),
    {Msgs, _} = eval(Client, Session, <<"1 +.">>),
    [Err] = [M || #{<<"err">> := _} = M <- Msgs],
    ?assertEqual(<<"syntax-error">>, maps:get(<<"ex">>, Err)),
    ?assert(lists:member(<<"eval-error">>, statuses_of(Msgs))).

runtime_error(Config) ->
    {Session, Client} = clone(?config(client, Config)),
    {Msgs, _} = eval(Client, Session, <<"1 div 0.">>),
    ?assert(lists:member(<<"eval-error">>, statuses_of(Msgs))),
    [ErrMsg] = [M || #{<<"err">> := _} = M <- Msgs],
    ?assertEqual(<<"error:badarith">>, maps:get(<<"ex">>, ErrMsg)),
    ?assertMatch({_, _}, binary:match(maps:get(<<"err">>, ErrMsg), <<"arithmetic">>)),
    %% a failed eval must not wedge the session
    {Msgs2, _} = eval(?config(client, Config), Session, <<"ok.">>),
    ?assertEqual(<<"ok">>, value_of(Msgs2)).

unknown_op(Config) ->
    {[Resp], _} = dialtone_client:request(?config(client, Config),
                                          #{<<"op">> => <<"frobnicate">>}),
    ?assertEqual([<<"unknown-op">>, <<"done">>], maps:get(<<"status">>, Resp)).

missing_code(Config) ->
    {Session, Client} = clone(?config(client, Config)),
    {Msgs, _} = dialtone_client:request(Client, #{<<"op">> => <<"eval">>,
                                                  <<"session">> => Session}),
    ?assert(lists:member(<<"eval-error">>, statuses_of(Msgs))).

stdout_streaming(Config) ->
    {Session, Client} = clone(?config(client, Config)),
    {Msgs, _} = eval(Client, Session,
                     <<"io:format(\"hello ~ts~n\", [\"света\"]), done."/utf8>>),
    ?assertEqual(<<"hello света\n"/utf8>>, out_of(Msgs)),
    ?assertEqual(<<"done">>, value_of(Msgs)).

%% Output chunks must be on the wire before the value/done of their eval.
stdout_before_done(Config) ->
    {Session, Client} = clone(?config(client, Config)),
    {Msgs, _} = eval(Client, Session,
                     <<"[io:format(\"~b\", [N]) || N <- lists:seq(1, 5)], ok.">>),
    LastOut = lists:max([I || {I, M} <- lists:enumerate(Msgs), maps:is_key(<<"out">>, M)]),
    FirstValue = lists:min([I || {I, M} <- lists:enumerate(Msgs), maps:is_key(<<"value">>, M)]),
    ?assert(LastOut < FirstValue),
    ?assertEqual(<<"12345">>, out_of(Msgs)).

stdin_roundtrip(Config) ->
    {Session, Client} = clone(?config(client, Config)),
    Client2 = dialtone_client:send(Client, #{<<"op">> => <<"eval">>,
                                             <<"id">> => <<"reader">>,
                                             <<"session">> => Session,
                                             <<"code">> => <<"io:get_line(\"name? \").">>}),
    %% collect until need-input shows up (the prompt arrives as out)
    {NeedInput, Client3} = recv_until_status(Client2, <<"need-input">>, []),
    ?assertEqual(<<"name? ">>, out_of(NeedInput)),
    {StdinMsgs, Client4} = dialtone_client:request(
                             Client3, #{<<"op">> => <<"stdin">>,
                                        <<"session">> => Session,
                                        <<"stdin">> => <<"Bozhidar\n">>}),
    ?assertEqual([<<"done">>], statuses_of(StdinMsgs)),
    {EvalMsgs, _} = dialtone_client:recv_until_done(Client4, <<"reader">>, 5000),
    ?assertEqual(<<"\"Bozhidar\\n\"">>, value_of(EvalMsgs)).

stdin_eof(Config) ->
    {Session, Client} = clone(?config(client, Config)),
    Client2 = dialtone_client:send(Client, #{<<"op">> => <<"eval">>,
                                             <<"id">> => <<"reader">>,
                                             <<"session">> => Session,
                                             <<"code">> => <<"io:get_line(\"\").">>}),
    {_, Client3} = recv_until_status(Client2, <<"need-input">>, []),
    {_, Client4} = dialtone_client:request(Client3, #{<<"op">> => <<"stdin">>,
                                                      <<"session">> => Session,
                                                      <<"stdin">> => <<>>}),
    {EvalMsgs, _} = dialtone_client:recv_until_done(Client4, <<"reader">>, 5000),
    ?assertEqual(<<"eof">>, value_of(EvalMsgs)).

recv_until_status(Client, Status, Acc) ->
    {Msg, Client2} = dialtone_client:recv_msg(Client, 5000),
    case lists:member(Status, maps:get(<<"status">>, Msg, [])) of
        true -> {lists:reverse([Msg | Acc]), Client2};
        false -> recv_until_status(Client2, Status, [Msg | Acc])
    end.

ls_sessions_and_close(Config) ->
    {Session, Client} = clone(?config(client, Config)),
    {[Ls], Client2} = dialtone_client:request(Client, #{<<"op">> => <<"ls-sessions">>}),
    ?assert(lists:member(Session, maps:get(<<"sessions">>, Ls))),
    {[CloseResp], Client3} =
        dialtone_client:request(Client2, #{<<"op">> => <<"close">>,
                                           <<"session">> => Session}),
    ?assertEqual([<<"done">>], maps:get(<<"status">>, CloseResp)),
    %% registry cleanup is async (DOWN); poll briefly
    ok = wait_until(fun() ->
                            {[Ls2], _} = dialtone_client:request(
                                           dialtone_client:connect(?config(port, Config)),
                                           #{<<"op">> => <<"ls-sessions">>}),
                            not lists:member(Session, maps:get(<<"sessions">>, Ls2, []))
                    end),
    %% close is idempotent
    {[CloseResp2], _} =
        dialtone_client:request(Client3, #{<<"op">> => <<"close">>,
                                           <<"session">> => Session}),
    ?assertEqual([<<"done">>], maps:get(<<"status">>, CloseResp2)).

ephemeral_eval(Config) ->
    {Msgs, _} = dialtone_client:request(?config(client, Config),
                                        #{<<"op">> => <<"eval">>,
                                          <<"code">> => <<"6 * 7.">>}),
    ?assertEqual(<<"42">>, value_of(Msgs)),
    %% the throwaway session id is echoed on every response
    [?assertMatch(#{<<"session">> := _}, M) || M <- Msgs].

clone_inherits_bindings(Config) ->
    {Session, Client} = clone(?config(client, Config)),
    {_, Client2} = eval(Client, Session, <<"Legacy = 7.">>),
    {[Resp], Client3} = dialtone_client:request(
                          Client2, #{<<"op">> => <<"clone">>,
                                     <<"session">> => Session}),
    Session2 = maps:get(<<"new-session">>, Resp),
    {Msgs, _} = eval(Client3, Session2, <<"Legacy * 2.">>),
    ?assertEqual(<<"14">>, value_of(Msgs)).

concurrent_sessions(Config) ->
    {S1, Client} = clone(?config(client, Config)),
    {S2, Client2} = clone(Client),
    Client3 = dialtone_client:send(Client2, #{<<"op">> => <<"eval">>,
                                              <<"id">> => <<"slow">>,
                                              <<"session">> => S1,
                                              <<"code">> => <<"timer:sleep(2000).">>}),
    Client4 = dialtone_client:send(Client3, #{<<"op">> => <<"eval">>,
                                              <<"id">> => <<"fast">>,
                                              <<"session">> => S2,
                                              <<"code">> => <<"1 + 1.">>}),
    %% the fast eval on the other session must not wait for the slow one
    {First, _} = dialtone_client:recv_msg(Client4, 1000),
    ?assertEqual(<<"fast">>, maps:get(<<"id">>, First)).

interrupt_running_eval(Config) ->
    {Session, Client} = clone(?config(client, Config)),
    {_, Client2} = eval(Client, Session, <<"Kept = 13.">>),
    Client3 = dialtone_client:send(Client2, #{<<"op">> => <<"eval">>,
                                              <<"id">> => <<"hang">>,
                                              <<"session">> => Session,
                                              <<"code">> => <<"timer:sleep(60000).">>}),
    timer:sleep(100),
    {IntMsgs, Client4} = dialtone_client:request(
                           Client3, #{<<"op">> => <<"interrupt">>,
                                      <<"session">> => Session,
                                      <<"interrupt-id">> => <<"hang">>}),
    ?assertEqual([<<"done">>], statuses_of(IntMsgs)),
    {HangMsgs, Client5} = dialtone_client:recv_until_done(Client4, <<"hang">>, 5000),
    ?assert(lists:member(<<"interrupted">>, statuses_of(HangMsgs))),
    %% session state survived the kill
    {Msgs, _} = eval(Client5, Session, <<"Kept.">>),
    ?assertEqual(<<"13">>, value_of(Msgs)).

interrupt_idle_session(Config) ->
    {Session, Client} = clone(?config(client, Config)),
    {[Resp], _} = dialtone_client:request(Client, #{<<"op">> => <<"interrupt">>,
                                                    <<"session">> => Session}),
    ?assertEqual([<<"session-idle">>, <<"done">>], maps:get(<<"status">>, Resp)).

interrupt_id_mismatch(Config) ->
    {Session, Client} = clone(?config(client, Config)),
    Client2 = dialtone_client:send(Client, #{<<"op">> => <<"eval">>,
                                             <<"id">> => <<"running">>,
                                             <<"session">> => Session,
                                             <<"code">> => <<"timer:sleep(60000).">>}),
    timer:sleep(100),
    {[Resp], Client3} = dialtone_client:request(
                          Client2, #{<<"op">> => <<"interrupt">>,
                                     <<"session">> => Session,
                                     <<"interrupt-id">> => <<"not-running">>}),
    ?assertEqual([<<"interrupt-id-mismatch">>, <<"done">>],
                 maps:get(<<"status">>, Resp)),
    %% clean up: interrupt for real
    {_, Client4} = dialtone_client:request(Client3, #{<<"op">> => <<"interrupt">>,
                                                      <<"session">> => Session}),
    {_, _} = dialtone_client:recv_until_done(Client4, <<"running">>, 5000).

close_mid_eval(Config) ->
    {Session, Client} = clone(?config(client, Config)),
    Client2 = dialtone_client:send(Client, #{<<"op">> => <<"eval">>,
                                             <<"id">> => <<"doomed">>,
                                             <<"session">> => Session,
                                             <<"code">> => <<"timer:sleep(60000).">>}),
    timer:sleep(100),
    Client3 = dialtone_client:send(Client2, #{<<"op">> => <<"close">>,
                                              <<"id">> => <<"closer">>,
                                              <<"session">> => Session}),
    {DoomedMsgs, Client4} = dialtone_client:recv_until_done(Client3, <<"doomed">>, 5000),
    ?assert(lists:member(<<"interrupted">>, statuses_of(DoomedMsgs))),
    {CloseMsgs, _} = dialtone_client:recv_until_done(Client4, <<"closer">>, 5000),
    ?assertEqual([<<"done">>], statuses_of(CloseMsgs)).

load_file_module(Config) ->
    {Session, Client} = clone(?config(client, Config)),
    Source = <<"-module(dialtone_ct_loaded).\n"
               "-export([answer/0]).\n"
               "answer() -> 42.\n">>,
    {Msgs, Client2} = dialtone_client:request(
                        Client, #{<<"op">> => <<"load-file">>,
                                  <<"session">> => Session,
                                  <<"file">> => Source,
                                  <<"file-path">> => <<"/tmp/dialtone_ct_loaded.erl">>,
                                  <<"file-name">> => <<"dialtone_ct_loaded.erl">>}),
    ?assertEqual(<<"{module, dialtone_ct_loaded}">>, value_of(Msgs)),
    {Msgs2, _} = eval(Client2, Session, <<"dialtone_ct_loaded:answer().">>),
    ?assertEqual(<<"42">>, value_of(Msgs2)),
    %% source attribution points at the client-side path
    {Msgs3, _} = eval(?config(client, Config), Session,
                      <<"proplists:get_value(source, "
                        "dialtone_ct_loaded:module_info(compile)).">>),
    ?assertEqual(<<"\"/tmp/dialtone_ct_loaded.erl\"">>, value_of(Msgs3)).

load_file_expressions(Config) ->
    {Session, Client} = clone(?config(client, Config)),
    {Msgs, _} = dialtone_client:request(
                  Client, #{<<"op">> => <<"load-file">>,
                            <<"session">> => Session,
                            <<"file">> => <<"A = 20, B = 22, A + B.">>}),
    ?assertEqual(<<"42">>, value_of(Msgs)).

load_file_compile_error(Config) ->
    {Session, Client} = clone(?config(client, Config)),
    Source = <<"-module(dialtone_ct_broken).\n"
               "-export([boom/0]).\n"
               "boom() -> NoSuchVar.\n">>,
    {Msgs, _} = dialtone_client:request(
                  Client, #{<<"op">> => <<"load-file">>,
                            <<"session">> => Session,
                            <<"file">> => Source,
                            <<"file-path">> => <<"/tmp/dialtone_ct_broken.erl">>}),
    ?assert(lists:member(<<"eval-error">>, statuses_of(Msgs))),
    [ErrMsg] = [M || #{<<"err">> := _} = M <- Msgs],
    ?assertEqual(<<"compile-error">>, maps:get(<<"ex">>, ErrMsg)),
    ?assertMatch({_, _}, binary:match(maps:get(<<"err">>, ErrMsg), <<"unbound">>)).

%% A malformed bencode stream is unrecoverable: the connection must close,
%% but the server (and existing sessions) live on.
malformed_frame_closes_connection(Config) ->
    {Session, Client} = clone(?config(client, Config)),
    #{sock := Sock} = Client,
    ok = gen_tcp:send(Sock, <<"this is not bencode">>),
    ?assertEqual({error, closed}, gen_tcp:recv(Sock, 0, 5000)),
    Client2 = dialtone_client:connect(?config(port, Config)),
    {[Ls], Client3} = dialtone_client:request(Client2, #{<<"op">> => <<"ls-sessions">>}),
    ?assert(lists:member(Session, maps:get(<<"sessions">>, Ls))),
    {Msgs, _} = eval(Client3, Session, <<"ok.">>),
    ?assertEqual(<<"ok">>, value_of(Msgs)).

session_survives_disconnect(Config) ->
    {Session, Client} = clone(?config(client, Config)),
    {_, Client2} = eval(Client, Session, <<"Durable = 99.">>),
    ok = dialtone_client:close(Client2),
    Reconnected = dialtone_client:connect(?config(port, Config)),
    {[Ls], Reconnected2} = dialtone_client:request(Reconnected,
                                                   #{<<"op">> => <<"ls-sessions">>}),
    ?assert(lists:member(Session, maps:get(<<"sessions">>, Ls))),
    {Msgs, _} = eval(Reconnected2, Session, <<"Durable.">>),
    ?assertEqual(<<"99">>, value_of(Msgs)).

%% Unicode in the code payload must survive the wire and the scanner.
%% (Printed *values* follow the node's +pc printable range, same as erl.)
unicode_roundtrip(Config) ->
    {Session, Client} = clone(?config(client, Config)),
    {Msgs, _} = eval(Client, Session, <<"byte_size(<<\"λ\"/utf8>>)."/utf8>>),
    ?assertEqual(<<"2">>, value_of(Msgs)),
    {Msgs2, _} = eval(?config(client, Config), Session,
                      <<"Grüße = <<\"здравей\"/utf8>>, byte_size(Grüße)."/utf8>>),
    ?assertEqual(<<"14">>, value_of(Msgs2)).

every_response_echoes_id_and_session(Config) ->
    {Session, Client} = clone(?config(client, Config)),
    {Msgs, _} = eval(Client, Session, <<"hello.">>),
    [?assertMatch(#{<<"id">> := _, <<"session">> := Session}, M) || M <- Msgs].

port_file_lifecycle(Config) ->
    PortFile = filename:join(?config(priv_dir, Config), ".nrepl-port"),
    {ok, Server} = dialtone:start_server(#{port => 0, port_file => PortFile}),
    Port = dialtone:port(Server),
    {ok, Contents} = file:read_file(PortFile),
    ?assertEqual(<<(integer_to_binary(Port))/binary, "\n">>, Contents),
    ok = dialtone:stop_server(Server),
    ?assertEqual({error, enoent}, file:read_file(PortFile)).

wait_until(Fun) ->
    wait_until(Fun, 50).

wait_until(_Fun, 0) ->
    {error, timeout};
wait_until(Fun, N) ->
    case Fun() of
        true -> ok;
        false -> timer:sleep(20), wait_until(Fun, N - 1)
    end.
