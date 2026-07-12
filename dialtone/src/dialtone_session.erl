%% @private One nREPL session: owns the persistent backend state (bindings,
%% env, ...), a queue of pending eval/load-file requests, and the currently
%% running worker.
%%
%% Concurrency model: eval and load-file are state transformers and run
%% strictly one at a time, in arrival order, each in a killable worker
%% process that gets a copy of the backend state and mails back the new one -
%% so interrupt (exit kill) can never corrupt session state. stdin and
%% interrupt are handled out-of-band (they must work while an eval runs).
%% completions/lookup are read-only and served immediately against the
%% current state: serialization exists to keep state consistent, and they
%% don't touch it - queueing them behind a blocked eval would hang editors.
-module(dialtone_session).

-behaviour(gen_server).

-export([start_link/3, start_ephemeral/2, request/3, get_bstate/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

%% Crude safety net against a multi-gigabyte value taking the editor down;
%% a proper client-negotiated print quota can replace it later.
-define(MAX_VALUE_BYTES, 8 * 1024 * 1024).

-record(session, {id :: binary(),
                  backend :: {module(), map()},
                  bstate :: term(),
                  io :: pid(),
                  ephemeral = false :: boolean(),
                  running :: undefined
                           | #{req := map(), reply_to := pid(),
                               worker := pid(), mref := reference(),
                               ref := reference()},
                  queue = queue:new() :: queue:queue({map(), pid()})}).

start_link(Id, Backend, InitialBState) ->
    gen_server:start_link(?MODULE, {Id, Backend, InitialBState, false}, []).

%% Ephemeral sessions serve a single session-less request and terminate.
%% They are unsupervised on purpose: nothing must restart them, and they are
%% not in the registry, so nothing can address them either.
start_ephemeral(Id, Backend) ->
    gen_server:start(?MODULE, {Id, Backend, undefined, true}, []).

-spec request(pid(), map(), pid()) -> ok.
request(Pid, Req, ReplyTo) ->
    gen_server:cast(Pid, {request, Req, ReplyTo}).

%% @doc The current backend state; used to seed a clone of this session.
-spec get_bstate(pid()) -> term().
get_bstate(Pid) ->
    gen_server:call(Pid, get_bstate, infinity).

init({Id, {BMod, BOpts} = Backend, InitialBState, Ephemeral}) ->
    BState = case InitialBState of
                 undefined ->
                     {ok, S} = BMod:init(BOpts),
                     S;
                 Inherited ->
                     Inherited
             end,
    {ok, Io} = dialtone_io_server:start_link(),
    {ok, #session{id = Id, backend = Backend, bstate = BState,
                  io = Io, ephemeral = Ephemeral}}.

handle_call(get_bstate, _From, State) ->
    {reply, State#session.bstate, State}.

handle_cast({request, #{<<"op">> := <<"close">>} = Req, ReplyTo}, State) ->
    interrupt_all(State),
    dialtone_msg:reply_done(ReplyTo, Req, #{}),
    {stop, normal, State#session{running = undefined, queue = queue:new()}};
handle_cast({request, Req, ReplyTo}, State) ->
    {noreply, handle_request(maps:get(<<"op">>, Req), Req, ReplyTo, State)}.

handle_info({eval_result, Ref, Result},
            #session{running = #{ref := Ref, req := Req, reply_to := ReplyTo,
                                 mref := MRef}} = State) ->
    %% Worker finished on its own; the DOWN that follows is uninteresting.
    demonitor(MRef, [flush]),
    ok = dialtone_io_server:reset(State#session.io),
    NewBState = deliver_result(Req, ReplyTo, Result, State),
    next(State#session{running = undefined, bstate = NewBState});
handle_info({'DOWN', MRef, process, _Pid, Reason},
            #session{running = #{mref := MRef, req := Req,
                                 reply_to := ReplyTo}} = State) ->
    %% Worker died without reporting a result: killed (interrupt) or took an
    %% exit we didn't catch (e.g. from a linked process). State unchanged.
    ok = dialtone_io_server:reset(State#session.io),
    case Reason of
        killed ->
            dialtone_msg:reply_done(ReplyTo, Req, [interrupted], #{});
        Other ->
            {BMod, _} = State#session.backend,
            ErrMap = dialtone_err:render(BMod, exit, Other, [], State#session.bstate),
            dialtone_msg:reply_done(ReplyTo, Req, ['eval-error'], ErrMap)
    end,
    next(State#session{running = undefined});
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    interrupt_all(State),
    %% The io server is linked, but a normal exit doesn't take it down.
    try gen_server:stop(State#session.io) catch _:_ -> ok end,
    ok.

%%% Request handling

handle_request(Op, Req, ReplyTo, State)
  when Op =:= <<"eval">>; Op =:= <<"load-file">> ->
    case validate(Op, Req) of
        ok ->
            enqueue_or_run({Req, ReplyTo}, State);
        {error, Err} ->
            dialtone_msg:reply_done(ReplyTo, Req, ['eval-error'],
                                    #{<<"err">> => Err, <<"ex">> => <<"bad-request">>}),
            State
    end;
handle_request(<<"stdin">>, Req, ReplyTo, State) ->
    %% Out-of-band: never queued (an eval blocked on input would deadlock).
    %% An empty payload signals EOF, anything else is buffered type-ahead.
    ok = dialtone_io_server:stdin(State#session.io,
                                  maps:get(<<"stdin">>, Req, <<>>)),
    dialtone_msg:reply_done(ReplyTo, Req, #{}),
    State;
handle_request(<<"interrupt">>, Req, ReplyTo, State) ->
    handle_interrupt(Req, ReplyTo, State);
handle_request(<<"completions">>, Req, ReplyTo, State) ->
    read_only(complete, [maps:get(<<"prefix">>, Req, <<>>), ro_meta(Req)],
              fun({ok, Candidates}) ->
                      #{<<"completions">> =>
                            [#{<<"candidate">> => C, <<"type">> => T}
                             || #{candidate := C, type := T} <- Candidates]}
              end, Req, ReplyTo, State);
handle_request(<<"lookup">>, Req, ReplyTo, State) ->
    read_only(lookup, [maps:get(<<"sym">>, Req, <<>>), ro_meta(Req)],
              fun({ok, Info}) -> #{<<"info">> => Info};
                 ({error, not_found}) -> #{}
              end, Req, ReplyTo, State).

validate(<<"eval">>, #{<<"code">> := Code}) when is_binary(Code) -> ok;
validate(<<"eval">>, _) -> {error, <<"eval op requires a code field">>};
validate(<<"load-file">>, #{<<"file">> := File}) when is_binary(File) -> ok;
validate(<<"load-file">>, _) -> {error, <<"load-file op requires a file field">>}.

ro_meta(Req) ->
    case maps:get(<<"ns">>, Req, undefined) of
        undefined -> #{};
        Ns -> #{ns => Ns}
    end.

%% Serve a read-only backend call in-process; a crashing backend must not
%% take the session (and its bindings) down with it.
read_only(F, Args, Render, Req, ReplyTo, #session{backend = {BMod, _}} = State) ->
    case erlang:function_exported(BMod, F, length(Args) + 1) of
        false ->
            dialtone_msg:reply_done(ReplyTo, Req, ['unknown-op'], #{});
        true ->
            try apply(BMod, F, Args ++ [State#session.bstate]) of
                Result ->
                    dialtone_msg:reply_done(ReplyTo, Req, Render(Result))
            catch
                Class:Reason:Stack ->
                    ErrMap = dialtone_err:render(BMod, Class, Reason, Stack,
                                                 State#session.bstate),
                    dialtone_msg:reply_done(ReplyTo, Req, ['server-error'], ErrMap)
            end
    end,
    State.

%%% Eval queue

enqueue_or_run(Job, #session{running = undefined} = State) ->
    run(Job, State);
enqueue_or_run(Job, #session{queue = Q} = State) ->
    State#session{queue = queue:in(Job, Q)}.

run({Req, ReplyTo}, #session{backend = Backend, bstate = BState,
                             io = Io} = State) ->
    Ref = make_ref(),
    Task = task(Req),
    ok = dialtone_io_server:set_sink(Io, ReplyTo, Req),
    {Worker, MRef} =
        spawn_monitor(dialtone_worker, run,
                      [self(), Ref, Task, Backend, BState, Io]),
    State#session{running = #{req => Req, reply_to => ReplyTo,
                              worker => Worker, mref => MRef, ref => Ref}}.

task(#{<<"op">> := <<"eval">>, <<"code">> := Code} = Req) ->
    {eval, Code, eval_meta(Req)};
task(#{<<"op">> := <<"load-file">>, <<"file">> := Contents} = Req) ->
    Meta = maps:filter(fun(_, V) -> V =/= undefined end,
                       #{path => maps:get(<<"file-path">>, Req, undefined),
                         name => maps:get(<<"file-name">>, Req, undefined)}),
    {load_file, Contents, Meta}.

eval_meta(Req) ->
    Fields = [{<<"ns">>, ns}, {<<"file">>, file}, {<<"line">>, line},
              {<<"column">>, column}],
    lists:foldl(fun({Key, Name}, Acc) ->
                        case maps:get(Key, Req, undefined) of
                            undefined -> Acc;
                            Value -> Acc#{Name => Value}
                        end
                end, #{}, Fields).

deliver_result(Req, ReplyTo, Result, #session{bstate = OldBState}) ->
    case Result of
        {ok, OkMap, NewBState} ->
            Value = truncate(unicode:characters_to_binary(maps:get(value, OkMap))),
            Extra = case OkMap of
                        #{ns := Ns} -> #{<<"ns">> => unicode:characters_to_binary(Ns)};
                        _ -> #{}
                    end,
            dialtone_msg:reply(ReplyTo, Req, Extra#{<<"value">> => Value}),
            dialtone_msg:reply_done(ReplyTo, Req, #{}),
            NewBState;
        {error, ErrMap, NewBState} ->
            dialtone_msg:reply_done(ReplyTo, Req, ['eval-error'],
                                    dialtone_err:to_wire(ErrMap)),
            NewBState;
        {caught, ErrMap} ->
            %% Raised out of the backend: worker already rendered it.
            %% Backend state rolls back to the pre-eval snapshot.
            dialtone_msg:reply_done(ReplyTo, Req, ['eval-error'],
                                    dialtone_err:to_wire(ErrMap)),
            OldBState
    end.

truncate(Bin) when byte_size(Bin) > ?MAX_VALUE_BYTES ->
    Head = binary:part(Bin, 0, ?MAX_VALUE_BYTES),
    <<Head/binary, "... (value truncated by dialtone)">>;
truncate(Bin) ->
    Bin.

next(#session{ephemeral = true, running = undefined} = State) ->
    %% One request served; this throwaway session is done.
    {stop, normal, State};
next(#session{queue = Q} = State) ->
    case queue:out(Q) of
        {empty, Q} ->
            {noreply, State};
        {{value, Job}, Rest} ->
            {noreply, run(Job, State#session{queue = Rest})}
    end.

%%% Interrupt (full semantics land in M3; running-eval kill works today)

handle_interrupt(Req, ReplyTo, #session{running = undefined, queue = Q} = State) ->
    case queue:is_empty(Q) of
        true ->
            dialtone_msg:reply_done(ReplyTo, Req, ['session-idle'], #{}),
            State;
        false ->
            interrupt_queued(Req, ReplyTo, State)
    end;
handle_interrupt(Req, ReplyTo,
                 #session{running = #{req := RunningReq, worker := Worker}} = State) ->
    RunningId = maps:get(<<"id">>, RunningReq, undefined),
    case maps:get(<<"interrupt-id">>, Req, RunningId) of
        RunningId ->
            exit(Worker, kill),
            %% The DOWN handler answers the interrupted eval; ack right away.
            dialtone_msg:reply_done(ReplyTo, Req, #{}),
            State;
        _Other ->
            case interrupt_queued_id(maps:get(<<"interrupt-id">>, Req), State) of
                {found, State2} ->
                    dialtone_msg:reply_done(ReplyTo, Req, #{}),
                    State2;
                not_found ->
                    dialtone_msg:reply_done(ReplyTo, Req, ['interrupt-id-mismatch'], #{}),
                    State
            end
    end.

interrupt_queued(Req, ReplyTo, State) ->
    case maps:get(<<"interrupt-id">>, Req, undefined) of
        undefined ->
            %% Nothing running; "interrupt whatever is current" is a no-op.
            dialtone_msg:reply_done(ReplyTo, Req, ['session-idle'], #{}),
            State;
        Id ->
            case interrupt_queued_id(Id, State) of
                {found, State2} ->
                    dialtone_msg:reply_done(ReplyTo, Req, #{}),
                    State2;
                not_found ->
                    dialtone_msg:reply_done(ReplyTo, Req, ['interrupt-id-mismatch'], #{}),
                    State
            end
    end.

%% Cancelling a queued request: answer it interrupted+done and drop it.
interrupt_queued_id(Id, #session{queue = Q} = State) ->
    Match = fun({#{<<"id">> := ReqId}, _}) -> ReqId =:= Id;
               ({_, _}) -> false
            end,
    case lists:partition(Match, queue:to_list(Q)) of
        {[], _} ->
            not_found;
        {[{QReq, QReplyTo} | _], Rest} ->
            dialtone_msg:reply_done(QReplyTo, QReq, [interrupted], #{}),
            {found, State#session{queue = queue:from_list(Rest)}}
    end.

%% Used by close/terminate: kill the worker and fail everything in flight.
interrupt_all(#session{running = Running, queue = Q}) ->
    case Running of
        #{worker := Worker, mref := MRef, req := Req, reply_to := ReplyTo} ->
            demonitor(MRef, [flush]),
            exit(Worker, kill),
            dialtone_msg:reply_done(ReplyTo, Req, [interrupted], #{});
        undefined ->
            ok
    end,
    lists:foreach(fun({QReq, QReplyTo}) ->
                          dialtone_msg:reply_done(QReplyTo, QReq, [interrupted], #{})
                  end, queue:to_list(Q)).
