-module(dialtone_bencode_tests).

-include_lib("eunit/include/eunit.hrl").

enc(Term) -> iolist_to_binary(dialtone_bencode:encode(Term)).

encode_test_() ->
    [?_assertEqual(<<"i42e">>, enc(42)),
     ?_assertEqual(<<"i-3e">>, enc(-3)),
     ?_assertEqual(<<"i0e">>, enc(0)),
     ?_assertEqual(<<"4:eval">>, enc(<<"eval">>)),
     ?_assertEqual(<<"0:">>, enc(<<>>)),
     ?_assertEqual(<<"4:done">>, enc(done)),
     ?_assertEqual(<<"le">>, enc([])),
     ?_assertEqual(<<"l4:done11:interruptede">>, enc([done, <<"interrupted">>])),
     ?_assertEqual(<<"de">>, enc(#{})),
     %% keys are emitted sorted regardless of map/atom form
     ?_assertEqual(<<"d4:code7:(+ 2 2)2:op4:evale">>,
                   enc(#{op => <<"eval">>, <<"code">> => <<"(+ 2 2)">>})),
     %% nested structures
     ?_assertEqual(<<"d3:opsd4:evaldeee">>, enc(#{ops => #{eval => #{}}})),
     %% byte-length (not char-length) prefixes for multibyte strings
     ?_assertEqual(<<"2:", 206, 187>>, enc(<<"λ"/utf8>>))].

decode_test_() ->
    [?_assertEqual({ok, 42, <<>>}, dialtone_bencode:decode(<<"i42e">>)),
     ?_assertEqual({ok, -7, <<"rest">>}, dialtone_bencode:decode(<<"i-7erest">>)),
     ?_assertEqual({ok, <<"eval">>, <<>>}, dialtone_bencode:decode(<<"4:eval">>)),
     ?_assertEqual({ok, <<>>, <<>>}, dialtone_bencode:decode(<<"0:">>)),
     ?_assertEqual({ok, [], <<>>}, dialtone_bencode:decode(<<"le">>)),
     ?_assertEqual({ok, [<<"a">>, 1], <<>>}, dialtone_bencode:decode(<<"l1:ai1ee">>)),
     ?_assertEqual({ok, #{}, <<>>}, dialtone_bencode:decode(<<"de">>)),
     ?_assertEqual({ok, #{<<"op">> => <<"eval">>, <<"code">> => <<"(+ 2 2)">>}, <<>>},
                   dialtone_bencode:decode(<<"d4:code7:(+ 2 2)2:op4:evale">>)),
     %% unsorted dict keys accepted on input (leniency)
     ?_assertEqual({ok, #{<<"b">> => 1, <<"a">> => 2}, <<>>},
                   dialtone_bencode:decode(<<"d1:bi1e1:ai2ee">>)),
     %% two messages back to back: rest is returned for the caller's loop
     ?_assertEqual({ok, #{<<"a">> => 1}, <<"d1:bi2ee">>},
                   dialtone_bencode:decode(<<"d1:ai1eed1:bi2ee">>))].

incomplete_test_() ->
    Msg = <<"d4:code7:(+ 2 2)2:op4:evale">>,
    [?_assertEqual({more, <<>>}, dialtone_bencode:decode(<<>>)),
     ?_assertEqual({more, <<"i42">>}, dialtone_bencode:decode(<<"i42">>)),
     ?_assertEqual({more, <<"4:ev">>}, dialtone_bencode:decode(<<"4:ev">>)),
     ?_assertEqual({more, <<"12">>}, dialtone_bencode:decode(<<"12">>)),
     ?_assertEqual({more, <<"l1:a">>}, dialtone_bencode:decode(<<"l1:a">>)),
     ?_assertEqual({more, <<"d1:a">>}, dialtone_bencode:decode(<<"d1:a">>)) |
     %% every proper prefix of a real message is 'more', never an error
     [?_assertEqual({more, binary:part(Msg, 0, N)},
                    dialtone_bencode:decode(binary:part(Msg, 0, N)))
      || N <- lists:seq(0, byte_size(Msg) - 1)]].

invalid_test_() ->
    [?_assertMatch({error, {unexpected_byte, $x}}, dialtone_bencode:decode(<<"x">>)),
     ?_assertMatch({error, {bad_integer, _}}, dialtone_bencode:decode(<<"iae">>)),
     ?_assertMatch({error, {bad_integer, _}}, dialtone_bencode:decode(<<"ie">>)),
     ?_assertMatch({error, {bad_integer, _}}, dialtone_bencode:decode(<<"i-e">>)),
     ?_assertMatch({error, {bad_length, _}}, dialtone_bencode:decode(<<"4x:abcd">>)),
     ?_assertMatch({error, non_string_dict_key}, dialtone_bencode:decode(<<"di1ei2ee">>)),
     ?_assertMatch({error, _}, dialtone_bencode:decode(<<"lxe">>))].

utf8_roundtrip_test() ->
    S = <<"λx → x²; здравей"/utf8>>,
    ?assertEqual({ok, S, <<>>}, dialtone_bencode:decode(enc(S))).
