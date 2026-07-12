defmodule Repartee.Completer do
  @moduledoc false
  # Completion candidates for repartee sessions.
  #
  # Deliberately simple and session-aware: variables come from the binding,
  # imported functions/macros and aliases from the session's %Macro.Env{},
  # modules from the code server. Candidates always complete the entire
  # prefix the client sent ("Enum.ma" -> "Enum.map"). IEx.Autocomplete is
  # not used - it is private API and expects a live IEx shell.

  @spec expand(String.t(), Macro.Env.t(), keyword) ::
          [%{candidate: String.t(), type: String.t()}]
  def expand(prefix, env, binding) do
    candidates =
      cond do
        # :lists.rev / :lis - Erlang module or function
        String.starts_with?(prefix, ":") ->
          erlang_candidates(String.trim_leading(prefix, ":"))

        # Enum.ma / String.Chars - function in (or submodule of) a module
        match = Regex.run(~r/\A(.+)\.([a-z_][A-Za-z0-9_?!]*)?\z/s, prefix) ->
          [_, mod_part, fun_part] = pad3(match)
          module_member_candidates(mod_part, fun_part, env)

        # Enu - module or alias
        prefix =~ ~r/\A[A-Z]/ ->
          alias_candidates(prefix, env) ++ elixir_module_candidates(prefix)

        # variables and imported functions/macros
        true ->
          variable_candidates(prefix, binding) ++ import_candidates(prefix, env)
      end

    Enum.sort_by(candidates, & &1.candidate)
  end

  defp pad3([a, b]), do: [a, b, ""]
  defp pad3([a, b, c]), do: [a, b, c]

  defp erlang_candidates(rest) do
    case String.split(rest, ".", parts: 2) do
      [mod, fun_prefix] ->
        with {:ok, module} <- existing_atom(mod) do
          for {name, type} <- exported_members(module),
              String.starts_with?(name, fun_prefix) do
            %{candidate: ":#{mod}.#{name}", type: type}
          end
        else
          _ -> []
        end

      [mod_prefix] ->
        for {name, _, _} <- :code.all_available(),
            name = List.to_string(name),
            name =~ ~r/\A[a-z]/,
            String.starts_with?(name, mod_prefix) do
          %{candidate: ":#{name}", type: "module"}
        end
    end
  end

  defp module_member_candidates(mod_part, member_prefix, env) do
    submodules =
      for name <- available_elixir_modules(),
          String.starts_with?(name, mod_part <> "."),
          candidate = next_segment(name, mod_part),
          String.starts_with?(candidate_last(candidate), member_prefix) do
        %{candidate: candidate, type: "module"}
      end

    functions =
      case resolve_module(mod_part, env) do
        {:ok, module} ->
          for {name, type} <- exported_members(module),
              String.starts_with?(name, member_prefix) do
            %{candidate: "#{mod_part}.#{name}", type: type}
          end

        :error ->
          []
      end

    Enum.uniq(submodules) ++ functions
  end

  # "Foo.Bar.Baz" given mod_part "Foo" -> "Foo.Bar" (complete one level)
  defp next_segment(full_name, mod_part) do
    rest = String.replace_prefix(full_name, mod_part <> ".", "")
    mod_part <> "." <> hd(String.split(rest, "."))
  end

  defp candidate_last(candidate),
    do: candidate |> String.split(".") |> List.last()

  defp alias_candidates(prefix, env) do
    for {short, _full} <- env.aliases,
        name = short |> inspect(),
        String.starts_with?(name, prefix) do
      %{candidate: name, type: "module"}
    end
  end

  # Complete one module level at a time: "Str" offers String and Stream,
  # not String.Chars.
  defp elixir_module_candidates(prefix) do
    for name <- available_elixir_modules(),
        String.starts_with?(name, prefix) do
      %{candidate: keep_levels(name, prefix), type: "module"}
    end
    |> Enum.uniq()
  end

  defp keep_levels(name, prefix) do
    prefix_depth = length(String.split(prefix, "."))
    name |> String.split(".") |> Enum.take(prefix_depth) |> Enum.join(".")
  end

  defp available_elixir_modules do
    for {name, _, _} <- :code.all_available(),
        name = List.to_string(name),
        String.starts_with?(name, "Elixir."),
        not String.contains?(name, "-") do
      String.trim_leading(name, "Elixir.")
    end
  end

  defp variable_candidates(prefix, binding) do
    for {name, _value} <- binding,
        is_atom(name),
        str = Atom.to_string(name),
        not String.starts_with?(str, "_"),
        String.starts_with?(str, prefix) do
      %{candidate: str, type: "var"}
    end
  end

  defp import_candidates(prefix, env) do
    functions =
      for {_mod, funs} <- env.functions, {name, _arity} <- funs do
        {Atom.to_string(name), "function"}
      end

    macros =
      for {_mod, macs} <- env.macros, {name, _arity} <- macs do
        {Atom.to_string(name), "macro"}
      end

    for {name, type} <- Enum.uniq(functions ++ macros),
        String.starts_with?(name, prefix),
        not String.starts_with?(name, "_") do
      %{candidate: name, type: type}
    end
  end

  defp exported_members(module) do
    with {:module, ^module} <- Code.ensure_loaded(module) do
      macros =
        if function_exported?(module, :__info__, 1) do
          for {name, _arity} <- module.__info__(:macros),
              do: {Atom.to_string(name), "macro"}
        else
          []
        end

      functions =
        for {name, _arity} <- module.module_info(:exports),
            name not in [:module_info, :__info__],
            str = Atom.to_string(name),
            not String.starts_with?(str, "MACRO-"),
            not String.starts_with?(str, "_") do
          {str, "function"}
        end

      Enum.uniq(macros ++ functions)
    else
      _ -> []
    end
  end

  defp resolve_module(mod_part, env) do
    parts = String.split(mod_part, ".")

    with {:ok, first} <- existing_atom("Elixir." <> hd(parts)) do
      resolved = Keyword.get(env.aliases, first, first)
      rest = tl(parts)

      case existing_atom(Enum.join([inspect(resolved) | rest], ".") |> elixirize()) do
        {:ok, module} -> {:ok, module}
        :error -> :error
      end
    end
  end

  defp elixirize("Elixir." <> _ = name), do: name
  defp elixirize(name), do: "Elixir." <> name

  defp existing_atom(str) do
    {:ok, String.to_existing_atom(str)}
  rescue
    ArgumentError -> :error
  end
end
