%% @private Routes writes to standard_error from evaluated code to the client.
%%
%% Erlang has a single standard_error device per node, so there's no
%% per-process way to capture it. This process takes over the registered
%% name and looks at the group leader of every process that writes to it:
%% eval workers (and anything they spawn) have their session's IO server as
%% group leader, so their output is relayed to that IO server, which sends
%% it to the client as "err". Everything else, including output from
%% session processes while no request is running, goes to the original
%% device untouched. The original gets its name back when this process
%% stops.
%%
%% Relayed writes are answered through this process, which watches the IO
%% server: if it goes away before answering, the writer gets an error
%% instead of waiting forever.
%%
%% Taking over a node-wide device is a big hammer for an embedded server, so
%% it's opt-in: see dialtone:capture_stderr/0 and the capture_stderr app env.
-module(dialtone_stderr).

-behaviour(gen_server).

-export([start_link/0, child_spec/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-record(state, {original :: pid() | undefined,
                %% relayed writes waiting for their IO server:
                %% Tag => {Writer, ReplyAs, Request message, Monitor}
                pending = #{} :: #{reference() => {pid(), term(), tuple(), reference()}}}).

start_link() ->
    gen_server:start_link(?MODULE, [], []).

child_spec() ->
    #{id => ?MODULE,
      start => {?MODULE, start_link, []},
      type => worker,
      shutdown => 5000}.

init([]) ->
    process_flag(trap_exit, true),
    Original = original_device(),
    _ = case whereis(standard_error) of
            undefined -> ok;
            _ -> unregister(standard_error)
        end,
    true = register(standard_error, self()),
    _ = case Original of
            undefined -> ok;
            _ -> monitor(process, Original)
        end,
    {ok, #state{original = Original}}.

%% The device to pass everything else to. A restart finds itself (or a
%% previous instance) under the name, so the first one seen is remembered,
%% as long as it's still alive.
original_device() ->
    Key = {?MODULE, original},
    case persistent_term:get(Key, undefined) of
        Pid when is_pid(Pid) ->
            case is_process_alive(Pid) of
                true -> Pid;
                false -> remember(Key, whereis(standard_error))
            end;
        undefined ->
            remember(Key, whereis(standard_error))
    end.

remember(Key, Pid) ->
    persistent_term:put(Key, Pid),
    Pid.

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({io_request, From, ReplyAs, Request} = Msg, State) when is_pid(From) ->
    case put_chars(Request) andalso session_io(From) of
        {ok, Io} ->
            Tag = make_ref(),
            MRef = monitor(process, Io),
            Io ! {stderr_request, self(), Tag, Request},
            Pending = State#state.pending,
            {noreply, State#state{pending = Pending#{Tag => {From, ReplyAs, Msg, MRef}}}};
        _ ->
            forward(Msg, State),
            {noreply, State}
    end;
handle_info({io_reply, Tag, Reply}, #state{pending = Pending} = State) ->
    case maps:take(Tag, Pending) of
        {{From, ReplyAs, _Msg, MRef}, Rest} ->
            demonitor(MRef, [flush]),
            From ! {io_reply, ReplyAs, Reply},
            {noreply, State#state{pending = Rest}};
        error ->
            {noreply, State}
    end;
handle_info({stderr_unclaimed, Tag}, #state{pending = Pending} = State) ->
    case maps:take(Tag, Pending) of
        {{_From, _ReplyAs, Msg, MRef}, Rest} ->
            demonitor(MRef, [flush]),
            forward(Msg, State),
            {noreply, State#state{pending = Rest}};
        error ->
            {noreply, State}
    end;
handle_info({'DOWN', _MRef, process, Pid, _Reason}, #state{original = Pid} = State) ->
    {noreply, State#state{original = undefined}};
handle_info({'DOWN', MRef, process, _Pid, _Reason}, #state{pending = Pending} = State) ->
    Gone = maps:filter(fun(_Tag, {_, _, _, M}) -> M =:= MRef end, Pending),
    maps:foreach(fun(_Tag, {From, ReplyAs, _Msg, _}) ->
                         From ! {io_reply, ReplyAs, {error, terminated}}
                 end, Gone),
    {noreply, State#state{pending = maps:without(maps:keys(Gone), Pending)}};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{original = Original, pending = Pending} = State) ->
    _ = case whereis(standard_error) of
            Self when Self =:= self() -> unregister(standard_error);
            _ -> ok
        end,
    _ = case Original of
            undefined -> ok;
            _ -> try register(standard_error, Original) catch error:badarg -> ok end
        end,
    %% Whatever is still waiting goes to the original device, so writers
    %% in the rest of the node don't see the device vanish under them.
    maps:foreach(fun(_Tag, {_, _, Msg, _}) -> forward(Msg, State) end, Pending),
    drain(State),
    ok.

drain(State) ->
    receive
        {io_request, From, _, _} = Msg when is_pid(From) ->
            forward(Msg, State),
            drain(State)
    after 0 ->
            ok
    end.

forward(Msg, #state{original = Original}) when is_pid(Original) ->
    Original ! Msg,
    ok;
forward({io_request, From, ReplyAs, _}, _State) ->
    From ! {io_reply, ReplyAs, {error, terminated}},
    ok.

%% Only output is relayed; anything else (getopts, geometry, ...) is a
%% question about the real device.
put_chars({put_chars, _, _}) -> true;
put_chars({put_chars, _, _, _, _}) -> true;
put_chars({put_chars, _}) -> true;
put_chars({put_chars, _, _, _}) -> true;
put_chars({requests, Requests}) when is_list(Requests) -> lists:all(fun put_chars/1, Requests);
put_chars(_) -> false.

session_io(From) when node(From) =/= node() ->
    none;
session_io(From) ->
    case erlang:process_info(From, group_leader) of
        {group_leader, Io} ->
            case dialtone_io_server:is_io_server(Io) of
                true -> {ok, Io};
                false -> none
            end;
        undefined ->
            none
    end.
