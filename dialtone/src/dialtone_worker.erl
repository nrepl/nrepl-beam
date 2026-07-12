%% @private The killable evaluation process. Gets a snapshot of the backend
%% state, runs exactly one eval/load-file, and mails the outcome (including
%% the successor state) back to its session. Because the session never hands
%% out its state mutably, exit(Worker, kill) is always safe.
-module(dialtone_worker).

-export([run/5]).

-spec run(pid(), reference(),
          {eval, binary(), map()} | {load_file, binary(), map()},
          {module(), map()}, term()) -> ok.
run(Session, Ref, Task, {BMod, _}, BState) ->
    Result =
        try
            case Task of
                {eval, Code, Meta} -> BMod:eval(Code, Meta, BState);
                {load_file, Contents, Meta} -> BMod:load_file(Contents, Meta, BState)
            end
        catch
            Class:Reason:Stack ->
                {caught, dialtone_err:render(BMod, Class, Reason, Stack, BState)}
        end,
    Session ! {eval_result, Ref, Result},
    ok.
