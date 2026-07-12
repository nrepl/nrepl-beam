%% @private Response construction and delivery.
%%
%% Two invariants live here so no call site can get them wrong:
%% every response echoes the request's "id" and "session", and all sends go
%% through a synchronous call to the connection process - the single socket
%% writer - so responses hit the wire in a total order (an out chunk is
%% written before the io_reply that unblocks user code, hence always before
%% the eval's value/done).
%%
%% Sends to a dead connection are discarded: sessions outlive connections by
%% design, and results of an eval whose client went away have nowhere to go.
-module(dialtone_msg).

-export([reply/3, reply_done/3, reply_done/4, send/2, response/2]).

%% @doc Build a response map echoing id/session from the request.
-spec response(map(), map()) -> map().
response(Req, Extra) ->
    maps:merge(maps:with([<<"id">>, <<"session">>], Req), Extra).

%% @doc Send an intermediate (non-terminal) response for a request.
-spec reply(pid(), map(), map()) -> ok.
reply(Conn, Req, Extra) ->
    send(Conn, response(Req, Extra)).

%% @doc Send the terminal response for a request: status gets "done" appended.
-spec reply_done(pid(), map(), map()) -> ok.
reply_done(Conn, Req, Extra) ->
    reply_done(Conn, Req, [], Extra).

%% @doc Terminal response with extra statuses, e.g. [interrupted] -> done last.
-spec reply_done(pid(), map(), [atom() | binary()], map()) -> ok.
reply_done(Conn, Req, Statuses, Extra) when is_list(Statuses) ->
    send(Conn, response(Req, Extra#{<<"status">> => Statuses ++ [done]})).

%% @doc Deliver a response map through the connection's single-writer path.
-spec send(pid(), map()) -> ok.
send(Conn, Msg) ->
    try
        gen_server:call(Conn, {send, Msg}, infinity)
    catch
        %% Connection gone (client disconnected): discard, by design.
        exit:_ -> ok
    end.
