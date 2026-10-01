%% A backend with only the required callbacks, for testing how dialtone
%% answers the optional ops it doesn't implement.
-module(dialtone_minimal_backend).

-behaviour(dialtone_backend).

-export([init/1, eval/3, version_info/0]).

init(_Opts) ->
    {ok, #{}}.

eval(Code, _Meta, State) ->
    {ok, #{value => Code}, State}.

version_info() ->
    #{}.
