%% @private Root supervisor.
%%
%% rest_for_one with the session registry first: the registry's ETS table is
%% the authoritative session map, so if it ever dies everything downstream of
%% it (sessions, connections, listeners) must be restarted for consistency.
%% A listener crash restarts only the listeners.
-module(dialtone_sup).

-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    Flags = #{strategy => rest_for_one, intensity => 3, period => 60},
    Children =
        [#{id => dialtone_sessions,
           start => {dialtone_sessions, start_link, []},
           type => worker},
         #{id => dialtone_session_sup,
           start => {dialtone_session_sup, start_link, []},
           type => supervisor},
         #{id => dialtone_conn_sup,
           start => {dialtone_conn_sup, start_link, []},
           type => supervisor},
         #{id => dialtone_server_sup,
           start => {dialtone_server_sup, start_link, []},
           type => supervisor}],
    {ok, {Flags, Children}}.
