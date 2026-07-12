%% @private Supervisor for session processes. Sessions are temporary by
%% design: restarting one would silently resurrect it with empty bindings
%% under the same session id, which is worse than letting the client see the
%% session die and clone a fresh one.
-module(dialtone_session_sup).

-behaviour(supervisor).

-export([start_link/0, start_session/3, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

start_session(Id, Backend, InitialBState) ->
    supervisor:start_child(?MODULE, [Id, Backend, InitialBState]).

init([]) ->
    Flags = #{strategy => simple_one_for_one, intensity => 10, period => 60},
    Child = #{id => dialtone_session,
              start => {dialtone_session, start_link, []},
              restart => temporary,
              type => worker},
    {ok, {Flags, [Child]}}.
