-module(chaser_input_tests).

-include_lib("eunit/include/eunit.hrl").

erlang_complete_test_() ->
    Complete = ["1 + 2.",
                "X = 4.",
                "\"string with . dot\".",
                "1 %. dot in a comment\n+ 2.",
                "fun(A) -> A end.",
                "",           %% blank input never blocks the prompt
                "   \n"],
    Incomplete = ["1 + 2",
                  "X = fun(A) ->",
                  "io:format(\"a.b\")",
                  "[1, 2,",
                  "\"unterminated."],
    [?_assert(chaser_input:complete(erlang, I)) || I <- Complete] ++
        [?_assertNot(chaser_input:complete(erlang, I)) || I <- Incomplete].

elixir_complete_test_() ->
    Complete = ["1 + 2",
                "x = 4",
                "fn x -> x end",
                "case x do\n  :a -> 1\nend",
                "def f, do: :ok",
                "defmodule M do\n  def f, do: :ok\nend",
                "\"string with do inside\"",
                "# do a comment",
                "Enum.map([1], & &1)"],
    Incomplete = ["x =",
                  "defmodule M do",
                  "case x do",
                  "fn x ->",
                  "[1, 2,",
                  "\"unterminated",
                  "x |>",
                  "1 +",
                  "foo and"],
    [?_assert(chaser_input:complete(elixir, I)) || I <- Complete] ++
        [?_assertNot(chaser_input:complete(elixir, I)) || I <- Incomplete].

elixir_word_boundaries_test_() ->
    %% `done`, `fnord`, `x_and` must not read as do/fn/and keywords
    [?_assert(chaser_input:complete(elixir, "done = 1")),
     ?_assert(chaser_input:complete(elixir, "fnord")),
     ?_assert(chaser_input:complete(elixir, "x_and"))].

none_always_complete_test_() ->
    [?_assert(chaser_input:complete(none, I))
     || I <- ["anything", "(unbalanced", "x ="]].
