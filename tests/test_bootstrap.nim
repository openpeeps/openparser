import std/[strutils, times, os]
import openparser/css/[parser, ast, syntaxdata, validator]

let sample = readFile("tests" / "data" / "sample.css")
let data = loadCssData()

echo "Parsing Bootstrap CSS (", sample.len, " bytes)..."
let start = epochTime()
let style = parseCss(sample)
let parseTime = epochTime() - start
echo "Parsed in ", (parseTime * 1000).formatFloat(ffDecimal, 2), "ms"

var totalDecls = 0
var validDecls = 0
var invalidDecls = 0
var unknownProps = 0

let valStart = epochTime()
for node in style.nodes:
  case node.kind
  of cssRuleSet:
    for decl in node.declarations:
      if decl.kind == cssDeclaration:
        inc totalDecls
        let result = validate(data, decl.property, decl.valueComponents)
        if result.valid:
          inc validDecls
        else:
          inc invalidDecls
          if invalidDecls <= 5:
            echo "  ✗ ", decl.property, ": ", decl.rawValue
            for err in result.errors:
              echo "    └─ ", err.message
  of cssAtRule:
    for child in node.atRules:
      if child.kind == cssRuleSet:
        for decl in child.declarations:
          if decl.kind == cssDeclaration:
            inc totalDecls
            let result = validate(data, decl.property, decl.valueComponents)
            if result.valid:
              inc validDecls
            else:
              inc invalidDecls
  else:
    discard

let valTime = epochTime() - valStart
echo "\nValidation: ", (valTime * 1000).formatFloat(ffDecimal, 2), "ms"
echo "Total declarations: ", totalDecls
echo "Valid:   ", validDecls
echo "Invalid: ", invalidDecls
echo "Unknown: ", unknownProps
