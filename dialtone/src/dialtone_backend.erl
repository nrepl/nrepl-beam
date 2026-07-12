%% @doc The language backend behaviour: everything dialtone doesn't know
%% about the language being served lives behind these callbacks. The core
%% handles the wire protocol, sessions, IO streaming and interrupts; a
%% backend turns code into values.
%%
%% `eval/3' and `load_file/3' run inside a worker process that may be killed
%% at any moment (interrupt), so they must treat their state argument as an
%% immutable snapshot and return the successor state - never mutate shared
%% resources they'd need to clean up. Output streaming needs no callback:
%% evaluated code writes through its group leader, which dialtone owns.
%%
%% Optional callbacks gate op advertisement: a backend without `complete/3'
%% simply yields a server that doesn't announce (or answer) `completions'.
-module(dialtone_backend).

-type state() :: term().
-type eval_meta() :: #{ns => binary(), file => binary(),
                       line => pos_integer(), column => pos_integer()}.
-type ok_result() :: #{value := unicode:chardata(), ns => unicode:chardata()}.
-type err_result() :: #{err := unicode:chardata(), ex := unicode:chardata()}.
-type candidate() :: #{candidate := binary(), type := binary()}.
%% Wire-shaped info map for lookup: keys like <<"name">>, <<"doc">>,
%% <<"arglists-str">>, <<"file">>, <<"line">>; values binary or integer.
-type info() :: #{binary() => binary() | integer()}.

-export_type([state/0, eval_meta/0, ok_result/0, err_result/0,
              candidate/0, info/0]).

-callback init(Opts :: map()) -> {ok, state()}.

-callback eval(Code :: binary(), eval_meta(), state()) ->
    {ok, ok_result(), state()} | {error, err_result(), state()}.

-callback load_file(Contents :: binary(),
                    #{path => binary(), name => binary()}, state()) ->
    {ok, ok_result(), state()} | {error, err_result(), state()}.

-callback complete(Prefix :: binary(), #{ns => binary()}, state()) ->
    {ok, [candidate()]}.

-callback lookup(Sym :: binary(), #{ns => binary()}, state()) ->
    {ok, info()} | {error, not_found}.

%% Renders exceptions raised (not returned) by eval/load_file. When absent,
%% dialtone_err falls back to erl_error-based formatting.
-callback format_exception(error | exit | throw, Reason :: term(),
                           erlang:stacktrace(), state()) -> err_result().

%% Feeds the "versions" map in describe responses,
%% e.g. #{<<"erlang">> => #{<<"version-string">> => <<"27.2">>}}.
-callback version_info() -> #{binary() => map()}.

-optional_callbacks([load_file/3, complete/3, lookup/3, format_exception/4]).
