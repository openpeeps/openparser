# A collection of tiny parsers and dumpers
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/openparser

## This is a high-performance CSS parser that supports CSS Syntax Level 3. It is designed to be fast, lightweight,
## and easy to use. It can parse CSS stylesheets, rulesets, declarations, and values, and provides a
## structured AST for further processing.
## 
## The parser is policy-driven, allowing you to specify which properties, at-rules, and functions are allowed or blocked.
## It also supports minification and comment preservation options.
## 
## It can be used as a standalone parser or as part of a larger CSS processing pipeline. The AST can be serialized back to CSS text,
## optionally minified.

import std/[unicode, strutils, memfiles, math]

import ./ast
import ../private/lexutils

type
  CssTokenKind* = enum
    tkIdent
    tkAtKeyword
    tkHash
    tkClass
    tkString
    tkBadString
    tkUrl
    tkBadUrl
    tkNumber
    tkPercentage
    tkDimension
    tkFunction
    tkColon
    tkSemicolon
    tkBraceOpen
    tkBraceClose
    tkParenOpen
    tkParenClose
    tkBracketOpen
    tkBracketClose
    tkComma
    tkCDO
    tkCDC
    tkIncludeMatch
    tkDashMatch
    tkPrefixMatch
    tkSuffixMatch
    tkSubstringMatch
    tkColumn
    tkDelim
    tkComment
    tkWhitespace
    tkEOF

  CssToken* = object
    kind*: CssTokenKind
    value*: string
    line*, col*, pos*: int

  CssLexer* = object
    ## A simple CSS lexer that tokenizes CSS input according to the
    ## CSS Syntax Level 3 specification.
    input*: string
      ## The entire CSS input string to be tokenized.
    data*: ptr UncheckedArray[char]
    len*: int
    line*, col*, pos*: int
    current*: char

  CssPolicy* = object
    ## Fine-grained parsing policy for CSS validation/filtering.
    allowedProperties*: seq[string]    ## If non-empty, only these properties are parsed
    blockedProperties*: seq[string]    ## Always blocked (takes precedence over allowed)
    
    allowedAtRules*: seq[string]        ## If non-empty, only these at-rules are parsed
    blockedAtRules*: seq[string]
    
    allowedFunctions*: seq[string]      ## If non-empty, only these functions are allowed in values
    blockedFunctions*: seq[string]
    
    allowImportant*: bool
    allowComments*: bool
    maxNestingDepth*: int           ## -1 = unlimited
    strictMode*: bool
      ## If true, policy violations raise errors instead of silently skipping disallowed content.

  CssParser* = object
    lexer*: CssLexer
    curr*, next*: CssToken
    policy*: CssPolicy
    depth*: int

  CSSParseError* = object of CatchableError

#
# Error handling
#
proc error*(p: var CssParser, msg: string, tok: CssToken = p.curr) =
  let atPos = tok.pos
  let atLine = tok.line
  let atCol = tok.col
  let context = getContext(p.lexer, atPos)
  raise newException(
    CSSParseError,
    ("\n" & context & "\n" & "Error ($1:$2) " % [$atLine, $atCol]) & msg
  )

proc defaultPolicy*: CssPolicy =
  result.allowImportant = true
  result.allowComments = true
  result.maxNestingDepth = -1

proc isInList*(list: seq[string], name: string): bool =
  ## Check if a name is in a list of strings, case-insensitively.
  for item in list:
    if item.cmpIgnoreCase(name) == 0:
      return true
  return false

proc isPropertyAllowed*(policy: CssPolicy, name: string): bool =
  ## Check if a property is allowed according to the policy.
  if isInList(policy.blockedProperties, name): return false
  if policy.allowedProperties.len > 0:
    return isInList(policy.allowedProperties, name)
  return true

proc isAtRuleAllowed*(policy: CssPolicy, name: string): bool =
  ## Check if an at-rule is allowed according to the policy.
  if isInList(policy.blockedAtRules, name): return false
  if policy.allowedAtRules.len > 0:
    return isInList(policy.allowedAtRules, name)
  return true

proc isFunctionAllowed*(policy: CssPolicy, name: string): bool =
  ## Check if a function is allowed according to the policy.
  if isInList(policy.blockedFunctions, name): return false
  if policy.allowedFunctions.len > 0:
    return isInList(policy.allowedFunctions, name)
  return true

proc validateValue*(val: CssValue, policy: CssPolicy): bool =
  ## Recursively check that all functions in a value are allowed.
  case val.kind
  of cvkFunction:
    if not policy.isFunctionAllowed(val.funcName): return false
    for arg in val.args:
      if not validateValue(arg, policy): return false
    return true
  of cvkBlock:
    for v in val.blockValues:
      if not validateValue(v, policy): return false
    return true
  else:
    return true

#
# Lexer helpers
#
proc isIdentStart(c: char): bool =
  c.isAlphaAscii() or c == '_' or c == '-' or c.byte > 127

proc isIdentChar(c: char): bool =
  c.isAlphaAscii() or c.isDigit() or c == '_' or c == '-' or c.byte > 127

proc isHexDigit(c: char): bool =
  c.isDigit() or c in {'a'..'f', 'A'..'F'}

proc consumeEscape(l: var CssLexer): string =
  l.advance() # skip \
  if l.current == '\n':
    return ""
  elif l.current.isHexDigit():
    var hex = ""
    for i in 0..5:
      if not l.current.isHexDigit(): break
      hex.add(l.current)
      l.advance()
    if l.current in {' ', '\t', '\n', '\r'}:
      l.advance()
    let codepoint = parseHexInt(hex)
    if codepoint == 0 or codepoint > 0x10FFFF or (codepoint >= 0xD800 and codepoint <= 0xDFFF):
      return "\uFFFD"
    return $Rune(codepoint)
  else:
    let ch = $l.current
    l.advance()
    return ch

proc consumeIdent(l: var CssLexer): string =
  var result = ""
  if l.current == '-':
    result.add('-')
    l.advance()
    if l.current == '-':
      result.add('-')
      l.advance()
  while true:
    if l.current.isIdentChar():
      result.add(l.current)
      l.advance()
    elif l.current == '\\' and l.charAt(l.pos + 1) != '\n':
      result.add(l.consumeEscape())
    else:
      break
  return result

proc consumeNumber(l: var CssLexer): string =
  var result = ""
  if l.current in {'+', '-'}:
    result.add(l.current)
    l.advance()
  while l.current.isDigit():
    result.add(l.current)
    l.advance()
  if l.current == '.' and l.charAt(l.pos + 1).isDigit():
    result.add('.')
    l.advance()
    while l.current.isDigit():
      result.add(l.current)
      l.advance()
  if l.current in {'e', 'E'} and (l.charAt(l.pos + 1).isDigit() or
     (l.charAt(l.pos + 1) in {'+', '-'} and l.charAt(l.pos + 2).isDigit())):
    result.add(l.current)
    l.advance()
    if l.current in {'+', '-'}:
      result.add(l.current)
      l.advance()
    while l.current.isDigit():
      result.add(l.current)
      l.advance()
  return result

proc lexString(l: var CssLexer, quote: char): CssToken =
  let startLine = l.line
  let startCol = l.col
  let startPos = l.pos
  l.advance() # skip opening quote
  var value = ""
  var bad = false
  while l.current != quote and l.current != '\0':
    if l.current == '\n':
      bad = true
      break
    if l.current == '\\':
      value.add(l.consumeEscape())
    else:
      value.add(l.current)
      l.advance()
  if l.current == quote:
    l.advance() # skip closing quote
  if bad:
    return CssToken(kind: tkBadString, value: value, line: startLine, col: startCol, pos: startPos)
  return CssToken(kind: tkString, value: value, line: startLine, col: startCol, pos: startPos)

#
# Tokenizer
#

proc nextToken*(l: var CssLexer): CssToken =
  l.skipWhitespace()
  let startPos = l.pos
  let startLine = l.line
  let startCol = l.col

  template tok(k: CssTokenKind, v = ""): CssToken =
    CssToken(kind: k, value: v, line: startLine, col: startCol, pos: startPos)

  if l.current == '\0':
    return tok(tkEOF)

  # CDO <!--
  if l.current == '<' and l.charAt(l.pos + 1) == '!' and
     l.charAt(l.pos + 2) == '-' and l.charAt(l.pos + 3) == '-':
    for i in 0..3: l.advance()
    return tok(tkCDO, "<!--")

  # CDC -->
  if l.current == '-' and l.charAt(l.pos + 1) == '-' and l.charAt(l.pos + 2) == '>':
    for i in 0..2: l.advance()
    return tok(tkCDC, "-->")

  # Comments
  if l.current == '/' and l.charAt(l.pos + 1) == '*':
    l.advance(); l.advance()
    let s = l.pos
    while not (l.current == '*' and l.charAt(l.pos + 1) == '/'):
      if l.current == '\0': break
      l.advance()
    let text = l.input[s ..< l.pos]
    l.advance(); l.advance()
    return tok(tkComment, text)

  # Strings
  if l.current in {'"', '\''}:
    return l.lexString(l.current)

  # Hash
  if l.current == '#':
    l.advance()
    if l.current.isIdentStart() or l.current.isDigit() or l.current in {'-', '_'} or
       (l.current == '\\' and l.charAt(l.pos + 1) != '\n'):
      let s = l.pos
      while l.current.isIdentChar() or l.current in {'-', '_'} or
            (l.current == '\\' and l.charAt(l.pos + 1) != '\n'):
        l.advance()
      return tok(tkHash, l.input[s ..< l.pos])
    else:
      return tok(tkDelim, "#")

  # At-keyword
  if l.current == '@':
    l.advance()
    if l.current.isIdentStart() or l.current in {'-', '_'} or
       (l.current == '\\' and l.charAt(l.pos + 1) != '\n'):
      let ident = l.consumeIdent()
      return tok(tkAtKeyword, ident)
    else:
      return tok(tkDelim, "@")

  # Ident or function
  if l.current.isIdentStart() or l.current in {'-', '_'} or
     (l.current == '\\' and l.charAt(l.pos + 1) != '\n'):
    let ident = l.consumeIdent()
    if l.current == '(':
      l.advance()
      return tok(tkFunction, ident)
    return tok(tkIdent, ident)

  # Numbers, dimensions, percentages
  if l.current.isDigit() or (l.current == '.' and l.charAt(l.pos + 1).isDigit()) or
     (l.current in {'+', '-'} and (l.charAt(l.pos + 1).isDigit() or
      (l.charAt(l.pos + 1) == '.' and l.charAt(l.pos + 2).isDigit()))):
    let numStr = l.consumeNumber()
    if l.current == '%':
      l.advance()
      return tok(tkPercentage, numStr & "%")
    if l.current.isIdentStart() or l.current in {'-', '_'} or
       (l.current == '\\' and l.charAt(l.pos + 1) != '\n'):
      let unitStart = l.pos
      let unit = l.consumeIdent()
      return tok(tkDimension, numStr & unit)
    return tok(tkNumber, numStr)

  # Single-char tokens and match operators
  case l.current
  of '{': l.advance(); return tok(tkBraceOpen, "{")
  of '}': l.advance(); return tok(tkBraceClose, "}")
  of '(': l.advance(); return tok(tkParenOpen, "(")
  of ')': l.advance(); return tok(tkParenClose, ")")
  of '[': l.advance(); return tok(tkBracketOpen, "[")
  of ']': l.advance(); return tok(tkBracketClose, "]")
  of ':': l.advance(); return tok(tkColon, ":")
  of ';': l.advance(); return tok(tkSemicolon, ";")
  of ',': l.advance(); return tok(tkComma, ",")
  of '.':
    if l.charAt(l.pos + 1).isDigit():
      let numStr = l.consumeNumber()
      if l.current == '%':
        l.advance()
        return tok(tkPercentage, numStr & "%")
      if l.current.isIdentStart() or l.current in {'-', '_'} or
         (l.current == '\\' and l.charAt(l.pos + 1) != '\n'):
        let unit = l.consumeIdent()
        return tok(tkDimension, numStr & unit)
      return tok(tkNumber, numStr)
    else:
      l.advance()
      let s = l.pos
      while l.current.isAlphaNumeric() or l.current == '-': l.advance()
      return tok(tkClass, l.input[s ..< l.pos])
  of '~':
    if l.charAt(l.pos + 1) == '=':
      l.advance(); l.advance()
      return tok(tkIncludeMatch, "~=")
  of '|':
    if l.charAt(l.pos + 1) == '=':
      l.advance(); l.advance()
      return tok(tkDashMatch, "|=")
    elif l.charAt(l.pos + 1) == '|':
      l.advance(); l.advance()
      return tok(tkColumn, "||")
  of '^':
    if l.charAt(l.pos + 1) == '=':
      l.advance(); l.advance()
      return tok(tkPrefixMatch, "^=")
  of '$':
    if l.charAt(l.pos + 1) == '=':
      l.advance(); l.advance()
      return tok(tkSuffixMatch, "$=")
  of '*':
    if l.charAt(l.pos + 1) == '=':
      l.advance(); l.advance()
      return tok(tkSubstringMatch, "*=")
  else:
    discard

  # Delimiters
  let ch = $l.current
  l.advance()
  return tok(tkDelim, ch)

#
# Parser helpers
#

proc advance(p: var CssParser) {.inline.} =
  p.curr = p.next
  p.next = p.lexer.nextToken()

proc expectWalk(p: var CssParser, kind: CssTokenKind) =
  if p.next.kind != kind:
    p.error("Expected " & $kind & " but got " & $p.next.kind & " (" & p.next.value & ")", p.next)
  p.advance()

proc collectComments(p: var CssParser): seq[CssNode] =
  while p.next.kind == tkComment:
    result.add(CssNode(kind: cssComment, text: p.next.value))
    p.advance()

proc skipDeclaration(p: var CssParser) =
  while p.next.kind notin {tkSemicolon, tkBraceClose, tkEOF}:
    p.advance()
  if p.next.kind == tkSemicolon:
    p.advance()

proc skipAtRuleBlock(p: var CssParser) =
  p.expectWalk(tkBraceOpen)
  var depth = 1
  while depth > 0 and p.next.kind != tkEOF:
    if p.next.kind == tkBraceOpen: inc depth
    elif p.next.kind == tkBraceClose: dec depth
    p.advance()

#
# Component value consumption (CSS Syntax Level 3)
#

proc consumeComponentValue(p: var CssParser): CssValue

proc consumeSimpleBlock(p: var CssParser, closeKind: CssTokenKind, closeChar: char): seq[CssValue] =
  p.advance() # consume opening token
  while p.next.kind notin {closeKind, tkEOF}:
    result.add(p.consumeComponentValue())
  if p.next.kind == closeKind:
    p.advance()
  else:
    p.error("Unclosed block, expected " & $closeKind, p.next)

proc consumeFunction(p: var CssParser, name: string): CssValue =
  p.advance() # consume function token
  var args: seq[CssValue] = @[]
  while p.next.kind notin {tkParenClose, tkEOF}:
    args.add(p.consumeComponentValue())
  if p.next.kind == tkParenClose:
    p.advance()
  else:
    p.error("Unclosed function, expected )", p.next)
  return CssValue(kind: cvkFunction, funcName: name, args: args)

proc consumeComponentValue(p: var CssParser): CssValue =
  case p.next.kind
  of tkBraceOpen:
    let vals = p.consumeSimpleBlock(tkBraceClose, '}')
    return CssValue(kind: cvkBlock, blockKind: '{', blockValues: vals)
  of tkParenOpen:
    let vals = p.consumeSimpleBlock(tkParenClose, ')')
    return CssValue(kind: cvkBlock, blockKind: '(', blockValues: vals)
  of tkBracketOpen:
    let vals = p.consumeSimpleBlock(tkBracketClose, ']')
    return CssValue(kind: cvkBlock, blockKind: '[', blockValues: vals)
  of tkFunction:
    let name = p.next.value
    return p.consumeFunction(name)
  of tkNumber:
    let val = p.next.value
    p.advance()
    return CssValue(kind: cvkNumber, numValue: val, numFloat: parseFloat(val))
  of tkPercentage:
    let val = p.next.value
    p.advance()
    var numPart = ""
    for ch in val:
      if ch == '%': break
      numPart.add(ch)
    return CssValue(kind: cvkPercentage, pctValue: val, pctFloat: parseFloat(numPart))
  of tkDimension:
    let val = p.next.value
    p.advance()
    var numEnd = 0
    var i = 0
    if i < val.len and val[i] in {'+', '-'}: inc i
    while i < val.len and val[i].isDigit(): inc i
    if i < val.len and val[i] == '.':
      inc i
      while i < val.len and val[i].isDigit(): inc i
    if i < val.len and val[i] in {'e', 'E'}:
      let expStart = i
      inc i
      if i < val.len and val[i] in {'+', '-'}: inc i
      if i < val.len and val[i].isDigit():
        while i < val.len and val[i].isDigit(): inc i
      else:
        i = expStart
    numEnd = i
    let numPart = val[0 ..< numEnd]
    let unitPart = val[numEnd ..< val.len]
    return CssValue(kind: cvkDimension, dimValue: val,
            dimUnit: unitPart, dimFloat: parseFloat(numPart))
  of tkString:
    let val = p.next.value
    p.advance()
    return CssValue(kind: cvkString, strValue: val)
  of tkIdent:
    let val = p.next.value
    p.advance()
    return CssValue(kind: cvkIdent, identValue: val)
  of tkHash:
    let val = p.next.value
    p.advance()
    return CssValue(kind: cvkHash, hashValue: val, hashFlag: "id")
  of tkClass:
    let val = p.next.value
    p.advance()
    return CssValue(kind: cvkPreserved, preservedValue: "." & val)
  of tkUrl:
    let val = p.next.value
    p.advance()
    return CssValue(kind: cvkUrl, urlValue: val)
  of tkDelim:
    let val = p.next.value
    p.advance()
    return CssValue(kind: cvkPreserved, preservedValue: val)
  of tkColon, tkSemicolon, tkComma,
     tkIncludeMatch, tkDashMatch, tkPrefixMatch, tkSuffixMatch, tkSubstringMatch, tkColumn:
    let val = p.next.value
    p.advance()
    return CssValue(kind: cvkPreserved, preservedValue: val)
  of tkComment:
    let val = p.next.value
    p.advance()
    return CssValue(kind: cvkComment, commentText: val)
  of tkBadString:
    let val = p.next.value
    p.advance()
    return CssValue(kind: cvkString, strValue: val)
  of tkBadUrl:
    let val = p.next.value
    p.advance()
    return CssValue(kind: cvkUrl, urlValue: val)
  of tkAtKeyword:
    let val = p.next.value
    p.advance()
    return CssValue(kind: cvkPreserved, preservedValue: "@" & val)
  of tkCDO, tkCDC:
    p.advance()
    return CssValue(kind: cvkPreserved, preservedValue: "")
  of tkWhitespace:
    p.advance()
    return CssValue(kind: cvkPreserved, preservedValue: " ")
  else:
    let val = p.next.value
    p.advance()
    return CssValue(kind: cvkPreserved, preservedValue: val)

#
# Value parsing
#

proc parseValue(p: var CssParser): CssNode =
  var components: seq[CssValue] = @[]
  while p.next.kind notin {tkSemicolon, tkBraceClose, tkEOF}:
    components.add(p.consumeComponentValue())
  
  let raw = serializeComponentList(components)
  return CssNode(kind: cssValue, raw: raw, components: components)

#
# Declaration parsing
#

proc parseDeclaration(p: var CssParser): CssNode =
  # Parse a CSS declaration: property: value; with optional !important.
  if p.next.kind != tkIdent:
    p.error("Expected property name, got " & $p.next.kind, p.next)
  
  let property = p.next.value
  p.advance()
  
  # Policy: block disallowed properties
  if not p.policy.isPropertyAllowed(property):
    if p.policy.strictMode: p.error("Property '" & property & "' is disallowed by policy", p.curr)
    p.skipDeclaration()
    return nil

  if p.next.kind != tkColon:
    p.error("Expected ':' after property name", p.next)
  p.advance()
  
  var components: seq[CssValue] = @[]
  while p.next.kind notin {tkSemicolon, tkBraceClose, tkEOF}:
    components.add(p.consumeComponentValue())
  
  # Check for !important
  var important = false
  if components.len >= 2:
    var lastIdx = components.len - 1
    while lastIdx >= 0 and components[lastIdx].kind == cvkPreserved and 
          components[lastIdx].preservedValue in [" ", "\t", "\n", "\r"]:
      dec lastIdx
    
    if lastIdx >= 1 and components[lastIdx].kind == cvkIdent and 
       components[lastIdx].identValue.cmpIgnoreCase("important") == 0:
      var secondLastIdx = lastIdx - 1
      while secondLastIdx >= 0 and components[secondLastIdx].kind == cvkPreserved and
            components[secondLastIdx].preservedValue in [" ", "\t", "\n", "\r"]:
        dec secondLastIdx
      
      if secondLastIdx >= 0 and components[secondLastIdx].kind == cvkPreserved and
         components[secondLastIdx].preservedValue == "!":
        important = true
        components.setLen(secondLastIdx)
  
  # Policy: strip !important if disallowed
  if not p.policy.allowImportant and important:
    if p.policy.strictMode: p.error("!important is disallowed by policy", p.curr)
    important = false

  let raw = serializeComponentList(components)
  # Policy: validate functions in value
  for comp in components:
    if not validateValue(comp, p.policy):
      if p.policy.strictMode: p.error("Disallowed function in value", p.curr)
      p.skipDeclaration()
      return nil
  if p.next.kind == tkSemicolon:
    p.advance()  
  return CssNode(kind: cssDeclaration, property: property,
                    rawValue: raw, valueComponents: components, important: important)

#
# Selector parsing
#

proc parseSelectors(p: var CssParser): seq[CssNode] =
  var parts: seq[string] = @[]
  var kinds: seq[CSSSelectorKind] = @[]
  var nodes: seq[CssNode] = @[]

  proc flush() =
    if parts.len > 0:
      var chosenKind = selectorType
      for i in 0 ..< kinds.len:
        if parts[i] notin [">", "+", "~", "*", " ", "||"]:
          chosenKind = kinds[i]
          break
      nodes.add(CssNode(kind: cssSelector, selectorKind: chosenKind, parts: parts))
      parts = @[]
      kinds = @[]

  while p.next.kind notin {tkBraceOpen, tkEOF}:
    case p.next.kind
    of tkIdent:
      parts.add(p.next.value)
      kinds.add(selectorType)
      p.advance()
    of tkHash:
      parts.add("#" & p.next.value)
      kinds.add(selectorId)
      p.advance()
    of tkClass:
      parts.add("." & p.next.value)
      kinds.add(selectorClass)
      p.advance()
    of tkColon:
      p.advance()
      if p.next.kind == tkColon:
        p.advance()
        if p.next.kind notin {tkIdent, tkFunction}:
          p.error("Expected identifier or function after ::", p.next)
        if p.next.kind == tkFunction:
          let funcName = p.next.value
          let funcNode = p.consumeComponentValue()
          parts.add("::" & funcName & serializeComponentValue(funcNode))
          kinds.add(selectorPseudoElement)
        else:
          parts.add("::" & p.next.value)
          kinds.add(selectorPseudoElement)
          p.advance()
      else:
        if p.next.kind notin {tkIdent, tkFunction}:
          p.error("Expected identifier or function after :", p.next)
        if p.next.kind == tkFunction:
          let funcName = p.next.value
          let funcNode = p.consumeComponentValue()
          parts.add(":" & funcName & serializeComponentValue(funcNode))
          kinds.add(selectorPseudo)
        else:
          parts.add(":" & p.next.value)
          kinds.add(selectorPseudo)
          p.advance()
    of tkBracketOpen:
      var attr = "["
      kinds.add(selectorAttribute)
      p.advance()
      while p.next.kind notin {tkBracketClose, tkEOF}:
        case p.next.kind
        of tkIdent, tkString, tkNumber, tkDelim:
          attr.add(p.next.value)
          p.advance()
        of tkIncludeMatch:
          attr.add("~=")
          p.advance()
        of tkDashMatch:
          attr.add("|=")
          p.advance()
        of tkPrefixMatch:
          attr.add("^=")
          p.advance()
        of tkSuffixMatch:
          attr.add("$=")
          p.advance()
        of tkSubstringMatch:
          attr.add("*=")
          p.advance()
        of tkColumn:
          attr.add("||")
          p.advance()
        else:
          attr.add(p.next.value)
          p.advance()
      if p.next.kind != tkBracketClose:
        p.error("Unclosed attribute selector", p.next)
      attr.add("]")
      p.advance()
      parts.add(attr)
    of tkComma:
      flush()
      p.advance()
    of tkDelim:
      case p.next.value
      of "*":
        parts.add("*")
        kinds.add(selectorUniversal)
        p.advance()
      of ">", "+", "~":
        parts.add(p.next.value)
        kinds.add(selectorCombinator)
        p.advance()
      of "|":
        p.advance()
        if p.next.kind == tkIdent:
          parts.add("|" & p.next.value)
          kinds.add(selectorType)
          p.advance()
        else:
          parts.add("|")
          kinds.add(selectorCombinator)
      else:
        p.advance()
    of tkWhitespace:
      # Whitespace between simple selectors is descendant combinator
      if parts.len > 0 and parts[^1] != " ":
        parts.add(" ")
        kinds.add(selectorCombinator)
      p.advance()
    else:
      p.advance()
  flush()
  nodes

#
# Rule set parsing
#

proc parseRuleSet(p: var CssParser): CssNode =
  # Parse a CSS rule set: selectors { declarations }
  let selectors = p.parseSelectors()
  p.expectWalk(tkBraceOpen)

  # Policy: nesting depth check
  if p.policy.maxNestingDepth >= 0 and p.depth >= p.policy.maxNestingDepth:
    if p.policy.strictMode: p.error("Nesting depth exceeded maximum of " & $p.policy.maxNestingDepth, p.curr)
    # Skip entire block
    var depth = 1
    while depth > 0 and p.next.kind != tkEOF:
      if p.next.kind == tkBraceOpen: inc depth
      elif p.next.kind == tkBraceClose: dec depth
      p.advance()
    return CssNode(kind: cssRuleSet, selectors: selectors, declarations: @[])
  
  inc p.depth
  var declarations: seq[CssNode] = @[]
  declarations.add(p.collectComments())
  while p.next.kind notin {tkBraceClose, tkEOF}:
    if p.next.kind == tkIdent:
      declarations.add(p.parseDeclaration())
    elif p.next.kind == tkComment:
      declarations.add(CssNode(kind: cssComment, text: p.next.value))
      p.advance()
    else:
      p.advance()
    declarations.add(p.collectComments())
  p.expectWalk(tkBraceClose)
  return CssNode(kind: cssRuleSet, selectors: selectors, declarations: declarations)

#
# At-rule parsing
#

proc parseAtRule(p: var CssParser): CssNode =
  ## Parse @-rules following CSS Syntax Level 3.
  p.advance() # consume '@' delim or at-keyword
  
  var name: string
  if p.curr.kind == tkAtKeyword:
    name = p.curr.value
  elif p.curr.kind == tkDelim and p.curr.value == "@":
    if p.next.kind != tkIdent:
      p.error("Expected identifier after @", p.next)
    p.advance()
    name = p.curr.value
  else:
    p.error("Expected at-keyword", p.curr)
  
  # Policy: block disallowed at-rules
  if not p.policy.isAtRuleAllowed(name):
    if p.policy.strictMode: p.error("At-rule '" & name & "' is disallowed by policy", p.curr)
    while p.next.kind notin {tkBraceOpen, tkSemicolon, tkEOF}:
      p.advance()
    if p.next.kind == tkSemicolon:
      p.advance()
      return nil
    if p.next.kind == tkBraceOpen:
      p.skipAtRuleBlock()
    return nil

  # Collect prelude (existing code)
  var preludeParts: seq[string] = @[]
  while p.next.kind notin {tkBraceOpen, tkSemicolon, tkEOF}:
    preludeParts.add(p.next.value)
    p.advance()

  var prelude = ""
  for i, part in preludeParts:
    if i > 0 and part.len > 0 and preludeParts[i-1].len > 0:
      let prev = preludeParts[i-1]
      if prev[^1].isAlphaNumeric() and part[0].isAlphaNumeric():
        prelude.add(" ")
    prelude.add(part)
  prelude = prelude.strip()
  
  if p.next.kind == tkSemicolon:
    p.advance()
    return CssNode(kind: cssAtRule, atName: name, prelude: prelude, atRules: @[])
  
  if p.next.kind == tkSemicolon:
    p.advance()
    return CssNode(kind: cssAtRule, atName: name, prelude: prelude, atRules: @[])
  
  if p.next.kind == tkBraceOpen:
    p.expectWalk(tkBraceOpen)
    
    if name in ["layer", "media", "supports", "document", "container"]:
      var inner: seq[CssNode] = @[]
      inner.add(p.collectComments())
      while p.next.kind notin {tkBraceClose, tkEOF}:
        if p.next.kind == tkComment:
          if p.policy.allowComments:
            inner.add(CssNode(kind: cssComment, text: p.next.value))
          p.advance()
        elif p.next.kind == tkDelim and p.next.value == "@":
          let child = p.parseAtRule()
          if child != nil: inner.add(child)
        elif p.next.kind == tkAtKeyword:
          let child = p.parseAtRule()
          if child != nil: inner.add(child)
        else:
          inner.add(p.parseRuleSet())
        inner.add(p.collectComments())
      p.expectWalk(tkBraceClose)
      return CssNode(kind: cssAtRule, atName: name, prelude: prelude, atRules: inner)
    
    if name == "keyframes":
      var inner: seq[CssNode] = @[]
      inner.add(p.collectComments())
      while p.next.kind notin {tkBraceClose, tkEOF}:
        if p.next.kind == tkComment:
          if p.policy.allowComments:
            inner.add(CssNode(kind: cssComment, text: p.next.value))
          p.advance()
        else:
          inner.add(p.parseRuleSet())
        inner.add(p.collectComments())
      p.expectWalk(tkBraceClose)
      return CssNode(kind: cssAtRule, atName: name, prelude: prelude, atRules: inner)
    
    var values: seq[CssValue] = @[]
    while p.next.kind notin {tkBraceClose, tkEOF}:
      values.add(p.consumeComponentValue())
    p.expectWalk(tkBraceClose)
    return CssNode(kind: cssAtRule, atName: name, prelude: prelude, blockValues: values)
  
  p.error("Expected ';' or '{' after at-rule prelude", p.next)

#
# Root parsing
#

proc parseRoot(p: var CssParser): seq[CssNode] =
  # Parse the root of a CSS stylesheet, collecting comments, at-rules, and rule sets.
  result.add(p.collectComments())
  while p.next.kind != tkEOF:
    if p.next.kind == tkComment:
      if p.policy.allowComments:
        result.add(CssNode(kind: cssComment, text: p.next.value))
      p.advance()
    elif p.next.kind == tkDelim and p.next.value == "@":
      let r = p.parseAtRule()
      if r != nil: result.add(r)
    elif p.next.kind == tkAtKeyword:
      let r = p.parseAtRule()
      if r != nil: result.add(r)
    else:
      result.add(p.parseRuleSet())
    result.add(p.collectComments())

proc parseCss*(input: string, policy: CssPolicy = defaultPolicy()): CssStyleSheet =
  ## Parse a CSS string into an AST
  var lexer = CssLexer(
    input: input,
    len: input.len,
    line: 1, col: 0, pos: 0,
    current: if input.len > 0: input[0] else: '\0'
  )
  var parser = CssParser(
    lexer: lexer,
    policy: policy,
    depth: 0
  )
  parser.next = parser.lexer.nextToken()
  result = CssStyleSheet(nodes: parser.parseRoot())