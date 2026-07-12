%% A minimal nREPL client used by the integration suites (and the seed of a
%% future standalone client). Purely functional: every operation returns the
%% updated client value, which carries the socket, decode buffer, and an id
%% counter.
-module(dialtone_client).

-export([connect/1, close/1, send/2, request/2, request/3,
         recv_msg/2, recv_until_done/3]).

-type client() :: #{sock := gen_tcp:socket(),
                    buffer := binary(),
                    next_id := pos_integer()}.

-export_type([client/0]).

-spec connect(inet:port_number()) -> client().
connect(Port) ->
    {ok, Sock} = gen_tcp:connect("127.0.0.1", Port,
                                 [binary, {packet, raw}, {active, false}]),
    #{sock => Sock, buffer => <<>>, next_id => 1}.

-spec close(client()) -> ok.
close(#{sock := Sock}) ->
    gen_tcp:close(Sock).

%% @doc Fire-and-forget send; the caller picks the id (or sends none).
-spec send(client(), map()) -> client().
send(#{sock := Sock} = Client, Msg) ->
    ok = gen_tcp:send(Sock, dialtone_bencode:encode(Msg)),
    Client.

%% @doc Send a request with a fresh id and collect every response for it
%% until one carries status "done". Responses for other ids fail the test -
%% single-request flows shouldn't see any.
-spec request(client(), map()) -> {[map()], client()}.
request(Client, Msg) ->
    request(Client, Msg, 5000).

-spec request(client(), map(), timeout()) -> {[map()], client()}.
request(#{next_id := N} = Client, Msg, Timeout) ->
    Id = integer_to_binary(N),
    Client2 = send(Client#{next_id := N + 1}, Msg#{<<"id">> => Id}),
    recv_until_done(Client2, Id, Timeout).

-spec recv_until_done(client(), binary(), timeout()) -> {[map()], client()}.
recv_until_done(Client, Id, Timeout) ->
    recv_until_done(Client, Id, Timeout, []).

recv_until_done(Client, Id, Timeout, Acc) ->
    {Msg, Client2} = recv_msg(Client, Timeout),
    case Msg of
        #{<<"id">> := Id} ->
            Statuses = maps:get(<<"status">>, Msg, []),
            case lists:member(<<"done">>, Statuses) of
                true -> {lists:reverse([Msg | Acc]), Client2};
                false -> recv_until_done(Client2, Id, Timeout, [Msg | Acc])
            end;
        _ ->
            error({unexpected_response, Msg, {expecting_id, Id}})
    end.

%% @doc Receive exactly one message (any id).
-spec recv_msg(client(), timeout()) -> {map(), client()}.
recv_msg(#{sock := Sock, buffer := Buffer} = Client, Timeout) ->
    case dialtone_bencode:decode(Buffer) of
        {ok, Msg, Rest} ->
            {Msg, Client#{buffer := Rest}};
        {more, Buffer} ->
            {ok, Data} = gen_tcp:recv(Sock, 0, Timeout),
            recv_msg(Client#{buffer := <<Buffer/binary, Data/binary>>}, Timeout);
        {error, Reason} ->
            error({bad_bencode_from_server, Reason})
    end.
