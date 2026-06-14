import std/[tables, strutils]
import ../json

type
  CssNodeKind* = enum
    cssStyleSheet
    cssRuleSet
    cssSelector
    cssDeclaration
    cssValue
    cssComment
    cssAtRule
    cssFunction
    cssNumber
    cssDimension
    cssPercentage
    cssString
    cssUrl
    cssIdent
    cssHash
    cssImportant
    cssBlock
    cssPreserved

  CSSSelectorKind* = enum
    selectorClass
    selectorId
    selectorType
    selectorPseudo
    selectorPseudoElement
    selectorAttribute
    selectorUniversal
    selectorCombinator

  CssNode* = ref object
    case kind*: CssNodeKind
    of cssStyleSheet:
      rules*: seq[CssNode]
    of cssRuleSet:
      selectors*: seq[CssNode]
      declarations*: seq[CssNode]
    of cssSelector:
      selectorKind*: CSSSelectorKind
      parts*: seq[string]
    of cssDeclaration:
      property*: string
      value*: CssNode
      important*: bool
    of cssValue:
      raw*: string
      components*: seq[CssNode]
    of cssComment:
      text*: string
    of cssAtRule:
      atName*: string
      prelude*: string
      atRules*: seq[CssNode]
      blockValues*: seq[CssNode]
    of cssFunction:
      funcName*: string
      args*: seq[CssNode]
    of cssNumber:
      numValue*: string
      numFloat*: float
    of cssDimension:
      dimValue*: string
      dimUnit*: string
      dimFloat*: float
    of cssPercentage:
      pctValue*: string
      pctFloat*: float
    of cssString:
      strValue*: string
    of cssUrl:
      urlValue*: string
    of cssIdent:
      identValue*: string
    of cssHash:
      hashValue*: string
      hashFlag*: string
    of cssImportant:
      discard
    of cssBlock:
      blockKind*: char
      values*: seq[CssNode]
    of cssPreserved:
      preservedValue*: string

  CssStyleSheet* = object
    nodes*: seq[CssNode]

proc serializeComponentValue*(node: CssNode): string =
  case node.kind
  of cssFunction:
    result = node.funcName & "("
    for i, arg in node.args:
      if i > 0: result.add(" ")
      result.add(serializeComponentValue(arg))
    result.add(")")
  of cssNumber:
    result = node.numValue
  of cssDimension:
    result = node.dimValue
  of cssPercentage:
    result = node.pctValue
  of cssString:
    result = "\"" & node.strValue & "\""
  of cssUrl:
    result = "url(" & node.urlValue & ")"
  of cssIdent:
    result = node.identValue
  of cssHash:
    result = "#" & node.hashValue
  of cssImportant:
    result = "!important"
  of cssBlock:
    case node.blockKind
    of '{':
      result = "{"
      for v in node.values:
        result.add(serializeComponentValue(v))
      result.add("}")
    of '(':
      result = "("
      for v in node.values:
        result.add(serializeComponentValue(v))
      result.add(")")
    of '[':
      result = "["
      for v in node.values:
        result.add(serializeComponentValue(v))
      result.add("]")
    else: discard
  of cssPreserved:
    result = node.preservedValue
  of cssComment:
    result = "/* " & node.text & " */"
  else:
    result = ""

type
  CSSOpts* = object
    preserveComments*: bool
    minify*: bool
    indent*: int

proc defaultOpts*: CSSOpts =
  result.indent = 2
  result.preserveComments = true
  result.minify = true

proc toString*(node: CssNode, pos: int = 0, opts = defaultOpts()): string =
  let indent = if opts.minify or pos == 0: "" else: repeat(' ', pos)
  case node.kind
  of cssStyleSheet:
    for rule in node.rules:
      result.add(toString(rule, pos, opts))
      if not opts.minify:
        result.add("\n")
  of cssRuleSet:
    if not opts.minify:
      result.add(indent)
    for i, sel in node.selectors:
      if i > 0:
        result.add(",")
        if not opts.minify:
          result.add(" ")
      result.add(toString(sel, 0, opts))
    result.add("{")
    if not opts.minify:
      result.add("\n")
    for decl in node.declarations:
      result.add(toString(decl, pos + opts.indent, opts))
    if not opts.minify:
      result.add(indent)
    result.add("}")
    if not opts.minify:
      result.add("\n")
  of cssSelector:
    for i, part in node.parts:
      if i == 0:
        result.add(part)
        continue
      if opts.minify:
        if part == " ":
          result.add(" ")
        elif part in [">", "+", "~", "||"]:
          result.add(part)
        elif part.startsWith(".") or part.startsWith("#") or part.startsWith("[") or part.startsWith(":"):
          result.add(part)
        else:
          result.add(part)
      else:
        if part == ">" or part == "+" or part == "~" or part == "||":
          result.add(" " & part & " ")
        elif part.startsWith(".") or part.startsWith("#") or part.startsWith("[") or part.startsWith(":"):
          result.add(part)
        else:
          result.add(" " & part)
  of cssDeclaration:
    if not opts.minify:
      result.add(indent)
    result.add(node.property & ":")
    if not opts.minify:
      result.add(" ")
    result.add(toString(node.value, 0, opts))
    if node.important:
      if not opts.minify:
        result.add(" ")
      result.add("!important")
    result.add(";")
    if not opts.minify:
      result.add("\n")
  of cssValue:
    result.add(node.raw)
  of cssComment:
    if not opts.preserveComments:
      return ""
    if opts.minify:
      result.add("/*" & node.text & "*/")
    else:
      result.add(indent & "/* " & node.text & " */\n")
  of cssAtRule:
    if not opts.minify:
      result.add(indent)
    result.add("@" & node.atName)
    if node.prelude.len > 0:
      result.add(" " & node.prelude)
    if node.atRules.len > 0 or node.blockValues.len > 0:
      result.add("{")
      if not opts.minify:
        result.add("\n")
      if node.atRules.len > 0:
        for r in node.atRules:
          result.add(toString(r, pos + opts.indent, opts))
      elif node.blockValues.len > 0:
        for v in node.blockValues:
          result.add(toString(v, pos + opts.indent, opts))
      if not opts.minify:
        result.add(indent)
      result.add("}")
      if not opts.minify:
        result.add("\n")
    else:
      result.add(";")
      if not opts.minify:
        result.add("\n")
  of cssFunction:
    result.add(serializeComponentValue(node))
  of cssNumber, cssDimension, cssPercentage, cssString, cssUrl, cssIdent, cssHash, cssImportant, cssBlock, cssPreserved:
    result.add(serializeComponentValue(node))

proc `$`*(style: CssStyleSheet): string =
  for rule in style.nodes:
    result.add(toString(rule))