%% @private Is the accumulated input a complete, submittable expression?
%%
%% Erlang: complete when erl_scan finds a dot-terminated form (the scanner's
%% own continuation handling deals with dots inside strings and comments).
%% Elixir: a balance heuristic over brackets, quotes and do/end - not a
%% parser, but right for the common shapes; wrong guesses just mean the
%% server reports a syntax error, exactly as if there were no heuristic.
%% Unknown languages: every line is complete.
-module(chaser_input).

-export([complete/2]).

-spec complete(erlang | elixir | none, unicode:chardata()) -> boolean().
complete(erlang, Input) ->
    %% The trailing newline matters: a form-ending dot only terminates once
    %% the scanner sees what follows it ("2." could still become "2.5").
    Str = unicode:characters_to_list(Input) ++ "\n",
    case erl_scan:tokens([], Str, 1) of
        {done, _Result, _Rest} -> true;
        {more, _Cont} -> not has_visible_chars(Str)
    end;
complete(elixir, Input) ->
    Str = unicode:characters_to_list(Input),
    balanced(Str, []) andalso not trailing_continuation(Str);
complete(none, _Input) ->
    true.

has_visible_chars(Str) ->
    lists:any(fun(C) -> not lists:member(C, " \t\n\r") end, Str).

%%% Elixir balance heuristic

%% Stack-based scan tracking brackets, strings and do/fn blocks.
balanced([], Stack) ->
    Stack =:= [];
balanced([$\\, _ | Rest], [Q | _] = Stack) when Q =:= $"; Q =:= $' ->
    balanced(Rest, Stack);
balanced([Q | Rest], [Q | Stack]) when Q =:= $"; Q =:= $' ->
    balanced(Rest, Stack);
balanced([_ | Rest], [Q | _] = Stack) when Q =:= $"; Q =:= $' ->
    balanced(Rest, Stack);
balanced([Q | Rest], Stack) when Q =:= $"; Q =:= $' ->
    balanced(Rest, [Q | Stack]);
balanced([$# | Rest], Stack) ->
    balanced(skip_line(Rest), Stack);
balanced([C | Rest], Stack) when C =:= $(; C =:= $[; C =:= ${ ->
    balanced(Rest, [closer(C) | Stack]);
balanced([C | Rest], [C | Stack]) when C =:= $); C =:= $]; C =:= $} ->
    balanced(Rest, Stack);
balanced([C | _Rest], _Stack) when C =:= $); C =:= $]; C =:= $} ->
    %% Unbalanced closer: call it complete and let the server complain.
    true;
balanced(Str, Stack) ->
    case keyword(Str) of
        {do, Rest} -> balanced(Rest, ['end' | Stack]);
        {fn, Rest} -> balanced(Rest, ['end' | Stack]);
        {'end', Rest} ->
            case Stack of
                ['end' | Stack2] -> balanced(Rest, Stack2);
                _ -> true
            end;
        {word, Rest} -> balanced(Rest, Stack);
        none -> balanced(tl(Str), Stack)
    end.

closer($() -> $);
closer($[) -> $];
closer(${) -> $}.

skip_line([]) -> [];
skip_line([$\n | Rest]) -> Rest;
skip_line([_ | Rest]) -> skip_line(Rest).

%% Recognize whole words so `done` or `fnord` don't count as do/fn/end.
%% `do:` is keyword-list syntax (def f, do: :ok), not a block opener.
keyword(Str) ->
    case take_word(Str) of
        {"", _} -> none;
        {"do", [$: | _] = Rest} -> {word, Rest};
        {"do", Rest} -> {do, Rest};
        {"fn", Rest} -> {fn, Rest};
        {"end", Rest} -> {'end', Rest};
        {_Word, Rest} -> {word, Rest}
    end.

take_word(Str) ->
    take_word(Str, []).

take_word([C | Rest], Acc)
  when C >= $a, C =< $z; C >= $A, C =< $Z; C >= $0, C =< $9; C =:= $_ ->
    take_word(Rest, [C | Acc]);
take_word(Rest, Acc) ->
    {lists:reverse(Acc), Rest}.

%% "x =", "foo <>", "x ->" at the end mean the user isn't done. Word
%% operators need the leading space so `x_and` doesn't read as `and`.
trailing_continuation(Str) ->
    Trimmed = string:trim(Str, trailing),
    lists:any(fun(Op) -> ends_with(Trimmed, Op) end,
              ["->", "=", "<>", "|>", "++", "--", "+", "-", "*", "/", ",",
               " and", " or", " when"]).

ends_with(Str, Suffix) ->
    lists:suffix(Suffix, Str).
