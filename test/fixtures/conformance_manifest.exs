# Frozen outcomes of the ISO Schematron conformance corpus, one entry per
# testcase file, one outcome per schema of that testcase. Replayed by
# `test/ex_schematron/conformance_test.exs`; regenerate with
# `MIX_ENV=test mix run scripts/refresh_conformance.exs`.
#
# Conforming: 24/50.
%{
  # expect valid -- NOT CONFORMING
  "core/extends-baseuri-fixup-01" => [
    error: "unsupported rule element {\"http://purl.oclc.org/dsdl/schematron\", \"extends\"} in rule \"/\""
  ],
  # expect invalid -- NOT CONFORMING
  "core/extends-recursive-01" => [
    error: "unsupported rule element {\"http://purl.oclc.org/dsdl/schematron\", \"extends\"} in rule \"/\""
  ],
  # expect valid -- NOT CONFORMING
  "core/include-baseuri-fixup-01" => [
    error: "unsupported pattern element {\"http://purl.oclc.org/dsdl/schematron\", \"include\"} in pattern nil"
  ],
  # expect invalid -- NOT CONFORMING
  "core/include-recursive-01" => [error: "unsupported schema-level element {\"http://purl.oclc.org/dsdl/schematron\", \"include\"}"],
  # expect error
  "core/let-name-collision-error-01" => [error: "variable $foo multiply defined in rule \"/\""],
  # expect error
  "core/let-name-collision-error-02" => [error: "variable $foo multiply defined in pattern nil"],
  # expect error
  "core/let-name-collision-error-03" => [error: "variable $foo multiply defined in schema"],
  # expect error -- NOT CONFORMING
  "core/let-name-collision-error-04" => [unsupported: "validation restricted to phase \"phase\""],
  # expect error -- NOT CONFORMING
  "core/let-name-collision-error-05" => [:valid],
  # expect error -- NOT CONFORMING
  "core/let-name-collision-error-06" => [:valid],
  # expect valid
  "core/let-pattern-global-01" => [:valid],
  # expect error
  "core/let-reference-undefined-01" => [error: "unknown variable $localname in context of rule 0 in pattern nil"],
  # expect error
  "core/let-reference-undefined-02" => [error: "unknown variable $variable in check nil"],
  # expect error
  "core/let-reference-undefined-03" => [error: "unknown variable $variable in check nil"],
  # expect error
  "core/let-reference-undefined-04" => [error: "unsupported rule element {nil, \"let\"} in rule \"*\""],
  # expect error
  "core/let-reference-undefined-05" => [error: "unknown variable $variable in check nil"],
  # expect error
  "core/let-reference-undefined-06" => [error: "unknown variable $variable in check nil"],
  # expect error -- NOT CONFORMING
  "core/let-reference-undefined-07" => [:valid],
  # expect valid
  "core/let-rule-global-01" => [:valid],
  # expect valid -- NOT CONFORMING
  "core/let-rule-global-02" => [unsupported: "validation restricted to phase \"phase\""],
  # expect valid
  "core/let-scope-pattern-01" => [:valid],
  # expect valid -- NOT CONFORMING
  "core/let-scope-phase-01" => [unsupported: "validation restricted to phase \"phase\""],
  # expect valid
  "core/let-scope-rule-01" => [:valid],
  # expect valid -- NOT CONFORMING
  "core/let-value-element-content-01" => [
    error: "missing attribute \"value\" on {\"http://purl.oclc.org/dsdl/schematron\", \"let\"}",
    error: "unsupported queryBinding \"xslt\""
  ],
  # expect invalid -- NOT CONFORMING
  "core/pattern-abstract-01" => [
    error: "unsupported pattern element {\"http://purl.oclc.org/dsdl/schematron\", \"param\"} in pattern nil"
  ],
  # expect invalid -- NOT CONFORMING
  "core/pattern-subordinate-document-01" => [:valid],
  # expect invalid -- NOT CONFORMING
  "core/pattern-subordinate-document-02" => [:valid],
  # expect invalid -- NOT CONFORMING
  "core/rule-abstract-01" => [error: "missing attribute \"context\" on {\"http://purl.oclc.org/dsdl/schematron\", \"rule\"}"],
  # expect error
  "core/rule-abstract-02" => [error: "missing attribute \"context\" on {\"http://purl.oclc.org/dsdl/schematron\", \"rule\"}"],
  # expect invalid
  "core/rule-context-attribute-01" => [:invalid],
  # expect invalid -- NOT CONFORMING
  "core/rule-context-comment-01" => [:valid],
  # expect invalid
  "core/rule-context-element-01" => [:invalid],
  # expect invalid -- NOT CONFORMING
  "core/rule-context-pi-01" => [
    error: "unsupported rule context form {:fn, {nil, \"processing-instruction\"}, []} in context of rule 0 in pattern nil"
  ],
  # expect invalid
  "core/rule-context-root-01" => [:invalid],
  # expect invalid
  "core/rule-context-text-01" => [:invalid],
  # expect valid
  "core/rule-context-variable-01" => [:valid],
  # expect valid -- NOT CONFORMING
  "core/rule-context-variable-02" => [unsupported: "validation restricted to phase \"phase\""],
  # expect valid
  "core/rule-context-variable-03" => [:valid],
  # expect valid
  "core/rule-order-01" => [:valid],
  # expect valid -- NOT CONFORMING
  "core/schema-default-phase-01" => [error: "schematron defaultPhase is not supported yet"],
  # expect valid -- NOT CONFORMING
  "core/schema-default-phase-02" => [unsupported: "validation restricted to phase \"#DEFAULT\""],
  # expect valid -- NOT CONFORMING
  "core/xslt-key-01" => [error: "unsupported schema-level element {\"http://www.w3.org/1999/XSL/Transform\", \"key\"}"],
  # expect valid -- NOT CONFORMING
  "core/xslt-key-element-content-01" => [error: "unsupported schema-level element {\"http://www.w3.org/1999/XSL/Transform\", \"key\"}"],
  # expect invalid -- NOT CONFORMING
  "svrl/svrl-diagnostic-01" => [error: "unsupported schema-level element {\"http://purl.oclc.org/dsdl/schematron\", \"diagnostics\"}"],
  # expect invalid -- NOT CONFORMING
  "svrl/svrl-diagnostic-02" => [error: "unsupported schema-level element {\"http://purl.oclc.org/dsdl/schematron\", \"diagnostics\"}"],
  # expect invalid
  "svrl/svrl-name-nopath-01" => [:invalid],
  # expect invalid
  "svrl/svrl-name-path-01" => [:invalid],
  # expect invalid -- NOT CONFORMING
  "svrl/svrl-property-01" => [error: "unsupported schema-level element {\"http://purl.oclc.org/dsdl/schematron\", \"properties\"}"],
  # expect invalid -- NOT CONFORMING
  "svrl/svrl-property-copy-of" => [
    error: "unsupported schema-level element {\"http://purl.oclc.org/dsdl/schematron\", \"properties\"}"
  ],
  # expect invalid
  "svrl/svrl-value-of-01" => [:invalid]
}
