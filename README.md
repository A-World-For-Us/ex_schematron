# ex_schematron

Compile ISO Schematron files into pure Elixir validation modules.

Instead of evaluating XPath at runtime, `ex_schematron` parses the `.sch` file at
build time and generates an Elixir module with one check per `assert`/`report`.
The generated code calls a small hand-written XPath runtime that implements the
XPath data model (sequences, general comparison, atomization, exact decimals,
document order). No JVM, no NIF, no network at runtime.

The generator raises on any XPath construct or Schematron form it does not
support: a new schematron version that introduces something new fails the build
instead of silently skipping checks.

## Usage

```sh
mix schematron.gen path/to/schema.sch
```

The generated module takes an XML binary and returns every violation, each with
the rule id, the original message and the path of the offending node.

## Status

Work in progress.
