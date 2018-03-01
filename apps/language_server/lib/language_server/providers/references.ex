defmodule ElixirLS.LanguageServer.Providers.References do
  @moduledoc """
  This module provides References support by using
  the `Mix.Tasks.Xref.call/0` task to find all references to
  any function or module identified at the provided location.
  """

  alias ElixirLS.LanguageServer.SourceFile
  alias ElixirSense.Core.{Metadata, Parser, Source, Introspection}

  def references(text, line, character, project_dir, _include_declaration) do
    xref_at_cursor(project_dir, text, line, character)
    |> Enum.filter(fn %{line: line} -> is_integer(line) end)
    |> Enum.map(&build_location/1)
  end

  def supported? do
    Mix.Tasks.Xref.__info__(:functions) |> Enum.member?({:calls, 0})
  end

  defp xref_at_cursor(project_dir, text, line, character) do
    env_at_cursor = line_environment(text, line)

    subject_at_cursor(text, line, character)
    |> Introspection.split_mod_fun_call()
    |> expand_mod_fun(env_at_cursor)
    |> add_arity(env_at_cursor)
    |> callers(project_dir)
  end

  defp line_environment(text, line) do
    Parser.parse_string(text, true, true, line + 1) |> Metadata.get_env(line + 1)
  end

  defp subject_at_cursor(text, line, character) do
    Source.subject(text, line + 1, character + 1)
  end

  defp expand_mod_fun({nil, nil}, _environment), do: nil

  defp expand_mod_fun(mod_fun, %{imports: imports, aliases: aliases, module: module}) do
    case Introspection.actual_mod_fun(mod_fun, imports, aliases, module) do
      {mod, nil} -> {mod, nil}
      {mod, fun} -> {mod, fun}
    end
  end

  defp add_arity({mod, fun}, %{scope: {fun, arity}, module: mod}), do: {mod, fun, arity}
  defp add_arity({mod, fun}, _env), do: {mod, fun, nil}

  def callers(nil, _), do: []

  def callers(mfa, project_dir) do
    if Mix.Project.umbrella?() do
      build_dir = Path.join(project_dir, ".elixir_ls/build")

      Mix.Project.apps_paths()
      |> Enum.flat_map(fn {app, path} ->
        Mix.Project.in_project(app, path, [build_path: build_dir], fn _ ->
          Mix.Tasks.Xref.calls()
          |> Enum.map(fn %{file: file} = call ->
            Map.put(call, :file, Path.join(path, file))
          end)
        end)
      end)
    else
      Mix.Tasks.Xref.calls()
    end
    |> Enum.filter(caller_filter(mfa))
  end

  defp caller_filter({module, nil, nil}), do: &match?(%{callee: {^module, _, _}}, &1)
  defp caller_filter({module, func, nil}), do: &match?(%{callee: {^module, ^func, _}}, &1)
  defp caller_filter({module, func, arity}), do: &match?(%{callee: {^module, ^func, ^arity}}, &1)

  defp build_location(call) do
    %{
      "uri" => SourceFile.path_to_uri(call.file),
      "range" => %{
        "start" => %{"line" => call.line - 1, "character" => 0},
        "end" => %{"line" => call.line - 1, "character" => 0}
      }
    }
  end
end
