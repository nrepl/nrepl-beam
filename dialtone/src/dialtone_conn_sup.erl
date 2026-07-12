%% @private Supervisor for per-connection processes. Connections are
%% temporary: a crashed connection must not be restarted (its socket is gone).
-module(dialtone_conn_sup).

-behaviour(supervisor).

-export([start_link/0, start_conn/2, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

start_conn(Sock, Opts) ->
    supervisor:start_child(?MODULE, [Sock, Opts]).

init([]) ->
    Flags = #{strategy => simple_one_for_one, intensity => 10, period => 60},
    Child = #{id => dialtone_conn,
              start => {dialtone_conn, start_link, []},
              restart => temporary,
              type => worker},
    {ok, {Flags, [Child]}}.
