%% @private Session registry: session id -> pid, backed by a protected named
%% ETS table so connections resolve sessions without calling into this
%% process. Sessions are monitored and swept from the table when they die.
-module(dialtone_sessions).

-behaviour(gen_server).

-export([start_link/0, new/2, lookup/1, list/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(TAB, ?MODULE).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc Create and register a session. InitialBState is undefined for a fresh
%% session, or a backend state inherited from a cloned source session.
-spec new({module(), map()}, term()) -> {ok, binary(), pid()} | {error, term()}.
new(Backend, InitialBState) ->
    gen_server:call(?MODULE, {new, Backend, InitialBState}).

-spec lookup(binary()) -> {ok, pid()} | error.
lookup(Id) ->
    case ets:lookup(?TAB, Id) of
        [{_, Pid}] -> {ok, Pid};
        [] -> error
    end.

-spec list() -> [binary()].
list() ->
    [Id || {Id, _Pid} <- ets:tab2list(?TAB)].

init([]) ->
    ?TAB = ets:new(?TAB, [named_table, protected, {read_concurrency, true}]),
    {ok, #{}}.

handle_call({new, Backend, InitialBState}, _From, Monitors) ->
    Id = dialtone_uuid:v4(),
    case dialtone_session_sup:start_session(Id, Backend, InitialBState) of
        {ok, Pid} ->
            MRef = monitor(process, Pid),
            true = ets:insert(?TAB, {Id, Pid}),
            {reply, {ok, Id, Pid}, Monitors#{MRef => Id}};
        {error, Reason} ->
            {reply, {error, Reason}, Monitors}
    end.

handle_cast(_Msg, Monitors) ->
    {noreply, Monitors}.

handle_info({'DOWN', MRef, process, _Pid, _Reason}, Monitors) ->
    case maps:take(MRef, Monitors) of
        {Id, Rest} ->
            true = ets:delete(?TAB, Id),
            {noreply, Rest};
        error ->
            {noreply, Monitors}
    end;
handle_info(_Info, Monitors) ->
    {noreply, Monitors}.
