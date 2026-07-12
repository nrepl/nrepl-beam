defmodule Repartee.Lookup do
  @moduledoc false
  # Symbol lookup for repartee sessions: docs and arglists from EEP-48 doc
  # chunks (Code.fetch_docs/1), source location from module_info(:compile).
  #
  # Accepted symbol shapes: "Enum", "Enum.map", "Enum.map/2", ":lists",
  # ":lists.map", ":lists.map/2", and bare names ("map") which are resolved
  # against the session's imports.

  @spec lookup(String.t(), Macro.Env.t()) ::
          {:ok, %{optional(binary) => binary | integer}} | {:error, :not_found}
  def lookup(sym, env) do
    case parse(sym, env) do
      {:module, module} -> module_details(module)
      {:function, module, fun, arity} -> function_info(module, fun, arity)
      :error -> {:error, :not_found}
    end
  end

  defp parse(":" <> erlang_sym, _env) do
    case String.split(erlang_sym, ".", parts: 2) do
      [mod] ->
        with {:ok, module} <- existing_atom(mod), do: {:module, module}

      [mod, fun_and_arity] ->
        with {:ok, module} <- existing_atom(mod),
             {:ok, fun, arity} <- parse_fun_arity(fun_and_arity) do
          {:function, module, fun, arity}
        end
    end
  end

  defp parse(sym, env) do
    cond do
      # Enum / Enum.Sub - a module (possibly via alias); every segment
      # starts uppercase, so Enum.map falls through to the function branch
      sym =~ ~r/\A[A-Z][A-Za-z0-9_]*(\.[A-Z][A-Za-z0-9_]*)*\z/ ->
        with {:ok, module} <- resolve_module(sym, env), do: {:module, module}

      # Enum.map / Enum.map/2
      match = Regex.run(~r/\A(.+)\.([a-z_][A-Za-z0-9_?!]*(?:\/\d+)?)\z/s, sym) ->
        [_, mod_part, fun_part] = match

        with {:ok, module} <- resolve_module(mod_part, env),
             {:ok, fun, arity} <- parse_fun_arity(fun_part) do
          {:function, module, fun, arity}
        end

      # bare name - look through the session's imports
      sym =~ ~r/\A[a-z_][A-Za-z0-9_?!]*(?:\/\d+)?\z/ ->
        with {:ok, fun, arity} <- parse_fun_arity(sym),
             {:ok, module} <- imported_from(fun, arity, env) do
          {:function, module, fun, arity}
        end

      true ->
        :error
    end
  end

  defp parse_fun_arity(str) do
    case String.split(str, "/") do
      [fun] ->
        with {:ok, atom} <- existing_atom(fun), do: {:ok, atom, :any}

      [fun, arity] ->
        with {:ok, atom} <- existing_atom(fun),
             {arity, ""} <- Integer.parse(arity) do
          {:ok, atom, arity}
        else
          _ -> :error
        end
    end
  end

  defp imported_from(fun, arity, env) do
    (env.functions ++ env.macros)
    |> Enum.find_value(:error, fn {module, funs} ->
      if Enum.any?(funs, fn {name, a} ->
           name == fun and (arity == :any or a == arity)
         end),
         do: {:ok, module}
    end)
  end

  defp module_details(module) do
    case Code.fetch_docs(module) do
      {:docs_v1, anno, _lang, _fmt, module_doc, _meta, _docs} ->
        {:ok,
         %{
           "name" => module_name(module),
           "ns" => module_name(module),
           "line" => :erl_anno.line(anno)
         }
         |> put_doc(module_doc)
         |> put_file(module)}

      {:error, _} ->
        case Code.ensure_loaded(module) do
          {:module, ^module} ->
            {:ok,
             %{"name" => module_name(module), "ns" => module_name(module), "line" => 1}
             |> put_file(module)}

          _ ->
            {:error, :not_found}
        end
    end
  end

  defp function_info(module, fun, arity) do
    with {:docs_v1, _, _, _, _, _, docs} <- Code.fetch_docs(module),
         {:ok, {{_, ^fun, _a}, anno, signature, doc, _meta}} <-
           find_entry(docs, fun, arity) do
      {:ok,
       %{
         "name" => Atom.to_string(fun),
         "ns" => module_name(module),
         "arglists-str" => Enum.join(signature, " "),
         "line" => :erl_anno.line(anno)
       }
       |> put_doc(doc)
       |> put_file(module)}
    else
      _ -> exported_fallback(module, fun, arity)
    end
  end

  defp find_entry(docs, fun, arity) do
    docs
    |> Enum.filter(fn
      {{kind, ^fun, a}, _, _, _, _} when kind in [:function, :macro] ->
        arity == :any or a == arity

      _ ->
        false
    end)
    |> Enum.sort_by(fn {{_, _, a}, _, _, _, _} -> a end)
    |> case do
      [entry | _] -> {:ok, entry}
      [] -> :error
    end
  end

  # No doc entry (no chunk, @doc false, ...): existence via exports.
  defp exported_fallback(module, fun, arity) do
    with {:module, ^module} <- Code.ensure_loaded(module),
         true <-
           Enum.any?(module.module_info(:exports), fn {f, a} ->
             f == fun and (arity == :any or a == arity)
           end) do
      {:ok,
       %{"name" => Atom.to_string(fun), "ns" => module_name(module)}
       |> put_file(module)}
    else
      _ -> {:error, :not_found}
    end
  end

  defp put_doc(info, %{"en" => text}), do: Map.put(info, "doc", text)
  defp put_doc(info, _), do: info

  defp put_file(info, module) do
    case module.module_info(:compile)[:source] do
      source when is_list(source) ->
        Map.put(info, "file", List.to_string(source))

      _ ->
        info
    end
  rescue
    UndefinedFunctionError -> info
  end

  defp module_name(module) do
    case Atom.to_string(module) do
      "Elixir." <> rest -> rest
      other -> ":" <> other
    end
  end

  defp resolve_module(mod_part, env) do
    [first | rest] = String.split(mod_part, ".")

    with {:ok, short} <- existing_atom("Elixir." <> first) do
      resolved = Keyword.get(env.aliases, short, short)

      "Elixir." <> resolved_name = Atom.to_string(resolved)
      existing_atom(Enum.join(["Elixir." <> resolved_name | rest], "."))
    end
  end

  defp existing_atom(str) do
    {:ok, String.to_existing_atom(str)}
  rescue
    ArgumentError -> :error
  end
end
