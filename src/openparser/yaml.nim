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

import std/[tables, critbits, strutils, macros,
        typetraits, enumutils, options]

import ./private/[types, lexutils]
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
    prev*, curr*, next*: YamlToken

  YAML* = string
    ## A simple alias for YAML strings

  OpenParserYamlError* = object of CatchableError
    ## Exception type for errors encountered during YAML parsing or dumping

const
  invalidToken = "Invalid token `$1`"
  errorEndOfFile = "Unexpected EOF while parsing `$1`"
  unexpectedToken = "Unexpected token `$1`"
  unexpectedTokenExpected = "Got `$1`, expected $2"
  unexpectedChar = "Unexpected character `$1`"

proc newYamlLexer*(input: string): YamlLexer =
  ## Create a new YamlLexer for the given input string
  YamlLexer(input: input, len: input.len, line: 1, col: 1)

proc error*(l: var YamlLexer, msg: string) =
  # Raise a lexer error
  let context = getContext(l)
  raise newException(OpenParserYamlError, ("\n" & context & "\n" & "Error ($1:$2) " % [$l.line, $l.col]) & msg)

proc error*(p: var YamlParser, msg: string) =
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
  while l.current in {'a'..'z', 'A'..'Z', '0'..'9', '_', '-', '/', '.'}:
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

const tokens = {
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
  of 'a'..'z', 'A'..'Z', '_', '/', '.':
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

  YamlNode* {.acyclic.} = ref object
    ## Represents a node in the YAML data structure, which can be a scalar, object or array
    case kind*: YamlValueKind
    of yamlInteger:
      intValue*: int64
        ## Represents an integer value in YAML
    of yamlFloat:
      floatValue*: float64
        ## Represents a floating-point value in YAML
    of yamlString:
      strValue*: string
        ## Represents a string value in YAML
    of yamlBoolean:
      boolValue*: bool
        ## Represents a boolean value in YAML
    of yamlObject:
      objValue*: OrderedTableRef[string, YamlNode]
        ## Represents a YAML mapping (object) with string keys and YamlNode values
    of yamlArray:
      arrValue*: seq[YamlNode]
        ## Represents a YAML sequence (array) of YamlNode items
    of yamlNull: discard

  YAMLObject* = OrderedTableRef[string, YamlNode]
    ## Represents a simple 

macro copyFieldsBeforeRecCase*(dst, src: typed): untyped =
  ## Copies fields declared before the `case` (RecCase) node in a variant object.
  result = newStmtList()
  let impl = dst.getTypeImpl()
  # impl[2] is the RecList for object types
  for field in impl[2]:
    if field.kind == nnkRecCase: break  # stop at the variant
    if field.kind == nnkIdentDefs:
      let fname = field[0]
      result.add quote do:
        `dst`.`fname` = `src`.`fname`

proc newYamlString*(s: string): YamlNode =
  ## Create a new YamlNode of kind yamlString
  YamlNode(kind: yamlString, strValue: s)

proc newYamlFloat*(f: float64): YamlNode =
  ## Create a new YamlNode of kind yamlFloat
  YamlNode(kind: yamlFloat, floatValue: f)

proc newYamlInteger*(i: int64): YamlNode =
  ## Create a new YamlNode of kind yamlInteger
  YamlNode(kind: yamlInteger, intValue: i)

proc newYamlBoolean*(b: bool): YamlNode =
  ## Create a new YamlNode of kind yamlBoolean
  YamlNode(kind: yamlBoolean, boolValue: b)

proc newYamlNull*(): YamlNode =
  ## Create a new YamlNode of kind yamlNull
  YamlNode(kind: yamlNull)

proc newYamlObject*(): YamlNode =
  ## Create a new YamlNode of kind yamlObject
  YamlNode(kind: yamlObject, objValue: newOrderedTable[string, YamlNode]())

proc newYamlArray*(): YamlNode =
  ## Create a new YamlNode of kind yamlArray
  YamlNode(kind: yamlArray, arrValue: @[])

proc get*(n: YamlNode, key: string): YamlNode =
  ## Recursively access nested YAML data using dot-separated keys.
  ## Example: get(config, "user.name")
  if n == nil or key.len == 0:
    return nil
  if '.' notin key:
    if n.kind == yamlObject and n.objValue.hasKey(key):
      return n.objValue[key]
    else:
      return nil
  let dotIdx = key.find('.')
  let head = key[0 ..< dotIdx]
  let tail = key[dotIdx+1 .. ^1]
  let nextNode =
    if n.kind == yamlObject and n.objValue.hasKey(head):
      n.objValue[head]
    else:
      nil
  if nextNode == nil:
    return nil
  return get(nextNode, tail)

proc get*(obj: YamlObject, key: string): YamlNode =
  ## Retrieves a value by key, supporting dot notation for nested access
  if key.contains("."):
    let parts = key.split('.', maxsplit = 1)
    result = obj.get(parts[0]).get(parts[1])
  else:
    # existing single-key lookup logic
    result = obj[key] # adjust to match actual field access

proc put*(obj: YamlObject, key: string, value: YamlNode) =
  ## Insert or update a key-value pair in a YAMLObject
  obj[key] = value

proc getStr*(n: YamlNode): string =
  ## Get string value or "" if not a string node
  if n != nil and n.kind == yamlString:
    result = n.strValue

proc getInt*(n: YamlNode): int64 =
  ## Get integer value or 0 if not an integer node
  if n != nil and n.kind == yamlInteger:
    result = n.intValue

proc getFloat*(n: YamlNode): float64 =
  ## Get float value or 0.0 if not a float node
  if n != nil and n.kind == yamlFloat:
    result = n.floatValue

proc getBool*(n: YamlNode): bool =
  ## Get boolean value or false if not a boolean node
  if n != nil and n.kind == yamlBoolean:
    result = n.boolValue

proc getArray*(n: YamlNode): seq[YamlNode] =
  ## Get array value or empty seq if not an array node
  if n != nil and n.kind == yamlArray:
    result = n.arrValue

proc getObject*(n: YamlNode): OrderedTableRef[string, YamlNode] =
  ## Get object value or empty table if not an object node
  if n != nil and n.kind == yamlObject:
    result = n.objValue

proc getValue*(v: YamlNode): string =
  ## Get the string representation of a YamlNode value (for debugging)
  case v.kind
  of yamlNull: "null"
  of yamlBoolean: $v.boolValue
  of yamlInteger: $v.intValue
  of yamlFloat: $v.floatValue
  of yamlString: v.strValue
  of yamlObject: "{...}"
  of yamlArray: "[...]"

proc advance*(p: var YamlParser) =
  ## Move to the next token, skipping comments
  p.prev = p.curr
  p.curr = p.next
  p.next = p.nextToken()
  while p.curr.kind == ytkComment:
    p.curr = p.next
    p.next = p.nextToken()

proc expectSkip*(p: var YamlParser, tkind: YamlTokenKind) =
  ## Expect the current token to be of a specific kind, then advance
  if p.curr.kind != tkind:
    if p.curr.kind == ytkEOF:
      p.error(errorEndOfFile % $tkind)
    else:
      p.error(unexpectedTokenExpected % [$p.curr.kind, $tkind])
  else:
    p.advance()

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

proc parsePlainUnquoted(p: var YamlParser, inlineMode = false): YamlNode =
  ## Parse plain scalar on the same line.
  ## In inline mode, stop at ',', ']' and '}'.
  let lineNo = p.curr.line
  let firstTok = p.curr
  var count = 0
  var buf = ""

  while p.curr.kind != ytkEOF and p.curr.line == lineNo:
    if p.curr.kind == ytkComment:
      break
    if inlineMode and p.curr.kind in {ytkComma, ytkRB, ytkRC}:
      break

    if count > 0 and p.curr.wsno > 0:
      buf.add(repeat(' ', p.curr.wsno))

    # prefer token value; fallback to token text
    # for punctuation-like tokens
    let part = if p.curr.value.len > 0: p.curr.value else: tokenText(p.curr)
    buf.add(part)

    inc count
    advance(p)

  if count == 1:
    result = getScalarValue(firstTok) # preserves bool/int/float/null coercion
  else:
    result = YamlNode(kind: yamlString, strValue: buf)

proc parseBlockString(p: var YamlParser, parentIndent: int, folded: bool): YamlNode =
  ## Parse YAML block scalar after '|' or '>'
  ## Current token must be ytkPipe or ytkGT.
  let markerLine = p.curr.line
  advance(p) # consume '|' or '>'

  var str: string
  var seenAny = false

  # Helper: return the raw line that contains position `pos`.
  proc rawLineAt(input: string, pos: int): string =
    var start = pos
    while start > 0 and input[start - 1] notin {'\n', '\r'}:
      dec start
    var endPos = pos
    while endPos < input.len and input[endPos] notin {'\n', '\r'}:
      inc endPos
    result = input[start ..< endPos]

  while p.curr.kind != ytkEOF and p.curr.indent > parentIndent:
    # Skip the line that contains the block‑scalar marker itself
    if p.curr.line == markerLine:
      advance(p)
      continue

    # New logical line: append newline if we've already added content
    if seenAny:
      str.add("\n")

    # Capture the whole source line once (preserves quotes/punctuation).
    let curLine = p.curr.line
    str.add(rawLineAt(p.lex.input, p.curr.pos))
    seenAny = true

    # Consume the rest of tokens that belong to the same logical line
    # so we don't append the same raw line multiple times.
    while p.curr.kind != ytkEOF and p.curr.line == curLine:
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
      if p.curr.kind in {ytkIdentifier, ytkString} and p.next.kind == ytkColon:
        # Sequence item like:
        # - name: Bob
        #   age: 25
        # First parse keys at current indent (e.g. "name"),
        # then merge continuation keys indented deeper than the dash indent (e.g. "age").
        var obj = parseMapping(p, p.curr.indent)

        while p.curr.kind in {ytkIdentifier, ytkString} and p.curr.indent > indent:
          let more = parseMapping(p, p.curr.indent)
          for k, v in more.pairs:
            obj[k] = v

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
  while p.curr.kind in {ytkIdentifier, ytkString} and p.curr.indent == indent:
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
  let inlineMode = parentIndent < 0
  case p.curr.kind
  of ytkIdentifier:
    if p.next.kind == ytkColon and p.curr.indent > parentIndent:
      let obj = parseMapping(p, p.curr.indent)
      result = YamlNode(kind: yamlObject, objValue: obj)
    else:
      result = parsePlainUnquoted(p, inlineMode)
  of ytkString, ytkFloat, ytkInteger:
    result = parsePlainUnquoted(p, inlineMode)
  of ytkLB:
    result = parseInlineArray(p)
  of ytkLC:
    result = parseInlineObject(p)
  of ytkDash:
    let arr = parseSequence(p, p.curr.indent)
    result = YamlNode(kind: yamlArray, arrValue: arr)
  of ytkPipe:
    result = parseBlockString(p, parentIndent, folded = false)
  of ytkGT:
    result = parseBlockString(p, parentIndent, folded = true)
  else:
    raise newException(
      ValueError,
      "Unexpected value token " & $p.curr.kind & " at line " & $p.curr.line & ", col " & $p.curr.col
    )

proc parseRoot(p: var YamlParser): YAMLObject =
  result = newOrderedTable[string, YamlNode]()
  if p.curr.kind == ytkEOF:
    return
  # Accept indented top-level YAML (common in triple-quoted test strings).
  result = parseMapping(p, p.curr.indent)

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
proc dumpHook*(s: var string, v: YamlNode) =
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

proc dump*(json: JsonNode): YAML =
  ## Dump from `JsonNode` to stringified YAML
  var res: YAML

  proc needsQuoting(s: string): bool =
    if s.len == 0: return true
    for ch in s:
      if ch in {' ', ':', '-', '{', '}', '[', ']', ',', '#', '&', '*', '!', '|', '>', '\'', '\"', '%', '@', '`'}:
        return true
    # start/end with numeric-like or boolean-like might be ambiguous
    if s[0].isDigit or s[0] == '-' or s[0] == '+':
      return true
    let keyw = s.toLowerAscii()
    if keyw in ["null", "~", "true", "false", "y", "n", "yes", "no", "on", "off"]:
      return true
    false

  proc emitIndent(n: int) =
    if n > 0: res.add(repeat(' ', n))

  proc emitScalar(s: string) =
    if needsQuoting(s):
      res.add(nimStringLiteral(s))
    else:
      res.add(s)

  proc dumpNode(n: JsonNode, indent: int) =
    ## Best-effort generic handling compatible with std/json-like JsonNode APIs.
    case n.kind
    of JNull:
      res.add("null")
    of JBool:
      when compiles(n.getBool):
        res.add($n.getBool())
      else:
        res.add($n)
    of JInt, JFloat:
      # rely on default `$` for numbers
      res.add($n)
    of JString:
      when compiles(n.getStr):
        emitScalar(n.getStr())
      else:
        emitScalar($n)
    of JArray:
      # empty inline array
      var isEmpty = true
      when compiles(n.len):
        isEmpty = n.len == 0
      elif compiles(n.items):
        isEmpty = n.items.len == 0
      if isEmpty:
        res.add("[]")
        return

      # block sequence
      when compiles(for item in n: discard):
        for item in n:
          res.add("\n")
          emitIndent(indent)
          res.add("- ")
          dumpNode(item, indent + 2)
      else:
        # fallback: try numeric indexing
        var i = 0
        while true:
          try:
            let item = n[i]
            res.add("\n")
            emitIndent(indent)
            res.add("- ")
            dumpNode(item, indent + 2)
            inc i
          except:
            break

    of JObject:
      # empty inline object
      var isEmpty = true
      when compiles(n.len):
        isEmpty = n.len == 0
      elif compiles(n.items):
        isEmpty = n.items.len == 0
      if isEmpty:
        res.add("{}")
        return

      # block mapping
      when compiles(for k, v in n: discard):
        for k, v in n:
          res.add("\n")
          emitIndent(indent)
          res.add(k & ": ")
          dumpNode(v, indent + 2)
      else:
        # fallback: try iteration over keys via `items` or `pairs`
        when compiles(n.items):
          for kv in n.items:
            let k = kv[0]
            let v = kv[1]
            res.add("\n")
            emitIndent(indent)
            res.add(k & ": ")
            dumpNode(v, indent + 2)
        else:
          # last resort: dump JSON text inline
          res.add(nimStringLiteral($n))

  dumpNode(json, 0)

  # strip leading newline if present
  if res.len > 0 and res[0] == '\n':
    result = res[1 .. ^1]
  else:
    result = res

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
proc parseHook*(p: var YamlParser, v: var string)
proc parseHook*[T: float|float32|float64](p: var YamlParser, v: var T)
proc parseHook*(p: var YamlParser, v: var bool)
proc parseHook*[T: ref object](p: var YamlParser, v: var T)
proc parseHook*[T](p: var YamlParser, v: var seq[T])
proc parseHook*[T: enum](p: var YamlParser, v: var T)
proc parseHook*[K: string, V](p: var YamlParser, v: var AnyTable[K, V])
proc parseHook*[T](p: var YamlParser, v: var set[T])
proc parseHook*[T: tuple](p: var YamlParser, v: var T)
proc parseHook*[T: distinct](p: var YamlParser, v: var T)
proc parseHook*[T](p: var YamlParser, v: var CritBitTree[T])
proc parseHook*[T](p: var YamlParser, v: var Option[T])

template isYamlNullToken(tok: YamlToken): bool =
  tok.kind == ytkIdentifier and (tok.value == "null" or tok.value == "~")

template parseYamlMappingPairs*(body: untyped) {.dirty.} =
  ## Iterates YAML mapping entries for both:
  ##   - inline: {k: v, ...}
  ##   - block:
  ##       k: v
  ##       ...
  ## Injects `key` into `body`.
  if p.curr.kind == ytkLC:
    p.advance() # '{'
    while p.curr.kind != ytkRC:
      if p.curr.kind == ytkEOF:
        p.error(errorEndOfFile % ["inline object"])
      if p.curr.kind notin {ytkIdentifier, ytkString}:
        p.error(unexpectedTokenExpected % [$p.curr.kind, "mapping key"])

      let key {.inject.} = p.curr.value
      let yamlMapIndent {.inject.} = -1
      p.advance()

      if p.curr.kind != ytkColon:
        p.error(unexpectedTokenExpected % [$p.curr.kind, $ytkColon])
      p.advance()

      body

      if p.curr.kind == ytkComma:
        p.advance()
      elif p.curr.kind != ytkRC:
        p.error(unexpectedTokenExpected % [$p.curr.kind, "comma or }"])
    p.advance() # '}'
  else:
    if p.curr.kind notin {ytkIdentifier, ytkString, ytkEOF}:
      p.error(unexpectedTokenExpected % [$p.curr.kind, "mapping key"])
    
    if p.curr.kind == ytkEOF:
      return # allow empty document

    let baseIndent = p.curr.indent
    let yamlMapIndent {.inject.} = baseIndent
    var effectiveIndent = baseIndent

    # Use effectiveIndent in the condition, NOT baseIndent.
    # On the first key of a dash-inline item (e.g. "- name: foo"),
    # effectiveIndent == baseIndent == dash-line indent.
    # After parsing that key, effectiveIndent is promoted to the
    # continuation indent (e.g. 4), and the loop continues correctly
    while p.curr.kind in {ytkIdentifier, ytkString} and
        p.curr.indent == effectiveIndent:
      let key {.inject.} = p.curr.value
      p.advance()

      if p.curr.kind != ytkColon:
        if p.curr.kind == ytkIdentifier:
          p.error(unexpectedTokenExpected % [p.curr.value, $ytkColon])
        else:
          p.error(unexpectedTokenExpected % [$p.curr.kind, $ytkColon])
      p.advance()

      body

      # Promote effectiveIndent once when continuation keys
      # sit deeper than the inline-after-dash first key.
      if effectiveIndent == baseIndent and
          p.curr.kind in {ytkIdentifier, ytkString} and
          p.curr.indent > baseIndent:
        effectiveIndent = p.curr.indent

#
# Parse Hooks
#
proc parseHook*[T](p: var YamlParser, v: var Option[T]) =
  # Parse an `Option[T]` field.
  # - `null` / `~` / EOF = `none(T)`
  # - any other value    = `some(innerValue)`
  if p.curr.kind == ytkEOF or isYamlNullToken(p.curr):
    v = none(T)
    if p.curr.kind != ytkEOF:
      p.advance()
    return
  var tmp: T
  p.parseHook(tmp)
  v = some(tmp)

proc parseHook*(p: var YamlParser, v: var string) =
  ## A hook to parse string fields
  case p.curr.kind
  of ytkPipe, ytkGT:
    # Block scalar – let the generic block‑string parser do the work.
    let node = p.parseBlockString(parentIndent = p.curr.indent,
                                 folded = (p.curr.kind == ytkGT))
    v = node.strValue
  else:
    # Regular scalar (identifier, quoted string, number, etc.)
    v = p.curr.value
    p.advance()

proc parseHook*(p: var YamlParser, v: var bool) =
  ## A hook to parse boolean fields
  v = p.curr.value.parseBool()
  p.advance()

proc parseHook*[T: float|float32|float64](p: var YamlParser, v: var T) =
  ## A hook to parse float fields
  v = p.curr.value.parseFloat()
  p.advance()

proc parseHook*[T: Integers](p: var YamlParser, v: var T) =
  ## A hook to parse integer fields
  v = cast[v.type](p.curr.value.parseInt())
  p.advance()

proc parseHook*[T: distinct](p: var YamlParser, v: var T) =
  ## A hook to parse distinct types by parsing their base type and then converting
  var tmp: T.distinctBase
  p.parseHook(tmp)
  v = T(tmp)

proc parseHook*[T: enum](p: var YamlParser, v: var T) =
  ## A hook to parse enum fields
  if p.curr.kind == ytkString or p.curr.kind == ytkIdentifier:
    let enumStr = p.curr.value
    # Fallback: try parseEnum which matches field names
    try:
      v = strutils.parseEnum[T](enumStr)
    except ValueError:
      p.error("Cannot parse `" & enumStr & "` as " & $T)
    p.advance()
  elif p.curr.kind == ytkInteger:
    v = T(p.curr.value.parseInt())
    p.advance()
  else:
    p.error(unexpectedTokenExpected % [$p.curr.kind, "string or number"])

proc parseHook*[T](p: var YamlParser, v: var set[T]) =
  ## A hook to parse set fields from YAML sequences (inline or block)
  v = {}
  case p.curr.kind
  of ytkLB:
    # inline: [a, b, c]
    p.advance() # '['
    while p.curr.kind != ytkRB:
      if p.curr.kind == ytkEOF:
        p.error(errorEndOfFile % ["inline array"])
      var item: T
      p.parseHook(item)
      v.incl(item)
      if p.curr.kind == ytkComma:
        p.advance()
      elif p.curr.kind != ytkRB:
        p.error(unexpectedTokenExpected % [$p.curr.kind, "comma or ]"])
    p.advance() # ']'
  of ytkDash:
    # block:
    # - a
    # - b
    let seqIndent = p.curr.indent
    while p.curr.kind == ytkDash and p.curr.indent == seqIndent:
      let dashLine = p.curr.line
      p.advance() # '-'
      var item: T
      if p.curr.kind == ytkEOF:
        discard
      elif p.curr.line == dashLine:
        p.parseHook(item)
      elif p.curr.indent > seqIndent:
        p.parseHook(item)
      else:
        discard
      v.incl(item)
  else:
    p.error(unexpectedTokenExpected % [$p.curr.kind, "sequence"])

proc parseHook*[T](p: var YamlParser, v: var seq[T]) =
  ## Parse YAML sequence into seq[T]
  v.setLen(0)
  case p.curr.kind
  of ytkLB:
    # inline: [a, b, c]
    p.advance() # '['
    while p.curr.kind != ytkRB:
      if p.curr.kind == ytkEOF:
        p.error(errorEndOfFile % ["inline array"])
      var item: T
      p.parseHook(item)
      v.add(item)

      if p.curr.kind == ytkComma:
        p.advance()
      elif p.curr.kind != ytkRB:
        p.error(unexpectedTokenExpected % [$p.curr.kind, "comma or ]"])
    p.advance() # ']'

  of ytkDash:
    # block:
    # - a
    # - b
    let seqIndent = p.curr.indent
    while p.curr.kind == ytkDash and p.curr.indent == seqIndent:
      let dashLine = p.curr.line
      p.advance() # '-'

      var item: T
      if p.curr.kind == ytkEOF:
        discard
      elif p.curr.line == dashLine:
        p.parseHook(item)
      elif p.curr.indent > seqIndent:
        p.parseHook(item)
      else:
        discard # "-\n" => default(T)
      v.add(item)
  else:
    p.error(unexpectedTokenExpected % [$p.curr.kind, "sequence"])


proc parseHook*[N: static[int]; T](p: var YamlParser, v: var array[N, T]) =
  ## Parse YAML sequence into fixed-size array. The sequence length must match the array size.
  var idx = 0
  
  case p.curr.kind
  of ytkLB:
    # inline: [a, b, c]
    p.advance() # '['
    while p.curr.kind != ytkRB:
      if p.curr.kind == ytkEOF:
        p.error(errorEndOfFile % ["inline array"])
      
      if idx >= N:
        p.error("Sequence has more items than array size (" & $N & ")")
      
      var item: T
      p.parseHook(item)
      v[idx] = item
      inc idx

      if p.curr.kind == ytkComma:
        p.advance()
      elif p.curr.kind != ytkRB:
        p.error(unexpectedTokenExpected % [$p.curr.kind, "comma or ]"])
    p.advance() # ']'

  of ytkDash:
    # block:
    # - a
    # - b
    let seqIndent = p.curr.indent
    while p.curr.kind == ytkDash and p.curr.indent == seqIndent:
      if idx >= N:
        p.error("Sequence has more items than array size (" & $N & ")")
      
      let dashLine = p.curr.line
      p.advance() # '-'

      var item: T
      if p.curr.kind == ytkEOF:
        discard
      elif p.curr.line == dashLine:
        p.parseHook(item)
      elif p.curr.indent > seqIndent:
        p.parseHook(item)
      else:
        discard # "-\n" => default(T)
      
      v[idx] = item
      inc idx
  else:
    p.error(unexpectedTokenExpected % [$p.curr.kind, "sequence"])
  
  if idx < N:
    p.error("Sequence has fewer items (" & $idx & ") than array size (" & $N & ")")

proc parseHook*[T: tuple](p: var YamlParser, v: var T) =
  ## Parse YAML mapping into tuple fields by name.
  parseYamlMappingPairs do:
    var matched = false
    for fieldName, fieldVal in v.fieldPairs:
      if key == fieldName:
        matched = true
        when compiles(p.parseHook(fieldVal)):
          p.parseHook(fieldVal)
        else:
          var tmp: type(fieldVal)
          p.parseHook(tmp)
          when compiles(fieldVal = tmp):
            fieldVal = tmp
          else:
            p.error("Field `" & fieldName & "` is immutable")
        break

    if not matched:
      discard parseValue(p, yamlMapIndent)

proc parseHook*[K: string, V](p: var YamlParser, v: var AnyTable[K, V]) =
  ## Parse YAML mapping into Table/OrderedTable and ref variants.
  when v is TableRef[K, V] or v is OrderedTableRef[K, V]:
    if isYamlNullToken(p.curr):
      v = nil
      p.advance()
      return

    when v is TableRef[K, V]:
      if v.isNil: v = newTable[K, V]() else: v[].clear()
    else:
      if v.isNil: v = newOrderedTable[K, V]() else: v[].clear()
  else:
    if isYamlNullToken(p.curr):
      when v is Table[K, V]:
        v = initTable[K, V]()
      else:
        v = initOrderedTable[K, V]()
      p.advance()
      return

    when v is Table[K, V]:
      v = initTable[K, V]()
    else:
      v = initOrderedTable[K, V]()

  parseYamlMappingPairs do:
    var item: V
    p.parseHook(item)
    v[key] = item

proc parseHook*[T](p: var YamlParser, v: var CritBitTree[T]) =
  ## Parse YAML mapping into CritBitTree[T] (string-keyed).
  if isYamlNullToken(p.curr):
    when compiles(v.clear()):
      v.clear()
    else:
      v = CritBitTree[T]()
    p.advance()
    return

  when compiles(v.clear()):
    v.clear()
  else:
    v = CritBitTree[T]()

  parseYamlMappingPairs do:
    var item: T
    p.parseHook(item)
    v[key] = item

proc parseHook*[T: object](p: var YamlParser, v: var T) =
  ## Parse YAML mapping into a Nim object.
  parseYamlMappingPairs do:
    var handled = false

    # variant discriminator handling: initialize correct branch early
    when isObjectVariant(v):
      if key == discriminatorFieldName(v):
        var d: type(discriminatorField(v))
        p.parseHook(d)

        let prev = v
        new(v, d)
        copyFieldsBeforeRecCase(v, prev)
        handled = true

    if not handled:
      var matched = false
      for objField, objVal in v.fieldPairs:
        if key == objField:
          matched = true
          when compiles(p.parseHook(objVal)):
            p.parseHook(objVal)
          else:
            var tmp: type(objVal)
            p.parseHook(tmp)
            when compiles(objVal = tmp):
              objVal = tmp
            else:
              p.error("Field `" & objField & "` is immutable")
          break

      if not matched:
        # Unknown key/value: parse and discard one YAML value.
        discard parseValue(p, yamlMapIndent)

proc toJsonNode(y: YamlNode): JsonNode =
  case y.kind
  of yamlString: result = %(y.strValue)
  of yamlInteger: result = %(y.intValue)
  of yamlFloat: result = %(y.floatValue)
  of yamlBoolean: result = %(y.boolValue)
  of yamlNull: result = newJNull()
  of yamlObject:
    result = newJObject()
    for k, v in y.objValue:
      result[k] = toJsonNode(v)
  of yamlArray:
    result = newJArray()
    for item in y.arrValue:
      result.add(toJsonNode(item))

proc parseHook*(p: var YamlParser, v: var JsonNode) =
  ## Parse YAML value (scalar, array, or mapping) into a JsonNode
  let node = parseValue(p, p.curr.indent)
  v = toJsonNode(node)

proc parseHook*[T: ref object](p: var YamlParser, v: var T) =
  ## A hook to parse ref object fields
  if isYamlNullToken(p.curr):
    v = nil
    p.advance()
  else:
    if v.isNil:
      new(v)
    p.parseHook(v[])

proc parseYAML*[T: object|ref object](p: var YamlParser, v: var T) =
  ## Parse top-level YAML into object/ref object.
  case p.curr.kind
  of ytkLC, ytkIdentifier, ytkString:
    p.parseHook(v)
  of ytkEOF:
    discard
  else:
    p.error(unexpectedTokenExpected % [$p.curr.kind, "mapping/object"])

macro parseYamlMacro(x: typed, str: typed): untyped =
  var objIdent = x.getTypeImpl()[1]
  var
    blockStmtList = newStmtList()
    blockStmtId = genSym(nskLabel, "openparserYaml")
  add blockStmtList, quote do:
    var
      tmp = `objIdent`()
      p = YamlParser(lex: newYamlLexer(`str`))
    
    p.lex.current = p.lex.charAt(0)
    p.curr = p.nextToken()
    p.next = p.nextToken()
    while p.curr.kind == ytkComment:
      p.curr = p.next
      p.next = p.nextToken()
    
    p.parseYAML(tmp)
    ensureMove(tmp) # return the parsed object
  var blockStmt = newBlockStmt(blockStmtId, blockStmtList)
  result = newStmtList().add(blockStmt)

proc parseYAML*[T](input: YAML, t: typedesc[T]): T =
  ## Parse YAML string into a Nim object or sequence of type `T`
  parseYamlMacro(T, input)
