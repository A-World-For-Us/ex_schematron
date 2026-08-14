defmodule ExSchematron.OracleValidators do
  @moduledoc """
  Builds one validator module per oracle pair at compile time, so the suite
  reuses the `_build` cache instead of recompiling the biggest schematrons
  (seconds each) at every run.
  """

  for pair <- ExSchematron.OracleSuite.pairs() do
    @external_resource ExSchematron.OracleSuite.sch_path(pair)
    ExSchematron.compile_file!(ExSchematron.OracleSuite.sch_path(pair), ExSchematron.OracleSuite.validator(pair))
  end
end
