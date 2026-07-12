%% @private One nREPL server endpoint: owns the listen socket, runs a linked
%% acceptor process, writes the .nrepl-port file and prints the startup
%% banner (whose exact shape editor tooling regex-matches, so treat it as API).
-module(dialtone_listener).

-behaviour(gen_server).

-export([start_link/1, port/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-record(state, {lsock :: gen_tcp:socket(),
                port :: inet:port_number(),
                port_file :: file:filename_all() | false,
                acceptor :: pid()}).

start_link(Opts) ->
    gen_server:start_link(?MODULE, Opts, []).

-spec port(pid()) -> inet:port_number().
port(Pid) ->
    gen_server:call(Pid, port).

init(Opts) ->
    process_flag(trap_exit, true),
    Bind = maps:get(bind, Opts, {127, 0, 0, 1}),
    TcpOpts = [binary, {packet, raw}, {active, false},
               {reuseaddr, true}, {ip, Bind}],
    case gen_tcp:listen(maps:get(port, Opts, 0), TcpOpts) of
        {ok, LSock} ->
            {ok, Port} = inet:port(LSock),
            PortFile = maps:get(port_file, Opts, ".nrepl-port"),
            ok = dialtone_port_file:write(PortFile, Port),
            Host = inet:ntoa(Bind),
            io:format("nREPL server started on port ~b on host ~s - nrepl://~s:~b~n",
                      [Port, Host, Host, Port]),
            ConnOpts = conn_opts(Opts),
            Acceptor = spawn_link(fun() -> accept_loop(LSock, ConnOpts) end),
            {ok, #state{lsock = LSock, port = Port,
                        port_file = PortFile, acceptor = Acceptor}};
        {error, Reason} ->
            {stop, {listen_failed, Reason}}
    end.

conn_opts(Opts) ->
    #{backend => maps:get(backend, Opts, {dialtone_backend_erlang, #{}}),
      max_frame => maps:get(max_frame, Opts, 16 * 1024 * 1024)}.

handle_call(port, _From, State) ->
    {reply, State#state.port, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({'EXIT', Pid, Reason}, #state{acceptor = Pid} = State) ->
    %% The acceptor only exits when the listen socket dies (or a conn child
    %% could not be started); nothing to salvage - restart the listener.
    {stop, {acceptor_died, Reason}, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{lsock = LSock, port_file = PortFile}) ->
    dialtone_port_file:delete(PortFile),
    _ = gen_tcp:close(LSock),
    ok.

accept_loop(LSock, ConnOpts) ->
    case gen_tcp:accept(LSock) of
        {ok, Sock} ->
            {ok, Pid} = dialtone_conn_sup:start_conn(Sock, ConnOpts),
            case gen_tcp:controlling_process(Sock, Pid) of
                ok -> dialtone_conn:activate(Pid);
                {error, _} -> gen_tcp:close(Sock)
            end,
            accept_loop(LSock, ConnOpts);
        {error, closed} ->
            ok;
        {error, Reason} ->
            exit({accept_failed, Reason})
    end.
