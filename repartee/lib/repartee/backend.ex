defmodule Repartee.Backend do
  @moduledoc false
  # The :dialtone_backend implementation for Elixir.
  #
  # State is %{binding: ..., env: %Macro.Env{}, inspect_opts: ...}: threading
  # binding and env through Code.eval_quoted_with_env is what makes aliases,
  # imports, requires and variables persist across evals in a session (the
  # same mechanism IEx and Livebook use). eval/load_file run inside
  # dialtone's killable worker process, so they only ever see a snapshot of
  # the state and return its successor.

  @behaviour :dialtone_backend

  @default_inspect_opts [pretty: true, limit: 50, width: 80]

  @impl true
  def init(opts) do
    env = Code.env_for_eval(file: "nrepl")

    inspect_opts =
      case Map.get(opts, :inspect_opts, []) do
        [] -> @default_inspect_opts
        other -> other
      end

    {:ok, %{binding: [], env: env, inspect_opts: inspect_opts}}
  end

  @impl true
  def eval(code, meta, state), do: eval(code, meta, state, true)

  # emit_all? says whether the expressions before the last one report their
  # values too.
  defp eval(code, meta, state, emit_all?) do
    file = Map.get(meta, :file, "nrepl")
    line = Map.get(meta, :line, 1)
    column = Map.get(meta, :column, 1)

    # No :emit_warnings here - parse warnings are written to :standard_error,
    # which reaches the client as err when stderr capture is on (see
    # :dialtone.capture_stderr/0) and the console otherwise.
    quoted_opts = [
      file: to_string(file),
      line: line,
      column: column
    ]

    case Code.string_to_quoted(code, quoted_opts) do
      {:ok, quoted} ->
        eval_exprs(top_level(quoted), state, emit_all?)

      {:error, {location, message, token}} ->
        {:error, syntax_error(file, location, message, token), state}
    end
  end

  @impl true
  def load_file(contents, meta, state) do
    file = Map.get(meta, :path, Map.get(meta, :name, "nrepl-load-file"))
    # Like nREPL, load-file reports just the last expression's value.
    eval(contents, %{file: file, line: 1}, state, false)
  end

  @impl true
  def complete(prefix, _meta, state) do
    {:ok, Repartee.Completer.expand(prefix, state.env, state.binding)}
  end

  @impl true
  def lookup(sym, _meta, state) do
    Repartee.Lookup.lookup(sym, state.env)
  end

  # Elixir IO expects devices in binary mode (Erlang's io defaults to lists).
  @impl true
  def io_opts, do: [binary: true, encoding: :unicode]

  # Called by dialtone's worker when evaluated code raises/exits/throws.
  # Reasons arrive raw from the Erlang-side catch ({:badmatch, 2}, not
  # %MatchError{}), so normalize before deriving the exception name.
  @impl true
  def format_exception(kind, reason, stacktrace, _state) do
    ex =
      case {kind, Exception.normalize(kind, reason, stacktrace)} do
        {:error, %struct{}} -> inspect(struct)
        {other_kind, other} -> "#{other_kind}:" <> inspect(other, limit: 5)
      end

    %{err: Exception.format(kind, reason, prune_stacktrace(stacktrace)), ex: ex}
  end

  @impl true
  def version_info do
    %{
      "elixir" => %{"version-string" => System.version()},
      "erlang" => %{
        "version-string" => List.to_string(:erlang.system_info(:otp_release))
      }
    }
  end

  # Several top-level expressions parse into a block without metadata. A
  # parenthesized block has some, and stays a single expression.
  defp top_level({:__block__, [], [_ | _] = exprs}), do: exprs
  defp top_level(quoted), do: [quoted]

  # One expression at a time, like IEx, so each one gets a value. Values
  # before the last go to the client right away.
  defp eval_exprs([quoted], state, _emit_all?) do
    {value, state} = eval_expr(quoted, state)
    {:ok, %{value: inspect(value, state.inspect_opts)}, state}
  end

  defp eval_exprs([quoted | rest], state, emit_all?) do
    {value, state} = eval_expr(quoted, state)
    if emit_all?, do: :dialtone_backend.emit_value(inspect(value, state.inspect_opts))

    # A later expression that fails keeps what this one did, as the
    # client may already have its value.
    try do
      eval_exprs(rest, state, emit_all?)
    catch
      kind, reason -> {:error, format_exception(kind, reason, __STACKTRACE__, state), state}
    end
  end

  defp eval_expr(quoted, state) do
    # :prune_binding would keep only the variables this code reads or
    # writes, and the session would lose the rest of them.
    {value, binding, env} = Code.eval_quoted_with_env(quoted, state.binding, state.env)
    {value, %{state | binding: binding, env: env}}
  end

  defp syntax_error(file, location, message, token) do
    line = Keyword.get(List.wrap(location), :line, location)

    where =
      case line do
        l when is_integer(l) -> "#{file}:#{l}: "
        _ -> "#{file}: "
      end

    detail =
      case message do
        {opening, closing} -> "#{opening}#{token}#{closing}"
        other -> "#{other}#{token}"
      end

    %{err: where <> detail <> "\n", ex: "syntax-error"}
  end

  # Everything below the eval plumbing (dialtone_worker, erl_eval, elixir's
  # own eval machinery) is noise to the person reading the stack trace.
  defp prune_stacktrace(stacktrace) do
    stacktrace
    |> Enum.take_while(fn {mod, _fun, _arity, _loc} ->
      mod not in [:elixir, :elixir_compiler, :erl_eval, :dialtone_worker]
    end)
    |> case do
      [] -> stacktrace
      pruned -> pruned
    end
  end
end
