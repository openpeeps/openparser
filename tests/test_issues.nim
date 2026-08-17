import std/[strutils]
import openparser/css/[parser, ast, syntax, syntaxdata, validator]

let data = loadCssData()

proc test(desc, rawCss: string) =
  let style = parseCss(rawCss)
  for node in style.nodes:
    if node.kind == cssRuleSet:
      for decl in node.declarations:
        if decl.kind == cssDeclaration:
          let result = validate(data, decl.property, decl.valueComponents)
          let status = if result.valid: "✓" else: "✗"
          echo status, " ", decl.property, ": ", decl.rawValue
          if not result.valid:
            for err in result.errors:
              echo "  └─ ", err.message

echo "=== color-scheme ==="
test("color-scheme", "a { color-scheme: dark; }")

echo "\n=== text-align with var() ==="
test("text-align", "a { text-align: var(--bs-body-text-align); }")

echo "\n=== font-size with calc() ==="
test("font-size calc", "a { font-size: calc(1.375rem + 1.5vw); }")

echo "\n=== font-size keyword ==="
test("font-size keyword", "a { font-size: 1rem; }")
