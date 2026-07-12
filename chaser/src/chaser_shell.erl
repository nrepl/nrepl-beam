%% @private The REPL loop, in two flavors sharing one engine: the custom
%% shell that shell:start_interactive/1 spawns (edlin line editing, TAB
%% completion, history), and a plain loop for pipes/dumb terminals.
%%
%% Reading is delegated to a pump process that owns every tty read, so the
%% loop can wait on eval responses and user input at the same time - that is
%% what makes "press Enter to interrupt a running eval" and the
%% need-input/stdin round-trip possible. The pump has at most one
%% outstanding read; each read is explicitly requested with a prompt.
-module(chaser_shell).

-export([start/1, run/1]).

-define(HINT_AFTER, 1000).

-record(sh, {conn :: pid(),
             session :: binary(),
             lang :: erlang | elixir | none,
             render :: term(),
             pump :: pid(),
             prompt :: unicode:chardata(),
             %% piped/dumb mode prints no prompts
             interactive = true :: boolean(),
             %% set when the pump is parked on a read we haven't consumed
             pump_armed = false :: boolean()}).

%% Entry for shell:start_interactive({chaser_shell, start, [Opts]}):
%% must return the pid of the shell process.
start(Opts) ->
    spawn(fun() -> init(Opts) end).

%% Entry for the non-tty (pipe/dumb) mode: run in the calling process.
run(Opts) ->
    init(Opts).

init(#{conn := Conn, session := Session, lang := Lang,
       color := Color, host := Host, port := Port} = Opts) ->
    case maps:get(interactive, Opts, true) of
        true ->
            ok = io:setopts([{expand_fun,
                              chaser_complete:expand_fun(Conn, Session)}]);
        false ->
            ok
    end,
    R0 = chaser_render:new(#{color => Color}),
    R1 = case maps:get(banner, Opts, undefined) of
             undefined -> R0;
             Banner -> print(chaser_render:banner(Banner, R0))
         end,
    Pump = spawn_link(fun pump/0),
    State = #sh{conn = Conn, session = Session, lang = Lang, render = R1,
                pump = Pump,
                interactive = maps:get(interactive, Opts, true),
                prompt = [unicode:characters_to_binary(Host), ":",
                          integer_to_binary(Port), "> "]},
    read_loop(State, []).

%%% The pump: owns all reads; at most one outstanding.

pump() ->
    receive
        {read, Prompt, ReplyTo} ->
            ReplyTo ! {line, io:get_line(Prompt)},
            pump()
    end.

ask(Prompt, #sh{pump = Pump} = State) ->
    Pump ! {read, Prompt, self()},
    State#sh{pump_armed = true}.

%%% Read/accumulate loop

read_loop(State0, Acc) ->
    Prompt = case {State0#sh.interactive, Acc} of
                 {false, _} -> "";
                 {true, []} -> State0#sh.prompt;
                 {true, _} -> continuation_prompt(State0)
             end,
    State = case State0#sh.pump_armed of
                true ->
                    %% A leftover read (armed during an eval that finished
                    %% quietly) will deliver the next line: just show a
                    %% prompt so the user knows we're listening.
                    print_prompt(Prompt, State0);
                false ->
                    ask(Prompt, State0)
            end,
    receive
        {line, eof} ->
            quit(State);
        {line, {error, _}} ->
            quit(State);
        {line, Line} ->
            State2 = State#sh{pump_armed = false},
            handle_line(unicode:characters_to_list(Line), State2, Acc)
    end.

handle_line(Line, State, []) ->
    case string:trim(Line) of
        "" ->
            read_loop(State, []);
        ":" ++ _ = Command ->
            read_loop(command(Command, State), []);
        _ ->
            maybe_submit(Line, State, [])
    end;
handle_line(Line, State, Acc) ->
    maybe_submit(Line, State, Acc).

maybe_submit(Line, State, Acc) ->
    Input = Acc ++ Line,
    case chaser_input:complete(State#sh.lang, Input) of
        true -> read_loop(eval(Input, State), []);
        false -> read_loop(State, Input)
    end.

continuation_prompt(#sh{prompt = Prompt}) ->
    Width = string:length(unicode:characters_to_binary(Prompt)),
    [lists:duplicate(max(0, Width - 4), $\s), "..> "].

%%% Evaluation

eval(Input, #sh{conn = Conn, session = Session} = State) ->
    Req = #{<<"op">> => <<"eval">>,
            <<"session">> => Session,
            <<"code">> => unicode:characters_to_binary(Input)},
    case chaser_conn:request_stream(Conn, Req, self()) of
        {ok, Id} ->
            await(Id, State, _HintShown = false);
        {error, closed} ->
            closed(State)
    end.

await(Id, State, HintShown) ->
    Timeout = case HintShown of
                  true -> infinity;
                  false -> ?HINT_AFTER
              end,
    receive
        {chaser_msg, Id, Msg} ->
            await(Id, render_msg(Msg, State), HintShown);
        {chaser_done, Id, Statuses} ->
            case lists:member(<<"connection-closed">>, Statuses) of
                true -> closed(State);
                false -> State
            end;
        {line, eof} when HintShown ->
            %% Ctrl-D during a running eval: treat as stdin EOF.
            State2 = send_stdin(<<>>, State#sh{pump_armed = false}),
            await(Id, State2, HintShown);
        {line, Line} when HintShown ->
            State2 = eval_input(Line, State#sh{pump_armed = false}),
            await(Id, State2, HintShown)
    after Timeout ->
            %% Still running: offer the escape hatch and start listening.
            State2 = print(chaser_render:note(
                             "(running - press Enter to interrupt, "
                             "or type input if the program is reading)",
                             State#sh.render), State),
            await(Id, ask("", State2), true)
    end.

%% A line typed while an eval runs: bare Enter interrupts, anything else is
%% forwarded as stdin (programs that read get their input; if nothing reads
%% it, the server buffers it as type-ahead).
eval_input("\n", State) ->
    interrupt(State);
eval_input(Line, State) ->
    ask("", send_stdin(unicode:characters_to_binary(Line), State)).

send_stdin(Data, #sh{conn = Conn, session = Session} = State) ->
    _ = chaser_conn:request(Conn, #{<<"op">> => <<"stdin">>,
                                    <<"session">> => Session,
                                    <<"stdin">> => Data}, 5000),
    State.

interrupt(#sh{conn = Conn, session = Session} = State) ->
    _ = chaser_conn:request(Conn, #{<<"op">> => <<"interrupt">>,
                                    <<"session">> => Session}, 5000),
    State.

render_msg(Msg, #sh{render = R0} = State) ->
    R1 = case Msg of
             #{<<"out">> := Out} -> print(chaser_render:out(Out, R0));
             _ -> R0
         end,
    R2 = case Msg of
             #{<<"value">> := Value} -> print(chaser_render:value(Value, R1));
             _ -> R1
         end,
    R3 = case Msg of
             #{<<"err">> := Err} ->
                 Summary = maps:get(<<"ex">>, Msg, <<"error">>),
                 print(chaser_render:err(Summary, Err, R2));
             _ ->
                 R2
         end,
    R4 = case lists:member(<<"interrupted">>,
                           maps:get(<<"status">>, Msg, [])) of
             true -> print(chaser_render:err(<<"interrupted">>, <<>>, R3));
             false -> R3
         end,
    State#sh{render = R4}.

%%% Colon commands

command(":quit" ++ _, State) ->
    quit(State);
command(":help" ++ _, State) ->
    print(chaser_render:note(
            ":doc SYMBOL   show documentation (server lookup op)\n"
            ":help         this text\n"
            ":quit         leave (Ctrl-D works too)\n"
            "TAB           complete (server completions op)\n"
            "Enter         during a long eval: interrupt it",
            State#sh.render), State);
command(":doc" ++ Rest, #sh{conn = Conn, session = Session} = State) ->
    case string:trim(Rest) of
        "" ->
            print(chaser_render:note("usage: :doc SYMBOL", State#sh.render),
                  State);
        Sym ->
            Req = #{<<"op">> => <<"lookup">>,
                    <<"session">> => Session,
                    <<"sym">> => unicode:characters_to_binary(Sym)},
            case chaser_conn:request(Conn, Req, 5000) of
                {ok, Msgs} ->
                    case [I || #{<<"info">> := I} <- Msgs] of
                        [Info | _] when map_size(Info) > 0 ->
                            print(chaser_render:doc(Info, State#sh.render),
                                  State);
                        _ ->
                            print(chaser_render:note("nothing found",
                                                     State#sh.render), State)
                    end;
                {error, _} ->
                    print(chaser_render:note("lookup failed",
                                             State#sh.render), State)
            end
    end;
command(Unknown, State) ->
    print(chaser_render:note(["unknown command ", Unknown,
                              " - try :help"], State#sh.render), State).

%%% Plumbing

%% print/1,2 take {IoData, Renderer} straight from chaser_render.
print({IoData, R}) ->
    io:put_chars(IoData),
    R.

print({IoData, R}, State) ->
    io:put_chars(IoData),
    State#sh{render = R}.

print_prompt(Prompt, State) ->
    {Text, R} = chaser_render:prompt(Prompt, State#sh.render),
    io:put_chars(Text),
    State#sh{render = R}.

-spec closed(#sh{}) -> no_return().
closed(State) ->
    _ = print(chaser_render:err(<<"connection closed">>, <<>>,
                                State#sh.render), State),
    halt(1).

-spec quit(#sh{}) -> no_return().
quit(#sh{conn = Conn}) ->
    try chaser_conn:close(Conn) catch _:_ -> ok end,
    halt(0).
