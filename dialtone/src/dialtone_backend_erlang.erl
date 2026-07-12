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

-export([init/1, eval/3, load_file/3, complete/3, lookup/3, version_info/0]).

init(_Opts) ->
    %% beams: module -> object code for modules loaded via load-file; kept
    %% so lookup can read their debug_info chunk (they exist only in memory).
    {ok, #{bindings => erl_eval:new_bindings(), beams => #{}}}.

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
                    Beams = maps:get(beams, State, #{}),
                    {ok, #{value => io_lib:format("{module, ~tp}", [Mod])},
                     State#{beams => Beams#{Mod => Bin}}};
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

%%% Completion
%%
%% Deliberately built from first principles (code server, exports, session
%% bindings) rather than edlin_expand, whose match format is undocumented.
%% Candidates complete the whole prefix the client sent: "lists:ma" yields
%% "lists:map", not "map".

complete(Prefix, _Meta, #{bindings := Bindings}) ->
    Candidates =
        case binary:split(Prefix, <<":">>) of
            [ModBin, FunPrefix] ->
                function_candidates(ModBin, FunPrefix);
            [Bare] ->
                lists:append([module_candidates(Bare),
                              bif_candidates(Bare),
                              variable_candidates(Bare, Bindings)])
        end,
    {ok, lists:sort(fun(#{candidate := A}, #{candidate := B}) -> A =< B end,
                    Candidates)}.

function_candidates(ModBin, FunPrefix) ->
    try binary_to_existing_atom(ModBin, utf8) of
        Mod ->
            case code:ensure_loaded(Mod) of
                {module, Mod} ->
                    Names = lists:usort([atom_to_binary(F, utf8)
                                         || {F, _A} <- Mod:module_info(exports)]),
                    [#{candidate => <<ModBin/binary, ":", Name/binary>>,
                       type => <<"function">>}
                     || Name <- Names, is_prefix(FunPrefix, Name)];
                _ ->
                    []
            end
    catch
        error:badarg -> []
    end.

module_candidates(Prefix) ->
    [#{candidate => Name, type => <<"module">>}
     || {NameStr, _Path, _Loaded} <- code:all_available(),
        Name <- [unicode:characters_to_binary(NameStr)],
        is_prefix(Prefix, Name)].

%% Auto-imported BIFs are callable without a module prefix.
bif_candidates(Prefix) ->
    Names = lists:usort([atom_to_binary(F, utf8)
                         || {F, A} <- erlang:module_info(exports),
                            erl_internal:bif(F, A)]),
    [#{candidate => Name, type => <<"function">>}
     || Name <- Names, is_prefix(Prefix, Name)].

variable_candidates(Prefix, Bindings) ->
    [#{candidate => Name, type => <<"var">>}
     || {Var, _Value} <- erl_eval:bindings(Bindings),
        Name <- [atom_to_binary(Var, utf8)],
        is_prefix(Prefix, Name)].

is_prefix(<<>>, _) -> true;
is_prefix(Prefix, Bin) ->
    case binary:longest_common_prefix([Prefix, Bin]) of
        N when N =:= byte_size(Prefix) -> true;
        _ -> false
    end.

%%% Lookup
%%
%% Symbols come in as "module", "module:function" or "module:function/arity"
%% (a bare function name is tried as an erlang-module BIF). Docs come from
%% EEP-48 doc chunks; for modules without them (say, something the client
%% just load-file'd) we fall back to exports for existence and the
%% debug_info chunk for a definition line.

lookup(Sym, _Meta, State) ->
    case parse_sym(Sym) of
        {function, Mod, Fun, Arity} -> lookup_function(Mod, Fun, Arity, State);
        {module, Mod} -> lookup_module(Mod);
        error -> {error, not_found}
    end.

parse_sym(Sym) ->
    try
        case binary:split(Sym, <<":">>) of
            [ModBin, FunAndArity] ->
                Mod = binary_to_existing_atom(ModBin, utf8),
                case binary:split(FunAndArity, <<"/">>) of
                    [FunBin, ArityBin] ->
                        {function, Mod, binary_to_existing_atom(FunBin, utf8),
                         binary_to_integer(ArityBin)};
                    [FunBin] ->
                        {function, Mod, binary_to_existing_atom(FunBin, utf8), any}
                end;
            [Bare] ->
                Atom = binary_to_existing_atom(Bare, utf8),
                case code:which(Atom) of
                    non_existing ->
                        case erlang:function_exported(erlang, Atom, 0)
                            orelse lists:keymember(Atom, 1, erlang:module_info(exports)) of
                            true -> {function, erlang, Atom, any};
                            false -> error
                        end;
                    _ ->
                        {module, Atom}
                end
        end
    catch
        error:badarg -> error
    end.

lookup_function(Mod, Fun, Arity, State) ->
    DocChunk = case code:get_doc(Mod) of
                   {ok, Docs} -> Docs;
                   {error, _} -> undefined
               end,
    case doc_entry(DocChunk, Fun, Arity) of
        {ok, {{function, Fun, A}, Anno, Signature, _Doc, _Meta}} ->
            Info = #{<<"name">> => atom_to_binary(Fun, utf8),
                     <<"ns">> => atom_to_binary(Mod, utf8),
                     <<"arglists-str">> => arglists(Signature),
                     <<"line">> => erl_anno:line(Anno)},
            {ok, add_doc(Mod, Fun, A, DocChunk, add_file(Mod, Info))};
        error ->
            %% No doc entry; the function may still exist (no doc chunk,
            %% @doc false, ...).
            Exports = try Mod:module_info(exports) catch error:undef -> [] end,
            case [Ar || {F, Ar} <- Exports, F =:= Fun,
                        Arity =:= any orelse Ar =:= Arity] of
                [] ->
                    {error, not_found};
                [A | _] ->
                    Info = #{<<"name">> => atom_to_binary(Fun, utf8),
                             <<"ns">> => atom_to_binary(Mod, utf8)},
                    Info2 = case debug_info_line(Mod, Fun, A, State) of
                                {ok, Line} -> Info#{<<"line">> => Line};
                                error -> Info
                            end,
                    {ok, add_file(Mod, Info2)}
            end
    end.

lookup_module(Mod) ->
    Info0 = #{<<"name">> => atom_to_binary(Mod, utf8),
              <<"ns">> => atom_to_binary(Mod, utf8),
              <<"line">> => 1},
    Info = add_file(Mod, Info0),
    case code:get_doc(Mod) of
        {ok, {docs_v1, Anno, _, _, _ModDoc, _, _} = Docs} ->
            WithLine = Info#{<<"line">> => erl_anno:line(Anno)},
            case render_docs(fun() -> shell_docs:render(Mod, Docs, #{ansi => false}) end) of
                {ok, Text} -> {ok, WithLine#{<<"doc">> => Text}};
                error -> {ok, WithLine}
            end;
        {error, _} ->
            case code:which(Mod) of
                non_existing -> {error, not_found};
                _ -> {ok, Info}
            end
    end.

doc_entry(undefined, _Fun, _Arity) ->
    error;
doc_entry({docs_v1, _, _, _, _, _, Entries}, Fun, Arity) ->
    Matches = [E || {{function, F, A}, _, _, _, _} = E <- Entries,
                    F =:= Fun, Arity =:= any orelse A =:= Arity],
    case lists:sort(fun({{function, _, A1}, _, _, _, _},
                        {{function, _, A2}, _, _, _, _}) -> A1 =< A2
                    end, Matches) of
        [Entry | _] -> {ok, Entry};
        [] -> error
    end.

arglists([]) -> <<>>;
arglists(Signature) ->
    unicode:characters_to_binary(lists:join(" ", Signature)).

add_doc(_Mod, _Fun, _A, undefined, Info) ->
    Info;
add_doc(Mod, Fun, A, Docs, Info) ->
    case render_docs(fun() -> shell_docs:render(Mod, Fun, A, Docs, #{ansi => false}) end) of
        {ok, Text} -> Info#{<<"doc">> => Text};
        error -> Info
    end.

render_docs(Render) ->
    try unicode:characters_to_binary(Render()) of
        Bin when is_binary(Bin) -> {ok, Bin};
        _ -> error
    catch
        _:_ -> error
    end.

add_file(Mod, Info) ->
    try proplists:get_value(source, Mod:module_info(compile)) of
        Source when is_list(Source) ->
            Info#{<<"file">> => unicode:characters_to_binary(Source)};
        _ ->
            Info
    catch
        error:undef -> Info
    end.

%% Definition line via the debug_info chunk. Modules loaded via load-file
%% exist only in memory, so their object code comes from the state stash;
%% everything else is read from its beam file.
debug_info_line(Mod, Fun, Arity, State) ->
    MaybeBeam = case maps:get(beams, State, #{}) of
                    #{Mod := Bin} -> Bin;
                    _ -> code:which(Mod)
                end,
    case is_list(MaybeBeam) orelse is_binary(MaybeBeam) of
        false ->
            error;
        true ->
            case beam_lib:chunks(MaybeBeam, [debug_info]) of
                {ok, {Mod, [{debug_info, {debug_info_v1, Backend, Data}}]}} ->
                    case Backend:debug_info(erlang_v1, Mod, Data, []) of
                        {ok, Forms} ->
                            case [Anno || {function, Anno, F, A, _} <- Forms,
                                          F =:= Fun, A =:= Arity] of
                                [Anno | _] -> {ok, erl_anno:line(Anno)};
                                [] -> error
                            end;
                        _ ->
                            error
                    end;
                _ ->
                    error
            end
    end.

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
                Line when is_integer(Line) -> io_lib:format("~b: ", [Line])
            end,
    #{err => [Where, Mod:format_error(Desc), $\n],
      ex => <<"syntax-error">>}.
