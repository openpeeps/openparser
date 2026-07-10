# A collection of tiny parsers and dumpers
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/openparser

## The CSS AST (Abstract Syntax Tree) representation and serialization logic.
## Thse AST is used to represent the structure of CSS code in a tree format, allowing for easy manipulation
## and serialization back to CSS text.

import std/[tables, strutils]
import ../json

type
  CssNodeKind* = enum
    ## The kind of CSS node, representing different components
    ## of a CSS stylesheet.
    cssStyleSheet
    cssRuleSet
    cssSelector
    cssDeclaration
    cssComment
    cssAtRule
    cssValue

  CSSSelectorKind* = enum
    ## The kind of CSS selector, representing different
    ## types of selectors in CSS.
    selectorClass
    selectorId
    selectorType
    selectorPseudo
    selectorPseudoElement
    selectorAttribute
    selectorUniversal
    selectorCombinator

  CssValueKind* = enum
    ## The kind of CSS value, representing different types
    ## of values in CSS declarations.
    cvkFunction
    cvkNumber
    cvkDimension
    cvkPercentage
    cvkString
    cvkUrl
    cvkIdent
    cvkHash
    cvkImportant
    cvkBlock
    cvkPreserved
    cvkComment

  CssValue* {.acyclic.} = object
    ## The representation of a CSS value, which can be a function, number, dimension,
    ## percentage, string, URL, identifier, hash, important flag, block, preserved value, or comment.
    case kind*: CssValueKind
    of cvkFunction:
      funcName*: string
      args*: seq[CssValue]
    of cvkNumber:
      numValue*: string
      numFloat*: float
    of cvkDimension:
      dimValue*: string
      dimUnit*: string
      dimFloat*: float
    of cvkPercentage:
      pctValue*: string
      pctFloat*: float
    of cvkString:
      strValue*: string
    of cvkUrl:
      urlValue*: string
    of cvkIdent:
      identValue*: string
    of cvkHash:
      hashValue*: string
      hashFlag*: string
    of cvkImportant:
      discard
    of cvkBlock:
      blockKind*: char
      blockValues*: seq[CssValue]
    of cvkPreserved:
      preservedValue*: string
    of cvkComment:
      commentText*: string

  CssNode* {.acyclic.} = ref object
    ## The representation of a CSS node, which can be a stylesheet, rule set, selector,
    ## declaration, comment, at-rule, or value.
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
      rawValue*: string
      valueComponents*: seq[CssValue]
      important*: bool
    of cssComment:
      text*: string
    of cssAtRule:
      atName*: string
      prelude*: string
      atRules*: seq[CssNode]
      blockValues*: seq[CssValue]
    of cssValue:
      raw*: string
      components*: seq[CssValue]

  CssStyleSheet* = object
    ## The representation of a CSS stylesheet, which contains a sequence of CSS nodes.
    nodes*: seq[CssNode]
      ## The sequence of CSS nodes that make up the stylesheet.

proc serializeComponentList*(nodes: seq[CssValue]): string

proc serializeComponentValue*(val: CssValue): string =
  ## Serializes a CssValue into its string representation.
  case val.kind
  of cvkFunction:
    result = val.funcName & "("
    result.add(serializeComponentList(val.args))
    result.add(")")
  of cvkNumber:       result = val.numValue
  of cvkDimension:    result = val.dimValue & val.dimUnit
  of cvkPercentage:   result = val.pctValue
  of cvkString:       result = "\"" & val.strValue & "\""
  of cvkUrl:          result = "url(" & val.urlValue & ")"
  of cvkIdent:        result = val.identValue
  of cvkHash:         result = "#" & val.hashValue
  of cvkImportant:    result = "!important"
  of cvkBlock:
    let (open, close) = case val.blockKind
      of '{': ("{", "}")
      of '(': ("(", ")")
      of '[': ("[", "]")
      else: ("", "")
    result = open
    result.add(serializeComponentList(val.blockValues))
    result.add(close)
  of cvkPreserved:    result = val.preservedValue
  of cvkComment:      result = "/*" & val.commentText & "*/"

proc serializeComponentList*(nodes: seq[CssValue]): string =
  for i, node in nodes:
    if i > 0:
      let prev = nodes[i-1]
      if node.kind == cvkPreserved and node.preservedValue in [",", ")", "]", "}", ";"]:
        discard
      elif prev.kind == cvkPreserved and prev.preservedValue in ["(", "[", "{"]:
        discard
      elif node.kind == cvkPreserved and node.preservedValue in ["(", "[", "{"]:
        discard
      elif prev.kind == cvkPreserved and prev.preservedValue in [")", "]", "}"]:
        result.add(" ")
      else:
        result.add(" ")
    result.add(serializeComponentValue(node))

type
  CSSOpts* = object
    ## Options for serializing CSS nodes, including whether to preserve comments,
    ## minify the output, and the indentation level.
    preserveComments*: bool
      ## Whether to preserve comments in the serialized output. If true,
      ## comments will be included; if false, they will be omitted.
    minify*: bool
      ## Whether to minify the serialized output. If true, the output will be
      ## compacted with minimal whitespace; if false, it will be formatted
      ## with indentation and line breaks for readability.
    indent*: int
      ## The number of spaces to use for indentation in the serialized output.

proc defaultOpts*: CSSOpts =
  ## Returns the default options for serializing CSS nodes, with an
  ## indentation of 2 spaces and comments preserved.
  result.indent = 2
  result.preserveComments = true

proc toString*(val: CssValue): string =
  ## Serialize CSSValue
  serializeComponentValue(val)

proc toString*(node: CssNode, pos: int = 0, opts = defaultOpts()): string =
  ## Transform `CSSNode` to stringified representation
  let indent = if opts.minify or pos == 0: "" else: repeat(' ', pos)
  case node.kind
  of cssStyleSheet:
    for rule in node.rules:
      result.add(toString(rule, pos, opts))
      if not opts.minify: result.add("\n")
  of cssRuleSet:
    if not opts.minify: result.add(indent)
    for i, sel in node.selectors:
      if i > 0:
        result.add(",")
        if not opts.minify: result.add(" ")
      result.add(toString(sel, 0, opts))
    if not opts.minify:
      result.add(" {")
      result.add("\n")
    else:
      result.add("{")
    for decl in node.declarations:
      result.add(toString(decl, pos + opts.indent, opts))
    if not opts.minify: result.add(indent)
    result.add("}")
    if not opts.minify: result.add("\n")
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
    if not opts.minify: result.add(indent)
    result.add(node.property & ":")
    if not opts.minify: result.add(" ")
    result.add(node.rawValue)
    if node.important:
      if not opts.minify: result.add(" ")
      result.add("!important")
    result.add(";")
    if not opts.minify: result.add("\n")
  of cssComment:
    if not opts.preserveComments: return ""
    if opts.minify:
      result.add("/*" & node.text & "*/")
    else:
      result.add(indent & "/* " & node.text & " */\n")
  of cssAtRule:
    if not opts.minify: result.add(indent)
    result.add("@" & node.atName)
    if node.prelude.len > 0:
      result.add(" " & node.prelude)
    if node.atRules.len > 0 or node.blockValues.len > 0:
      if not opts.minify:
        result.add(" {")
        result.add("\n")
      else:
        result.add("{") # No space before the opening brace in minified mode
      for r in node.atRules:
        result.add(toString(r, pos + opts.indent, opts))
      for v in node.blockValues:
        result.add(repeat(' ', pos + opts.indent))
        result.add(serializeComponentValue(v))
        if not opts.minify: result.add("\n")
      if not opts.minify: result.add(indent)
      result.add("}")
      if not opts.minify: result.add("\n")
    else:
      result.add(";")
      if not opts.minify: result.add("\n")
  of cssValue:
    result.add(node.raw)

proc `$`*(style: CssStyleSheet): string =
  ## Transform CSSStyleSheet to stringified CSS representation
  for rule in style.nodes:
    result.add(toString(rule))
