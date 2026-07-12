-module(chaser_complete_tests).

-include_lib("eunit/include/eunit.hrl").

%% A stand-in for chaser_conn answering completions requests.
conn_stub(Candidates) ->
    spawn_link(fun() -> stub_loop(Candidates) end).

stub_loop(Candidates) ->
    receive
        {'$gen_call', From, {request, #{<<"op">> := <<"completions">>}}} ->
            gen_server:reply(From, {ok, [#{<<"completions">> => Candidates,
                                           <<"status">> => [<<"done">>]}]}),
            stub_loop(Candidates)
    end.

cand(Name, Type) ->
    #{<<"candidate">> => Name, <<"type">> => Type}.

expand(RevLine, Candidates) ->
    Conn = conn_stub(Candidates),
    chaser_complete:expand(RevLine, Conn, <<"session">>).

no_symbol_at_cursor_test() ->
    ?assertEqual({no, "", []}, expand(lists:reverse("1 + "), [])).

no_candidates_test() ->
    ?assertEqual({no, "", []}, expand(lists:reverse("lists:zzz"), [])).

single_candidate_inserts_rest_test() ->
    {yes, Insert, Matches} =
        expand(lists:reverse("lists:rev"),
               [cand(<<"lists:reverse">>, <<"function">>)]),
    ?assertEqual("erse", Insert),
    ?assertEqual([], Matches).

common_prefix_extension_test() ->
    {yes, Insert, _} =
        expand(lists:reverse("lists:ma"),
               [cand(<<"lists:mapfoldl">>, <<"function">>),
                cand(<<"lists:mapfoldr">>, <<"function">>)]),
    ?assertEqual("pfold", Insert).

grouped_sections_test() ->
    {yes, "", Sections} =
        expand(lists:reverse("li"),
               [cand(<<"lists">>, <<"module">>),
                cand(<<"line_length">>, <<"var">>),
                cand(<<"lift">>, <<"function">>)]),
    Titles = lists:sort([maps:get(title, S) || S <- Sections]),
    ?assertEqual(["functions", "modules", "variables"], Titles),
    [ModuleSection] = [S || #{title := "modules"} = S <- Sections],
    ?assertEqual([{"lists", []}], maps:get(elems, ModuleSection)),
    %% documented edlin section shape: title/elems/options keys only
    [?assertEqual([elems, options, title], lists:sort(maps:keys(S)))
     || S <- Sections].

prefix_charset_test() ->
    %% symbol chars reach across module separators for both languages
    {yes, Insert, _} =
        expand(lists:reverse("x = Enum.ma"),
               [cand(<<"Enum.map">>, <<"function">>)]),
    ?assertEqual("p", Insert).

server_timeout_degrades_to_no_test() ->
    %% a conn that never answers: expand must give up quickly, not hang
    Conn = spawn_link(fun() -> receive after infinity -> ok end end),
    ?assertEqual({no, "", []},
                 chaser_complete:expand(lists:reverse("foo"), Conn, <<"s">>)).
