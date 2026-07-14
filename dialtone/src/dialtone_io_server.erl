%% @private Per-session IO device (group leader of eval workers),
%% implementing the Erlang I/O protocol.
%%
%% Output (put_chars) is forwarded to the client as "out" responses tagged
%% with the currently running request - synchronously through the
%% connection's single-writer path, so the chunk is on the wire before the
%% io_reply releases the evaluating code (this is what makes output appear
%% before the eval's value/done, structurally). Output arriving while no
%% request is running (stragglers spawned by past evals) is dropped.
%%
%% Input (get_until/get_line/get_chars) is served from a type-ahead buffer;
%% when it runs dry the request is parked, the client is told "need-input",
%% and a later stdin op resumes the parked read. An empty stdin payload
%% means EOF, after which reads return eof (matching C-d at a terminal).
-module(dialtone_io_server).

-behaviour(gen_server).

-export([start_link/0, set_sink/3, reset/1, stdin/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-record(io, {sink :: undefined | {pid(), map()},
             %% reads parked waiting for input: {From, ReplyAs, Spec}
             pending = queue:new() :: queue:queue(),
             input = <<>> :: binary(),
             eof = false :: boolean(),
             binary = false :: boolean(),
             encoding = unicode :: unicode | latin1}).

start_link() ->
    gen_server:start_link(?MODULE, [], []).

%% @doc Attach the request whose lifetime we are inside: out/need-input
%% responses are tagged with its id/session and sent via Conn.
set_sink(Io, Conn, Req) ->
    gen_server:call(Io, {set_sink, Conn, Req}, infinity).

%% @doc Detach after the request finished (or its worker was killed).
%% Parked reads get `{error, terminated}'; type-ahead and EOF state persist.
reset(Io) ->
    gen_server:call(Io, reset, infinity).

%% @doc Feed input from a stdin op. An empty payload signals EOF.
stdin(Io, Data) ->
    gen_server:call(Io, {stdin, Data}, infinity).

init([]) ->
    {ok, #io{}}.

handle_call({set_sink, Conn, Req}, _From, State) ->
    {reply, ok, State#io{sink = {Conn, Req}}};
handle_call(reset, _From, #io{pending = Pending} = State) ->
    lists:foreach(fun({From, ReplyAs, _Spec}) ->
                          io_reply(From, ReplyAs, {error, terminated})
                  end, queue:to_list(Pending)),
    {reply, ok, State#io{sink = undefined, pending = queue:new()}};
handle_call({stdin, <<>>}, _From, State) ->
    {reply, ok, pump(State#io{eof = true})};
handle_call({stdin, Data}, _From, #io{input = Input} = State) ->
    {reply, ok, pump(State#io{input = <<Input/binary, Data/binary>>})}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({io_request, From, ReplyAs, Request}, State) ->
    {noreply, io_request(From, ReplyAs, Request, State)};
handle_info(_Info, State) ->
    {noreply, State}.

%%% Requests

io_request(From, ReplyAs, {put_chars, Encoding, Chars}, State) ->
    io_reply(From, ReplyAs, do_put_chars(Encoding, Chars, State)),
    State;
io_request(From, ReplyAs, {put_chars, Encoding, M, F, A}, State) ->
    Chars = try apply(M, F, A) catch _:_ -> {error, format} end,
    case Chars of
        {error, _} = Error -> io_reply(From, ReplyAs, Error);
        _ -> io_reply(From, ReplyAs, do_put_chars(Encoding, Chars, State))
    end,
    State;
%% Pre-R15 forms without encoding still occur in the wild.
io_request(From, ReplyAs, {put_chars, Chars}, State) ->
    io_request(From, ReplyAs, {put_chars, latin1, Chars}, State);
io_request(From, ReplyAs, {put_chars, M, F, A}, State) ->
    io_request(From, ReplyAs, {put_chars, latin1, M, F, A}, State);
io_request(From, ReplyAs, {get_until, Encoding, Prompt, M, F, A}, State) ->
    enqueue_read(From, ReplyAs, {until, Encoding, M, F, A, []}, Prompt, State);
io_request(From, ReplyAs, {get_line, Encoding, Prompt}, State) ->
    enqueue_read(From, ReplyAs, {line, Encoding}, Prompt, State);
io_request(From, ReplyAs, {get_chars, Encoding, Prompt, N}, State) ->
    enqueue_read(From, ReplyAs, {chars, Encoding, N}, Prompt, State);
io_request(From, ReplyAs, {get_line, Prompt}, State) ->
    io_request(From, ReplyAs, {get_line, latin1, Prompt}, State);
io_request(From, ReplyAs, {get_chars, Prompt, N}, State) ->
    io_request(From, ReplyAs, {get_chars, latin1, Prompt, N}, State);
io_request(From, ReplyAs, {get_until, Prompt, M, F, A}, State) ->
    io_request(From, ReplyAs, {get_until, latin1, Prompt, M, F, A}, State);
io_request(From, ReplyAs, {setopts, Opts}, State) ->
    {Reply, State2} = setopts(Opts, State),
    io_reply(From, ReplyAs, Reply),
    State2;
io_request(From, ReplyAs, getopts, State) ->
    io_reply(From, ReplyAs, [{binary, State#io.binary},
                             {encoding, State#io.encoding}]),
    State;
io_request(From, ReplyAs, {get_geometry, _}, State) ->
    io_reply(From, ReplyAs, {error, enotsup}),
    State;
io_request(From, ReplyAs, {requests, Requests}, State) ->
    %% The composite's reply is the last request's reply; put_chars replies
    %% are computed inline, so only output requests are legal here (which is
    %% how the io module uses it).
    Reply = lists:foldl(
              fun({put_chars, E, C}, _) -> do_put_chars(E, C, State);
                 ({put_chars, E, M, F, A}, _) ->
                      do_put_chars(E, try apply(M, F, A) catch _:_ -> <<>> end, State);
                 (_, Acc) -> Acc
              end, ok, Requests),
    io_reply(From, ReplyAs, Reply),
    State;
io_request(From, ReplyAs, _Unknown, State) ->
    io_reply(From, ReplyAs, {error, request}),
    State.

io_reply(From, ReplyAs, Reply) ->
    From ! {io_reply, ReplyAs, Reply},
    ok.

%%% Output

do_put_chars(Encoding, Chars, #io{sink = Sink}) ->
    case unicode:characters_to_binary(Chars, Encoding, utf8) of
        Bin when is_binary(Bin) ->
            emit_out(Bin, Sink);
        _ ->
            {error, {no_translation, Encoding, utf8}}
    end.

emit_out(_Bin, undefined) ->
    ok;
emit_out(Bin, {Conn, Req}) ->
    dialtone_msg:reply(Conn, Req, #{<<"out">> => Bin}).

%%% Input

enqueue_read(From, ReplyAs, Spec, Prompt, #io{pending = Pending} = State) ->
    emit_prompt(Prompt, State#io.sink),
    pump(State#io{pending = queue:in({From, ReplyAs, Spec}, Pending)}).

%% A prompt is client-side rendering, so it goes out as ordinary output.
emit_prompt(Prompt, Sink) ->
    Chars = case Prompt of
                '' -> <<>>;
                {format, Fmt, Args} ->
                    try io_lib:format(Fmt, Args) catch _:_ -> <<>> end;
                _ ->
                    try unicode:characters_to_binary(io_lib:format("~ts", [Prompt]))
                    catch _:_ -> <<>>
                    end
            end,
    case iolist_size(Chars) of
        0 -> ok;
        _ -> _ = emit_out(iolist_to_binary(Chars), Sink), ok
    end.

%% Try to satisfy parked reads from the buffer; if input runs dry (and no
%% EOF), ask the client for more.
pump(#io{pending = Pending} = State) ->
    case queue:out(Pending) of
        {empty, Pending} ->
            State;
        {{value, {From, ReplyAs, Spec}}, Rest} ->
            case serve(Spec, State) of
                {reply, Reply, State2} ->
                    io_reply(From, ReplyAs, Reply),
                    pump(State2#io{pending = Rest});
                {park, Spec2, State2} ->
                    need_input(State2#io.sink),
                    State2#io{pending = queue:in_r({From, ReplyAs, Spec2}, Rest)}
            end
    end.

need_input(undefined) ->
    ok;
need_input({Conn, Req}) ->
    dialtone_msg:reply(Conn, Req, #{<<"status">> => ['need-input']}).

%% serve/2 -> {reply, Reply, State'} | {park, Spec', State'}

serve({until, Encoding, M, F, A, Cont}, #io{input = Input, eof = Eof} = State) ->
    %% Tail = bytes of an incomplete trailing UTF-8 sequence (stdin can be
    %% chunked mid-character); they stay buffered until completed.
    {Chars, Tail} = input_chars(Input),
    Data = case {Chars, Eof} of
               {[], true} -> eof;
               _ -> Chars
           end,
    case {Data, Eof} of
        {[], false} ->
            {park, {until, Encoding, M, F, A, Cont}, State};
        _ ->
            %% The collector consumes the data we hand it: whatever the
            %% outcome, those chars leave the buffer (a done result may put
            %% leftovers back).
            Res = try apply(M, F, [Cont, Data | A])
                  catch _:_ -> collector_crashed
                  end,
            case Res of
                {done, Result, RestChars} ->
                    {reply, coerce(Result, Encoding, State),
                     State#io{input = <<(rest_to_binary(RestChars))/binary,
                                        Tail/binary>>}};
                collector_crashed ->
                    {reply, {error, err_func}, State#io{input = Tail}};
                _Cont2 when Eof ->
                    %% The collector wants more but there is none, ever.
                    {reply, eof, State#io{input = Tail}};
                {more, Cont2} ->
                    %% io_lib:fread-style collectors wrap their continuation.
                    {park, {until, Encoding, M, F, A, Cont2},
                     State#io{input = Tail}};
                Cont2 ->
                    {park, {until, Encoding, M, F, A, Cont2},
                     State#io{input = Tail}}
            end
    end;
serve({line, Encoding}, #io{input = Input, eof = Eof} = State) ->
    case binary:match(Input, <<"\n">>) of
        {Pos, 1} ->
            Len = Pos + 1,
            <<Line:Len/binary, Rest/binary>> = Input,
            {reply, coerce_data(Line, Encoding, State), State#io{input = Rest}};
        nomatch when Eof, Input =:= <<>> ->
            {reply, eof, State};
        nomatch when Eof ->
            {reply, coerce_data(Input, Encoding, State), State#io{input = <<>>}};
        nomatch ->
            {park, {line, Encoding}, State}
    end;
serve({chars, Encoding, N}, #io{input = Input, eof = Eof} = State) ->
    {Chars, Tail} = input_chars(Input),
    case {length(Chars) >= N, Eof} of
        {true, _} ->
            {Taken, Rest} = lists:split(N, Chars),
            {reply, coerce_data(Taken, Encoding, State),
             State#io{input = <<(unicode:characters_to_binary(Rest))/binary,
                                Tail/binary>>}};
        {false, true} when Chars =:= [] ->
            {reply, eof, State};
        {false, true} ->
            {reply, coerce_data(Chars, Encoding, State), State#io{input = Tail}};
        {false, false} ->
            {park, {chars, Encoding, N}, State}
    end.

%% Split buffered input into complete characters + incomplete UTF-8 tail.
input_chars(Bin) ->
    case unicode:characters_to_list(Bin, utf8) of
        Chars when is_list(Chars) -> {Chars, <<>>};
        {incomplete, Chars, Tail} -> {Chars, Tail};
        {error, Chars, _Garbage} -> {Chars, <<>>}
    end.

rest_to_binary(eof) -> <<>>;
rest_to_binary(Chars) -> unicode:characters_to_binary(Chars).

%% get_until results are the collector's business - pass through untouched.
coerce(Result, _Encoding, _State) ->
    Result.

%% get_line/get_chars results honor the device's binary/list mode.
coerce_data(Data, _Encoding, #io{binary = true}) ->
    unicode:characters_to_binary(Data);
coerce_data(Data, _Encoding, #io{binary = false}) ->
    unicode:characters_to_list(Data, utf8).

setopts(Opts, State) ->
    lists:foldl(
      fun(Opt, {Reply, S}) ->
              case Opt of
                  {binary, B} when is_boolean(B) -> {Reply, S#io{binary = B}};
                  binary -> {Reply, S#io{binary = true}};
                  list -> {Reply, S#io{binary = false}};
                  {list, B} when is_boolean(B) -> {Reply, S#io{binary = not B}};
                  {encoding, E} when E =:= unicode; E =:= utf8 ->
                      {Reply, S#io{encoding = unicode}};
                  {encoding, latin1} ->
                      {Reply, S#io{encoding = latin1}};
                  _ ->
                      {{error, enotsup}, S}
              end
      end, {ok, State}, Opts).
