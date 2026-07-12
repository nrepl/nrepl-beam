%% @doc Incremental bencode codec for the nREPL wire protocol.
%%
%% Bencode has four types, mapped to Erlang terms as follows:
%% byte string &lt;-&gt; binary(), integer &lt;-&gt; integer(), list &lt;-&gt; list(),
%% dictionary &lt;-&gt; map() with binary keys.
%%
%% The decoder is incremental: fed a buffer that ends mid-value it returns
%% `{more, Buffer}' so callers can accumulate TCP data and retry. It is
%% deliberately lenient about canonical form on input (unsorted dict keys
%% are accepted); the encoder always emits canonical form (sorted keys).
-module(dialtone_bencode).

-export([encode/1, decode/1]).

-type value() :: integer() | binary() | atom() | [value()] | #{key() => value()}.
-type key() :: binary() | atom().

-export_type([value/0]).

%%% Encoding

%% @doc Encode a term as bencode iodata. Atoms encode as their name, which
%% keeps call sites free of atom_to_binary noise (statuses, op names).
-spec encode(value()) -> iodata().
encode(I) when is_integer(I) ->
    [$i, integer_to_binary(I), $e];
encode(B) when is_binary(B) ->
    [integer_to_binary(byte_size(B)), $:, B];
encode(A) when is_atom(A) ->
    encode(atom_to_binary(A, utf8));
encode(L) when is_list(L) ->
    [$l, [encode(E) || E <- L], $e];
encode(M) when is_map(M) ->
    Pairs = lists:keysort(1, [{key_to_binary(K), V} || K := V <- M]),
    [$d, [[encode(K), encode(V)] || {K, V} <- Pairs], $e].

key_to_binary(K) when is_binary(K) -> K;
key_to_binary(K) when is_atom(K) -> atom_to_binary(K, utf8).

%%% Decoding

%% @doc Decode one complete bencode value from the front of a buffer.
%% Returns the remaining bytes so callers can loop over a message stream.
-spec decode(binary()) ->
          {ok, value(), Rest :: binary()} | {more, binary()} | {error, term()}.
decode(Bin) when is_binary(Bin) ->
    try dec(Bin) of
        {Value, Rest} -> {ok, Value, Rest}
    catch
        throw:more -> {more, Bin};
        throw:{invalid, Reason} -> {error, Reason}
    end.

dec(<<$i, Rest/binary>>) ->
    dec_int(Rest, <<>>);
dec(<<$l, Rest/binary>>) ->
    dec_list(Rest, []);
dec(<<$d, Rest/binary>>) ->
    dec_dict(Rest, #{});
dec(<<C, _/binary>> = Bin) when C >= $0, C =< $9 ->
    dec_str(Bin, 0);
dec(<<>>) ->
    throw(more);
dec(<<C, _/binary>>) ->
    throw({invalid, {unexpected_byte, C}}).

%% i<digits>e, optional leading minus. Empty digits ("ie", "i-e") invalid.
dec_int(<<$-, Rest/binary>>, <<>>) ->
    dec_int_digits(Rest, <<$->>);
dec_int(Bin, <<>>) ->
    dec_int_digits(Bin, <<>>).

dec_int_digits(<<C, Rest/binary>>, Acc) when C >= $0, C =< $9 ->
    dec_int_digits(Rest, <<Acc/binary, C>>);
dec_int_digits(<<$e, Rest/binary>>, Acc) when Acc =/= <<>>, Acc =/= <<"-">> ->
    {binary_to_integer(Acc), Rest};
dec_int_digits(<<>>, _Acc) ->
    throw(more);
dec_int_digits(<<C, _/binary>>, _Acc) ->
    throw({invalid, {bad_integer, C}}).

%% <length>:<bytes>
dec_str(<<C, Rest/binary>>, Len) when C >= $0, C =< $9 ->
    dec_str(Rest, Len * 10 + (C - $0));
dec_str(<<$:, Rest/binary>>, Len) ->
    case Rest of
        <<Str:Len/binary, Tail/binary>> -> {Str, Tail};
        _ -> throw(more)
    end;
dec_str(<<>>, _Len) ->
    throw(more);
dec_str(<<C, _/binary>>, _Len) ->
    throw({invalid, {bad_length, C}}).

dec_list(<<$e, Rest/binary>>, Acc) ->
    {lists:reverse(Acc), Rest};
dec_list(<<>>, _Acc) ->
    throw(more);
dec_list(Bin, Acc) ->
    {Value, Rest} = dec(Bin),
    dec_list(Rest, [Value | Acc]).

dec_dict(<<$e, Rest/binary>>, Acc) ->
    {Acc, Rest};
dec_dict(<<>>, _Acc) ->
    throw(more);
dec_dict(Bin, Acc) ->
    case dec(Bin) of
        {Key, Rest} when is_binary(Key) ->
            {Value, Rest2} = dec(Rest),
            dec_dict(Rest2, Acc#{Key => Value});
        {_NonString, _Rest} ->
            throw({invalid, non_string_dict_key})
    end.
