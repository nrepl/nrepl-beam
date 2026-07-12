%% @private TAB completion: an expand_fun for edlin that asks the server's
%% completions op and renders candidates in edlin's grouped-section format
%% (functions / modules / vars in titled columns).
%%
%% Runs inside the tty group process, so it must never block typing: the
%% server gets a short deadline and any failure degrades to "no matches".
-module(chaser_complete).

-export([expand_fun/2, expand/3, sections/2]).

-define(TIMEOUT, 300).
%% What can appear in a symbol across our languages: Erlang mod:fun, Elixir
%% Mod.fun/arity, :erlang_mod, predicates (?, !), module vars (@).
-define(SYMBOL_CHARS,
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_:.?!@").

-spec expand_fun(pid(), binary()) -> fun((string()) -> tuple()).
expand_fun(Conn, Session) ->
    fun(ReversedLine) -> expand(ReversedLine, Conn, Session) end.

expand(ReversedLine, Conn, Session) ->
    case prefix(ReversedLine) of
        "" ->
            {no, "", []};
        Prefix ->
            case candidates(Conn, Session, Prefix) of
                [] -> {no, "", []};
                Candidates -> render(Prefix, Candidates)
            end
    end.

%% The symbol being typed = longest run of symbol chars at the cursor
%% (the line arrives reversed, so it's a prefix of the reversed line).
prefix(ReversedLine) ->
    lists:reverse(lists:takewhile(
                    fun(C) -> lists:member(C, ?SYMBOL_CHARS) end,
                    ReversedLine)).

candidates(Conn, Session, Prefix) ->
    Req = #{<<"op">> => <<"completions">>,
            <<"session">> => Session,
            <<"prefix">> => unicode:characters_to_binary(Prefix)},
    case chaser_conn:request(Conn, Req, ?TIMEOUT) of
        {ok, Msgs} ->
            lists:append([Cs || #{<<"completions">> := Cs} <- Msgs]);
        {error, _} ->
            []
    end.

render(Prefix, Candidates) ->
    Names = [maps:get(<<"candidate">>, C)
             || C <- Candidates, is_map_key(<<"candidate">>, C)],
    Insert = insertion(Prefix, Names),
    case {Names, Insert} of
        {[_Single], _} ->
            %% One candidate: insert the rest, nothing to display.
            {yes, Insert, []};
        {_, ""} ->
            {yes, "", sections(Prefix, Candidates)};
        _ ->
            %% Extend to the common prefix; showing the matches too helps.
            {yes, Insert, sections(Prefix, Candidates)}
    end.

%% Characters to insert: common prefix of all candidates, minus what's typed.
insertion(Prefix, Names) ->
    Common = common_prefix(Names),
    PrefixBin = unicode:characters_to_binary(Prefix),
    PrefixSize = byte_size(PrefixBin),
    case Common of
        <<P:PrefixSize/binary, Rest/binary>> when P =:= PrefixBin ->
            unicode:characters_to_list(Rest);
        _ ->
            ""
    end.

common_prefix([First | Rest]) ->
    lists:foldl(fun(Name, Acc) ->
                        Len = binary:longest_common_prefix([Name, Acc]),
                        binary:part(Acc, 0, Len)
                end, First, Rest).

%% Group by server-reported type into edlin's documented section maps.
-spec sections(string(), [map()]) -> [map()].
sections(_Prefix, Candidates) ->
    ByType = lists:foldr(
               fun(C, Acc) ->
                       Name = maps:get(<<"candidate">>, C, undefined),
                       case Name of
                           undefined -> Acc;
                           _ ->
                               Type = maps:get(<<"type">>, C, <<"other">>),
                               maps:update_with(
                                 Type, fun(L) -> [Name | L] end, [Name], Acc)
                       end
               end, #{}, Candidates),
    [#{title => title(Type),
       elems => [{unicode:characters_to_list(Name), []} || Name <- Names],
       options => [{hide, result}]}
     || Type := Names <- ByType].

title(<<"function">>) -> "functions";
title(<<"macro">>) -> "macros";
title(<<"module">>) -> "modules";
title(<<"var">>) -> "variables";
title(Other) -> unicode:characters_to_list(Other).
