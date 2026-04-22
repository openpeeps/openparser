# A collection of tiny parsers and dumpers
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/openparser

## This module provides a YAML parser and serializer for Nim.
## 
## It can convert Nim objects, tables and arrays to YAML format
## and parse YAML strings into Nim data structures. 
## 
## If your Nim data structures contains doc-comments, they will be
## included as comments in the generated YAML output. This allows you to
## write self-documenting Nim code that can be easily converted to YAML
## configuration files

import std/[tables, strutils, macros]

import ./private/types
import ./json

type
  YamlTokenKind* = enum
    ytkEOF = "EOF"
    ytkIdentifier = "Identifier"
    ytkColon = ":"
    ytkComma = ","
    ytkDash = "-"
    ytkLB = "["
    ytkRB = "]"
    ytkLC = "{"
    ytkRC = "}"
    ytkPipe = "|"
    ytkGT = ">"
    ytkQuote = "\""
    ytkSingleQuote = "'"
    ytkString
    ytkFloat
    ytkInteger
    ytkBoolean
    ytkComment
    ytkUnknown

  YamlToken* = ref object
    ## Represents a lexical token produced by the YAML lexer
    kind*: YamlTokenKind
    value*: string
    line*: int
    col*: int
    pos*: int
    wsno*: int
    indent*: int

  YamlLexer* = object
    ## Performs lexical analysis on a YAML input string,
    ## producing tokens for the parser
    input: string
    pos: int
    len: int
    line, col: int
    current: char

  YamlParser* = object
    ## Parses a sequence of tokens from the YamlLexer to build a YAMLObject
    lex: YamlLexer
    prev, curr, next: YamlToken

  YAML* = string
    ## A simple alias for YAML strings

  OpenParserYamlError* = object of CatchableError
    ## Exception type for errors encountered during YAML parsing or dumping

proc newYamlLexer*(input: string): YamlLexer =
  ## Create a new YamlLexer for the given input string
  YamlLexer(input: input, len: input.len, line: 1, col: 1)

proc charAt(l: YamlLexer, idx: int): char {.inline.} =
  if idx < 0 or idx >= l.len: return '\0'
  else: return l.input[idx]

const
  invalidToken = "Invalid token `$1`"
  errorEndOfFile = "Unexpected EOF while parsing `$1`"
  unexpectedToken = "Unexpected token `$1`"
  unexpectedTokenExpected = "Got `$1`, expected $2"
  unexpectedChar = "Unexpected character `$1`"


proc getContext(l: YamlLexer, posOverride: int = -1): string =
  # Show the full current line and place caret at exact token position.
  let rawPos = if posOverride >= 0: posOverride else: l.pos
  let atPos = max(0, min(rawPos, l.len))

  var lineStart = atPos
  while lineStart > 0 and l.charAt(lineStart - 1) != '\n':
    dec lineStart

  var lineEnd = atPos
  while lineEnd < l.len and l.charAt(lineEnd) notin {'\n', '\r'}:
    inc lineEnd

  var snippet: string
  if l.input.len > 0:
    snippet = l.input[lineStart ..< lineEnd]
  else:
    snippet = newStringOfCap(max(0, lineEnd - lineStart))
    for i in lineStart ..< lineEnd:
      snippet.add(l.charAt(i))

  let markerPos = max(0, min(snippet.len, atPos - lineStart))
  result = snippet & "\n" & " ".repeat(markerPos) & "^"

proc error(l: var YamlLexer, msg: string) =
  # Raise a lexer error
  let context = getContext(l)
  raise newException(OpenParserYamlError, ("\n" & context & "\n" & "Error ($1:$2) " % [$l.line, $l.col]) & msg)

proc error(p: var YamlParser, msg: string) =
  # Prefer current token coordinates over lexer cursor (lookahead-safe).
  var atPos = p.lex.pos
  var atLine = p.lex.line
  var atCol = p.lex.col

  if p.curr != nil:
    atPos = p.curr.pos
    atLine = p.curr.line
    atCol = p.curr.col

  let context = getContext(p.lex, atPos)
  raise newException(
    OpenParserYamlError,
    ("\n" & context & "\n" & "Error ($1:$2) " % [$atLine, $atCol]) & msg
  )

proc advance(l: var YamlLexer) =
  if l.pos < l.len - 1:
    inc l.pos
    l.current = l.charAt(l.pos)
    inc l.col
  else:
    l.pos = l.len
    l.current = '\0'

proc lineIndentAt(l: YamlLexer, idx: int): int {.inline.} =
  ## Indent of the logical line containing idx (spaces/tabs at line start).
  if idx < 0 or idx >= l.len: return 0

  var start = idx
  while start > 0 and l.charAt(start - 1) notin {'\n', '\r'}:
    dec start

  var i = start
  while true:
    case l.charAt(i)
    of ' ':
      inc result
      inc i
    of '\t':
      result += 2
      inc i
    else:
      break

proc skipWhitespace(l: var YamlLexer, wsBeforeToken: var int): int =
  # Skip whitespace/newlines
  wsBeforeToken = 0
  while true:
    case l.current
    of ' ':
      inc wsBeforeToken
      advance(l)
    of '\t':
      wsBeforeToken += 2
      advance(l)
    of '\n':
      inc l.line
      l.col = 0
      advance(l)
      wsBeforeToken = 0
    of '\r':
      advance(l)
      wsBeforeToken = 0
    else:
      break
  if l.current == '\0':
    return 0
  result = lineIndentAt(l, l.pos)

proc readIdentifier(l: var YamlLexer): string =
  # Read an unquoted identifier (e.g. for keys or unquoted values)
  while l.current in {'a'..'z', 'A'..'Z', '0'..'9', '_', '-'}:
    result.add(l.current)
    advance(l)

proc readComment(l: var YamlLexer): string =
  # Read from '#' to end of line (excluding newline)
  advance(l) # skip '#'
  while l.current notin {'\0', '\n', '\r'}:
    result.add(l.current)
    advance(l)

proc readString(l: var YamlLexer, quote: char): string =
  # read a quoted string, handling escape sequences for double quotes
  while true:
    if l.current == '\0':
      raise newException(ValueError, "Unterminated string literal")
    if l.current == quote:
      advance(l)
      break
    if quote == '"' and l.current == '\\':
      advance(l)
      case l.current
      of '"': result.add('"')
      of '\\': result.add('\\')
      of 'n': result.add('\n')
      of 'r': result.add('\r')
      of 't': result.add('\t')
      else:
        raise newException(ValueError, "Invalid escape sequence: \\" & $(l.current))
    else:
      result.add(l.current)
    advance(l)

proc readNumber(l: var YamlLexer, kind: var YamlTokenKind): string =
  result = ""
  kind = ytkInteger

  if l.current == '-':
    result.add('-')
    advance(l)

  while l.current in {'0'..'9'}:
    result.add(l.current)
    advance(l)

  if l.current == '.':
    kind = ytkFloat
    result.add('.')
    advance(l)
    while l.current in {'0'..'9'}:
      result.add(l.current)
      advance(l)

  if l.current in {'e', 'E'}:
    kind = ytkFloat
    result.add(l.current)
    advance(l)
    if l.current in {'+', '-'}:
      result.add(l.current)
      advance(l)
    while l.current in {'0'..'9'}:
      result.add(l.current)
      advance(l)

proc tokenText(t: YamlToken): string =
  case t.kind
  of ytkIdentifier, ytkString, ytkFloat, ytkInteger: t.value
  else: $t.kind

let tokens = {
  ':': ytkColon,
  ',': ytkComma,
  '-': ytkDash,
  '[': ytkLB,
  ']': ytkRB,
  '{': ytkLC,
  '}': ytkRC,
  '|': ytkPipe,
  '>': ytkGT,
}.toTable

proc nextToken*(p: var YamlParser): YamlToken =
  ## Lexical analysis to produce the next token from the input
  var wsBefore = 0
  let lineIndent = skipWhitespace(p.lex, wsBefore)

  result = YamlToken()
  result.line = p.lex.line
  result.col = p.lex.col
  result.pos = p.lex.pos
  result.indent = lineIndent
  result.wsno = wsBefore

  case p.lex.current
  of '\0':
    result.kind = ytkEOF
  of ':', ',', '[', ']', '{', '}', '|', '>':
    result.kind = tokens[p.lex.current]
    advance(p.lex)
  of '-', '0'..'9':
    if p.lex.current == '-' and not (p.lex.charAt(p.lex.pos + 1) in {'0'..'9'}):
      result.kind = ytkDash
      advance(p.lex)
    else:
      result.value = p.lex.readNumber(result.kind)
  of '"', '\'':
    let q = p.lex.current
    advance(p.lex)
    result.kind = ytkString
    result.value = p.lex.readString(q)
  of 'a'..'z', 'A'..'Z', '_':
    result.kind = ytkIdentifier
    result.value = p.lex.readIdentifier()
  of '#':
    result.kind = ytkComment
    result.value = p.lex.readComment().strip()
  else:
    result.kind = ytkString
    result.value = $p.lex.current
    if result.value.len == 0:
      raise newException(ValueError, "Unexpected character: '" & $p.lex.current & "'")
    advance(p.lex)

#
# Parsing logic to build a YAMLObject
#
type
  YamlValueKind* = enum
    yamlInteger
    yamlFloat
    yamlString
    yamlBoolean
    yamlObject
    yamlArray
    yamlNull

  YamlNode* {.acyclic.} = object
    case kind*: YamlValueKind
    of yamlInteger:
      intValue*: int64
    of yamlFloat:
      floatValue*: float64
    of yamlString:
      strValue*: string
    of yamlBoolean:
      boolValue*: bool
    of yamlNull: discard
    of yamlObject:
      objValue*: OrderedTableRef[string, YamlNode]
    of yamlArray:
      arrValue*: seq[YamlNode]

  YAMLObject* = OrderedTableRef[string, YamlNode]
    ## Represents a simple 

proc advance(p: var YamlParser) {.inline.} =
  p.prev = p.curr
  p.curr = p.next
  p.next = p.nextToken()
  while p.curr.kind == ytkComment:
    p.curr = p.next
    p.next = p.nextToken()

proc getScalarValue(t: YamlToken): YamlNode =
  # Convert a scalar token to a YamlNode based on its kind
  case t.kind
  of ytkString:
    result = YamlNode(kind: yamlString, strValue: t.value)
  of ytkFloat:
    result = YamlNode(kind: yamlFloat, floatValue: parseFloat(t.value))
  of ytkInteger:
    result = YamlNode(kind: yamlInteger, intValue: parseInt(t.value))
  of ytkIdentifier:
    let v = t.value.toLowerAscii()
    if v == "true":
      result = YamlNode(kind: yamlBoolean, boolValue: true)
    elif v == "false":
      result = YamlNode(kind: yamlBoolean, boolValue: false)
    elif v == "null" or v == "~":
      result = YamlNode(kind: yamlNull)
    else:
      result = YamlNode(kind: yamlString, strValue: t.value)
  else:
    raise newException(ValueError, "Expected scalar token")

proc parseScalar(p: var YamlParser): YamlNode =
  case p.curr.kind
  of ytkString, ytkIdentifier, ytkFloat, ytkInteger:
    result = getScalarValue(p.curr)
    advance(p)
  else:
    raise newException(ValueError,
      "Expected scalar at line " & $p.curr.line & ", col " & $p.curr.col)

proc parseValue(p: var YamlParser, parentIndent: int): YamlNode
proc parseMapping(p: var YamlParser, indent: int): YAMLObject
proc parseSequence(p: var YamlParser, indent: int): seq[YamlNode]
proc parseInlineArray(p: var YamlParser): YamlNode
proc parseInlineObject(p: var YamlParser): YamlNode

proc parsePlainUnquoted(p: var YamlParser): YamlNode =
  ## Parse plain scalar on the same line (e.g.: title: hello world)
  let lineNo = p.curr.line
  var parts: seq[string] = @[]
  var firstTok = p.curr

  while p.curr.kind in {ytkIdentifier, ytkInteger, ytkFloat} and p.curr.line == lineNo:
    parts.add(p.curr.value)
    advance(p)

  if parts.len == 1:
    # preserve bool/null/integer/float behavior
    result = getScalarValue(firstTok)
  else:
    result = YamlNode(kind: yamlString, strValue: parts.join(" "))

proc parseBlockString(p: var YamlParser, parentIndent: int, folded: bool): YamlNode =
  ## Parse YAML block scalar after '|' or '>'
  ## Current token must be ytkPipe or ytkGT.
  let markerLine = p.curr.line
  advance(p) # consume '|' or '>'

  var str: string
  var lastLine = -1

  while p.curr.kind != ytkEOF and p.curr.indent > parentIndent:
    if p.curr.line == markerLine:
      advance(p)
      continue

    if lastLine != -1 and p.curr.line != lastLine:
      # New line, don't add indent for the first token
      str.add("\n")
    elif lastLine != -1:
      # Same line, add indent before token
      str.add(repeat(' ', p.curr.wsno))

    str.add(tokenText(p.curr))
    lastLine = p.curr.line
    advance(p)

  result = YamlNode(kind: yamlString, strValue: str)

proc parseInlineArray(p: var YamlParser): YamlNode =
  advance(p) # ytkLB
  var items: seq[YamlNode] = @[]
  while p.curr.kind != ytkRB:
    if p.curr.kind == ytkEOF:
      raise newException(ValueError, "Unterminated inline array")
    items.add(parseValue(p, -1))
    if p.curr.kind == ytkComma:
      advance(p)
    elif p.curr.kind != ytkRB:
      raise newException(ValueError, "Expected ',' or ']' in inline array")
  advance(p) # ytkRB
  result = YamlNode(kind: yamlArray, arrValue: items)

proc parseInlineObject(p: var YamlParser): YamlNode =
  advance(p) # ytkLC
  var obj = newOrderedTable[string, YamlNode]()

  while p.curr.kind != ytkRC:
    if p.curr.kind == ytkEOF:
      raise newException(ValueError, "Unterminated inline object")
    if p.curr.kind notin {ytkIdentifier, ytkString}:
      raise newException(ValueError, "Expected key in inline object")

    let key = p.curr.value
    advance(p)

    if p.curr.kind != ytkColon:
      raise newException(ValueError, "Expected ':' in inline object")
    advance(p)

    obj[key] = parseValue(p, -1)

    if p.curr.kind == ytkComma: advance(p)
    elif p.curr.kind != ytkRC:
      raise newException(ValueError, "Expected ',' or '}' in inline object")

  advance(p) # consume '}'
  result = YamlNode(kind: yamlObject, objValue: obj)

proc parseSequence(p: var YamlParser, indent: int): seq[YamlNode] =
  # Parse a YAML sequence (list) starting with '-'. Uses indentation to
  # determine nesting level. Current token must be ytkDash.
  while p.curr.kind == ytkDash and p.curr.indent == indent:
    let dashLine = p.curr.line
    advance(p) # ytkDash
    if p.curr.kind == ytkEOF:
      result.add(YamlNode(kind: yamlNull))
      break

    if p.curr.line == dashLine:
      if p.curr.kind == ytkIdentifier and p.next.kind == ytkColon:
        let obj = parseMapping(p, p.curr.indent)
        result.add(YamlNode(kind: yamlObject, objValue: obj))
      else:
        result.add(parseValue(p, indent))
      continue
    
    if p.curr.indent > indent:
      result.add(parseValue(p, indent))
    else:
      result.add(YamlNode(kind: yamlNull))

proc parseMapping(p: var YamlParser, indent: int): YAMLObject =
  result = newOrderedTable[string, YamlNode]()
  while p.curr.kind == ytkIdentifier and p.curr.indent >= indent:
    let key = p.curr.value
    advance(p)
    
    if p.curr.kind != ytkColon:
      raise newException(ValueError,
        "Expected ':' after key '" & key & "' at line " & $p.curr.line & ", col " & $p.curr.col)
    
    let colonLine = p.curr.line
    advance(p)

    if p.curr.kind == ytkEOF:
      result[key] = YamlNode(kind: yamlNull)
      break
    
    # Handle value on the same line (e.g. "key: value")
    if p.curr.line == colonLine:
      result[key] = parseValue(p, indent)
      continue
    
    # Handle block string with '|' or '>'
    if p.curr.kind == ytkGT or p.curr.kind == ytkPipe:
      result[key] = parseBlockString(p, indent, folded = (p.curr.kind == ytkGT))
      continue
    
    # Handle nested mapping or sequence
    if p.curr.indent > indent:
      result[key] = parseValue(p, indent)
    else:
      result[key] = YamlNode(kind: yamlNull)

proc parseValue(p: var YamlParser, parentIndent: int): YamlNode =
  case p.curr.kind
  of ytkIdentifier:
    if p.next.kind == ytkColon and p.curr.indent > parentIndent:
      let obj = parseMapping(p, p.curr.indent)
      result = YamlNode(kind: yamlObject, objValue: obj)
    else:
      result = parsePlainUnquoted(p)
  of ytkString, ytkFloat, ytkInteger:
    result = parseScalar(p)
  of ytkLB:
    result = parseInlineArray(p)
  of ytkLC:
    result = parseInlineObject(p)
  of ytkDash:
    let arr = parseSequence(p, p.curr.indent) # use indentation, not wsno
    result = YamlNode(kind: yamlArray, arrValue: arr)
  of ytkPipe:
    result = parseBlockString(p, parentIndent, folded = false)
  of ytkGT:
    result = parseBlockString(p, parentIndent, folded = true)
  else:
    raise newException(ValueError,
      "Unexpected value token " & $p.curr.kind & " at line " & $p.curr.line & ", col " & $p.curr.col)

proc parseRoot(p: var YamlParser): YAMLObject =
  result = parseMapping(p, 0)

proc nimStringLiteral(s: string): string =
  result = "\""
  for ch in s:
    case ch
    of '\\': result.add("\\\\")
    of '\"': result.add("\\\"")
    of '\n': result.add("\\n")
    of '\r': result.add("\\r")
    of '\t': result.add("\\t")
    else:
      let o = ord(ch)
      if o < 32:
        result.add("\\x" & toHex(o, 2))
      else:
        result.add(ch)
  result.add("\"")

#
# Dump hook to for converting YAMLObject to JSON
#
proc dumpHook(s: var string, v: YamlNode) =
  case v.kind
  of yamlNull:
    s.add("null")
  of yamlBoolean:
    s.add($v.boolValue)
  of yamlInteger:
    s.add($v.intValue)
  of yamlFloat:
    s.add($v.floatValue)
  of yamlString:
    s.add(nimStringLiteral(v.strValue))
  of yamlObject:
    s.add("{")
    var first = true
    for k, val in v.objValue.pairs:
      if not first: s.add(", ")
      first = false
      s.add(nimStringLiteral(k) & ": ")
      dumpHook(s, val)
    s.add("}")
  of yamlArray:
    s.add("[")
    for i, item in v.arrValue:
      if i > 0: s.add(", ")
      dumpHook(s, item)
    s.add("]")

proc `$`*(yamlObject: YAMLObject): string =
  ## Return a JSON string representation of the YAMLObject
  toJson(yamlObject)

proc parseYAML*(input: YAML): YAMLObject =
  var p = YamlParser(lex: YamlLexer(input: input, len: input.len, line: 1, col: 1))
  p.lex.current = p.lex.charAt(0)
  p.curr = p.nextToken()
  p.next = p.nextToken()
  while p.curr.kind == ytkComment:
    p.curr = p.next
    p.next = p.nextToken()
  p.parseRoot()


#
# Direct-to-object parsing API
#
proc parseHook*(parser: var YamlParser, v: var string)
proc parseHook*[T: float|float32|float64](parser: var YamlParser, v: var T)
proc parseHook*(parser: var YamlParser, v: var bool)
# proc parseHook*[T](parser: var YamlParser, v: var seq[T])
# proc parseHook*[T: ref object](parser: var YamlParser, v: var T)
# proc parseHook*[T: enum](parser: var YamlParser, v: var T)
# proc parseHook*[K: string, V](parser: var YamlParser, v: var AnyTable[K, V])
# proc parseHook*[T](parser: var YamlParser, v: var set[T])
# proc parseHook*[T: Integers](parser: var YamlParser, v: var T)
# proc parseHook*[T: tuple](parser: var YamlParser, v: var T)

#
# Parse Hooks
#
proc parseHook*(parser: var YamlParser, v: var string) =
  ## A hook to parse string fields
  v = parser.curr.value
  parser.advance()

proc parseHook*(parser: var YamlParser, v: var bool) =
  ## A hook to parse boolean fields
  # v = parser.curr.kind == ytkBool
  parser.advance()

proc parseHook*[T: float|float32|float64](parser: var YamlParser, v: var T) =
  ## A hook to parse float fields
  v = parser.curr.value.parseFloat()
  parser.advance()

proc parseHook*[T: Integers](parser: var YamlParser, v: var T) =
  ## A hook to parse integer fields
  v = parser.curr.value.parseInt()
  parser.advance()

proc parseHook*[T: enum](parser: var YamlParser, v: var T) =
  ## A hook to parse enum fields
  if parser.curr.kind == ytkString:
    let enumStr = parser.curr.value
    v = strutils.parseEnum[T](enumStr)
    parser.advance()
  elif parser.curr.kind == ytkInteger:
    let enumNum = parser.curr.value.parseInt() # it must be an integer
    v = T(enumNum)
    parser.advance()
  else:
    parser.error(unexpectedTokenExpected % [$parser.curr.kind, "string or number"])

proc parseHook*[T](parser: var YamlParser, v: var set[T]) = 
  ## A hook to parse set fields from JSON arrays
  parser.expectSkip(ytkLB) # start of array
  while parser.curr.kind != ytkRB:
    var item: T
    parser.parseHook(item)
    v.incl(item)
    if parser.curr.kind == ytkComma:
      parser.advance()
  parser.expectSkip(ytkRB) # end of array

proc parseYAML*[T: object|ref object](parser: var YamlParser, v: var T) =
  case parser.curr.kind
  of ytkLB:
    parser.parseHook(v)
  else:
    discard
    # parser.error(unexpectedToken % [$parser.curr.kind])

macro parseYamlMacro(x: typed, str: typed): untyped =
  var objIdent = x.getTypeImpl()[1]
  var
    blockStmtList = newStmtList()
    blockStmtId = genSym(nskLabel, "openparserYaml")
  add blockStmtList, quote do:
    var
      tmp = `objIdent`()
      parser = YamlParser(lex: newYamlLexer(`str`))
    parser.curr = parser.nextToken()
    parser.next = parser.nextToken()
    parser.parseYAML(tmp)
    ensureMove(tmp) # return the parsed object
  var blockStmt = newBlockStmt(blockStmtId, blockStmtList)
  result = newStmtList().add(blockStmt)

proc parseYAML*[T](input: YAML, t: typedesc[T]): T =
  ## Parse YAML string into a Nim object or sequence of type `T`
  parseYamlMacro(T, input)

# when isMainModule:
#   echo parseYAML(readFile("test.yaml"))

