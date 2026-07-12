%% @private Rendering: pure functions from response fields to iodata, so the
%% exact bytes are unit-testable. The one piece of state is whether the
%% cursor sits at the start of a line - streamed output may end mid-line,
%% and a value/error marker must never be glued onto it.
%%
%% Style (chosen by the user): streamed output prints as-is; values get a
%% green "=> " prefix; errors a red "!! " summary with the trace indented.
-module(chaser_render).

-export([new/1, out/2, value/2, err/3, note/2, banner/2, doc/2, prompt/2]).

-record(r, {color :: boolean(),
            bol = true :: boolean()}).  %% at beginning of line?

-define(GREEN, "\e[32m").
-define(RED, "\e[31m").
-define(DIM, "\e[2m").
-define(BOLD, "\e[1m").
-define(RESET, "\e[0m").

-spec new(#{color := boolean()}) -> #r{}.
new(#{color := Color}) ->
    #r{color = Color}.

%% @doc Streamed output, printed exactly as the program wrote it.
out(Chunk, R) ->
    {Chunk, track(Chunk, R)}.

%% @doc An eval result: `=> Value', with continuation lines indented to
%% align under the value.
value(Value, R) ->
    Indented = indent_continuations(Value, "   "),
    emit_line([style(?GREEN, "=> ", R), Indented], R).

%% @doc An error: `!! Summary' plus the indented multi-line account.
err(Summary, Detail, R) ->
    Content =
        case string:trim(Detail, trailing, "\n") of
            "" -> style(?RED, ["!! ", Summary], R);
            <<>> -> style(?RED, ["!! ", Summary], R);
            Trimmed -> [style(?RED, ["!! ", Summary], R), $\n,
                        indent_all(Trimmed, "   ")]
        end,
    emit_line(Content, R).

%% @doc A client-side notice, e.g. the interrupt hint. Dimmed.
note(Text, R) ->
    emit_line([style(?DIM, Text, R)], R).

banner(#{url := Url, server := Server}, R) ->
    emit_line([style(?BOLD, ["chaser ", version()], R),
               style(?DIM, [" | ", Url, " | ", Server], R)], R).

%% @doc Render a lookup "info" map for :doc.
doc(Info, R) ->
    Name = maps:get(<<"name">>, Info, <<>>),
    Ns = maps:get(<<"ns">>, Info, <<>>),
    Arglists = maps:get(<<"arglists-str">>, Info, <<>>),
    Doc = maps:get(<<"doc">>, Info, <<"no documentation">>),
    Where = case maps:get(<<"file">>, Info, undefined) of
                undefined -> [];
                File ->
                    Line = maps:get(<<"line">>, Info, 1),
                    [$\n, style(?DIM, [File, ":", integer_to_binary(Line)], R)]
            end,
    Header = [Ns, ":", Name, case Arglists of <<>> -> []; _ -> [" ", Arglists] end],
    emit_line([style(?BOLD, Header, R), $\n,
               string:trim(Doc, trailing, "\n") | Where], R).

prompt(Text, R) ->
    {Text, R#r{bol = false}}.

%%% Internals

%% Every discrete message starts on a fresh line, even when streamed output
%% left the cursor mid-line.
emit_line(IoData, #r{bol = true} = R) ->
    {[IoData, $\n], R#r{bol = true}};
emit_line(IoData, R) ->
    {[$\n, IoData, $\n], R#r{bol = true}}.

style(_Ansi, Text, #r{color = false}) -> Text;
style(Ansi, Text, #r{color = true}) -> [Ansi, Text, ?RESET].

track(Chunk, R) ->
    Bin = unicode:characters_to_binary(Chunk),
    case Bin of
        <<>> -> R;
        _ -> R#r{bol = binary:last(Bin) =:= $\n}
    end.

indent_continuations(Text, Pad) ->
    string:replace(unicode:characters_to_binary(Text), <<"\n">>,
                   <<"\n", (unicode:characters_to_binary(Pad))/binary>>, all).

indent_all(Text, Pad) ->
    [Pad, indent_continuations(Text, Pad)].

version() ->
    case application:get_key(chaser, vsn) of
        {ok, Vsn} -> Vsn;
        undefined -> "dev"
    end.
