-module(prop_dialtone_bencode).

-include_lib("proper/include/proper.hrl").

%% Generator for the wire-representable term universe. Atoms are an
%% encoder-side convenience that decodes to binaries, so the roundtrip
%% property uses only decoder-shaped terms (binary/integer/list/map).
value() ->
    ?SIZED(Size, value(Size)).

value(0) ->
    oneof([integer(), utf8()]);
value(Size) ->
    Smaller = value(Size div 3),
    oneof([integer(),
           utf8(),
           list(Smaller),
           map(utf8(), Smaller)]).

prop_roundtrip() ->
    ?FORALL(V, value(),
            begin
                Encoded = iolist_to_binary(dialtone_bencode:encode(V)),
                {ok, V, <<>>} =:= dialtone_bencode:decode(Encoded)
            end).

%% Feeding any split of an encoded message through the accumulate-and-retry
%% loop yields the same term: the {more, _} contract the connection relies on.
prop_chunked_decode() ->
    ?FORALL({V, Splits}, {value(), list(range(0, 200))},
            begin
                Encoded = iolist_to_binary(dialtone_bencode:encode(V)),
                Chunks = split_at(Encoded, Splits),
                {ok, V, <<>>} =:= feed(Chunks, <<>>)
            end).

%% A truncated message is always {more, _}, never an error or a bogus value.
%% Checking every prefix is quadratic in message size and PropEr happily
%% generates multi-KB values, so sample at most ~64 evenly-spread cut points
%% (the exhaustive small-message check lives in the eunit suite).
prop_truncation_is_more() ->
    ?FORALL(V, value(),
            begin
                Encoded = iolist_to_binary(dialtone_bencode:encode(V)),
                Size = byte_size(Encoded),
                Step = max(1, Size div 64),
                lists:all(fun(N) ->
                                  Prefix = binary:part(Encoded, 0, N),
                                  dialtone_bencode:decode(Prefix) =:= {more, Prefix}
                          end,
                          lists:seq(0, Size - 1, Step))
            end).

%% The decoder never crashes on arbitrary junk: any input yields ok/more/error.
prop_no_crash_on_junk() ->
    ?FORALL(Junk, binary(),
            case dialtone_bencode:decode(Junk) of
                {ok, _, _} -> true;
                {more, Junk} -> true;
                {error, _} -> true
            end).

split_at(Bin, Splits) ->
    Points = lists:usort([min(P, byte_size(Bin)) || P <- Splits]),
    do_split(Bin, Points, 0).

do_split(Bin, [], _Offset) ->
    [Bin];
do_split(Bin, [P | Rest], Offset) ->
    At = P - Offset,
    <<Chunk:At/binary, Tail/binary>> = Bin,
    [Chunk | do_split(Tail, Rest, P)].

feed([Chunk | Rest], Buffer) ->
    Acc = <<Buffer/binary, Chunk/binary>>,
    case dialtone_bencode:decode(Acc) of
        {more, Acc} -> feed(Rest, Acc);
        {ok, V, Tail} when Rest =:= [], Tail =:= <<>> -> {ok, V, <<>>};
        Other -> Other
    end.
