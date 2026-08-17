import std/[strutils]
import openparser/css/[parser, ast, syntaxdata, validator]

let cssInput = """
.d-print-none {
  display: none !important;
}
.foo {
  displa: none !important;
  color: #ff0000;
  width: 100px;
}
"""

let data = loadCssData()
let style = parseCss(cssInput)

for node in style.nodes:
  if node.kind == cssRuleSet:
    var selParts: seq[string] = @[]
    for sel in node.selectors:
      selParts.add(sel.parts.join(" "))
    echo "Selectors: ", selParts.join(", ")
    for decl in node.declarations:
      if decl.kind == cssDeclaration:
        let result = validate(data, decl.property, decl.valueComponents)
        let status = if result.valid: "✓" else: "✗"
        echo "  ", status, " ", decl.property, ": ", decl.rawValue
        if not result.valid:
          for err in result.errors:
            echo "    └─ ", err.message
