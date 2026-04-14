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
        critbits, typetraits]

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

  #
  # JSON Parser
  #
  TokenKind = enum
    tkEof,
    tkLBrace = "{"
    tkRBrace = "}"
    tkLBracket = "["
    tkRBracket = "]"
    tkComma = ","
    tkColon = ":"
    tkString, tkNumber, tkTrue, tkFalse, tkNull = "null"

  Lexer = ref object
    input: string
    data: ptr UncheckedArray[char]
    len: int
    pos: int
    line, col: int
    current: char

  Token = ref object
    kind: TokenKind
    value: string
    line, col: int

  Parser = object
    lexer: Lexer
    prev, curr, next: Token
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

proc error(l: var Lexer, msg: string) =
  # Raise a lexer error
  raise newException(OpenParserJsonError, ("Error ($1:$2) " % [$l.line, $l.col]) & msg)

proc error(p: var Parser, msg: string) =
  # Raise a parsing error with the current lexer position
  raise newException(OpenParserJsonError, ("Error ($1:$2) " % [$p.lexer.line, $p.lexer.col]) & msg)

proc openReadOnly*(filename: string, allowRemap = false,
                   mapFlags = cint(-1)): MemFile {.inline.} =
  ## Convenience helper for read-only memory-mapped file opening.
  open(filename, mode = fmRead, allowRemap = allowRemap, mapFlags = mapFlags)

proc isMapped*(m: MemFile): bool {.inline.} =
  ## True when this MemFile currently has a valid mapped region.
  m.mem != nil and m.size > 0


#
# JSONY object variants
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

template fieldPairs*[T: ref object](x: T): untyped =
  x[].fieldPairs

macro isObjectVariant*(v: typed): bool =
  ## Is this an object variant?
  var typ = v.getTypeImpl()
  if typ.kind == nnkSym:
    return ident("false")
  while typ.kind != nnkObjectTy:
    typ = typ[0].getTypeImpl()
  if typ[2].hasKind(nnkRecCase):
    ident("true")
  else:
    ident("false")

proc discriminator*(v: NimNode): NimNode =
  var typ = v.getTypeImpl()
  while typ.kind != nnkObjectTy:
    typ = typ[0].getTypeImpl()
  return typ[nnkRecList][nnkRecCase][nnkIdentDefs][nnkSym]

macro discriminatorFieldName*(v: typed): untyped =
  ## Turns into the discriminator field.
  return newLit($discriminator(v))

macro discriminatorField*(v: typed): untyped =
  ## Turns into the discriminator field.
  let
    fieldName = discriminator(v)
  return quote do:
    `v`.`fieldName`

macro new*(v: typed, d: typed): untyped =
  ## Creates a new object variant with the discriminator field.
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

proc toJson*[T](v: T, opts: JsonOptions = nil): string =
  ## Convert a Nim object to its JSON string representation using dump hooks.
  var s = ""
  dumpHook(s, v)
  result = s

macro toStaticJson*(v: typed, opts: static JsonOptions = nil): untyped =
  ## Converts a Nim object to its JSON representation.
  ## 
  ## This macro uses compile-time reflection to inspect the structure of `v` and 
  ## generate code that constructs a JSON string representation of it, mostly at compile time.
  let tInst = v.getTypeInst()
  if tInst.kind == nnkSym and tInst.strVal == "JsonNode":
    return quote do:
      $`v` # if it's already a JsonNode, just return it as-is without further processing
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
  s.add("\"" & val & "\"")

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
  # echo v.getImpl().treerepr
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
# JSON Parser
#
proc `$`*(tk: TokenKind): string =
  ## Convert TokenKind to string
  result = 
    case tk
    of tkLBrace, tkRBrace, tkLBracket,
        tkRBracket, tkComma, tkColon:
          tk.symbolName
    of tkEof: "<EOF>"
    of tkString: "<string>"
    of tkNumber: "<number>"
    of tkTrue, tkFalse: "<boolean>"
    of tkNull: "<null>"

proc `$`*(tk: Token): string =
  ## Convert Token to string
  result = "TOKEN<kind: " & $tk.kind & 
           (if tk.value.len > 0: ", value:" & tk.value else: "") & 
           ", line:" & $tk.line & ", col:" & $tk.col & ">"

proc nextToken(parser: var Parser): Token {.discardable.}

proc charAt(l: Lexer, idx: int): char {.inline.} =
  if idx < 0 or idx >= l.len: return '\0'
  if l.data != nil: l.data[idx] else: l.input[idx]

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

proc peekChar(l: var Lexer): char =
  l.charAt(l.pos + 1)

proc peekUntil(parser: var Parser, stopChar: char): string =
  var tempPos = parser.lexer.pos
  result = ""
  while tempPos < parser.lexer.len and parser.lexer.charAt(tempPos) != stopChar:
    result.add(parser.lexer.charAt(tempPos))
    inc tempPos

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

proc nextToken(parser: var Parser): Token =
  # Get the next token from the lexer
  skipWhitespace(parser.lexer)
  result = Token(line: parser.lexer.line, col: parser.lexer.col)
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

proc walk(parser: var Parser): Token {.discardable.} =
  # Advance to the next token and return it
  parser.prev = parser.curr
  parser.curr = parser.next
  parser.next = parser.nextToken()
  result = parser.curr

#
# Parse Hooks for JSON Deserialization
#
proc parseHook*(parser: var Parser, field: string, v: var string)
proc parseHook*[T: float|float32|float64](parser: var Parser, field: string, v: var T)
proc parseHook*(parser: var Parser, field: string, v: var bool)
proc parseHook*[T](parser: var Parser, field: string, v: var seq[T])
proc parseHook*[T: ref object](parser: var Parser, field: string, v: var T)
proc parseHook*[T: enum](parser: var Parser, field: string, v: var T)
proc parseHook*[K: string, V](parser: var Parser, field: string, v: var AnyTable[K, V])
proc parseHook*[T](parser: var Parser, field: string, v: var set[T])
proc parseHook*[T: Integers](parser: var Parser, field: string, v: var T)

proc skipValue*(parser: var Parser)

proc expectSkip(parser: var Parser, tkind: TokenKind) =
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
proc skipValue*(parser: var Parser) =
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

#
# Parse Hooks
#
proc parseHook*(parser: var Parser, field: string, v: var string) =
  ## A hook to parse string fields
  v = parser.curr.value
  parser.walk()

proc parseHook*[T: float|float32|float64](parser: var Parser, field: string, v: var T) =
  ## A hook to parse integer fields
  v = parser.curr.value.parseFloat()
  parser.walk()

proc parseHook*(parser: var Parser, field: string, v: var bool) =
  ## A hook to parse boolean fields
  v = parser.curr.kind == tkTrue
  parser.walk()

proc parseHook*[K: string, V](parser: var Parser, field: string, v: var AnyTable[K, V]) =
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
    parser.parseHook(key, item)
    v[key] = item

    # normalize cursor position for scalar vs composite parseHook implementations
    if parser.curr.kind notin {tkComma, tkRBrace, tkEof}:
      parser.walk()
    if parser.curr.kind == tkComma:
      parser.walk()

  parser.expectSkip(tkRBrace)

proc parseHook*[T: enum](parser: var Parser, field: string, v: var T) =
  ## A hook to parse enum fields
  if parser.curr.kind == tkString:
    let enumStr = parser.curr.value
    v = strutils.parseEnum[T](enumStr)
    parser.walk()
  elif parser.curr.kind == tkNumber:
    let enumNum = parser.curr.value.parseInt()
    v = T(enumNum)
    parser.walk()
  else:
    parser.error(unexpectedTokenExpected % [$parser.curr.kind, "string or number"])

proc parseHook*[T](parser: var Parser, field: string, v: var set[T]) = 
  ## A hook to parse set fields from JSON arrays
  parser.expectSkip(tkLBracket) # start of array
  while parser.curr.kind != tkRBracket:
    var item: T
    parser.parseHook("", item)
    v.incl(item)
    if parser.curr.kind == tkComma:
      parser.walk()
  parser.expectSkip(tkRBracket) # end of array

proc parseHook*[T: distinct](parser: var Parser, field: string, v: var T) =
  ## A hook to parse distinct types by parsing their base type and then converting
  var tmp: T.distinctBase
  parser.parseHook("", tmp)
  v = T(tmp)
  parser.walk()

proc parseHook*[T: Integers](parser: var Parser, field: string, v: var T) =
  ## A hook to parse integer fields
  v = cast[v.type](parser.curr.value.parseInt())
  parser.walk()

macro getObjectFields(obj: typed): untyped =
  let objImpl = obj.getType()
  let tempFields =
    if objImpl.kind == nnkBracketExpr and objImpl[0].kind == nnkSym and objImpl[0].strVal == "ref":
      objImpl[1].getType()[2]
    else:
    obj.getType()[2]
  var fields =
    if tempFields.len > 0 and tempFields[0].kind == nnkRecList:
      tempFields[0]
    else:
      tempFields
  var fieldList = newNimNode(nnkBracket)
  for field in fields:
    case field.kind
    of nnkSym:
      fieldList.add(newLit(field.strVal))
    else: discard
  result = newStmtList().add(nnkPrefix.newTree(ident"@", fieldList))

proc parseHook*[T: object|ref object](parser: var Parser, field: string, v: var T) =
  parser.expectSkip(tkLBrace) # start of object
  const objectFields: seq[string] = getObjectFields(v)

  while parser.curr.kind notin {tkRBrace, tkEof}:
    if parser.curr.kind != tkString:
      parser.error(unexpectedTokenExpected % [$parser.curr.kind, $tkString])

    let key = parser.curr.value

    # Variant discriminator handling: initialize correct branch early.
    when isObjectVariant(v):
      if key == discriminatorFieldName(v):
        parser.walk()
        parser.expectSkip(tkColon)

        var d: type(discriminatorField(v))
        parser.parseHook(key, d)
        new(v, d) # initialize the object variant with the discriminator value

        if parser.curr.kind notin {tkComma, tkRBrace, tkEof}:
          parser.walk()
        if parser.curr.kind == tkComma:
          parser.walk()
        continue

    var matched = false
    for objField, objVal in v.fieldPairs:
      if key == objField:
        matched = true
        parser.walk()
        parser.expectSkip(tkColon)

        when compiles(parser.parseHook(objField, objVal)):
          parser.parseHook(objField, objVal)
        else:
          var tmp: type(objVal)
          parser.parseHook(objField, tmp)
          when compiles(objVal = tmp):
            objVal = tmp
          else:
            parser.error("Field `" & objField & "` is immutable")

        if parser.curr.kind notin {tkComma, tkRBrace, tkEof}:
          parser.walk()
        break

    if not matched:
      # unknown key/value
      parser.walk()
      parser.expectSkip(tkColon)
      parser.skipValue()

    if parser.curr.kind == tkComma:
      parser.walk()

  parser.expectSkip(tkRBrace)

proc parseHook*[T: ref object](parser: var Parser, field: string, v: var T) =
  ## A hook to parse ref object fields
  if parser.curr.kind == tkNull:
    v = nil
    parser.walk()
  else:
    if v.isNil:
      new(v)
    parser.parseHook("", v[])

proc parseHook*[T](parser: var Parser, field: string, v: var seq[T]) =
  ## A hook to parse sequence fields
  parser.expectSkip(tkLBracket) # start of array
  while parser.curr.kind != tkRBracket:
    var item: T
    parser.parseHook("", item)
    v.add(item)
    if parser.curr.kind == tkComma:
      parser.walk()
  parser.expectSkip(tkRBracket) # end of array

#
# JsonNode Objects
#
#
# Forward decl for JSON parsing
#
proc parseObject(parser: var Parser, obj: var JsonNode)
proc parseArray(parser: var Parser, arr: var JsonNode)

#
# JSON Parsing Implementation
#
proc parseObject(parser: var Parser, obj: var JsonNode) =
  # Parse a JSON object
  while parser.curr.kind != tkRBrace:
    let token = parser.walk()
    case token.kind
    of tkEOF:
      raise newException(ValueError, "EOF reached while parsing object")
    of tkString:
      let key = token.value
      let colonToken = parser.walk()
      if colonToken.kind != tkColon:
        raise newException(ValueError,
          "Expected ':' after key '" & key & "' at line " & $token.line & ", column " & $token.col)
      let valToken = parser.walk()
      case valToken.kind
        of tkString:
          obj[key] = newJString(valToken.value)
        of tkNumber:
          let num =
            try:
              newJInt(parseInt(valToken.value))
            except ValueError:
              newJFloat(parseFloat(valToken.value))
          obj[key] = num
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
    of tkComma, tkRBrace:
      continue
    else:
      parser.error(unexpectedToken % [$token.kind])
  parser.walk() # consume the closing '}'

proc parseArray(parser: var Parser, arr: var JsonNode) =
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

proc initParser(lexer: Lexer): Parser =
  result = Parser(lexer: lexer)
  result.curr = result.nextToken()
  result.next = result.nextToken()

proc parseAnyRoot(parser: var Parser): JsonNode =
  case parser.curr.kind
  of tkLBrace:
    result = newJObject()
    parser.parseObject(result)
  of tkLBracket:
    result = newJArray()
    parser.parseArray(result)
  else:
    parser.error(unexpectedToken % [$parser.curr.kind])

proc parseAnyRootL(parser: var Parser): JsonNode =
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
proc parseJson[T: object|ref object](parser: var Parser, v: var T) =
  case parser.curr.kind
  of tkLBrace:
    parser.parseHook("", v)
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
      parser = Parser(lexer: newLexer(`str`))
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
