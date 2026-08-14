defmodule Mix.Tasks.Schematron.Gen do
  @shortdoc "Generates an Elixir validation module from a schematron file"

  @moduledoc """
  Generates an Elixir validation module from an ISO Schematron file.

      mix schematron.gen SCH_PATH --module MyApp.Validator --out lib/my_app/validator.ex

  Generation fails loudly on any construct outside the supported subset.
  """

  use Mix.Task

  @impl true
  def run(args) do
    {opts, positional, []} = OptionParser.parse(args, strict: [module: :string, out: :string])

    case {positional, opts[:module], opts[:out]} do
      {[sch_path], module_string, out_path} when is_binary(module_string) and is_binary(out_path) ->
        Mix.Task.run("compile")
        module = Module.concat([module_string])
        source = ExSchematron.Compiler.compile_file!(sch_path, module)
        File.mkdir_p!(Path.dirname(out_path))
        File.write!(out_path, source)
        Mix.shell().info("Generated #{out_path} (#{module_string})")

      _invalid ->
        Mix.raise("usage: mix schematron.gen SCH_PATH --module MODULE --out FILE")
    end
  end
end
