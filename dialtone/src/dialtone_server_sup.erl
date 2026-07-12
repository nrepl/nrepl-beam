%% @private Supervisor for dialtone_listener instances; supports several
%% servers per node (e.g. different backends on different ports).
-module(dialtone_server_sup).

-behaviour(supervisor).

-export([start_link/0, start_server/1, stop_server/1, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

start_server(Opts) ->
    supervisor:start_child(?MODULE, [Opts]).

stop_server(Pid) ->
    supervisor:terminate_child(?MODULE, Pid).

init([]) ->
    Flags = #{strategy => simple_one_for_one, intensity => 5, period => 60},
    Child = #{id => dialtone_listener,
              start => {dialtone_listener, start_link, []},
              restart => transient,
              type => worker},
    {ok, {Flags, [Child]}}.
