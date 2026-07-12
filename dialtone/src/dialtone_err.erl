%% @private Exception rendering: the multi-line human-readable account goes
%% in "err", a one-line summary in "ex" (the spec leaves its format to the
%% language). Backends can override via the format_exception/4 callback.
-module(dialtone_err).

-export([render/5, to_wire/1]).

-spec render(module(), error | exit | throw, term(), erlang:stacktrace(),
             term()) -> dialtone_backend:err_result().
render(BMod, Class, Reason, Stack, BState) ->
    case erlang:function_exported(BMod, format_exception, 4) of
        true ->
            try
                BMod:format_exception(Class, Reason, Stack, BState)
            catch
                _:_ -> default(Class, Reason, Stack)
            end;
        false ->
            default(Class, Reason, Stack)
    end.

default(Class, Reason, Stack) ->
    Err = erl_error:format_exception(Class, Reason, Stack),
    Ex = io_lib:format("~w:~0tP", [Class, Reason, 8]),
    #{err => Err, ex => Ex}.

%% @doc Backend err_result (chardata) -> wire fields (utf8 binaries).
-spec to_wire(dialtone_backend:err_result()) -> #{binary() => binary()}.
to_wire(#{err := Err, ex := Ex}) ->
    #{<<"err">> => to_bin(Err), <<"ex">> => to_bin(Ex)}.

to_bin(Chardata) ->
    case unicode:characters_to_binary(Chardata) of
        Bin when is_binary(Bin) -> Bin;
        _ -> <<"unprintable">>
    end.
