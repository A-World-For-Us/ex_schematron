defmodule ExSchematron do
  @moduledoc """
  Compiles ISO Schematron files into Elixir validation modules.

  The usual way is compile-time injection — the schematron lives in the consuming
  application, nothing is generated on disk:

      defmodule MyApp.InvoiceValidator do
        use ExSchematron, sch: "priv/schematron/rules.sch"
      end

      MyApp.InvoiceValidator.validate(xml_binary)
      #=> [%{type: :assert, rule: "BR-01", flag: "warning", message: "...", node: "/inv:Invoice[1]/..."}]

  The module recompiles when the `.sch` file changes. Compilation raises on any
  construct outside the supported subset, never skipping a check silently.

  `compile!/2` builds a module at runtime instead, from a schematron source string.
  """

  alias ExSchematron.Compiler
  alias ExSchematron.Sch

  defmacro __using__(opts) do
    {opts, _bindings} = Code.eval_quoted(opts, [], __CALLER__)
    sch_path = Keyword.fetch!(opts, :sch)
    body = sch_path |> Sch.parse_file!() |> Compiler.build_body!()

    quote do
      @external_resource unquote(sch_path)
      unquote(body)
    end
  end

  @doc "Builds a validation module named `module_name` from schematron source."
  @spec compile!(binary(), module()) :: module()
  def compile!(sch_source, module_name) do
    body = sch_source |> Sch.parse!() |> Compiler.build_body!()
    {:module, module, _binary, _result} = Module.create(module_name, body, Macro.Env.location(__ENV__))
    module
  end
end
