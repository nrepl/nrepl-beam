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
  def eval(code, meta, state) do
    file = Map.get(meta, :file, "nrepl")
    line = Map.get(meta, :line, 1)
    column = Map.get(meta, :column, 1)

    quoted_opts = [
      file: to_string(file),
      line: line,
      column: column,
      emit_warnings: false
    ]

    case Code.string_to_quoted(code, quoted_opts) do
      {:ok, quoted} ->
        {value, binding, env} =
          Code.eval_quoted_with_env(quoted, state.binding, state.env, prune_binding: true)

        {:ok, %{value: inspect(value, state.inspect_opts)}, %{state | binding: binding, env: env}}

      {:error, {location, message, token}} ->
        {:error, syntax_error(file, location, message, token), state}
    end
  end

  @impl true
  def load_file(contents, meta, state) do
    file = Map.get(meta, :path, Map.get(meta, :name, "nrepl-load-file"))
    eval(contents, %{file: file, line: 1}, state)
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
