%% @doc The Erlang language backend: shell-style expression evaluation with
%% bindings that persist across evals in a session.
%%
%% Code is scanned/parsed/evaluated with the stdlib erl_scan/erl_parse/
%% erl_eval pipeline. Dot-terminated forms evaluate in sequence, threading
%% bindings; the last value is reported. A missing final dot is forgiven
%% (editors send bare expressions like "1 + 2"). Evaluating module
%% definitions is not supported by erl_eval - load-file (M3) compiles module
%% sources via compile:forms instead.
-module(dialtone_backend_erlang).

-behaviour(dialtone_backend).

-export([init/1, eval/3, load_file/3, version_info/0]).

init(_Opts) ->
    {ok, #{bindings => erl_eval:new_bindings()}}.

eval(Code, Meta, #{bindings := Bindings} = State) ->
    StartLoc = {maps:get(line, Meta, 1), maps:get(column, Meta, 1)},
    Str = unicode:characters_to_list(Code),
    case erl_scan:string(Str, StartLoc) of
        {ok, [], _EndLoc} ->
            %% Whitespace/comments only: nothing to do, value is unchanged
            %% state and the atom ok, mirroring the shell's behavior.
            {ok, #{value => <<"ok">>}, State};
        {ok, Tokens, EndLoc} ->
            case parse_forms(ensure_dot(Tokens, EndLoc)) of
                {ok, ExprLists} ->
                    eval_forms(ExprLists, Bindings, State);
                {error, ErrResult} ->
                    {error, ErrResult, State}
            end;
        {error, {Loc, Mod, Desc}, _} ->
            {error, syntax_error(Loc, Mod, Desc), State}
    end.

%% A module source (leading -module attribute) is compiled with debug_info
%% and hot-loaded, attributed to its client-side path so stack traces and
%% jump-to-definition point at the real file. Anything else (scratch
%% buffers, expression files) is evaluated like eval.
load_file(Contents, Meta, State) ->
    Path = maps:get(path, Meta, maps:get(name, Meta, <<"nrepl-load-file">>)),
    Str = unicode:characters_to_list(Contents),
    case erl_scan:string(Str) of
        {ok, Tokens, EndLoc} ->
            Forms = split_dots(ensure_dot(Tokens, EndLoc)),
            case is_module_source(Forms) of
                true -> compile_module(Forms, Path, State);
                false -> eval(Contents, #{file => Path}, State)
            end;
        {error, {Loc, Mod, Desc}, _} ->
            {error, syntax_error(Loc, Mod, Desc), State}
    end.

is_module_source([FirstForm | _]) ->
    case erl_parse:parse_form(FirstForm) of
        {ok, {attribute, _, module, _}} -> true;
        _ -> false
    end;
is_module_source([]) ->
    false.

compile_module(TokenForms, Path, State) ->
    case parse_module_forms(TokenForms, []) of
        {ok, Forms} ->
            PathStr = unicode:characters_to_list(Path),
            Opts = [return_errors, return_warnings, debug_info,
                    {source, PathStr}],
            case compile:forms(Forms, Opts) of
                {ok, Mod, Bin, _Warnings} ->
                    {module, Mod} = code:load_binary(Mod, PathStr, Bin),
                    {ok, #{value => io_lib:format("{module, ~tp}", [Mod])}, State};
                {error, Errors, _Warnings} ->
                    {error, #{err => format_compile_errors(Errors),
                              ex => <<"compile-error">>}, State}
            end;
        {error, ErrResult} ->
            {error, ErrResult, State}
    end.

parse_module_forms([], Acc) ->
    {ok, lists:reverse(Acc)};
parse_module_forms([FormTokens | Rest], Acc) ->
    case erl_parse:parse_form(FormTokens) of
        {ok, Form} -> parse_module_forms(Rest, [Form | Acc]);
        {error, {Loc, Mod, Desc}} -> {error, syntax_error(Loc, Mod, Desc)}
    end.

format_compile_errors(Errors) ->
    [[format_compile_error(File, Loc, Mod, Desc) || {Loc, Mod, Desc} <- Problems]
     || {File, Problems} <- Errors].

format_compile_error(File, Loc, Mod, Desc) ->
    Where = case Loc of
                {Line, Col} -> io_lib:format("~ts:~b:~b: ", [File, Line, Col]);
                Line when is_integer(Line) -> io_lib:format("~ts:~b: ", [File, Line]);
                _ -> io_lib:format("~ts: ", [File])
            end,
    [Where, Mod:format_error(Desc), $\n].

version_info() ->
    OtpRelease = unicode:characters_to_binary(erlang:system_info(otp_release)),
    ErtsVersion = unicode:characters_to_binary(erlang:system_info(version)),
    #{<<"erlang">> => #{<<"version-string">> => OtpRelease,
                        <<"erts">> => ErtsVersion}}.

%%% Internals

ensure_dot(Tokens, EndLoc) ->
    case lists:last(Tokens) of
        {dot, _} -> Tokens;
        _ -> Tokens ++ [{dot, erl_anno:new(EndLoc)}]
    end.

%% Split the token stream at dots and parse each form as an expression list.
parse_forms(Tokens) ->
    parse_forms(split_dots(Tokens), []).

parse_forms([], Acc) ->
    {ok, lists:reverse(Acc)};
parse_forms([FormTokens | Rest], Acc) ->
    case erl_parse:parse_exprs(FormTokens) of
        {ok, Exprs} -> parse_forms(Rest, [Exprs | Acc]);
        {error, {Loc, Mod, Desc}} -> {error, syntax_error(Loc, Mod, Desc)}
    end.

split_dots(Tokens) ->
    split_dots(Tokens, [], []).

split_dots([], [], Forms) ->
    lists:reverse(Forms);
split_dots([], Current, Forms) ->
    %% Unreachable in practice (ensure_dot guarantees a trailing dot), but
    %% harmless: treat a dangling fragment as its own form.
    lists:reverse([lists:reverse(Current) | Forms]);
split_dots([{dot, _} = Dot | Rest], Current, Forms) ->
    split_dots(Rest, [], [lists:reverse([Dot | Current]) | Forms]);
split_dots([Token | Rest], Current, Forms) ->
    split_dots(Rest, [Token | Current], Forms).

%% Runtime errors raise out of erl_eval and are rendered by the worker's
%% catch-all (dialtone_err) - by design, so users see real stacktraces.
eval_forms(ExprLists, Bindings0, State) ->
    {Value, Bindings} =
        lists:foldl(fun(Exprs, {_PrevValue, B}) ->
                            {value, V, B2} = erl_eval:exprs(Exprs, B),
                            {V, B2}
                    end, {ok, Bindings0}, ExprLists),
    {ok, #{value => io_lib:format("~tp", [Value])},
     State#{bindings := Bindings}}.

syntax_error(Loc, Mod, Desc) ->
    Where = case Loc of
                {Line, Col} -> io_lib:format("~b:~b: ", [Line, Col]);
                Line when is_integer(Line) -> io_lib:format("~b: ", [Line]);
                _ -> ""
            end,
    #{err => [Where, Mod:format_error(Desc), $\n],
      ex => <<"syntax-error">>}.
