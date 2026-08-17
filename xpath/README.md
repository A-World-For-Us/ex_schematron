# ExSchematron XPath engine

A compiled XPath 2.0 *subset* engine for Elixir: XPath sources are compiled
into quoted Elixir expressions that evaluate against a purpose-built document
model. It is the engine underneath `ex_schematron`'s generated validators, and
it implements the XPath that real-world schematrons (EN 16931 e-invoicing,
Factur-X, the ISO Schematron conformance corpus) actually use — not the full
recommendation.

## What it is

- **Document model** (`ExSchematron.Xml`): parsed with Saxy, nodes stored in a
  flat map keyed by dense preorder ids — comparing ids gives document order,
  `MapSet` on ids gives deduplication. Node kinds: document, element,
  attribute, text.
- **Lexer and parser** (`ExSchematron.XPath.Lexer` / `Parser`): recursive
  descent to a tagged-tuple AST. Supported grammar: comma sequences,
  `or`/`and`, general (`=`, `!=`, `<` …), value (`eq`, `lt` …) and node
  (`is`, `<<`, `>>`) comparisons, string `||`, `to` ranges, arithmetic with
  `idiv`/`mod`, union, `cast as`/`castable as`, `if/then/else`,
  `for … return`, `some/every … satisfies`, paths over twelve axes, kind
  tests (`node()`, `text()`, `comment()`), filter expressions, variables.
- **Compiler** (`ExSchematron.XPath.Compiler`): AST → quoted Elixir. The
  emitted code reads the document from the variable `doc_var/0` returns;
  predicates compile to `fn item, position, size -> … end` closures. Two
  `Env` hooks extend the engine: `rewrite` (recognize and replace expression
  shapes, e.g. `ex_schematron`'s `document()` code-list lookup) and
  `resolve_call` (bind user-defined functions). Anything outside the
  supported table raises at compile time — never a silent skip.
- **Runtime** (`ExSchematron.Runtime` / `Runtime.Functions`): the XPath 2.0
  data model — sequences, effective boolean value, atomization, type
  promotion — with exact `xs:decimal` arithmetic on the `Decimal` library,
  plus 33 functions of the F&O library and the `xs:decimal`, `xs:integer`,
  `xs:double`, `xs:string`, `xs:boolean` and `xs:date` constructors.

## How it is validated

Conformance is anchored to a **differential oracle**: the ten EN 16931 /
Factur-X schematron-document corpora in the parent repository are validated
by both this engine and Saxon (via the reference XSLT pipeline), and every
verdict must match. The ISO Schematron conformance corpus runs as a second
frozen regression suite. The W3C QT3 test suite is **not** run; numbers like
"XPath 2.0 support" below are scoped by the corpora, not by the
recommendation.

## Limitations

- No comment or processing-instruction nodes in the document model; `text()`
  and `node()` tests work, `comment()` currently selects nothing (see known
  issues).
- No generic `document()` — callers provide it through the `rewrite` hook if
  they need one.
- No date/time arithmetic or duration types; `xs:date` supports parsing and
  comparison only.
- No collations; string comparison is codepoint order.
- Missing F&O functions include `min`, `max`, `avg`, `index-of`,
  `deep-equal`, `subsequence`, the date/time component accessors, and the
  QName functions.
- XSD regular expressions are compiled with PCRE; constructs whose meaning
  would silently differ (character class subtraction, `\i`/`\c`) are
  rejected, other XSD-only constructs fail at evaluation time.
- `ExSchematron.Runtime` also carries helpers for the schematron compiler's
  emitted code (`match_set`, `match_set_reverse`, `matched_ids`, `value_of`,
  `message`, `codelist_member?`, `node_path`); they will move out before the
  package is published separately.

## Known issues

Deviations confirmed against Saxon/the spec, kept out of scope for now
because their fixes change behavior more broadly:

- `double_string` (`runtime.ex`) prints integral doubles ≥ 1e6 in plain
  notation where the XPath canonical form is scientific, and delegates to
  `Float.to_string` inside the plain-notation range, which switches to
  scientific below 1e-4.
- Computed numeric predicates in rule-context match patterns (`b[1+1]`,
  `b[$n]`) are wrapped in EBV instead of being positional
  (`ex_schematron`'s `compiler.ex`, reverse-predicate compilation).
- `(a|b)[position() = 1]` on a filtered rule context bypasses the
  positional-predicate guard that rejects `(a|b)[1]`.
- `comment()` compiles and silently selects nothing instead of being
  rejected at compile time.
- `castable as` swallows every exception as `false`, not just
  `Runtime.Error`.
- `substring`'s 3-arg form reuses the 2-arg unbounded-length sentinel for a
  literal `INF` length, so `substring(x, -INF, INF)` returns the whole
  string where the spec's IEEE arithmetic gives the empty string.
