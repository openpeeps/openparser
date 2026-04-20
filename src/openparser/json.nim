# A collection of tiny parsers and dumpers
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/openparser

## This module implements a JSON parser and serializer for Nim language.
## 
## It can convert Nim objects, tables and arrays to JSON strings and vice versa.
## It also provides compile-time options for customizing the serialization process.
## 
## This JSON implementation has a similar API to [pkg/jsony](https://github.com/treeform/jsony)
## but is designed to work with memory-mapped files and provide a more flexible and extensible
## serialization/deserialization mechanism.
import std/[macros, macrocache, json, sequtils,
        strutils, options, tables, enumutils, memfiles,
        critbits, typetraits, strutils]

export json # re-exporting the standard JSON module for JsonNode and related types

type
  Integers* = int | int8 | int16 | int32 | int64 | uint8 | uint16 | uint32 | uint64 | uint
  
  AnyTable*[K, V] =
    Table[K, V] | OrderedTable[K, V] | TableRef[K, V] | OrderedTableRef[K, V]
  
  JsonOptions* = ref object
    ## Options for JSON serialization
    pretty: bool
      ## Whether to pretty-print the JSON output
    skipFields*: seq[string]
      ## Fields to skip during serialization
    skipNulls: bool
      ## Whether to skip fields that are null
      ## during serialization
    lineDelimited: bool
      ## Whether to output JSON in a line-delimited
      ## format. This is useful for large datasets
      ## where each JSON object is on a new line
    skipDefaults: bool
      ## Whether to skip fields that have default
      ## values during serialization
    skipUnknownFields: bool = true
      ## Whether to ignore unknown fields during
      ## deserialization
    indentSize: int = 0
      # Number of spaces to use for indentation when pretty-printing JSON
    newLine: string = "\n"
      # Newline character(s) to use when pretty-printing JSON

  #
  # JSON JsonParser
  #
  TokenKind* = enum
    ## Token kinds for JSON parsing
    tkEof = "<EOF>"
    tkLBrace = "{"
    tkRBrace = "}"
    tkLBracket = "["
    tkRBracket = "]"
    tkComma = ","
    tkColon = ":"
    tkString = "<string>"
    tkNumber = "<number>"
    tkTrue = "<true>"
    tkFalse = "<false>"
    tkNull = "<null>"

  Lexer = ref object
    input: string
    data: ptr UncheckedArray[char]
    len: int
    pos: int
    line, col: int
    current: char

  Token* = ref object
    kind*: TokenKind
    value*: string
    line*, col*, pos*: int

  JsonParser* = object
    lexer: Lexer
    prev*, curr*, next*: Token
    currentField*: Option[string] # for context-aware parseHooks
      ## The name of the current field being parsed, if applicable. This is set
      ## before calling parseHook for a field value, allowing parseHooks to have
      ## context about which field they are parsing
    options: JsonOptions
    lvl: int # indentation level

  OpenParserJsonError* = object of CatchableError

template skippable*() {.pragma.}

const
  invalidToken = "Invalid token `$1`"
  errorEndOfFile = "Unexpected EOF while parsing `$1`"
  unexpectedToken = "Unexpected token `$1`"
  unexpectedTokenExpected = "Got `$1`, expected $2"
  unexpectedChar = "Unexpected character `$1`"

proc charAt(l: Lexer, idx: int): char {.inline.} =
  if idx < 0 or idx >= l.len: return '\0'
  if l.data != nil: l.data[idx] else: l.input[idx]

proc getContext(l: Lexer, posOverride: int = -1): string =
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

# proc `$`(tk: TokenKind): string =
#   ## Convert TokenKind to string
#   result = 
#     case tk
#     of tkLBrace, tkRBrace, tkLBracket,
#         tkRBracket, tkComma, tkColon:
#           tk.symbolName
#     of tkEof: "<EOF>"
#     of tkString: "<string>"
#     of tkNumber: "<number>"
#     of tkTrue, tkFalse: "<boolean>"
#     of tkNull: "<null>"

proc error(l: var Lexer, msg: string) =
  # Raise a lexer error
  let context = getContext(l)
  raise newException(OpenParserJsonError, ("\n" & context & "\n" & "Error ($1:$2) " % [$l.line, $l.col]) & msg)


proc error(p: var JsonParser, msg: string) =
  # Prefer current token coordinates over lexer cursor (lookahead-safe).
  var atPos = p.lexer.pos
  var atLine = p.lexer.line
  var atCol = p.lexer.col

  if p.curr != nil:
    atPos = p.curr.pos
    atLine = p.curr.line
    atCol = p.curr.col

  let context = getContext(p.lexer, atPos)
  raise newException(
    OpenParserJsonError,
    ("\n" & context & "\n" & "Error ($1:$2) " % [$atLine, $atCol]) & msg
  )

proc openReadOnly*(filename: string, allowRemap = false,
                   mapFlags = cint(-1)): MemFile {.inline.} =
  ## Convenience helper for read-only memory-mapped file opening.
  open(filename, mode = fmRead, allowRemap = allowRemap, mapFlags = mapFlags)

proc isMapped*(m: MemFile): bool {.inline.} =
  ## True when this MemFile currently has a valid mapped region.
  m.mem != nil and m.size > 0


#
# JSONY object variants utility macros
# https://github.com/treeform/jsony
#
proc hasKind(node: NimNode, kind: NimNodeKind): bool =
  for c in node.children:
    if c.kind == kind:
      return true
  return false

proc `[]`(node: NimNode, kind: NimNodeKind): NimNode =
  for c in node.children:
    if c.kind == kind:
      return c
  return nil

template fieldPairs[T: ref object](x: T): untyped =
  x[].fieldPairs

macro isObjectVariant(v: typed): bool =
  # Is this an object variant?
  var typ = v.getTypeImpl()
  if typ.kind == nnkSym:
    return ident("false")
  while typ.kind != nnkObjectTy:
    typ = typ[0].getTypeImpl()
  if typ[2].hasKind(nnkRecCase):
    ident("true")
  else:
    ident("false")

proc discriminator(v: NimNode): NimNode =
  var typ = v.getTypeImpl()
  while typ.kind != nnkObjectTy:
    typ = typ[0].getTypeImpl()
  return typ[nnkRecList][nnkRecCase][nnkIdentDefs][nnkSym]

macro discriminatorFieldName(v: typed): untyped =
  # Turns into the discriminator field.
  return newLit($discriminator(v))

macro discriminatorField(v: typed): untyped =
  # Turns into the discriminator field.
  let
    fieldName = discriminator(v)
  return quote do:
    `v`.`fieldName`

macro new(v: typed, d: typed): untyped =
  # Creates a new object variant with the discriminator field.
  let
    typ = v.getTypeInst()
    fieldName = discriminator(v)
  return quote do:
    `v` = `typ`(`fieldName`: `d`)


# Forward declarations
proc objectToJson*(v, valImpl: NimNode, opts: JsonOptions = nil): NimNode
proc arrayToJson*(v, valImpl: NimNode, opts: JsonOptions = nil): NimNode

proc dumpHook*(s: var string, val: string)
proc dumpHook*(s: var string, val: Integers)
proc dumpHook*(s: var string, val: float32|float64)
proc dumpHook*(s: var string, val: bool)
proc dumpHook*(s: var string, val: tuple)
proc dumpHook*(s: var string, val: object)
proc dumpHook*[T: ref object](s: var string, val: T)
proc dumpHook*(s: var string, v: enum)
proc dumpHook*[K: string, V](s: var string, val: AnyTable[K, V])
proc dumpHook*[T](s: var string, val: set[T])
proc dumpHook*[T: distinct](s: var string, v: T)
proc dumpHook*(s: var string, v: JsonNode)

type t[T] = tuple[a: string, b: T]
proc dumpHook*[N, T](s: var string, v: array[N, t[T]])
proc dumpHook*[N, T](s: var string, v: array[N, T])
proc dumpHook*[T](s: var string, v: Option[T])

proc toJson*[T](v: T, opts: JsonOptions = nil): string =
  ## Convert a Nim object to its JSON string representation using dump hooks.
  result.dumpHook(v)

macro toStaticJson*(v: typed, opts: static JsonOptions = nil): untyped =
  ## Converts a Nim object to its JSON representation.
  ## 
  ## This macro uses compile-time reflection to inspect the structure of `v` and 
  ## generate code that constructs a JSON string representation of it, mostly at compile time.
  let tInst = v.getTypeInst()
  if tInst.kind == nnkSym and tInst.strVal == "JsonNode":
    return quote do:
      dumpHook(v)
  # retrieve the implementation of typed `v`
  var valImpl = v.getType()
  var objName = v.getTypeInst()
  case valImpl.kind:
  of nnkObjectTy:
    return objectToJson(v, valImpl, opts)
  of nnkBracketExpr:
    let ty = v.getTypeImpl()
    if ty.kind == nnkRefTy:
      return objectToJson(v, valImpl[1].getType(), opts)
    # sequences or arrays
    return arrayToJson(v, valImpl, opts)
  else: discard

#
# Dump Hooks for JSON Serialization
#
proc dumpHook*[T: distinct](s: var string, v: T) =
  var x = cast[T.distinctBase](v)
  s.dumpHook(x)

proc dumpHook*[K: string, V](s: var string, val: AnyTable[K, V]) =
  ## Converts Table/OrderedTable and ref variants to JSON object.
  when val is TableRef[K, V] or val is OrderedTableRef[K, V]:
    if val.isNil:
      s.add("null")
      return

  s.add("{")
  var i = 0

  when val is TableRef[K, V] or val is OrderedTableRef[K, V]:
    for k, item in val[].pairs:
      if i > 0: s.add(",")
      dumpHook(s, k)     # JSON object key (string)
      s.add(":")
      dumpHook(s, item)  # JSON object value
      inc i
  else:
    for k, item in val.pairs:
      if i > 0: s.add(",")
      dumpHook(s, k)     
      s.add(":")
      dumpHook(s, item)
      inc i

  s.add("}")

proc dumpHook*[T](s: var string, val: set[T]) =
  ## Converts a set to a JSON array.
  s.add("[")
  var i = 0
  for item in val:
    if i > 0: s.add(",")
    dumpHook(s, item)
    inc i
  s.add("]")

proc dumpHook*[T](s: var string, arr: seq[T]) = 
  ## Converts a sequence of items to a JSON array string.
  s.add("[")
  for i, item in arr:
    if i > 0: s.add(",") # add comma between items
    s.dumpHook(item)
  s.add("]")

proc dumpHook*(s: var string, val: string) = 
  ## Converts a string to JSON
  s.add(escapeJson(val))

proc dumpHook*(s: var string, val: Integers) = 
  ## Converts int to JSON
  s.add($val)

proc dumpHook*(s: var string, val: float32|float64) = 
  ## Converts float to JSON
  s.add($val)

proc dumpHook*(s: var string, val: bool) = 
  ## Converts a bool to JSON
  s.add($val)

proc dumpHook*(s: var string, val: object) =
  when isObjectVariant(val):
    const discName = discriminatorFieldName(val)

    s.add("{")
    s.add("\"" & discName & "\":")
    dumpHook(s, discriminatorField(val))

    for fieldName, fieldVal in fieldPairs(val):
      if fieldName != discName:
        s.add(",")
        s.add("\"" & fieldName & "\":")
        dumpHook(s, fieldVal)

    s.add("}")
  else:
    s.add("{")
    var i = 0
    for fieldName, fieldVal in fieldPairs(val):
      if i > 0: s.add(",")
      s.add("\"" & fieldName & "\":")
      dumpHook(s, fieldVal)
      inc i
    s.add("}")

proc dumpHook*[T: ref object](s: var string, val: T) =
  if val.isNil:
    s.add("null")
  else:
    dumpHook(s, val[])

proc dumpHook*(s: var string, v: enum) =
  ## Converts an enum to JSON
  s.add("\"" & $v & "\"")

proc dumpHook*(s: var string, val: tuple) = 
  ## Converts a tuple to JSON Object
  s.add("{")
  var i = 0
  var tupleKeys: seq[string]
  for k, v in val.fieldPairs:
    tupleKeys.add(k) # kinda hacky but works
  for k, v in val.fieldPairs:
    s.add("\"" & k & "\":")
    dumpHook(s, v)
    if i > 0 and k != tupleKeys[^1]:
      s.add(",") # add comma between fields
    inc i
  s.add("}")

proc dumpHook*(s: var string, v: JsonNode) =
  ## Converts a JsonNode to its JSON string representation.
  if v == nil:
    s.add("null")
    return
  case v.kind
  of JObject:
    s.add("{")
    var i = 0
    for k, item in v.fields:
      if i > 0: s.add(",")
      s.add("\"" & k & "\"") # JSON object key (string)
      s.add(":")
      dumpHook(s, item)  # JSON object value
      inc i
    s.add("}")
  of JArray:
    s.add("[")
    for i, item in v.elems:
      if i > 0: s.add(",") # add comma between items
      dumpHook(s, item)
    s.add("]")
  of JString: dumpHook(s, v.str)
  of JInt:   dumpHook(s, v.num)
  of JFloat: dumpHook(s, v.fnum)
  of JBool:  dumpHook(s, v.bval)
  of JNull:  s.add("null")

proc dumpHook*[N, T](s: var string, v: array[N, t[T]]) = 
  ## Converts an array of tuples to a JSON array of objects, where
  ## each tuple is converted to a JSON object with "a" and "b" fields.
  s.add("[")
  for i, item in v:
    if i > 0: s.add(",") # add comma between items
    s.add("{")
    dumpHook(s, item.a) # convert the "a" field of the tuple to JSON
    s.add(":")
    dumpHook(s, item.b) # convert the "b" field of the tuple to JSON
    s.add("}")
  s.add("]")

proc dumpHook*[N, T](s: var string, v: array[N, T]) =
  ## Converts an array to a JSON array by dumping each element using dumpHook
  s.add("[")
  for i, item in v:
    if i > 0: s.add(",") # add comma between items
    dumpHook(s, item) # convert each item to JSON
  s.add("]")

proc dumpHook*[T](s: var string, v: Option[T]) =
  ## Converts an Option[T] to JSON, where None is represented as null
  if v.isSome:
    dumpHook(s, v.get())
  else:
    s.add("null")

proc objectToJson*(v, valImpl: NimNode, opts: JsonOptions = nil): NimNode =
  var hasRecCase = false
  for field in valImpl[2]:
    if field.kind == nnkRecCase:
      hasRecCase = true
      break

  if hasRecCase:
    # Variant objects: use runtime dumpHook path (handles discriminator + active branch)
    result = quote do:
      block:
        var s = ""
        dumpHook(s, `v`)
        s
    return

  let strObj = newStmtList()
  var i = 0
  let res = genSym(nskVar, "res")
  var len = valImpl[2].len
  for field in valImpl[2]:
    case field.kind
    of nnkSym:
      let fieldName = field.strVal
      if opts != nil:
        if opts.skipFields.len > 0 and opts.skipFields.contains(fieldName):
          inc i
          continue
      if i != 0 and i < len:
        strObj.add(newCall(ident"add", res, newLit(",")))
      strObj.add(newCall(ident"add", res, newLit("\"" & fieldName & "\":")))
      strObj.add(
        nnkWhenStmt.newTree(
          nnkElifBranch.newTree(
            nnkCall.newTree(
              ident("compiles"),
              newCall(ident("dumpHook"), res, newDotExpr(v, ident(fieldName)))
            ),
            newCall(ident("dumpHook"), res, newDotExpr(v, ident(fieldName)))
          )
        )
      )
      inc i
    of nnkRecCase:
      discard
    else:
      discard

  let objectSerialization = genSym(nskLabel, "objectSerialization")
  result = newStmtList()
  result.add quote do:
    block `objectSerialization`:
      var `res` = "{"
      `strObj`
      `res`.add("}")
      `res`

proc arrayToJson*(v, valImpl: NimNode, opts: JsonOptions = nil): NimNode =
  ## Converts a Nim array or sequence to its JSON representation.
  var strArrayItems = newStmtList()
  var blockLabel = genSym(nskLabel, "VoodooArraySerialization")
  result = newStmtList()
  result.add quote do:
    block `blockLabel`:
      var str: string
      str.add("[")
      if `v`.len > 0:
        dumpHook(str, `v`[0]) # first item without comma
        for i, item in `v`[1..^1]:
          str.add(",")
          dumpHook(str, item)
      str.add("]")
      move(str) # return the JSON string

#
# Lexer API
#
proc `$`(tk: Token): string =
  ## Convert Token to string
  result = "TOKEN<kind: " & $tk.kind & 
           (if tk.value.len > 0: ", value:" & tk.value else: "") & 
           ", line:" & $tk.line & ", col:" & $tk.col & ">"

proc nextToken(parser: var JsonParser): Token {.discardable.}

proc newLexer(input: string): Lexer =
  result = Lexer(input: input, data: nil, len: input.len, pos: 0, line: 1, col: 1)
  result.current = result.charAt(0)

proc newLexer(mem: pointer, size: int): Lexer =
  result = Lexer(data: cast[ptr UncheckedArray[char]](mem), len: size, pos: 0, line: 1, col: 1)
  result.current = result.charAt(0)

proc advance(l: var Lexer) =
  if l.pos < l.len - 1:
    inc l.pos
    l.current = l.charAt(l.pos)
    inc l.col
  else:
    l.pos = l.len
    l.current = '\0'

proc matchKeyword(l: var Lexer, kw: string): bool =
  if l.pos + kw.len > l.len: return false
  for i, c in kw:
    if l.charAt(l.pos + i) != c:
      return false
  for _ in 0..<kw.len:
    advance(l)
  result = true

proc skipWhitespace(l: var Lexer) =
  while true:
    case l.current
    of {' ', '\t', '\n', '\r'}:
      if l.current == '\n':
        inc l.line
        l.col = 0
      advance(l)
    else: break

proc readString(l: var Lexer): string =
  result = ""
  while true:
    case l.current
    of '\0':
      l.error(errorEndOfFile % "string")
    of '"':
      advance(l) # consume closing quote
      break
    of '\\':
      advance(l) # move to escape code
      case l.current
      of '"', '\\', '/':
        result.add(l.current)
      of 'b':
        result.add('\b')
      of 'f':
        result.add('\f')
      of 'n':
        result.add('\n')
      of 'r':
        result.add('\r')
      of 't':
        result.add('\t')
      of 'u':
        # keep \uXXXX as-is for now (prevents tokenizer breakage)
        result.add("\\u")
        for _ in 0..<4:
          advance(l)
          if l.current notin {'0'..'9', 'a'..'f', 'A'..'F'}:
            l.error("Invalid unicode escape sequence")
          result.add(l.current)
      else:
        l.error("Invalid escape sequence `\\" & $l.current & "`")
      advance(l) # move past escape code (or last hex digit for \uXXXX)
    of '\n', '\r':
      l.error("Unescaped newline in string")
    else:
      result.add(l.current)
      advance(l)

proc readNumber(l: var Lexer): string =
  result = ""
  if l.current == '-':
    result.add('-')
    advance(l)
  while l.current in {'0'..'9'}:
    result.add(l.current)
    advance(l)
  if l.current == '.':
    result.add('.')
    advance(l)
    while l.current in {'0'..'9'}:
      result.add(l.current)
      advance(l)
  if l.current in {'e', 'E'}:
    # scientific notation
    result.add(l.current)
    advance(l)
    if l.current in {'+', '-'}:
      result.add(l.current)
      advance(l)
    while l.current in {'0'..'9'}:
      result.add(l.current)
      advance(l)

#
# JSON Parsing implementation to Nim objects
#
proc nextToken(parser: var JsonParser): Token =
  # Get the next token from the lexer
  skipWhitespace(parser.lexer)
  result = Token(
    line: parser.lexer.line,
    col: parser.lexer.col,
    pos: parser.lexer.pos
  )
  case parser.lexer.current
  of '\0':
    result.kind = tkEof
  of '{':
    result.kind = tkLBrace
    advance(parser.lexer)
  of '}':
    result.kind = tkRBrace
    advance(parser.lexer)
  of '[':
    result.kind = tkLBracket
    advance(parser.lexer)
  of ']':
    result.kind = tkRBracket
    advance(parser.lexer)
  of ',':
    result.kind = tkComma
    advance(parser.lexer)
  of ':':
    result.kind = tkColon
    advance(parser.lexer)
  of '"':
    advance(parser.lexer)  # skip the opening quote
    result.kind = tkString
    result.value = readString(parser.lexer)
  of '0'..'9', '-':
    result.kind = tkNumber
    result.value = readNumber(parser.lexer)
  of 't':
    if matchKeyword(parser.lexer, "true"):
      result.kind = tkTrue
    else:
      parser.lexer.error(invalidToken % $parser.lexer.current)
  of 'f':
    if matchKeyword(parser.lexer, "false"):
      result.kind = tkFalse
    else:
      parser.lexer.error(invalidToken % $parser.lexer.current)
  of 'n':
    if matchKeyword(parser.lexer, "null"):
      result.kind = tkNull
    else:
      parser.lexer.error(invalidToken % $parser.lexer.current)
  else:
    parser.lexer.error(unexpectedChar % [$parser.lexer.current])

#
# Parse Hooks for JSON Deserialization
#
proc parseHook*(parser: var JsonParser, v: var string)
proc parseHook*[T: float|float32|float64](parser: var JsonParser, v: var T)
proc parseHook*(parser: var JsonParser, v: var bool)
proc parseHook*[T](parser: var JsonParser, v: var seq[T])
proc parseHook*[T: ref object](parser: var JsonParser, v: var T)
proc parseHook*[T: enum](parser: var JsonParser, v: var T)
proc parseHook*[K: string, V](parser: var JsonParser, v: var AnyTable[K, V])
proc parseHook*[T](parser: var JsonParser, v: var set[T])
proc parseHook*[T: Integers](parser: var JsonParser, v: var T)
proc parseHook*[T: tuple](parser: var JsonParser, v: var T)

proc skipValue*(parser: var JsonParser)

proc walk*(parser: var JsonParser): Token {.discardable.} =
  # Advance to the next token and return it
  parser.prev = parser.curr
  parser.curr = parser.next
  parser.next = parser.nextToken()
  result = parser.curr

proc expectSkip(parser: var JsonParser, tkind: TokenKind) =
  if parser.curr.kind != tkind:
    if parser.curr.kind == tkEof:
      parser.error(errorEndOfFile % $parser.curr.kind)
    else:
      parser.error(unexpectedTokenExpected % [$parser.curr.kind, $tkind])
  else:
    parser.walk()
    

template withKeyValue(body: untyped) {.inject.} =
  let key = parser.curr
  parser.walk()
  parser.expectSkip(tkColon)
  var token = parser.curr
  parser.walk()
  body
  if parser.curr.kind == tkComma:
    parser.walk()

template withKey(body: untyped) {.inject.} =
  let key = parser.walk()
  parser.expectSkip(tkColon)
  body
  if parser.next.kind == tkComma:
    parser.walk()
  
#
# Skip Values
#
proc skipValue*(parser: var JsonParser) =
  ## Skip the current value in the parser
  case parser.curr.kind
  of tkLBrace:
    # skip object
    while parser.curr.kind != tkRBrace:
      parser.walk()
      skipValue(parser)
      if parser.curr.kind == tkComma:
        parser.walk()
    parser.expectSkip(tkRBrace)
  of tkLBracket:
    # skip array
    while parser.curr.kind != tkRBracket:
      parser.walk()
      skipValue(parser)
      if parser.curr.kind == tkComma:
        parser.walk()
    parser.expectSkip(tkRBracket)
  else:
    while parser.curr.kind notin {tkComma, tkRBrace, tkRBracket, tkEof}:
      parser.walk()

template ensureComma() {.inject.} =
  if parser.curr.kind == tkComma:
    parser.walk()
  elif parser.curr.kind notin {tkRBrace, tkRBracket}:
    parser.error(unexpectedTokenExpected % [$parser.curr.kind, "comma or closing brace/bracket"])

#
# Parse Hooks
#
proc parseHook*(parser: var JsonParser, v: var string) =
  ## A hook to parse string fields
  v = parser.curr.value
  parser.walk()


proc parseHook*[T: float|float32|float64](parser: var JsonParser, v: var T) =
  ## A hook to parse integer fields
  v = parser.curr.value.parseFloat()
  parser.walk()

proc parseHook*(parser: var JsonParser, v: var bool) =
  ## A hook to parse boolean fields
  v = parser.curr.kind == tkTrue
  parser.walk()

proc parseHook*[K: string, V](parser: var JsonParser, v: var AnyTable[K, V]) =
  ## Parse JSON object into Table/OrderedTable and ref variants.
  when v is TableRef[K, V] or v is OrderedTableRef[K, V]:
    if parser.curr.kind == tkNull:
      v = nil
      parser.walk()
      return

    when v is TableRef[K, V]:
      if v.isNil: v = newTable[K, V]() else: v[].clear()
    else:
      if v.isNil: v = newOrderedTable[K, V]() else: v[].clear()

  else:
    if parser.curr.kind == tkNull:
      when v is Table[K, V]:
        v = initTable[K, V]()
      else:
        v = initOrderedTable[K, V]()
      parser.walk()
      return

    when v is Table[K, V]:
      v = initTable[K, V]()
    else:
      v = initOrderedTable[K, V]()

  parser.expectSkip(tkLBrace) # consume '{' and move to first key/value or '}'
  while parser.curr.kind != tkRBrace:
    if parser.curr.kind != tkString:
      parser.error(unexpectedTokenExpected % [$parser.curr.kind, $tkString])

    let key = parser.curr.value
    parser.walk()
    parser.expectSkip(tkColon)

    var item: V
    parser.currentField = some(key)
    parser.parseHook(item)
    v[key] = item

    # normalize cursor position for scalar vs composite parseHook implementations
    # if parser.curr.kind notin {tkComma, tkRBrace, tkEof}:
    #   parser.walk()
    ensureComma()
  parser.expectSkip(tkRBrace) # consume closing '}' and move on

proc parseHook*[T: enum](parser: var JsonParser, v: var T) =
  ## A hook to parse enum fields
  if parser.curr.kind == tkString:
    let enumStr = parser.curr.value
    v = strutils.parseEnum[T](enumStr)
    parser.walk()
  elif parser.curr.kind == tkNumber:
    let enumNum = parser.curr.value.parseInt() # it must be an integer
    v = T(enumNum)
    parser.walk()
  else:
    parser.error(unexpectedTokenExpected % [$parser.curr.kind, "string or number"])

proc parseHook*[T](parser: var JsonParser, v: var set[T]) = 
  ## A hook to parse set fields from JSON arrays
  parser.expectSkip(tkLBracket) # start of array
  while parser.curr.kind != tkRBracket:
    var item: T
    parser.parseHook(item)
    v.incl(item)
    if parser.curr.kind == tkComma:
      parser.walk()
  parser.expectSkip(tkRBracket) # end of array

proc parseHook*[T: distinct](parser: var JsonParser, v: var T) =
  ## A hook to parse distinct types by parsing their base type and then converting
  var tmp: T.distinctBase
  parser.parseHook(tmp)
  v = T(tmp)
  parser.walk()

proc parseHook*[T: Integers](parser: var JsonParser, v: var T) =
  ## A hook to parse integer fields
  v = cast[v.type](parser.curr.value.parseInt())
  parser.walk()

proc snakeCase(s: string): string =
  if s.len == 0: return ""
  result.add(s[0]) # preserve first char case
  for i in 1 ..< s.len:
    let c = s[i]
    if c != '_':
      result.add(c.toLowerAscii)

proc parseHook*[T: tuple](parser: var JsonParser, v: var T) =
  ## A hook to parse tuple fields (named tuples)
  parser.expectSkip(tkLBrace) # start of object
  when T.isNamedTuple():
    while parser.curr.kind != tkRBrace:
      if parser.curr.kind != tkString:
        parser.error(unexpectedTokenExpected % [$parser.curr.kind, $tkString])
      let key = parser.curr.value
      parser.walk()
      parser.expectSkip(tkColon)
      var matched = false
      block all:
        for k, field in v.fieldPairs:
          if k == key or snakeCase(k) == snakeCase(key):
            var tmp: type(field)
            parser.parseHook(tmp)
            field = tmp
            matched = true
            break all
      if not matched:
        parser.skipValue()
      ensureComma()
    parser.expectSkip(tkRBrace)
    
      
macro copyFieldsBeforeRecCase(dst, src: typed): untyped =
  # Copy fields declared before `nnkRecCase` (shared fields in variant objects).
  var typ = dst.getTypeImpl()
  while typ.kind != nnkObjectTy:
    typ = typ[0].getTypeImpl()

  let recList = typ[nnkRecList]
  result = newStmtList()

  for n in recList:
    if n.kind == nnkRecCase:
      break
    case n.kind
    of nnkIdentDefs:
      for i in 0 ..< n.len - 2:
        let field = n[i]
        result.add quote do:
          `dst`.`field` = `src`.`field`
    of nnkSym:
      let field = n
      result.add quote do:
        `dst`.`field` = `src`.`field`
    else:
      discard

proc parseHook*[T: object|ref object](parser: var JsonParser, v: var T) =
  parser.expectSkip(tkLBrace) # start of object
  # const objectFields: seq[string] = getObjectFields(v)

  while parser.curr.kind notin {tkRBrace, tkEof}:
    if parser.curr.kind != tkString:
      parser.error(unexpectedTokenExpected % [$parser.curr.kind, $tkString])

    let key = parser.curr.value

    # variant discriminator handling: initialize correct branch early
    when isObjectVariant(v):
      if key == discriminatorFieldName(v):
        parser.walk()
        parser.expectSkip(tkColon)

        var d: type(discriminatorField(v))
        parser.currentField = some(key)
        parser.parseHook(d)

        let prev = v
        new(v, d)
        copyFieldsBeforeRecCase(v, prev)
        ensureComma()
        # if parser.curr.kind notin {tkComma, tkRBrace, tkEof}:
        #   parser.walk()
        # if parser.curr.kind == tkComma:
        #   parser.walk()
        continue

    var matched = false
    for objField, objVal in v.fieldPairs:
      if key == objField:
        matched = true
        parser.walk()
        parser.expectSkip(tkColon)

        when compiles(parser.parseHook(objVal)):
          parser.currentField = some(objField)
          parser.parseHook(objVal)
        else:
          var tmp: type(objVal)
          parser.currentField = some(objField)
          parser.parseHook(tmp)
          when compiles(objVal = tmp):
            objVal = tmp
          else:
            parser.error("Field `" & objField & "` is immutable")

        ensureComma()
        break

    if not matched:
      # unknown key/value
      parser.walk()
      parser.expectSkip(tkColon)
      parser.skipValue()

    if parser.curr.kind == tkComma:
      parser.walk()
    # ensureComma()
  parser.expectSkip(tkRBrace)

proc parseHook*[T: ref object](parser: var JsonParser, v: var T) =
  ## A hook to parse ref object fields
  if parser.curr.kind == tkNull:
    v = nil
    parser.walk()
  else:
    if v.isNil:
      new(v)
    parser.parseHook(v[])

proc parseHook*[T](parser: var JsonParser, v: var seq[T]) =
  ## A hook to parse sequence fields
  parser.expectSkip(tkLBracket) # start of array
  while parser.curr.kind != tkRBracket:
    var item: T
    parser.parseHook(item)
    v.add(item)
    ensureComma()
  parser.expectSkip(tkRBracket) # end of array


proc parseHook*[T](parser: var JsonParser, v: var Option[T]) =
  ## A hook to parse a value wrapped in an Option type, treating null as
  ## None and any other value as Some(value).
  if parser.curr.kind == tkNull:
    v = none(T)
    parser.walk()
  else:
    var tmp: T
    parser.parseHook(tmp)
    v = some(tmp)
  
#
# JsonNode Objects
#

#
# Forward decl for JSON parsing
#
proc parseObject(parser: var JsonParser, obj: var JsonNode)
proc parseArray(parser: var JsonParser, arr: var JsonNode)

#
# JSON Parsing Implementation
#
proc parseObject(parser: var JsonParser, obj: var JsonNode) =
  # Parse a JSON object
  while parser.curr.kind != tkRBrace:
    let token = parser.walk()
    case token.kind
    of tkEOF:
      parser.error(errorEndOfFile % "object")
    of tkString:
      let key = token.value
      let colonToken = parser.walk()
      if colonToken.kind != tkColon:
        parser.error(unexpectedTokenExpected % [$colonToken.kind, $tkColon])
      let valToken = parser.walk()
      case valToken.kind
      of tkString:
        obj[key] = newJString(valToken.value)
      of tkNumber:
        var numNode: JsonNode
        try:
          numNode = newJInt(parseInt(valToken.value))
        except ValueError:
          try:
            numNode = newJFloat(parseFloat(valToken.value))
          except ValueError:
            parser.error("Invalid number format: " & valToken.value)
        obj[key] = numNode
      of tkTrue, tkFalse:
        obj[key] = newJBool(valToken.kind == tkTrue)
      of tkNull:
        obj[key] = newJNull()
      of tkLBrace:
        var nestedObj = newJObject()
        parser.parseObject(nestedObj)
        obj[key] = nestedObj
      of tkLBracket:
        var nestArr = newJArray()
        parser.parseArray(nestArr)
        obj[key] = nestArr
      else:
        parser.error(unexpectedToken % [$valToken.kind])
    else:
      if parser.curr.kind notin {tkComma, tkRBrace, tkEof}:
        parser.error(unexpectedToken % [$token.kind])
  parser.walk() # consume the closing '}'

proc parseArray(parser: var JsonParser, arr: var JsonNode) =
  # Parse a JSON array to JsonNode
  while parser.curr.kind != tkRBracket:
    let token = parser.walk()
    case token.kind
    of tkEOF:
      parser.error(errorEndOfFile % "array")
    of tkLBracket:
      # nested array
      var nestedArr = newJArray()
      parser.parseArray(nestedArr)
      arr.add(nestedArr)
    of tkString:
      arr.add(newJString(token.value))
    of tkNumber:
      let num =
        try:
          newJInt(parseInt(token.value))
        except ValueError:
          newJFloat(parseFloat(token.value))
      arr.add(num)
    of tkTrue, tkFalse:
      arr.add(newJBool(token.kind == tkTrue))
    of tkNull:
      arr.add(newJNull())
    of tkLBrace:
      var nestedObj = newJObject()
      parser.parseObject(nestedObj)
      arr.add(nestedObj)
    of tkComma, tkRBracket:
      continue
    else:
      parser.error(unexpectedToken % [$token.kind])
  parser.walk() # consume the closing ']'

proc initParser(lexer: Lexer): JsonParser =
  result = JsonParser(lexer: lexer)
  result.curr = result.nextToken()
  result.next = result.nextToken()

proc parseAnyRoot(parser: var JsonParser): JsonNode =
  case parser.curr.kind
  of tkLBrace:
    result = newJObject()
    parser.parseObject(result)
  of tkLBracket:
    result = newJArray()
    parser.parseArray(result)
  else:
    parser.error(unexpectedToken % [$parser.curr.kind])

proc parseAnyRootL(parser: var JsonParser): JsonNode =
  result = newJArray()
  while parser.curr.kind != tkEof:
    case parser.curr.kind
    of tkLBrace:
      var obj = newJObject()
      parser.parseObject(obj)
      result.add(obj)
    of tkLBracket:
      var arr = newJArray()
      parser.parseArray(arr)
      result.add(arr)
    else:
      parser.error(unexpectedToken % [$parser.curr.kind])

proc fromJson*(str: string): JsonNode =
  ## Parse a JSON from `str` and returns the standard `JsonNode`
  var parser = initParser(newLexer(str))
  result = parseAnyRoot(parser)

proc fromJsonL*(str: string): JsonNode =
  ## Parse line-delimited JSON from `str` and returns a `JsonNode` array
  var parser = initParser(newLexer(str))
  result = parseAnyRootL(parser)

proc fromJson*(mapped: MemFile): JsonNode =
  ## Parse JSON directly from mapped memory.
  var parser = initParser(newLexer(mapped.mem, mapped.size))
  result = parseAnyRoot(parser)

proc fromJsonL*(mapped: MemFile): JsonNode =
  ## Parse line-delimited JSON directly from mapped memory.
  var parser = initParser(newLexer(mapped.mem, mapped.size))
  result = parseAnyRootL(parser)

proc fromJsonFile*(filename: string): JsonNode =
  ## Parse JSON from a memory-mapped file.
  var mf = memfiles.open(filename, fmRead)
  defer: mf.close()
  result = fromJson(mf)

proc fromJsonLFile*(filename: string): JsonNode =
  ## Parse JSON-L from a memory-mapped file.
  var mf = memfiles.open(filename, fmRead)
  defer: mf.close()
  result = fromJsonL(mf)

#
# Nim Objects
#
proc parseJson[T: object|ref object](parser: var JsonParser, v: var T) =
  case parser.curr.kind
  of tkLBrace:
    parser.parseHook(v)
  else:
    parser.error(unexpectedToken % [$parser.curr.kind])

macro fromJsonMacro(x: typed, str: typed): untyped =
  # macro to parse JSON string `str` into object of type `x`
  var objIdent = x.getTypeImpl()[1]
  # var objRef: bool
  var
    blockStmtList = newStmtList()
    blockStmtId = genSym(nskLabel, "voodoo")
  add blockStmtList, quote do:
    var
      tmp = `objIdent`()
      parser = JsonParser(lexer: newLexer(`str`))
    parser.curr = parser.nextToken()
    parser.next = parser.nextToken()
    parser.parseJson(tmp)
    ensureMove(tmp) # return the parsed object
  var blockStmt = newBlockStmt(blockStmtId, blockStmtList)
  result = newStmtList().add(blockStmt)

proc fromJson*[T](s: string, x: typedesc[T]): T =
  ## Provide a direct to object conversion from JSON string to Nim objects
  when x is JsonNode:
    return fromJson(s)
  else:
    return fromJsonMacro(x, s)
