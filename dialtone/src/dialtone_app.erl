%% @private
-module(dialtone_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    {ok, Sup} = dialtone_sup:start_link(),
    Listen = application:get_env(dialtone, listen, []),
    lists:foreach(
      fun(Opts) ->
              case dialtone:start_server(Opts) of
                  {ok, _Pid} -> ok;
                  {error, Reason} -> exit({listen_failed, Opts, Reason})
              end
      end, Listen),
    {ok, Sup}.

stop(_State) ->
    ok.
