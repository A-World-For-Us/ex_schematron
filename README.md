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

### ISO conformance corpus

The oracle says we agree with Saxon on real invoices; it says nothing about the
corners of the standard those invoices never reach. For that, the
[Schematron conformance corpus](https://github.com/Schematron/schematron-conformance)
(the suite SchXslt validates against) is vendored as a git submodule:

```
git submodule update --init test/fixtures/conformance
mix test.conformance
```

Each of its testcases is one self-contained document -- input document(s),
schema, and expected outcome (`valid`, `invalid`, or `error` for a schema the
processor must reject). This library implements a subset of ISO Schematron, so
it does not pass the whole corpus; the outcomes are frozen in
`test/fixtures/conformance_manifest.exs` and replayed, which turns the corpus
into a regression check and an explicit record of what is not supported yet.
Refresh it with `MIX_ENV=test mix run scripts/refresh_conformance.exs`, which
rewrites the manifest and prints the score and every non-conforming testcase.

#### Score: 24/50

| Area | Pass | Missing or wrong |
| --- | --- | --- |
| Variables (`let`) | 13/20 | `let` holding element content instead of `@value` unsupported. An undefined variable in `pattern/@documents` is not caught. Three testcases blocked on phase support. The corpus contradicts itself on shadowing: `let-name-collision-error-05/06` expect an error for a pattern `let` shadowing a schema-level one, while the newer `let-scope-*` testcases require it to be legal -- we allow shadowing, like SchXslt. |
| Rule context | 6/9 | `comment()` and `processing-instruction()` contexts unsupported. One testcase blocked on phase support. |
| Rule order and abstract rules | 2/3 | Abstract rules unsupported. |
| Patterns | 0/3 | Abstract patterns (`<param>`) unsupported. `<pattern documents="...">` is silently ignored -- the one place the library skips a check without saying so. |
| Phases | 0/2 | `defaultPhase` raises; validating under a named phase has no API. |
| `include` / `extends` fixup | 0/4 | Neither is implemented, so base-URI fixup is untested. |
| `xsl:key` | 0/2 | Schema-level `xsl:key` unsupported. |
| SVRL output | 3/7 | `diagnostics` and `properties` unsupported; `validate/1` returns verdict maps, not an SVRL report. |

Two adaptations, both recorded in the manifest rather than hidden:

* The corpus targets the default XSLT 1.0 query binding, which this library does
  not implement. A schema declaring no `queryBinding` is compiled as `xslt2`; a
  schema declaring one is left alone, so the explicit `queryBinding="xslt"`
  variants surface as errors.
* `<schemas phase="...">` asks for validation restricted to a phase, which
  `validate/1` has no argument for. Those five testcases yield `{:unsupported,
  reason}` instead of a made-up verdict.

The seven SVRL testcases also carry `<expectations>`, XPath assertions over an
SVRL report. Only their `@expect` is checked.

## Status

Work in progress.
