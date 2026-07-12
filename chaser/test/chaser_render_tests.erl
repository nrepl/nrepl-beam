-module(chaser_render_tests).

-include_lib("eunit/include/eunit.hrl").

plain() -> chaser_render:new(#{color => false}).
color() -> chaser_render:new(#{color => true}).

render(Fun) ->
    {IoData, _R} = Fun(plain()),
    unicode:characters_to_binary(IoData).

out_passthrough_test() ->
    ?assertEqual(<<"hi\n">>, render(fun(R) -> chaser_render:out("hi\n", R) end)).

value_at_line_start_test() ->
    ?assertEqual(<<"=> 42\n">>,
                 render(fun(R) -> chaser_render:value(<<"42">>, R) end)).

value_after_partial_output_gets_own_line_test() ->
    R0 = plain(),
    {Out, R1} = chaser_render:out("no newline", R0),
    {Val, _} = chaser_render:value(<<"42">>, R1),
    ?assertEqual(<<"no newline\n=> 42\n">>,
                 unicode:characters_to_binary([Out, Val])).

multiline_value_aligns_continuations_test() ->
    ?assertEqual(<<"=> [1,\n    2]\n">>,
                 render(fun(R) -> chaser_render:value(<<"[1,\n 2]">>, R) end)).

error_summary_and_indented_detail_test() ->
    Rendered = render(fun(R) ->
                              chaser_render:err(<<"error:badarith">>,
                                                <<"exception error: bad\n  in div/2\n">>,
                                                R)
                      end),
    ?assertEqual(<<"!! error:badarith\n"
                   "   exception error: bad\n"
                   "     in div/2\n">>, Rendered).

error_without_detail_test() ->
    ?assertEqual(<<"!! interrupted\n">>,
                 render(fun(R) -> chaser_render:err(<<"interrupted">>, <<>>, R) end)).

color_wraps_value_marker_test() ->
    {IoData, _} = chaser_render:value(<<"1">>, color()),
    Bin = unicode:characters_to_binary(IoData),
    ?assertMatch({_, _}, binary:match(Bin, <<"\e[32m=> \e[0m">>)).

no_color_means_no_escapes_test() ->
    Bin = render(fun(R) -> chaser_render:err(<<"x">>, <<"y">>, R) end),
    ?assertEqual(nomatch, binary:match(Bin, <<"\e[">>)).

doc_rendering_test() ->
    Info = #{<<"name">> => <<"map">>, <<"ns">> => <<"lists">>,
             <<"arglists-str">> => <<"map(Fun, List1)">>,
             <<"doc">> => <<"Applies a fun.">>,
             <<"file">> => <<"/src/lists.erl">>, <<"line">> => 2364},
    Bin = render(fun(R) -> chaser_render:doc(Info, R) end),
    ?assertEqual(<<"lists:map map(Fun, List1)\n"
                   "Applies a fun.\n"
                   "/src/lists.erl:2364\n">>, Bin).
