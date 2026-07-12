%% @private v4 UUID strings for session ids.
-module(dialtone_uuid).

-export([v4/0]).

-spec v4() -> binary().
v4() ->
    <<A:32, B:16, C:16, D:16, E:48>> = crypto:strong_rand_bytes(16),
    C1 = (C band 16#0fff) bor 16#4000,
    D1 = (D band 16#3fff) bor 16#8000,
    iolist_to_binary(
      io_lib:format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b",
                    [A, B, C1, D1, E])).
