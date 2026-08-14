# ex_schematron

Compile ISO Schematron files into pure Elixir validation modules.

Instead of evaluating XPath at runtime, `ex_schematron` parses the `.sch` file at
compile time and injects an Elixir module with one check per `assert`/`report`.
The compiled code calls a small hand-written XPath runtime that implements the
XPath data model (sequences, general comparison, atomization, exact decimals,
document order). No JVM, no NIF, no network at runtime.

Compilation raises on any XPath construct or Schematron form it does not
support: a new schematron version that introduces something new fails the build
instead of silently skipping checks.

## Usage

The schematron lives in the consuming application; nothing is generated on disk:

```elixir
defmodule MyApp.InvoiceValidator do
  use ExSchematron, sch: "priv/schematron/rules.sch"
end

MyApp.InvoiceValidator.validate(xml_binary)
#=> [%{type: :assert, rule: "BR-01", flag: "warning", message: "...", node: "/inv:Invoice[1]/inv:ID[1]"}]
```

The module recompiles when the `.sch` file changes. `validate/1` returns every
violation (no fail-fast), each carrying the rule id, the original message and
the path of the offending node.

To build a module at runtime from schematron source:

```elixir
ExSchematron.compile!(sch_source, MyValidator)
```

## Correctness

Beyond unit tests of the XPath runtime, the test suite replays a differential
oracle: thousands of deterministic mutants of real invoices, with the verdicts
of Saxon-HE (running each schematron's reference XSLT) frozen per schematron in
`test/fixtures/oracle/`. The suite requires no Java; refreshing the manifests
does (`mix run scripts/refresh_oracle.exs`).

## Status

Work in progress.
