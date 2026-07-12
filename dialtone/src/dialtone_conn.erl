%% @private One nREPL connection: owns the socket, decodes the bencode
%% stream incrementally, routes requests, and is the single writer of
%% responses (all sends arrive as synchronous calls, giving a per-connection
%% total order on the wire and backpressure against runaway output).
%%
%% Framing policies: a malformed bencode stream cannot be resynchronized
%% (bencode is self-delimiting with no message boundary markers), so on a
%% decode error we log and close the connection - sessions survive. The same
%% applies to a frame growing past max_frame. A message that decodes but is
%% not a dict, or lacks "op", is recoverable: answer unknown-op and carry on.
-module(dialtone_conn).

-behaviour(gen_server).

-export([start_link/2, activate/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-include_lib("kernel/include/logger.hrl").

-record(conn, {sock :: gen_tcp:socket(),
               buffer = <<>> :: binary(),
               backend :: {module(), map()},
               max_frame :: pos_integer()}).

start_link(Sock, Opts) ->
    gen_server:start_link(?MODULE, {Sock, Opts}, []).

%% Called by the acceptor once controlling_process/2 has been transferred.
activate(Pid) ->
    gen_server:cast(Pid, activate).

init({Sock, Opts}) ->
    {ok, #conn{sock = Sock,
               backend = maps:get(backend, Opts),
               max_frame = maps:get(max_frame, Opts)}}.

handle_call({send, Msg}, _From, #conn{sock = Sock} = State) ->
    case gen_tcp:send(Sock, dialtone_bencode:encode(Msg)) of
        ok ->
            {reply, ok, State};
        {error, Reason} ->
            %% Peer gone; terminate quietly, sessions live on.
            {stop, {shutdown, {send_failed, Reason}}, ok, State}
    end.

handle_cast(activate, #conn{sock = Sock} = State) ->
    ok = inet:setopts(Sock, [{active, once}]),
    {noreply, State}.

handle_info({tcp, Sock, Data}, #conn{sock = Sock, buffer = Buffer} = State) ->
    case drain(<<Buffer/binary, Data/binary>>, State) of
        {ok, Rest} ->
            ok = inet:setopts(Sock, [{active, once}]),
            {noreply, State#conn{buffer = Rest}};
        {stop, Reason} ->
            {stop, {shutdown, Reason}, State}
    end;
handle_info({tcp_closed, Sock}, #conn{sock = Sock} = State) ->
    {stop, {shutdown, tcp_closed}, State};
handle_info({tcp_error, Sock, Reason}, #conn{sock = Sock} = State) ->
    {stop, {shutdown, {tcp_error, Reason}}, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #conn{sock = Sock}) ->
    _ = gen_tcp:close(Sock),
    ok.

%%% Decode loop

drain(Buffer, State) ->
    case dialtone_bencode:decode(Buffer) of
        {ok, Msg, Rest} when is_map(Msg) ->
            handle_message(Msg, State),
            drain(Rest, State);
        {ok, Other, Rest} ->
            %% Well-formed bencode, but not a request. Recoverable.
            ?LOG_WARNING("dialtone: non-dict message ~0tP", [Other, 6]),
            send_self(#{<<"status">> => ['unknown-op', done]}, State),
            drain(Rest, State);
        {more, Buffer} when byte_size(Buffer) > State#conn.max_frame ->
            ?LOG_ERROR("dialtone: frame exceeds max_frame (~b bytes buffered), "
                       "closing connection", [byte_size(Buffer)]),
            {stop, frame_too_large};
        {more, Buffer} ->
            {ok, Buffer};
        {error, Reason} ->
            ?LOG_ERROR("dialtone: malformed bencode (~0tp), closing connection: ~0tP",
                       [Reason, binary:part(Buffer, 0, min(64, byte_size(Buffer))), 6]),
            {stop, {malformed, Reason}}
    end.

%%% Request routing

handle_message(Req, State) ->
    case maps:get(<<"op">>, Req, undefined) of
        undefined -> send_self(dialtone_msg:response(Req, #{<<"status">> => ['unknown-op', done]}), State);
        <<"describe">> -> describe(Req, State);
        <<"clone">> -> clone(Req, State);
        <<"ls-sessions">> -> ls_sessions(Req, State);
        <<"close">> -> close(Req, State);
        Op when Op =:= <<"eval">>; Op =:= <<"load-file">>; Op =:= <<"stdin">>;
                Op =:= <<"interrupt">>; Op =:= <<"completions">>; Op =:= <<"lookup">> ->
            route_to_session(Req, State);
        _UnknownOp ->
            send_self(dialtone_msg:response(Req, #{<<"status">> => ['unknown-op', done]}), State)
    end.

describe(Req, #conn{backend = {BMod, _}} = State) ->
    Versions0 = #{<<"dialtone">> => #{<<"version-string">> => dialtone:version()},
                  <<"nrepl">> => #{<<"major">> => 1, <<"minor">> => 0,
                                   <<"incremental">> => 0,
                                   <<"version-string">> => <<"1.0.0">>}},
    Versions = maps:merge(Versions0, BMod:version_info()),
    Resp = dialtone_msg:response(Req, #{<<"ops">> => ops_map(BMod),
                                        <<"versions">> => Versions,
                                        <<"status">> => [done]}),
    send_self(Resp, State).

%% Core ops are always available; tooling ops only when the backend exports
%% the matching callback. Emitted as the dict form (op name -> {}) that
%% existing clients key on; the spec's list form is noted in the docs.
ops_map(BMod) ->
    Core = [<<"clone">>, <<"close">>, <<"describe">>, <<"eval">>,
            <<"interrupt">>, <<"ls-sessions">>, <<"stdin">>],
    Optional = [{<<"load-file">>, load_file, 3},
                {<<"completions">>, complete, 3},
                {<<"lookup">>, lookup, 3}],
    Exported = [Op || {Op, F, A} <- Optional,
                      erlang:function_exported(BMod, F, A)],
    maps:from_keys(Core ++ Exported, #{}).

clone(Req, #conn{backend = Backend} = State) ->
    InitialBState =
        case maps:get(<<"session">>, Req, undefined) of
            undefined -> undefined;
            SourceId ->
                case dialtone_sessions:lookup(SourceId) of
                    {ok, SourcePid} -> dialtone_session:get_bstate(SourcePid);
                    error -> undefined
                end
        end,
    case dialtone_sessions:new(Backend, InitialBState) of
        {ok, Id, _Pid} ->
            send_self(dialtone_msg:response(
                        Req, #{<<"new-session">> => Id, <<"status">> => [done]}),
                      State);
        {error, Reason} ->
            server_error(Req, Reason, State)
    end.

ls_sessions(Req, State) ->
    send_self(dialtone_msg:response(
                Req, #{<<"sessions">> => dialtone_sessions:list(),
                       <<"status">> => [done]}),
              State).

%% close is idempotent: closing an unknown (or absent) session still answers
%% done. A live session tears down its own in-flight work and sends the done
%% itself - routing close through the async request path like any other
%% session op keeps message flow one-directional (conn never blocks on a
%% session that might be blocking on the conn).
close(Req, State) ->
    case maps:get(<<"session">>, Req, undefined) of
        undefined ->
            send_self(dialtone_msg:response(Req, #{<<"status">> => [done]}), State);
        Id ->
            case dialtone_sessions:lookup(Id) of
                {ok, Pid} ->
                    dialtone_session:request(Pid, Req, self());
                error ->
                    send_self(dialtone_msg:response(Req, #{<<"status">> => [done]}),
                              State)
            end
    end.

route_to_session(#{<<"session">> := Id} = Req, State) ->
    case dialtone_sessions:lookup(Id) of
        {ok, Pid} ->
            dialtone_session:request(Pid, Req, self());
        error ->
            unknown_session(Req, State)
    end;
route_to_session(Req, State) ->
    %% No session: run in a throwaway (ephemeral) session, except interrupt,
    %% which has nothing durable to target.
    case maps:get(<<"op">>, Req, undefined) of
        <<"interrupt">> ->
            send_self(dialtone_msg:response(
                        Req, #{<<"status">> => ['session-ephemeral', done]}),
                      State);
        _ ->
            ephemeral(Req, State)
    end.

unknown_session(#{<<"op">> := <<"interrupt">>} = Req, State) ->
    %% Either never existed or was an ephemeral one - not interruptible.
    send_self(dialtone_msg:response(
                Req, #{<<"status">> => ['session-ephemeral', done]}),
              State);
unknown_session(Req, State) ->
    send_self(dialtone_msg:response(
                Req, #{<<"err">> => <<"unknown session">>,
                       <<"status">> => ['unknown-session', done]}),
              State).

ephemeral(Req, #conn{backend = Backend} = State) ->
    Id = dialtone_uuid:v4(),
    case dialtone_session:start_ephemeral(Id, Backend) of
        {ok, Pid} ->
            dialtone_session:request(Pid, Req#{<<"session">> => Id}, self());
        {error, Reason} ->
            server_error(Req, Reason, State)
    end.

server_error(Req, Reason, State) ->
    Err = unicode:characters_to_binary(io_lib:format("~0tP", [Reason, 8])),
    send_self(dialtone_msg:response(
                Req, #{<<"err">> => Err, <<"status">> => ['server-error', done]}),
              State).

%% Direct socket write for responses originating in this process (routing
%% errors, describe, ...): calling dialtone_msg:send/2 here would deadlock.
send_self(Msg, #conn{sock = Sock}) ->
    _ = gen_tcp:send(Sock, dialtone_bencode:encode(Msg)),
    ok.
