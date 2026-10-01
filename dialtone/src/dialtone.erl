%% @doc Public API for the dialtone nREPL server.
-module(dialtone).

-export([start_server/1, stop_server/1, port/1, version/0, capture_stderr/0]).

-type server_opts() :: #{port => inet:port_number(),
                         bind => inet:ip_address(),
                         backend => {module(), map()},
                         port_file => file:filename_all() | false,
                         max_frame => pos_integer()}.

-export_type([server_opts/0]).

%% @doc Start an nREPL server. With `port => 0' (the default) the OS picks a
%% free port; read it back with {@link port/1}. The server runs under
%% dialtone's supervision tree, so the `dialtone' application must be started.
-spec start_server(server_opts()) -> {ok, pid()} | {error, term()}.
start_server(Opts) when is_map(Opts) ->
    dialtone_server_sup:start_server(Opts).

-spec stop_server(pid()) -> ok | {error, term()}.
stop_server(Pid) ->
    dialtone_server_sup:stop_server(Pid).

%% @doc The TCP port a server (as returned by start_server/1) listens on.
-spec port(pid()) -> inet:port_number().
port(Pid) ->
    dialtone_listener:port(Pid).

%% @doc Send what evaluated code writes to standard_error to the client, as
%% "err", instead of the node's console. standard_error is a single device
%% for the whole node, so this takes over its registered name (writes from
%% everything else still reach the console). That's why it's off by
%% default; the standalone servers turn it on, and so does setting the
%% `capture_stderr' app env. Calling it again is harmless.
-spec capture_stderr() -> ok | {error, term()}.
capture_stderr() ->
    try supervisor:start_child(dialtone_sup, dialtone_stderr:child_spec()) of
        Result -> started(Result)
    catch
        exit:{noproc, _} -> {error, not_started}
    end.

started(Result) ->
    case Result of
        {ok, _} -> ok;
        {error, {already_started, _}} -> ok;
        {error, already_present} ->
            case supervisor:restart_child(dialtone_sup, dialtone_stderr) of
                {ok, _} -> ok;
                {error, running} -> ok;
                Error -> Error
            end;
        Error -> Error
    end.

-spec version() -> binary().
version() ->
    {ok, Vsn} = application:get_key(dialtone, vsn),
    unicode:characters_to_binary(Vsn).
