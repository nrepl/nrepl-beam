defmodule Repartee.BackendTest do
  use ExUnit.Case, async: true

  alias Repartee.Backend

  defp init_state do
    {:ok, state} = Backend.init(%{})
    state
  end

  defp eval!(code, state) do
    {:ok, %{value: value}, state} = Backend.eval(code, %{}, state)
    {value, state}
  end

  test "evaluates expressions and threads the binding" do
    {value, state} = eval!("x = 41", init_state())
    assert value == "41"
    {value, _} = eval!("x + 1", state)
    assert value == "42"
  end

  test "aliases persist across evals" do
    {_, state} = eval!("alias String, as: S", init_state())
    {value, _} = eval!(~s|S.upcase("neat")|, state)
    assert value == ~s("NEAT")
  end

  test "imports persist across evals" do
    {_, state} = eval!("import Integer, only: [is_even: 1]", init_state())
    {value, _} = eval!("is_even(4)", state)
    assert value == "true"
  end

  test "defmodule defines a callable module" do
    {_, state} = eval!("defmodule ReparteeBackendTest.M do def f, do: :hi end", init_state())
    {value, _} = eval!("ReparteeBackendTest.M.f()", state)
    assert value == ":hi"
  end

  test "syntax errors come back as structured errors, not raises" do
    assert {:error, %{ex: "syntax-error", err: err}, _state} =
             Backend.eval("1 +", %{}, init_state())

    assert err =~ "nrepl:1"
  end

  test "eval meta controls file/line attribution of syntax errors" do
    assert {:error, %{err: err}, _} =
             Backend.eval("1 +", %{file: "lib/foo.ex", line: 41}, init_state())

    assert err =~ "lib/foo.ex:41"
  end

  test "format_exception renders Elixir exceptions" do
    stack =
      try do
        raise ArgumentError, "boom"
      rescue
        _ -> __STACKTRACE__
      end

    %{err: err, ex: ex} =
      Backend.format_exception(:error, %ArgumentError{message: "boom"}, stack, init_state())

    assert ex == "ArgumentError"
    assert err =~ "boom"
  end

  test "load_file evaluates with file semantics" do
    {:ok, %{value: value}, _} =
      Backend.load_file("a = 2\na * 21", %{path: "/tmp/x.exs"}, init_state())

    assert value == "42"
  end

  test "version_info reports elixir and erlang" do
    assert %{"elixir" => %{"version-string" => v}} = Backend.version_info()
    assert v == System.version()
  end
end

defmodule Repartee.CompleterTest do
  use ExUnit.Case, async: true

  alias Repartee.Completer

  defp env do
    Code.env_for_eval(file: "nrepl")
  end

  defp candidates(prefix, env \\ nil, binding \\ []) do
    Completer.expand(prefix, env || env(), binding)
  end

  test "completes functions of a module" do
    cands = candidates("Enum.ma")
    assert %{candidate: "Enum.map", type: "function"} in cands
    assert %{candidate: "Enum.map_join", type: "function"} in cands
  end

  test "completes macros with their own type" do
    cands = candidates("Kernel.defm")
    assert %{candidate: "Kernel.defmodule", type: "macro"} in cands
  end

  test "completes modules one level at a time" do
    cands = candidates("Stri")
    assert %{candidate: "String", type: "module"} in cands
    refute Enum.any?(cands, &(&1.candidate == "String.Chars"))
  end

  test "completes submodules" do
    cands = candidates("String.C")
    assert %{candidate: "String.Chars", type: "module"} in cands
  end

  test "completes erlang modules and functions" do
    assert %{candidate: ":lists", type: "module"} in candidates(":lis")
    assert %{candidate: ":lists.reverse", type: "function"} in candidates(":lists.rev")
  end

  test "completes variables from the binding" do
    assert [%{candidate: "my_thing", type: "var"}] =
             candidates("my_th", nil, my_thing: 1)
  end

  test "completes imported functions and macros" do
    cands = candidates("spaw")
    assert %{candidate: "spawn_link", type: "function"} in cands
    assert %{candidate: "def", type: "macro"} in candidates("def")
  end

  test "respects aliases from the env" do
    {_, _, env} =
      Code.eval_quoted_with_env(
        Code.string_to_quoted!("alias Enum, as: MyE"),
        [],
        env()
      )

    assert %{candidate: "MyE.map", type: "function"} in candidates("MyE.ma", env)
  end
end

defmodule Repartee.LookupTest do
  use ExUnit.Case, async: true

  alias Repartee.Lookup

  defp env, do: Code.env_for_eval(file: "nrepl")

  test "looks up a function with arity" do
    assert {:ok, info} = Lookup.lookup("Enum.map/2", env())
    assert info["name"] == "map"
    assert info["ns"] == "Enum"
    assert info["arglists-str"] == "map(enumerable, fun)"
    assert info["doc"] =~ "Returns a list"
    assert is_integer(info["line"])
    assert String.ends_with?(info["file"], "enum.ex")
  end

  test "looks up a function without arity (smallest wins)" do
    assert {:ok, info} = Lookup.lookup("Enum.map", env())
    assert info["name"] == "map"
  end

  test "looks up macros" do
    assert {:ok, info} = Lookup.lookup("Kernel.defmodule", env())
    assert info["name"] == "defmodule"
  end

  test "looks up modules" do
    assert {:ok, info} = Lookup.lookup("Enum", env())
    assert info["ns"] == "Enum"
    assert info["doc"] =~ "Functions for working with"
  end

  test "looks up erlang functions" do
    assert {:ok, info} = Lookup.lookup(":lists.map/2", env())
    assert info["name"] == "map"
    assert info["ns"] == ":lists"
  end

  test "resolves bare names through imports" do
    assert {:ok, info} = Lookup.lookup("spawn/1", env())
    assert info["ns"] == "Kernel"
  end

  test "resolves aliases from the env" do
    {_, _, env} =
      Code.eval_quoted_with_env(
        Code.string_to_quoted!("alias Enum, as: MyE"),
        [],
        env()
      )

    assert {:ok, info} = Lookup.lookup("MyE.map/2", env)
    assert info["ns"] == "Enum"
  end

  test "unknown symbols are not found" do
    assert {:error, :not_found} = Lookup.lookup("Definitely.not_a_thing/9", env())
    assert {:error, :not_found} = Lookup.lookup("@#!", env())
  end
end
