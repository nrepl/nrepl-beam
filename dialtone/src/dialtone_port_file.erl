%% @private The .nrepl-port file: just the decimal port, newline-terminated,
%% which is the shape editor clients (neat, CIDER, ...) expect to discover.
-module(dialtone_port_file).

-export([write/2, delete/1]).

-spec write(file:filename_all() | false, inet:port_number()) -> ok | {error, term()}.
write(false, _Port) ->
    ok;
write(Path, Port) ->
    file:write_file(Path, [integer_to_binary(Port), $\n]).

-spec delete(file:filename_all() | false) -> ok.
delete(false) ->
    ok;
delete(Path) ->
    _ = file:delete(Path),
    ok.
