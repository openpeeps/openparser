import std/[tables, strutils]
import ./css/[parser, ast, syntax, syntaxdata, validator]
export parser, ast, syntax, syntaxdata, validator

const VendorPrefixes = ["-webkit-", "-moz-", "-ms-", "-o-"]

proc propertyAlias(prop: string): string =
  case prop
  of "color-adjust": "print-color-adjust"
  of "-webkit-margin-end": "margin-inline-end"
  else: ""

proc resolveProperty(data: CssData; prop: string): string =
  if data.properties.hasKey(prop):
    return prop
  # Custom properties are always valid
  if prop.startsWith("--"):
    return prop
  # Check aliases
  let alias = propertyAlias(prop)
  if alias != "" and data.properties.hasKey(alias):
    return alias
  # Strip vendor prefixes and check base name
  for prefix in VendorPrefixes:
    if prop.startsWith(prefix):
      let base = prop[prefix.len..^1]
      if data.properties.hasKey(base):
        return base
      let baseAlias = propertyAlias(base)
      if baseAlias != "" and data.properties.hasKey(baseAlias):
        return baseAlias
  ""

when isMainModule:
  let style = parseCss(readFile("sample.css"))
  let data = loadCssData()
  var totalDecls = 0
  var validDecls = 0
  var invalidDecls = 0
  var unknownProps = 0

  template processDecl(decl: CssNode) =
    if decl.kind == cssDeclaration:
      inc totalDecls
      let resolved = resolveProperty(data, decl.property)
      if resolved == "":
        inc unknownProps
      elif resolved.startsWith("--"):
        inc validDecls
      else:
        let result = validate(data, resolved, decl.valueComponents)
        if result.valid:
          inc validDecls
        else:
          inc invalidDecls
          if invalidDecls <= 10:
            echo "  ✗ ", decl.property, ": ", decl.rawValue
            for err in result.errors:
              echo "    └─ ", err.message

  for node in style.nodes:
    case node.kind
    of cssRuleSet:
      for decl in node.declarations:
        processDecl(decl)
    of cssAtRule:
      for child in node.atRules:
        if child.kind == cssRuleSet:
          for decl in child.declarations:
            processDecl(decl)
    else:
      discard

  echo "Total: ", totalDecls, " | Valid: ", validDecls,
       " | Invalid: ", invalidDecls, " | Unknown: ", unknownProps
