%% @private The nREPL connection: a gen_server owning the socket, so the
%% shell loop and the TAB-completion fun (which runs in the tty group
%% process) can share it safely.
%%
%% Two request styles: request/3 collects every response until "done" and
%% returns them (describe, clone, completions, lookup, interrupt, stdin);
%% request_stream/3 tags a receiver pid that gets {chaser_msg, Id, Msg} per
%% response and {chaser_done, Id, Statuses} at the end (eval - output must
%% render as it arrives).
-module(chaser_conn).

-behaviour(gen_server).

-export([connect/2, close/1, request/2, request/3, request_stream/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-record(conn, {sock :: gen_tcp:socket(),
               buffer = <<>> :: binary(),
               next_id = 1 :: pos_integer(),
               %% Id => {collect, From, [Msg]} | {stream, pid()}
               pending = #{} :: map()}).

-spec connect(inet:hostname() | inet:ip_address(), inet:port_number()) ->
          {ok, pid()} | {error, term()}.
connect(Host, Port) ->
    gen_server:start_link(?MODULE, {Host, Port}, []).

-spec close(pid()) -> ok.
close(Conn) ->
    gen_server:stop(Conn, normal, 1000).

%% @doc Send a request, collect all its responses until done.
-spec request(pid(), map()) -> {ok, [map()]} | {error, term()}.
request(Conn, Msg) ->
    request(Conn, Msg, 15000).

-spec request(pid(), map(), timeout()) -> {ok, [map()]} | {error, term()}.
request(Conn, Msg, Timeout) ->
    try
        gen_server:call(Conn, {request, Msg}, Timeout)
    catch
        exit:{timeout, _} -> {error, timeout};
        exit:_ -> {error, closed}
    end.

%% @doc Send a request whose responses stream to Receiver as they arrive.
-spec request_stream(pid(), map(), pid()) -> {ok, binary()} | {error, term()}.
request_stream(Conn, Msg, Receiver) ->
    try
        gen_server:call(Conn, {request_stream, Msg, Receiver}, 5000)
    catch
        exit:_ -> {error, closed}
    end.

init({Host, Port}) ->
    HostArg = case Host of
                  H when is_binary(H) -> binary_to_list(H);
                  H -> H
              end,
    case gen_tcp:connect(HostArg, Port,
                         [binary, {packet, raw}, {active, once}], 5000) of
        {ok, Sock} -> {ok, #conn{sock = Sock}};
        {error, Reason} -> {stop, {connect_failed, Reason}}
    end.

handle_call({request, Msg}, From, State) ->
    {Id, State2} = send_msg(Msg, State),
    {noreply, State2#conn{pending = maps:put(Id, {collect, From, []},
                                             State2#conn.pending)}};
handle_call({request_stream, Msg, Receiver}, _From, State) ->
    {Id, State2} = send_msg(Msg, State),
    {reply, {ok, Id},
     State2#conn{pending = maps:put(Id, {stream, Receiver},
                                    State2#conn.pending)}}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({tcp, Sock, Data}, #conn{sock = Sock, buffer = Buffer} = State) ->
    State2 = drain(<<Buffer/binary, Data/binary>>, State),
    ok = inet:setopts(Sock, [{active, once}]),
    {noreply, State2};
handle_info({tcp_closed, Sock}, #conn{sock = Sock} = State) ->
    notify_closed(State),
    {stop, {shutdown, closed}, State};
handle_info({tcp_error, Sock, Reason}, #conn{sock = Sock} = State) ->
    notify_closed(State),
    {stop, {shutdown, {tcp_error, Reason}}, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #conn{sock = Sock}) ->
    _ = gen_tcp:close(Sock),
    ok.

send_msg(Msg, #conn{sock = Sock, next_id = N} = State) ->
    Id = integer_to_binary(N),
    ok = gen_tcp:send(Sock, dialtone_bencode:encode(Msg#{<<"id">> => Id})),
    {Id, State#conn{next_id = N + 1}}.

drain(Buffer, State) ->
    case dialtone_bencode:decode(Buffer) of
        {ok, Msg, Rest} when is_map(Msg) ->
            drain(Rest, route(Msg, State#conn{buffer = Rest}));
        {ok, _Other, Rest} ->
            drain(Rest, State#conn{buffer = Rest});
        {more, Buffer2} ->
            State#conn{buffer = Buffer2};
        {error, _Reason} ->
            %% Desynced stream; nothing to salvage.
            notify_closed(State),
            exit({shutdown, malformed_stream})
    end.

route(Msg, #conn{pending = Pending} = State) ->
    Id = maps:get(<<"id">>, Msg, undefined),
    Statuses = maps:get(<<"status">>, Msg, []),
    Done = lists:member(<<"done">>, Statuses),
    case maps:get(Id, Pending, undefined) of
        undefined ->
            State;
        {collect, From, Acc} when Done ->
            gen_server:reply(From, {ok, lists:reverse([Msg | Acc])}),
            State#conn{pending = maps:remove(Id, Pending)};
        {collect, From, Acc} ->
            State#conn{pending = maps:put(Id, {collect, From, [Msg | Acc]},
                                          Pending)};
        {stream, Receiver} when Done ->
            Receiver ! {chaser_msg, Id, Msg},
            Receiver ! {chaser_done, Id, Statuses},
            State#conn{pending = maps:remove(Id, Pending)};
        {stream, Receiver} ->
            Receiver ! {chaser_msg, Id, Msg},
            State
    end.

notify_closed(#conn{pending = Pending}) ->
    maps:foreach(
      fun(Id, {stream, Receiver}) ->
              Receiver ! {chaser_done, Id, [<<"done">>, <<"connection-closed">>]};
         (_Id, {collect, From, _Acc}) ->
              gen_server:reply(From, {error, closed})
      end, Pending).
