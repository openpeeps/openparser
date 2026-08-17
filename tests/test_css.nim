import std/[strutils, sequtils]
import openparser/css/[parser, ast, syntax, syntaxdata, validator]

let data = loadCssData()

proc componentToString(c: CssValue): string =
  case c.kind
  of cvkDimension: result = c.dimValue & c.dimUnit
  of cvkNumber: result = $c.numValue
  of cvkPercentage: result = $c.pctValue & "%"
  of cvkIdent: result = c.identValue
  of cvkString: result = "\"" & c.strValue & "\""
  of cvkPreserved: result = "PRESERVED:" & c.preservedValue
  of cvkFunction: result = c.funcName & "(...)"
  of cvkComment: result = "/*" & c.commentText & "*/"
  else: result = $c.kind

let rawCss = "a { background: transparent var(--bs-btn-close-bg) center / 1em auto no-repeat; }"
let style = parseCss(rawCss)
for node in style.nodes:
  if node.kind == cssRuleSet:
    for decl in node.declarations:
      if decl.kind == cssDeclaration:
        echo "Property: ", decl.property, " = ", decl.rawValue
        echo "  Components:"
        for i, c in decl.valueComponents:
          echo "    [", i, "] ", c.kind, " = ", componentToString(c)
        let result = validate(data, decl.property, decl.valueComponents)
        echo "  Valid: ", result.valid
        if not result.valid and result.errors.len > 0:
          echo "  Reason: ", result.errors[0].message
