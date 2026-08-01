# A collection of tiny parsers and dumpers
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/openparser

## This module implements a TOML parser and serializer for Nim,
## allowing you to read and write TOML configuration files with ease.
## 
## It can parse TOML format into Nim data structures, like tables, sequences,
## and basic types, and serialize data structures back into TOML format.
## 
## Parsing to pre-defined Toml AST nodes is supported as well, so you can work with
## a structured representation of the TOML document if you need more control or want to
## implement custom validation rules beyond what the direct-to-struct parsing provides
import std/[strutils, tables, times]
import ./private/types
import ./json

type
  TOML* = string

  TomlLexer* = object of OpenLexer
    ## The TomlLexer is responsible for tokenizing a TOML input string.
    ## It produces a stream of TomlTokens that can be consumed by a parser

  TomlTokenKind* = enum
    ## The different kinds of tokens that can be encountered in a TOML file
    ttkEOF = "EOF"
    ttkError = "Error"
    ttkString
    ttkInteger
    ttkFloat
    ttkBoolean
    ttkDateTime
    ttkIdentifier
    ttkEquals = "="
    ttkDot = "."
    ttkComma = ","
    ttkLB = "["
    ttkRB = "]"
    ttkLC = "{"
    ttkRC = "}"
    ttkComment

  TomlToken* = ref object of OpenToken
    ## The kind of token, which can be a string, number, boolean, identifier, or punctuation
    kind*: TomlTokenKind
    indent*: int

  OpenParserTomlError* = object of CatchableError
    ## Exception type for errors that occur during TOML parsing


const
  invalidToken = "Invalid token `$1`"
  errorEndOfFile = "Unexpected EOF while parsing `$1`"
  unexpectedToken = "Unexpected token `$1`"
  unexpectedTokenExpected = "Got `$1`, expected $2"
  unexpectedChar = "Unexpected character `$1`"

proc charAt(l: TomlLexer, idx: int): char {.inline.} =
  if idx < 0 or idx >= l.len: return '\0'
  else: return l.input[idx]

proc newTomlLexer*(input: string): TomlLexer =
  ## Initializes a new TomlLexer with the given input string
  ## Sets up the initial state for lexing, including position and current character
  result = TomlLexer(input: input, len: input.len, line: 1, col: 1)
  result.current = result.charAt(0)

proc getContext(l: TomlLexer, posOverride: int = -1): string =
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

proc error(l: var TomlLexer, msg: string) =
  # Raise a lexer error
  let context = getContext(l)
  raise newException(OpenParserTomlError, ("\n" & context & "\n" & "Error ($1:$2) " % [$l.line, $l.col]) & msg)

proc advance(l: var TomlLexer) =
  if l.pos < l.len - 1:
    inc l.pos
    l.current = l.charAt(l.pos)
    inc l.col
  else:
    l.pos = l.len
    l.current = '\0'

proc lineIndentAt(l: TomlLexer, idx: int): int {.inline.} =
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

proc skipWhitespace(l: var TomlLexer, wsBeforeToken: var int): int =
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

proc peekChar*(lex: TomlLexer, offset: int): char =
  # Lookahead character at current position + offset without advancing
  lex.charAt(lex.pos + offset)

proc readIdentifier(l: var TomlLexer): string =
  # Read an unquoted identifier (e.g. for keys or unquoted values)
  while l.current in {'a'..'z', 'A'..'Z', '0'..'9', '_', '-'}:
    result.add(l.current)
    advance(l)

proc readComment(l: var TomlLexer): string =
  # Read from '#' to end of line (excluding newline)
  advance(l) # skip '#'
  while l.current notin {'\0', '\n', '\r'}:
    result.add(l.current)
    advance(l)

proc readString(l: var TomlLexer, quote: char): string =
  # read a quoted string, handling escape sequences for double quotes
  advance(l) # Skip the opening quote
  while true:
    if l.current == '\0':
      raise newException(OpenParserTomlError, "Unterminated string literal")
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
        result.add('\\')
        result.add(l.current)
      advance(l)
    else:
      result.add(l.current)
      advance(l)

proc readMultiLineString(l: var TomlLexer): string =
  # Read a multi-line string delimited by triple quotes """...""" or '''...'''
    # consume the opening triple quotes
    advance(l); advance(l); advance(l)
    # optional initial newline after opening delimiter is trimmed per TOML
    if l.current == '\n':
      inc l.line
      l.col = 0
      advance(l)
    while true:
      if l.current == '\0':
        raise newException(OpenParserTomlError, "Unterminated multi-line string literal")
      # check for closing triple quotes
      if l.current == '"' and l.charAt(l.pos+1) == '"' and l.charAt(l.pos+2) == '"':
        advance(l); advance(l); advance(l)
        break
      if l.current == '\\':
        # handle escapes and line continuations
        advance(l)
        if l.current == '\0':
          raise newException(OpenParserTomlError, "Unterminated escape in multi-line string")
        case l.current
        of '"': result.add('"')
        of '\\': result.add('\\')
        of 'n': result.add('\n')
        of 'r': result.add('\r')
        of 't': result.add('\t')
        of '\n':
          # line continuation: backslash + newline -> skip newline and following indentation
          inc l.line
          l.col = 0
          advance(l)
          while l.current in {' ', '\t'}:
            advance(l)
          continue
        else:
          # unknown escape: preserve backslash + char
          result.add('\\')
          result.add(l.current)
        advance(l)
      else:
        if l.current == '\n':
          inc l.line
          l.col = 0
        result.add(l.current)
        advance(l)

proc readNumber(l: var TomlLexer, kind: var TomlTokenKind): string =
  result = ""
  kind = ttkInteger

  if l.current == '-':
    result.add('-')
    advance(l)
  elif l.current == '+':
    advance(l)

  # collect leading digits (year or plain number)
  while l.current in {'0'..'9'}:
    result.add(l.current)
    advance(l)

  # delimiters that terminate a date/time token
  let terminators = {' ', '\n', '\r', '\t', ',', ']', '}', '#', '\0'}

  # Attempt to detect a date or datetime: YYYY-MM-DD [T hh:mm[:ss[.frac]] [Z|±HH:MM]]
  if l.current == '-':
    var la = l.pos
    var ok = true

    # expect '-' then two month digits
    if l.charAt(la) != '-': ok = false
    inc la
    if not (l.charAt(la) in {'0'..'9'} and l.charAt(la+1) in {'0'..'9'}): ok = false
    la += 2
    if l.charAt(la) != '-': ok = false
    inc la
    if not (l.charAt(la) in {'0'..'9'} and l.charAt(la+1) in {'0'..'9'}): ok = false
    la += 2

    if ok:
      # If next is 'T' then parse time portion; otherwise it's a local date (YYYY-MM-DD)
      if l.charAt(la) == 'T':
        inc la
        # hour: two digits
        if not (l.charAt(la) in {'0'..'9'} and l.charAt(la+1) in {'0'..'9'}):
          ok = false
        la += 2
        if l.charAt(la) != ':': ok = false
        inc la
        # minute: two digits
        if not (l.charAt(la) in {'0'..'9'} and l.charAt(la+1) in {'0'..'9'}):
          ok = false
        la += 2

        # optional seconds :ss
        if l.charAt(la) == ':':
          inc la
          if not (l.charAt(la) in {'0'..'9'} and l.charAt(la+1) in {'0'..'9'}):
            ok = false
          la += 2
          # optional fractional seconds .digits
          if l.charAt(la) == '.':
            inc la
            if not (l.charAt(la) in {'0'..'9'}):
              ok = false
            while l.charAt(la) in {'0'..'9'}:
              inc la

        # optional timezone: Z or ±HH:MM
        if l.charAt(la) in {'Z', 'z'}:
          inc la
        elif l.charAt(la) in {'+', '-'}:
          inc la
          if not (l.charAt(la) in {'0'..'9'} and l.charAt(la+1) in {'0'..'9'}):
            ok = false
          la += 2
          if l.charAt(la) == ':':
            inc la
            if not (l.charAt(la) in {'0'..'9'} and l.charAt(la+1) in {'0'..'9'}):
              ok = false
            la += 2

        # If everything looks like a valid datetime, consume it from the lexer
        if ok:
          while l.current notin terminators:
            result.add(l.current)
            advance(l)
          kind = ttkDateTime
          return
      else:
        # local date YYYY-MM-DD (no 'T')
        # consume the remaining date chars
        while l.current notin terminators:
          result.add(l.current)
          advance(l)
        kind = ttkDateTime
        return

  # fallback: floats (fraction/exponent)
  if l.current == '.':
    kind = ttkFloat
    result.add('.')
    advance(l)
    while l.current in {'0'..'9'}:
      result.add(l.current)
      advance(l)

  if l.current in {'e', 'E'}:
    kind = ttkFloat
    result.add(l.current)
    advance(l)
    if l.current in {'+', '-'}:
      result.add(l.current)
      advance(l)
    while l.current in {'0'..'9'}:
      result.add(l.current)
      advance(l)

#
# AST & Parser API
#
type
  TomlValueKind* = enum
    tvkString
    tvkInteger
    tvkFloat
    tvkBoolean
    tvkDateTime
    tvkArray
    tvkTable

  TomlNode* {.acyclic.} = ref object
    case kind*: TomlValueKind
    of tvkString:
      strVal*: string
    of tvkInteger:
      intVal*: int64
    of tvkFloat:
      floatVal*: float64
    of tvkBoolean:
      boolVal*: bool
    of tvkDateTime:
      dateTimeVal*: DateTime
    of tvkArray:
      arrayVal*: seq[TomlNode]
    of tvkTable:
      tableVal*: OrderedTableRef[string, TomlNode]

  TomlDocument* = TomlNode
    ## The root of a TOML document is a table mapping keys to values

  TomlParser* = object
    ## The TomlParser takes a TomlLexer and produces a Nim data structure
    ## representing the TOML content
    lex*: TomlLexer
    prev*, curr*, next*: TomlToken
  
proc newTomlString*(s: string): TomlNode =
  ## Helper to create a TomlNode of kind string
  TomlNode(kind: tvkString, strVal: s)

proc newTomlInteger*(i: int64): TomlNode =
  ## Helper to create a TomlNode of kind integer
  TomlNode(kind: tvkInteger, intVal: i)

proc newTomlFloat*(f: float64): TomlNode =
  ## Helper to create a TomlNode of kind float
  TomlNode(kind: tvkFloat, floatVal: f)

proc newTomlBoolean*(b: bool): TomlNode =
  ## Helper to create a TomlNode of kind boolean
  TomlNode(kind: tvkBoolean, boolVal: b)

proc newTomlDateTime*(dt: DateTime): TomlNode =
  ## Helper to create a TomlNode of kind datetime
  TomlNode(kind: tvkDateTime, dateTimeVal: dt)

proc newTomlArray*: TomlNode =
  ## Helper to create a TomlNode of kind array
  TomlNode(kind: tvkArray)

proc newTomlTable*: TomlNode =
  ## Helper to create a TomlNode of kind table
  TomlNode(kind: tvkTable, tableVal: newOrderedTable[string, TomlNode]())

proc getStr*(n: TomlNode): string =
  ## Get string value or "" if not a string node
  if n != nil and n.kind == tvkString:
    result = n.strVal

proc getInt*(n: TomlNode): int64 =
  ## Get integer value or 0 if not an integer node
  if n != nil and n.kind == tvkInteger:
    result = n.intVal

proc getFloat*(n: TomlNode): float64 =
  ## Get float value or 0.0 if not a float node
  if n != nil and n.kind == tvkFloat:
    result = n.floatVal

proc getBool*(n: TomlNode): bool =
  ## Get boolean value or false if not a boolean node
  if n != nil and n.kind == tvkBoolean:
    result = n.boolVal

proc getArray*(n: TomlNode): seq[TomlNode] =
  ## Get array value or empty seq if not an array node
  if n != nil and n.kind == tvkArray:
    result = n.arrayVal
  else:
    result = @[]

proc getObject*(n: TomlNode): OrderedTableRef[string, TomlNode] =
  ## Get table value or an empty table if not a table node
  if n != nil and n.kind == tvkTable:
    result = n.tableVal
  else:
    result = newOrderedTable[string, TomlNode]()

proc getValue*(v: TomlNode): string =
  ## Get the string representation of a TomlNode value (for debugging)
  if v == nil:
    return "null"
  case v.kind
  of tvkDateTime:
    result = v.dateTimeVal.format("yyyy-MM-dd'T'HH:mm:ss")
  of tvkBoolean:
    result = $v.boolVal
  of tvkInteger:
    result = $v.intVal
  of tvkFloat:
    result = $v.floatVal
  of tvkString:
    result = v.strVal
  of tvkTable:
    result = "{...}"
  of tvkArray:
    result = "[...]"

proc get*(n: TomlNode, key: string): TomlNode =
  ## Recursively access nested TOML data using dot-separated keys.
  ## Example: get(doc, "owner.name"). An exact key match wins first, so keys
  ## that themselves contain dots (e.g. `"a.b" = 1`) are addressable too.
  if n == nil or key.len == 0:
    return nil
  if n.kind == tvkTable and n.tableVal.hasKey(key):
    return n.tableVal[key]
  if '.' notin key:
    return nil
  let dotIdx = key.find('.')
  let head = key[0 ..< dotIdx]
  let tail = key[dotIdx+1 .. ^1]
  let nextNode =
    if n.kind == tvkTable and n.tableVal.hasKey(head):
      n.tableVal[head]
    else:
      nil
  if nextNode == nil:
    return nil
  return get(nextNode, tail)

proc get*(obj: OrderedTableRef[string, TomlNode], key: string): TomlNode =
  ## Access a value from a TOML table using a key
  if obj.hasKey(key):
    return obj[key]
  else:
    return nil

proc put*(obj: OrderedTableRef[string, TomlNode], key: string, value: TomlNode) =
  ## Insert or update a key-value pair in a TOML table
  obj[key] = value

#
# Parser API
#
let tokens = {
  ';': ttkComment,
  '#': ttkComment,
  '"': ttkString,
  '\'': ttkString,
  '=': ttkEquals,
  '.': ttkDot,
  ',': ttkComma,
  '[': ttkLB,
  ']': ttkRB,
  '{': ttkLC,
  '}': ttkRC
}.toTable

const strQuote = ['\'', '"']
proc nextToken*(p: var TomlParser): TomlToken =
  ## Lexical analysis to produce the next token from the input
  var wsBefore = 0
  let lineIndent = skipWhitespace(p.lex, wsBefore)

  result = TomlToken()
  result.line = p.lex.line
  result.col = p.lex.col
  result.pos = p.lex.pos
  result.indent = lineIndent
  result.wsno = wsBefore
  case p.lex.current
  of '\0':
    result.kind = ttkEOF
  of '#':
    result.kind = ttkComment
    result.value = p.lex.readComment()
  of '"', '\'':
    if p.lex.current in strQuote and p.lex.peekChar(1) == p.lex.current and p.lex.peekChar(2) == p.lex.current:
     result.kind = ttkString 
     result.value = p.lex.readMultiLineString()
    else:
      result.kind = ttkString
      result.value = p.lex.readString(p.lex.current)
  of '0'..'9', '-', '+':
    result.value = p.lex.readNumber(result.kind)
  of '=', '.', ',', '[', ']', '{', '}':
    result.kind = tokens[p.lex.current]
    advance(p.lex)
  of 'a'..'z', 'A'..'Z', '_':
    if p.lex.current in {'t', 'T', 'f', 'F'}:
      # Could be a boolean literal (true/false)
      let ident = p.lex.readIdentifier()
      if ident.toLowerAscii() == "true":
        result.kind = ttkBoolean
        result.value = "true"
      elif ident.toLowerAscii() == "false":
        result.kind = ttkBoolean
        result.value = "false"
      else:
        result.kind = ttkIdentifier
        result.value = ident
    else:
      result.kind = ttkIdentifier
      result.value = p.lex.readIdentifier()
  else:
    raise newException(OpenParserTomlError, "Invalid character: " & $(p.lex.current))

proc error(p: var TomlParser, msg: string) =
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
    OpenParserTomlError,
    ("\n" & context & "\n" & "Error ($1:$2) " % [$atLine, $atCol]) & msg
  )

proc advance(p: var TomlParser) {.inline.} =
  p.prev = p.curr
  p.curr = p.next
  p.next = p.nextToken()
  while p.curr.kind == ttkComment:
    p.curr = p.next
    p.next = p.nextToken()

#
# Parse hook for Toml nodes
#
proc parseTomlDateTime(s: string): DateTime =
  # Try several common TOML date/time formats. If there's a timezone suffix
  # (Z or ±HH:MM) we strip it and retry parsing the local-time portion.
  let fmts = @[
    "yyyy-MM-dd'T'HH:mm:ss.SSSSSS",
    "yyyy-MM-dd'T'HH:mm:ss.SSS",
    "yyyy-MM-dd'T'HH:mm:ss",
    "yyyy-MM-dd'T'HH:mm",
    "yyyy-MM-dd"
  ]

  for fmt in fmts:
    try:
      return times.parse(s, fmt)
    except:
      discard

  # If there's a timezone marker after the 'T', strip it and retry.
  let tpos = s.find('T')
  if tpos >= 0:
    var tzIdx = -1
    for i in tpos+1 ..< s.len:
      case s[i]
      of 'Z', 'z':
        tzIdx = i
        break
      of '+', '-':
        tzIdx = i
        break
      else: continue
    if tzIdx >= 0:
      let sNoTz = s[0..tzIdx-1]
      for fmt in fmts:
        try:
          return times.parse(sNoTz, fmt)
        except:
          discard
  raise newException(OpenParserTomlError, "Failed to parse TOML datetime: " & s)


proc parseHook*(p: var TomlParser, v: var TomlNode)
proc parseObject*(p: var TomlParser, ln: int): TomlNode

proc keyPath(p: var TomlParser): seq[string] =
  ## Consume a key path — bare or quoted identifiers separated by dots.
  result = @[]
  while p.curr.kind in {ttkIdentifier, ttkString}:
    result.add(p.curr.value)
    p.advance()
    if p.curr.kind == ttkDot:
      p.advance()
      continue
    break

proc expectEquals(p: var TomlParser) =
  if p.curr.kind != ttkEquals:
    p.error("Expected '=' after key, got " & $p.curr.kind)
  p.advance()

proc setAtPath(tbl: TomlNode, path: seq[string], val: TomlNode) =
  ## Set a value at a (possibly dotted) key path, creating intermediate tables.
  var cur = tbl
  for i, part in path:
    if i == path.len - 1:
      cur.tableVal[part] = val
    else:
      if not cur.tableVal.hasKey(part):
        cur.tableVal[part] = newTomlTable()
      cur = cur.tableVal[part]

proc parseInlineObject(p: var TomlParser): TomlNode =
  p.advance() # consume '{'
  var obj = newTomlTable()
  while p.curr.kind != ttkRC:
    case p.curr.kind
    of ttkIdentifier, ttkString:
      let key = p.curr.value
      p.advance()
      expectEquals(p)
      var val: TomlNode
      p.parseHook(val)
      obj.tableVal[key] = val
      if p.curr.kind == ttkComma:
        p.advance() # consume comma and continue
      elif p.curr.kind != ttkRC:
        p.error("Expected ',' or '}' in inline table, got " & $p.curr.kind)
    of ttkComment:
      p.advance() # skip comments
    else:
      p.error("Expected key or end of inline table, got " & $p.curr.kind)
  p.advance() # consume '}'
  result = obj

proc parseHook*(p: var TomlParser, v: var TomlNode) =
  case p.curr.kind
  of ttkString:
    v = newTomlString(p.curr.value)
    p.advance()
  of ttkInteger:
    v = newTomlInteger(parseInt(p.curr.value))
    p.advance()
  of ttkFloat:
    v = newTomlFloat(parseFloat(p.curr.value))
    p.advance()
  of ttkBoolean:
    v = newTomlBoolean(p.curr.value.toLowerAscii() == "true")
    p.advance()
  of ttkDateTime:
    v = newTomlDateTime(parseTomlDateTime(p.curr.value))
    p.advance()
  of ttkLC:
    v = p.parseInlineObject()
  of ttkLB:
    # array value: [ v1, v2, ... ]
    p.advance() # consume '['
    var arr = newTomlArray()
    if p.curr.kind != ttkRB:
      while true:
        var item: TomlNode
        p.parseHook(item)
        arr.arrayVal.add(item)
        if p.curr.kind == ttkComma:
          p.advance()
          if p.curr.kind == ttkRB:
            break
        elif p.curr.kind == ttkRB:
          break
        else:
          p.error("Expected ',' or ']' in array, got " & $p.curr.kind)
    p.advance() # consume ']'
    v = arr
  else:
    p.error("Expected a value, got " & $p.curr.kind)

proc parseObjectInto(p: var TomlParser, target: TomlNode) =
  ## Parse key = value entries into `target`, stopping at a table header or EOF.
  while p.curr.kind != ttkEOF and p.curr.kind != ttkLB:
    case p.curr.kind
    of ttkIdentifier, ttkString:
      let path = keyPath(p)
      expectEquals(p)
      var val: TomlNode
      p.parseHook(val)
      setAtPath(target, path, val)
    of ttkComment:
      p.advance()
    else:
      p.error("Expected a key or start of next table, got " & $p.curr.kind)

proc parseObject*(p: var TomlParser, ln: int): TomlNode =
  ## Parse a sequence of key = value entries into a table and return it.
  result = newTomlTable()
  while p.curr.kind == ttkComment:
    p.advance()
  parseObjectInto(p, result)

proc parseRoot*(p: var TomlParser): TomlNode =
  ## Parses the entire TOML document and returns a TomlDocument
  result = newTomlTable()
  while p.curr.kind != ttkEOF:
    case p.curr.kind
    of ttkIdentifier, ttkString:
      # top-level key = value (possibly dotted / quoted)
      let path = keyPath(p)
      expectEquals(p)
      var val: TomlNode
      p.parseHook(val)
      setAtPath(result, path, val)
    of ttkLB:
      p.advance() # consume '['
      if p.curr.kind == ttkLB:
        # [[a.b]] array of tables
        p.advance() # consume second '['
        let path = keyPath(p)
        if p.curr.kind != ttkRB or p.next.kind != ttkRB:
          p.error("Expected ']]' after array of tables header, got " & $p.curr.kind & " and " & $p.next.kind)
        p.advance() # consume first ']'
        p.advance() # consume second ']'
        var parent = result
        for i in 0 ..< path.len - 1:
          let part = path[i]
          if not parent.tableVal.hasKey(part):
            parent.tableVal[part] = newTomlTable()
          parent = parent.tableVal[part]
        let last = path[^1]
        if not parent.tableVal.hasKey(last):
          parent.tableVal[last] = newTomlArray()
        let arr = parent.tableVal[last]
        if arr.kind != tvkArray:
          p.error("'" & last & "' is not an array")
        arr.arrayVal.add(newTomlTable())
        parseObjectInto(p, arr.arrayVal[^1])
      else:
        # [a.b.c] table header
        let path = keyPath(p)
        if p.curr.kind != ttkRB:
          p.error("Expected ']' after table header, got " & $p.curr.kind)
        p.advance() # consume ']'
        var cur = result
        for i, part in path:
          if i == path.len - 1:
            if not cur.tableVal.hasKey(part):
              cur.tableVal[part] = newTomlTable()
            parseObjectInto(p, cur.tableVal[part])
          else:
            if not cur.tableVal.hasKey(part):
              cur.tableVal[part] = newTomlTable()
            cur = cur.tableVal[part]
    of ttkComment:
      p.advance()
    else:
      p.error("Unexpected token in TOML document: " & $p.curr.kind)

proc parseTOML*(input: TOML): TomlDocument =
  ## Parses a TOML string into a `TomlDocument`,
  ## which is a table mapping keys to `TomlNode` nodes
  ## 
  ## For direct-to-struct parsing, use the `parseTOML(input, typedesc[T])` overload instead
  var parser = TomlParser(lex: newTomlLexer(input))
  parser.curr = parser.nextToken()
  parser.next = parser.nextToken()
  var root = parser.parseRoot()
  result = newTomlTable()
  result.tableVal = root.tableVal

proc parseTOML*[T: object|ref object](p: var TomlParser, v: var T) =
  ## The main parsing function that consumes tokens and builds the TOML AST
  discard

proc parseTOML*[T](input: TOML, t: typedesc[T]): T =
  ## Parses a TOML string into a Nim data structure of type T
  var parser = TomlParser(lex: newTomlLexer(input))
  var tmp: T()
  parser.curr = parser.nextToken()
  parser.next = parser.nextToken()
  parser.parseTOML(tmp)
  result = ensureMove(tmp)


proc dumpTOML*(doc: TomlDocument): string =
  ## Serialize a `TomlDocument` back to TOML.
  proc isBareKey(k: string): bool =
    if k.len == 0: return false
    for c in k:
      if c notin {'a'..'z', 'A'..'Z', '0'..'9', '_', '-'}:
        return false
    true
  proc qKey(k: string): string =
    if isBareKey(k): k else: "\"" & k.replace("\\", "\\\\").replace("\"", "\\\"") & "\""
  proc dumpValue(n: TomlNode, s: var string)
  proc dumpTable(tbl: TomlNode, s: var string, path: string) =
    if path.len > 0:
      s.add("[" & path & "]\n")
    for k, v in tbl.tableVal:
      case v.kind
      of tvkTable:
        dumpTable(v, s, (if path.len == 0: k else: path & "." & k))
      of tvkArray:
        if v.arrayVal.len > 0 and v.arrayVal[0].kind == tvkTable:
          let p = if path.len == 0: k else: path & "." & k
          for item in v.arrayVal:
            s.add("[[" & p & "]]\n")
            dumpTable(item, s, "")
        else:
          s.add(qKey(k) & " = ")
          dumpValue(v, s)
          s.add("\n")
      else:
        s.add(qKey(k) & " = ")
        dumpValue(v, s)
        s.add("\n")
  proc dumpValue(n: TomlNode, s: var string) =
    case n.kind
    of tvkString:
      s.add("\"" & n.strVal.replace("\\", "\\\\").replace("\"", "\\\"") & "\"")
    of tvkInteger:
      s.add($n.intVal)
    of tvkFloat:
      s.add($n.floatVal)
    of tvkBoolean:
      s.add($n.boolVal)
    of tvkDateTime:
      s.add(n.dateTimeVal.format("yyyy-MM-dd'T'HH:mm:ss"))
    of tvkArray:
      s.add("[")
      for i, item in n.arrayVal:
        if i > 0: s.add(", ")
        dumpValue(item, s)
      s.add("]")
    of tvkTable:
      s.add("{")
      var first = true
      for kk, vv in n.tableVal:
        if not first: s.add(", ")
        first = false
        s.add("\"" & kk & "\" = ")
        dumpValue(vv, s)
      s.add("}")
  result = ""
  dumpTable(doc, result, "")


#
# Dump Hook API
#

when isMainModule:
  proc dumpHook*(s: var string, val: DateTime) =
    s.add(val.format("yyyy-MM-dd'T'HH:mm:ss"))

  let doc = parseTOML(readFile("example.toml"))
  echo toJson(doc)