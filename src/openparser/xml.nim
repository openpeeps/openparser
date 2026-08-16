# A collection of tiny parsers and dumpers
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/openparser

## This module implements an XML parser and serializer for Nim language.
##
## It can convert Nim objects, tables and arrays to XML strings and vice versa.
## It also provides compile-time options for customizing the serialization process.
##
## This XML implementation has a similar API to the JSON module and is designed
## to work with memory-mapped files and provide a flexible and extensible
## serialization/deserialization mechanism.

import std/[macros, strutils, options, tables,
            critbits, typetraits, memfiles]

import ./private/[types, lexutils]
when not defined(openparserXmlNoSimd) and (defined(amd64) or defined(i386)):
  import ./private/xml_simd

type
  XmlOptions* = ref object
    ## Options for XML serialization
    pretty: bool
      ## Whether to pretty-print the XML output
    skipFields*: seq[string]
      ## Fields to skip during serialization
    skipNulls: bool
      ## Whether to skip fields that are null
    skipDefaults: bool
      ## Whether to skip fields that have default values
    skipUnknownFields*: bool = true
      ## Whether to ignore unknown fields during deserialization
    indentSize: int = 2
      ## Number of spaces to use for indentation when pretty-printing XML
    newLine: string = "\n"
      ## Newline character(s) to use when pretty-printing XML
    rootTag*: string
      ## Override the root element tag name (default: type name)
    preserveComments: bool = true
      ## Whether to preserve comments in the DOM tree
    allowDoctype: bool = true
      ## Whether to allow DOCTYPE declarations
    allowProcessingInstructions: bool = true
      ## Whether to allow processing instructions

  #
  # XML Token kinds
  #
  XmlTokenKind* = enum
    ## XmlToken kinds for XML parsing
    xtkEof = "<EOF>"
    xtkTagOpen = "<name>"
    xtkTagClose = "</name>"
    xtkSelfClosing = "/>"
    xtkEndTagClose = ">"
    xtkAttributeName = "<attribute-name>"
    xtkEquals = "="
    xtkAttributeValue = "<attribute-value>"
    xtkText = "<text>"
    xtkComment = "<comment>"
    xtkCdata = "<![CDATA[...]]>"
    xtkProlog = "<?...?>"
    xtkDoctype = "<!DOCTYPE>"

  XmlLexer = ref object
    input: string
    data: ptr UncheckedArray[char]
    len, pos, line, col: int
    current: char
    inTag: bool

  XmlToken* = ref object
    ## Represents a single token produced by the XML lexer
    kind*: XmlTokenKind
    value*: string
    tag*: string
      ## Tag name for xtkTagOpen/xtkTagClose/xtkSelfClosing
    line*, col*, pos*: int

  XmlParser* = object
    lexer: XmlLexer
    prev*, curr*, next*: XmlToken
    currentField*: Option[string]
      ## The name of the current field being parsed, if applicable
    options: XmlOptions
    lvl: int

  OpenParserXmlError* = object of CatchableError

  XmlNodeKind* = enum
    ## The kind of an XML node
    xnElement
    xnText
    xnComment
    xnCdata
    xnProlog
    xnDoctype

  XmlNode* {.acyclic.} = ref object
    ## Represents a node in the XML DOM tree
    case kind*: XmlNodeKind
    of xnElement:
      tag*: string
      attrs*: OrderedTable[string, string]
      children*: seq[XmlNode]
    of xnText:
      text*: string
    of xnComment:
      comment*: string
    of xnCdata:
      cdata*: string
    of xnProlog:
      prolog*: string
    of xnDoctype:
      doctype*: string

  XML* = string
    ## A simple alias for XML strings

template skippable*() {.pragma.}

const
  invalidToken* = "Invalid token `$1`"
  errorEndOfFile* = "Unexpected EOF while parsing `$1`"
  unexpectedToken* = "Unexpected token `$1`"
  unexpectedTokenExpected* = "Got `$1`, expected $2"
  unexpectedChar* = "Unexpected character `$1`"

proc error*(l: var XmlLexer, msg: string) =
  let context = getContext(l)
  raise newException(OpenParserXmlError, ("\n" & context & "\n" & "Error ($1:$2) " % [$l.line, $l.col]) & msg)

proc error*(p: var XmlParser, msg: string) =
  var atPos = p.lexer.pos
  var atLine = p.lexer.line
  var atCol = p.lexer.col

  if p.curr != nil:
    atPos = p.curr.pos
    atLine = p.curr.line
    atCol = p.curr.col

  let context = getContext(p.lexer, atPos)
  raise newException(
    OpenParserXmlError,
    ("\n" & context & "\n" & "Error ($1:$2) " % [$atLine, $atCol]) & msg
  )

proc openReadOnly*(filename: string, allowRemap = false,
                   mapFlags = cint(-1)): MemFile {.inline.} =
  ## Convenience helper for read-only memory-mapped file opening.
  open(filename, mode = fmRead, allowRemap = allowRemap, mapFlags = mapFlags)

proc isMapped*(m: MemFile): bool {.inline.} =
  ## True when this MemFile currently has a valid mapped region.
  m.mem != nil and m.size > 0

proc newXmlLexer*(input: string): XmlLexer =
  result = XmlLexer(input: input, data: nil, len: input.len, pos: 0, line: 1, col: 1)
  result.current = result.charAt(0)

proc newXmlLexer*(mem: pointer, size: int): XmlLexer =
  result = XmlLexer(data: cast[ptr UncheckedArray[char]](mem), len: size, pos: 0, line: 1, col: 1)
  result.current = result.charAt(0)

# Forward declarations
proc dumpHook*(s: var string, val: string)
proc dumpHook*(s: var string, val: Integers)
proc dumpHook*(s: var string, val: float32|float64)
proc dumpHook*(s: var string, val: bool)
proc dumpHook*(s: var string, val: tuple)
proc dumpHook*(s: var string, val: object)
proc dumpHook*[T](s: var string, val: ref T)
proc dumpHook*(s: var string, val: pointer)
proc dumpHook*(s: var string, v: enum)
proc dumpHook*[K: string, V](s: var string, val: AnyTable[K, V])
proc dumpHook*[T](s: var string, val: set[T])
proc dumpHook*[T: distinct](s: var string, v: T)
proc dumpHook*(s: var string, v: XmlNode)
proc dumpHook*(s: var string, v: char)
proc dumpHook*[T](s: var string, v: seq[T])
proc dumpHook*[N, T](s: var string, v: array[N, T])
proc dumpHook*[T](s: var string, v: Option[T])
proc dumpHook*[T](s: var string, v: CritBitTree[T])

# ---------------------------------------------------------------------------
# Entity decoding
# ---------------------------------------------------------------------------

proc decodeEntity(l: var XmlLexer, buf: var string) =
  ## Decode an XML entity starting after the '&'
  advance(l) # skip '&'
  if l.current == '#':
    advance(l)
    var codePoint: int
    if l.current == 'x' or l.current == 'X':
      advance(l) # skip 'x'
      while l.current in {'0'..'9', 'a'..'f', 'A'..'F'}:
        codePoint = codePoint * 16 + (case l.current
        of '0'..'9': ord(l.current) - ord('0')
        of 'a'..'f': ord(l.current) - ord('a') + 10
        of 'A'..'F': ord(l.current) - ord('A') + 10
        else: 0)
        advance(l)
    else:
      while l.current in {'0'..'9'}:
        codePoint = codePoint * 10 + (ord(l.current) - ord('0'))
        advance(l)
    if l.current != ';':
      l.error("Expected ';' after numeric entity")
    advance(l)
    # Encode as UTF-8
    if codePoint < 128:
      buf.add(char(codePoint))
    elif codePoint < 2048:
      buf.add(char(0xC0 or (codePoint shr 6)))
      buf.add(char(0x80 or (codePoint and 0x3F)))
    elif codePoint < 65536:
      buf.add(char(0xE0 or (codePoint shr 12)))
      buf.add(char(0x80 or ((codePoint shr 6) and 0x3F)))
      buf.add(char(0x80 or (codePoint and 0x3F)))
    else:
      buf.add(char(0xF0 or (codePoint shr 18)))
      buf.add(char(0x80 or ((codePoint shr 12) and 0x3F)))
      buf.add(char(0x80 or ((codePoint shr 6) and 0x3F)))
      buf.add(char(0x80 or (codePoint and 0x3F)))
  else:
    var entity = ""
    while l.current in {'a'..'z', 'A'..'Z', '0'..'9'}:
      entity.add(l.current)
      advance(l)
    if l.current != ';':
      l.error("Expected ';' after entity name")
    advance(l)
    case entity
    of "amp":  buf.add('&')
    of "lt":   buf.add('<')
    of "gt":   buf.add('>')
    of "quot": buf.add('"')
    of "apos": buf.add('\'')
    else: l.error("Unknown entity `" & entity & "`")

# ---------------------------------------------------------------------------
# Lexer
# ---------------------------------------------------------------------------

proc readText(l: var XmlLexer, tok: var XmlToken) =
  ## Read text content from the input, decoding entities
  let buf = if l.data != nil: l.data else: cast[ptr UncheckedArray[char]](unsafeAddr l.input[0])
  tok.value = ""
  while l.current notin {'<', '\0'}:
    if l.current == '&':
      decodeEntity(l, tok.value)
    elif l.current == '\n':
      inc l.line
      l.col = 0
      advance(l)
    else:
      when not defined(openparserXmlNoSimd) and (defined(amd64) or defined(i386)):
        # Scan forward for next '<' or '&' using SIMD
        let startPos = l.pos
        var endPos = scanTextRun(cast[ptr char](buf), l.pos, l.len)
        if endPos < 0: endPos = l.len
        let copyLen = endPos - startPos
        if copyLen > 0:
          let oldLen = tok.value.len
          tok.value.setLen(oldLen + copyLen)
          copyMem(addr tok.value[oldLen], addr buf[startPos], copyLen)
          # Count newlines in copied chunk
          for i in startPos ..< endPos:
            if buf[i] == '\n':
              inc l.line
              l.col = 0
          l.col += copyLen
        l.pos = endPos
        l.current = l.charAt(l.pos)
        # If we stopped at '&', decode the entity
        if l.current == '&':
          decodeEntity(l, tok.value)
        else:
          break
      else:
        tok.value.add(l.current)
        advance(l)
  tok.kind = xtkText

proc readAttrValue(l: var XmlLexer, quote: char): string =
  ## Read an attribute value between quotes, decoding entities
  advance(l) # skip opening quote
  result = ""
  while l.current != quote and l.current != '\0':
    if l.current == '&':
      decodeEntity(l, result)
    elif l.current == '\n':
      inc l.line
      l.col = 0
      advance(l)
    else:
      when not defined(openparserXmlNoSimd) and (defined(amd64) or defined(i386)):
        let buf = if l.data != nil: l.data else: cast[ptr UncheckedArray[char]](unsafeAddr l.input[0])
        let startPos = l.pos
        var endPos = scanAttrValueEnd(cast[ptr char](buf), l.pos, l.len, quote)
        if endPos < 0: endPos = l.len
        let copyLen = endPos - startPos
        if copyLen > 0:
          let oldLen = result.len
          result.setLen(oldLen + copyLen)
          copyMem(addr result[oldLen], addr buf[startPos], copyLen)
          for i in startPos ..< endPos:
            if buf[i] == '\n':
              inc l.line
              l.col = 0
          l.col += copyLen
        l.pos = endPos
        l.current = l.charAt(l.pos)
        if l.current == '&':
          decodeEntity(l, result)
        else:
          break
      else:
        result.add(l.current)
        advance(l)
  if l.current != quote:
    l.error("Unterminated attribute value")
  advance(l) # skip closing quote

proc readName(l: var XmlLexer): string =
  ## Read an XML name (tag or attribute name)
  when not defined(openparserXmlNoSimd) and (defined(amd64) or defined(i386)):
    let buf = if l.data != nil: l.data else: cast[ptr UncheckedArray[char]](unsafeAddr l.input[0])
    let startPos = l.pos
    var endPos = scanNameEnd(cast[ptr char](buf), l.pos, l.len)
    if endPos < 0: endPos = l.len
    let copyLen = endPos - startPos
    result = newString(copyLen)
    if copyLen > 0:
      copyMem(addr result[0], addr buf[startPos], copyLen)
    l.pos = endPos
    l.current = l.charAt(l.pos)
  else:
    result = ""
    while l.current in {'a'..'z', 'A'..'Z', '0'..'9', '-', '_', '.', ':'}:
      result.add(l.current)
      advance(l)

proc nextToken(l: var XmlLexer): XmlToken =
  ## Produce the next token from the XML input
  if l.inTag:
    # In tag context: skip whitespace before attribute names, '=', '>', '/>'
    while l.current in {' ', '\t', '\n', '\r'}:
      if l.current == '\n':
        inc l.line
        l.col = 0
      advance(l)

  result = XmlToken(line: l.line, col: l.col, pos: l.pos)

  if l.inTag:
    # In tag context: handle attribute names, '=', values, '>', '/>'
    case l.current
    of '\0':
      result.kind = xtkEof
    of '>':
      advance(l)
      l.inTag = false
      result.kind = xtkEndTagClose
    of '/':
      advance(l) # skip '/'
      if l.current == '>':
        advance(l) # skip '>'
        l.inTag = false
        result.kind = xtkSelfClosing
      else:
        l.error(unexpectedChar % $l.current)
    of '=':
      advance(l)
      result.kind = xtkEquals
    of '"', '\'':
      # Attribute value (should not happen directly after whitespace skip)
      let quote = l.current
      result.kind = xtkAttributeValue
      result.value = readAttrValue(l, quote)
    of 'a'..'z', 'A'..'Z', '_', '-', '.', ':':
      # Attribute name
      result.kind = xtkAttributeName
      result.value = readName(l)
    else:
      l.error(unexpectedChar % $l.current)
  else:
    # Not in tag context
    case l.current
    of '\0':
      result.kind = xtkEof
    of '<':
      advance(l) # skip '<'
      case l.current
      of '/':
        # Closing tag
        advance(l) # skip '/'
        result.tag = readName(l)
        result.kind = xtkTagClose
        # Skip whitespace before '>'
        while l.current in {' ', '\t', '\n', '\r'}:
          if l.current == '\n':
            inc l.line
            l.col = 0
          advance(l)
        if l.current != '>':
          l.error(unexpectedChar % $l.current)
        advance(l) # skip '>'
        l.inTag = false
      of '?':
        # Processing instruction (e.g. <?xml version="1.0"?>)
        advance(l) # skip '?'
        var piContent = ""
        while true:
          if l.current == '\0':
            l.error(errorEndOfFile % "processing instruction")
          if l.current == '?' and l.charAt(l.pos + 1) == '>':
            advance(l)
            advance(l)
            break
          piContent.add(l.current)
          advance(l)
        result.kind = xtkProlog
        result.value = piContent.strip()
      of '!':
        advance(l) # skip '!'
        if l.current == '-' and l.charAt(l.pos + 1) == '-':
          advance(l) # skip first '-'
          advance(l) # skip second '-'
          var commentContent = ""
          while true:
            if l.current == '\0':
              l.error(errorEndOfFile % "comment")
            if l.current == '-' and l.charAt(l.pos + 1) == '-' and l.charAt(l.pos + 2) == '>':
              advance(l)
              advance(l)
              advance(l)
              break
            commentContent.add(l.current)
            advance(l)
          result.kind = xtkComment
          result.value = commentContent
        elif l.current == '[' and l.charAt(l.pos + 1) == 'C' and l.charAt(l.pos + 2) == 'D' and
             l.charAt(l.pos + 3) == 'A' and l.charAt(l.pos + 4) == 'T' and
             l.charAt(l.pos + 5) == 'A' and l.charAt(l.pos + 6) == '[':
          for _ in 0 ..< 7: advance(l) # skip '[CDATA['
          var cdataContent = ""
          while true:
            if l.current == '\0':
              l.error(errorEndOfFile % "CDATA section")
            if l.current == ']' and l.charAt(l.pos + 1) == ']' and l.charAt(l.pos + 2) == '>':
              advance(l)
              advance(l)
              advance(l)
              break
            cdataContent.add(l.current)
            advance(l)
          result.kind = xtkCdata
          result.value = cdataContent
        else:
          # DOCTYPE
          var doctypeContent = "!"
          while l.current notin {'>', '\0'}:
            doctypeContent.add(l.current)
            advance(l)
          if l.current == '>':
            advance(l)
          result.kind = xtkDoctype
          result.value = doctypeContent.strip()
      else:
        # Opening tag
        let tagName = readName(l)
        result.kind = xtkTagOpen
        result.tag = tagName
        l.inTag = true
    else:
      # Text content
      result.kind = xtkText
      readText(l, result)
    # After reading text, we're not in a tag

# ---------------------------------------------------------------------------
# Parser
# ---------------------------------------------------------------------------

proc nextToken(p: var XmlParser): XmlToken {.discardable.}

proc advance*(p: var XmlParser): XmlToken {.discardable.} =
  p.prev = p.curr
  p.curr = p.next
  p.next = p.nextToken()
  result = p.curr

proc expectSkip*(p: var XmlParser, tkind: XmlTokenKind) =
  if p.curr.kind != tkind:
    if p.curr.kind == xtkEof:
      p.error(errorEndOfFile % $tkind)
    else:
      p.error(unexpectedTokenExpected % [$p.curr.kind, $tkind])
  else:
    p.advance()

template ensureComma* {.inject.} =
  discard  # XML doesn't use commas, but keep for API parity

proc isWhitespaceOnly(s: string): bool =
  for c in s:
    if c notin {' ', '\t', '\n', '\r'}:
      return false
  true

# ---------------------------------------------------------------------------
# Skip Values
# ---------------------------------------------------------------------------

proc skipValue*(p: var XmlParser) =
  ## Skip the current element (including all children)
  case p.curr.kind
  of xtkTagOpen:
    let tagName = p.curr.tag
    p.advance() # consume opening tag
    if p.curr.kind == xtkSelfClosing:
      p.advance()
      return
    if p.curr.kind == xtkEndTagClose:
      p.advance()
    while true:
      if p.curr.kind == xtkEof:
        p.error(errorEndOfFile % "element")
      if p.curr.kind == xtkTagClose and p.curr.tag == tagName:
        p.advance()
        break
      if p.curr.kind == xtkTagOpen:
        skipValue(p)
      else:
        p.advance()
  of xtkText, xtkComment, xtkCdata:
    p.advance()
  of xtkAttributeName, xtkEquals, xtkAttributeValue:
    p.advance()
  else:
    p.advance()

# ---------------------------------------------------------------------------
# Dump Hooks for XML Serialization
# ---------------------------------------------------------------------------

proc xmlEscape*(s: string): string =
  ## Escape a string for XML text content
  result = ""
  for c in s:
    case c
    of '&': result.add("&amp;")
    of '<': result.add("&lt;")
    of '>': result.add("&gt;")
    else: result.add(c)

proc xmlAttrEscape*(s: string): string =
  ## Escape a string for XML attribute values
  result = ""
  for c in s:
    case c
    of '&': result.add("&amp;")
    of '<': result.add("&lt;")
    of '>': result.add("&gt;")
    of '"': result.add("&quot;")
    of '\'': result.add("&apos;")
    else: result.add(c)

proc dumpHook*[T: distinct](s: var string, v: T) =
  var x = cast[T.distinctBase](v)
  s.dumpHook(x)

proc dumpHook*[K: string, V](s: var string, val: AnyTable[K, V]) =
  when val is TableRef[K, V] or val is OrderedTableRef[K, V]:
    if val.isNil:
      return
  for k, item in val.pairs:
    s.add("<" & k & ">")
    dumpHook(s, item)
    s.add("</" & k & ">")

proc dumpHook*[T](s: var string, val: set[T]) =
  for item in val:
    s.add("<item>")
    dumpHook(s, item)
    s.add("</item>")

proc dumpHook*[T](s: var string, v: seq[T]) =
  for item in v:
    s.add("<item>")
    dumpHook(s, item)
    s.add("</item>")

proc dumpHook*(s: var string, val: string) =
  s.add(xmlEscape(val))

proc dumpHook*(s: var string, val: Integers) =
  s.add($val)

proc dumpHook*(s: var string, val: float32|float64) =
  s.add($val)

proc dumpHook*(s: var string, val: bool) =
  s.add($val)

proc dumpHook*[T, R](s: var string, val: T, renameVal: R, tag: string) =
  ## Shared object dumping with tag name support.
  when val is object or val is ref object:
    when isObjectVariant(val):
      const discName = discriminatorFieldName(val)
      s.add("<" & tag & " ")
      s.add(discriminatorField(val))
      s.add("=\"")
      s.add(xmlAttrEscape($discriminatorField(val)))
      s.add("\">")
      for fieldName, fieldVal in fieldPairs(val):
        if fieldName != discName:
          var wireName = fieldName
          when compiles(renameHook(renameVal, wireName)):
            renameHook(renameVal, wireName)
          s.add("<" & wireName & ">")
          dumpHook(s, fieldVal)
          s.add("</" & wireName & ">")
      s.add("</" & tag & ">")
    else:
      s.add("<" & tag & ">")
      var i = 0
      for fieldName, fieldVal in fieldPairs(val):
        var wireName = fieldName
        when compiles(renameHook(renameVal, wireName)):
          renameHook(renameVal, wireName)
        when fieldVal is object or fieldVal is ref object:
          dumpHook(s, fieldVal, renameVal, wireName)
        else:
          s.add("<" & wireName & ">")
          dumpHook(s, fieldVal)
          s.add("</" & wireName & ">")
        inc i
      s.add("</" & tag & ">")
  else:
    # Scalar value - just dump it with the tag
    s.add("<" & tag & ">")
    dumpHook(s, val)
    s.add("</" & tag & ">")

proc dumpHook*(s: var string, val: object) =
  ## Dump an object as an XML element.
  ## Uses type name as tag name.
  s.add("<" & name(type(val)) & ">")
  for fieldName, fieldVal in fieldPairs(val):
    var wireName = fieldName
    dumpHook(s, fieldVal, val, wireName)
  s.add("</" & name(type(val)) & ">")

proc dumpHook*[T](s: var string, val: ref T) =
  if val.isNil:
    s.add("null")
  else:
    dumpHook(s, val[], val, name(type(val)))

proc dumpHook*(s: var string, val: pointer) =
  if val == nil:
    s.add("null")
  else:
    s.add("<pointer>" & $cast[uint](val) & "</pointer>")

proc dumpHook*(s: var string, v: enum) =
  s.add($v)

proc dumpHook*(s: var string, val: tuple) =
  s.add("<tuple>")
  for k, v in val.fieldPairs:
    s.add("<" & k & ">")
    dumpHook(s, v)
    s.add("</" & k & ">")
  s.add("</tuple>")

proc dumpHook*(s: var string, v: XmlNode) =
  case v.kind
  of xnElement:
    s.add("<" & v.tag)
    for attrKey, attrVal in v.attrs:
      s.add(" " & attrKey & "=\"")
      s.add(xmlAttrEscape(attrVal))
      s.add("\"")
    if v.children.len == 0:
      s.add("/>")
    else:
      s.add(">")
      for child in v.children:
        dumpHook(s, child)
      s.add("</" & v.tag & ">")
  of xnText:
    s.add(xmlEscape(v.text))
  of xnComment:
    s.add("<!--" & v.comment & "-->")
  of xnCdata:
    s.add("<![CDATA[" & v.cdata & "]]>")
  of xnProlog:
    s.add("<?" & v.prolog & "?>")
  of xnDoctype:
    s.add("<!" & v.doctype & ">")

proc dumpHook*(s: var string, v: char) =
  s.add(xmlEscape($v))

proc dumpHook*[N, T](s: var string, v: array[N, T]) =
  for item in v:
    s.add("<item>")
    dumpHook(s, item)
    s.add("</item>")

proc dumpHook*[T](s: var string, v: Option[T]) =
  if v.isSome:
    dumpHook(s, v.get())

proc dumpHook*[T](s: var string, v: CritBitTree[T]) =
  for key, item in v:
    s.add("<" & key & ">")
    dumpHook(s, item)
    s.add("</" & key & ">")

# ---------------------------------------------------------------------------
# Parse Hooks for XML Deserialization
# ---------------------------------------------------------------------------

proc parseHook*(p: var XmlParser, v: var string)
proc parseHook*[T: float|float32|float64](p: var XmlParser, v: var T)
proc parseHook*(p: var XmlParser, v: var bool)
proc parseHook*[T](p: var XmlParser, v: var seq[T])
proc parseHook*[T: object](p: var XmlParser, v: var T)
proc parseHook*[T: ref object](p: var XmlParser, v: var T)
proc parseHook*[T: enum](p: var XmlParser, v: var T)
proc parseHook*[K: string, V](p: var XmlParser, v: var AnyTable[K, V])
proc parseHook*[T](p: var XmlParser, v: var set[T])
proc parseHook*[T: Integers](p: var XmlParser, v: var T)
proc parseHook*[T: tuple](p: var XmlParser, v: var T)

proc readElementContent(p: var XmlParser): string =
  ## Read text and CDATA content from within an element until closing tag
  result = ""
  while p.curr.kind notin {xtkTagClose, xtkEndTagClose, xtkSelfClosing, xtkEof}:
    case p.curr.kind
    of xtkText:
      result.add(p.curr.value)
    of xtkCdata:
      result.add(p.curr.value)
    of xtkComment:
      discard # skip comments in content
    else:
      break
    p.advance()

proc skipWhitespaceText(p: var XmlParser) =
  ## Skip whitespace-only text tokens
  while p.curr.kind == xtkText and isWhitespaceOnly(p.curr.value):
    p.advance()

#
# Scalar parse hooks
#
proc parseHook*(p: var XmlParser, v: var string) =
  ## Parse an XML element's text content into a string
  if p.curr.kind == xtkTagOpen:
    p.advance() # consume opening tag
    if p.curr.kind == xtkSelfClosing:
      v = ""
      p.advance()
      return
    if p.curr.kind == xtkEndTagClose:
      p.advance() # consume the '>' after tag name
    # Read text content
    v = readElementContent(p)
    # Consume closing tag
    skipWhitespaceText(p)
    if p.curr.kind == xtkTagClose:
      p.advance()
  else:
    v = p.curr.value
    p.advance()

proc parseHook*(p: var XmlParser, v: var bool) =
  ## Parse an XML element's text content into a bool
  if p.curr.kind == xtkTagOpen:
    p.advance()
    if p.curr.kind == xtkSelfClosing:
      v = false
      p.advance()
      return
    if p.curr.kind == xtkEndTagClose:
      p.advance()
    let text = readElementContent(p)
    v = text.parseBool()
    skipWhitespaceText(p)
    if p.curr.kind == xtkTagClose:
      p.advance()
  else:
    v = p.curr.value.parseBool()
    p.advance()

proc parseHook*[T: float|float32|float64](p: var XmlParser, v: var T) =
  if p.curr.kind == xtkTagOpen:
    p.advance()
    if p.curr.kind == xtkSelfClosing:
      v = T(0)
      p.advance()
      return
    if p.curr.kind == xtkEndTagClose:
      p.advance()
    let text = readElementContent(p)
    v = text.parseFloat()
    skipWhitespaceText(p)
    if p.curr.kind == xtkTagClose:
      p.advance()
  else:
    v = p.curr.value.parseFloat()
    p.advance()

proc parseHook*[T: Integers](p: var XmlParser, v: var T) =
  if p.curr.kind == xtkTagOpen:
    p.advance()
    if p.curr.kind == xtkSelfClosing:
      v = T(0)
      p.advance()
      return
    if p.curr.kind == xtkEndTagClose:
      p.advance()
    let text = readElementContent(p)
    v = cast[T](text.parseInt())
    skipWhitespaceText(p)
    if p.curr.kind == xtkTagClose:
      p.advance()
  else:
    v = cast[T](p.curr.value.parseInt())
    p.advance()

proc parseHook*[T: enum](p: var XmlParser, v: var T) =
  if p.curr.kind == xtkTagOpen:
    p.advance()
    if p.curr.kind == xtkSelfClosing:
      p.error("Cannot parse enum from self-closing element")
    if p.curr.kind == xtkEndTagClose:
      p.advance() # consume the '>' after tag name
    let text = readElementContent(p)
    try:
      v = strutils.parseEnum[T](text)
    except ValueError:
      p.error("Cannot parse `" & text & "` as " & $T)
    skipWhitespaceText(p)
    if p.curr.kind == xtkTagClose:
      p.advance()
  elif p.curr.kind == xtkText:
    try:
      v = strutils.parseEnum[T](p.curr.value)
    except ValueError:
      p.error("Cannot parse `" & p.curr.value & "` as " & $T)
    p.advance()
  else:
    p.error(unexpectedTokenExpected % [$p.curr.kind, "text or element"])

proc parseHook*[T: distinct](p: var XmlParser, v: var T) =
  var tmp: T.distinctBase
  p.parseHook(tmp)
  v = T(tmp)

proc parseHook*[T](p: var XmlParser, v: var Option[T]) =
  if p.curr.kind == xtkTagOpen:
    # Check for self-closing (empty → none)
    let savedTag = p.curr.tag
    p.advance()
    if p.curr.kind == xtkSelfClosing:
      v = none(T)
      p.advance()
      return
    if p.curr.kind == xtkEndTagClose:
      p.advance()
      # Check if this is immediately followed by a close tag (empty element)
      if p.curr.kind == xtkTagClose and p.curr.tag == savedTag:
        v = none(T)
        p.advance()
        return
    # Has content - parse as some
    var tmp: T
    p.parseHook(tmp)
    # Consume closing tag if present
    skipWhitespaceText(p)
    if p.curr.kind == xtkTagClose:
      p.advance()
    v = some(tmp)
  elif p.curr.kind == xtkText:
    var tmp: T
    p.parseHook(tmp)
    v = some(tmp)
  elif p.curr.kind == xtkText:
    var tmp: T
    p.parseHook(tmp)
    v = some(tmp)
  else:
    v = none(T)

proc parseHook*[T](p: var XmlParser, v: var set[T]) =
  ## Parse XML element's children into a set
  if p.curr.kind == xtkTagOpen:
    p.advance()
    if p.curr.kind == xtkSelfClosing:
      p.advance()
      return
    if p.curr.kind == xtkEndTagClose:
      p.advance()
      # Don't return - continue to parse children
    while p.curr.kind != xtkTagClose:
      if p.curr.kind == xtkEof:
        p.error(errorEndOfFile % "set")
      if p.curr.kind == xtkTagOpen:
        var item: T
        p.parseHook(item)
        v.incl(item)
      else:
        p.advance()
    p.advance()
  else:
    p.error(unexpectedTokenExpected % [$p.curr.kind, $xtkTagOpen])

proc parseHook*[T](p: var XmlParser, v: var seq[T]) =
  ## Parse XML elements into a sequence.
  ## Expects repeated child elements or a container element with repeated children.
  if p.curr.kind == xtkTagOpen:
    let containerTag = p.curr.tag
    p.advance()
    if p.curr.kind == xtkSelfClosing:
      p.advance()
      return
    if p.curr.kind == xtkEndTagClose:
      p.advance()
      # Don't return - continue to parse children
    while true:
      if p.curr.kind == xtkTagClose:
        if p.curr.tag == containerTag:
          p.advance()
          break
        p.advance()
        continue
      if p.curr.kind == xtkEof:
        p.error(errorEndOfFile % "sequence")
      if p.curr.kind == xtkTagOpen:
        var item: T
        p.parseHook(item)
        v.add(item)
      elif p.curr.kind == xtkText:
        # Text content in a container - try to parse as item
        # Only skip whitespace
        if not isWhitespaceOnly(p.curr.value):
          var item: T
          p.parseHook(item)
          v.add(item)
        else:
          p.advance()
      else:
        p.advance()
  elif p.curr.kind == xtkText:
    # For root-level seq: text before first element
    var item: T
    p.parseHook(item)
    v.add(item)
  else:
    p.error(unexpectedTokenExpected % [$p.curr.kind, $xtkTagOpen])

proc parseHook*[N: static[int]; T](p: var XmlParser, v: var array[N, T]) =
  var idx = 0
  if p.curr.kind == xtkTagOpen:
    let containerTag = p.curr.tag
    p.advance()
    if p.curr.kind == xtkSelfClosing:
      p.advance()
      return
    if p.curr.kind == xtkEndTagClose:
      p.advance()
      # Don't return - continue to parse children
    while true:
      if p.curr.kind == xtkTagClose:
        if p.curr.tag == containerTag:
          p.advance()
          break
        p.advance()
        continue
      if p.curr.kind == xtkEof:
        p.error(errorEndOfFile % "array")
      if idx >= N:
        p.error("Array overflow: more items than " & $N)
      if p.curr.kind == xtkTagOpen:
        var item: T
        p.parseHook(item)
        v[idx] = item
        inc idx
      else:
        p.advance()
  else:
    p.error(unexpectedTokenExpected % [$p.curr.kind, $xtkTagOpen])

proc parseHook*[T: tuple](p: var XmlParser, v: var T) =
  if p.curr.kind == xtkTagOpen:
    p.advance()
    if p.curr.kind == xtkSelfClosing:
      p.advance()
      return
    if p.curr.kind == xtkEndTagClose:
      p.advance()
      return
    when T.isNamedTuple():
      while p.curr.kind != xtkTagClose:
        if p.curr.kind == xtkEof:
          p.error(errorEndOfFile % "tuple")
        if p.curr.kind == xtkTagOpen:
          let childTag = p.curr.tag
          var matched = false
          for k, field in v.fieldPairs:
            if k == childTag:
              matched = true
              p.parseHook(field)
              break
          if not matched:
            skipValue(p)
        else:
          p.advance()
      p.advance()
    else:
      p.error("Cannot parse unnamed tuple from XML")

proc parseHook*[K: string, V](p: var XmlParser, v: var AnyTable[K, V]) =
  when v is TableRef[K, V] or v is OrderedTableRef[K, V]:
    if p.curr.kind == xtkTagOpen:
      p.advance()
      if p.curr.kind == xtkSelfClosing:
        p.advance()
        return
      if p.curr.kind == xtkEndTagClose:
        p.advance()
        # Don't return - continue to parse children
      when v is TableRef[K, V]:
        if v.isNil: v = newTable[K, V]() else: v[].clear()
      else:
        if v.isNil: v = newOrderedTable[K, V]() else: v[].clear()
      while p.curr.kind != xtkTagClose:
        if p.curr.kind == xtkEof:
          p.error(errorEndOfFile % "table")
        if p.curr.kind == xtkTagOpen:
          let key = p.curr.tag
          var item: V
          p.parseHook(item)
          v[key] = item
        else:
          p.advance()
      p.advance()
  else:
    if p.curr.kind == xtkTagOpen:
      p.advance()
      if p.curr.kind == xtkSelfClosing:
        p.advance()
        return
      if p.curr.kind == xtkEndTagClose:
        p.advance()
        # Don't return - continue to parse children
      when v is Table[K, V]:
        v = initTable[K, V]()
      else:
        v = initOrderedTable[K, V]()
      while p.curr.kind != xtkTagClose:
        if p.curr.kind == xtkEof:
          p.error(errorEndOfFile % "table")
        if p.curr.kind == xtkTagOpen:
          let key = p.curr.tag
          var item: V
          p.parseHook(item)
          v[key] = item
        else:
          p.advance()
      p.advance()

proc parseHook*[T](p: var XmlParser, v: var CritBitTree[T]) =
  if p.curr.kind == xtkTagOpen:
    p.advance()
    if p.curr.kind == xtkSelfClosing:
      p.advance()
      return
    if p.curr.kind == xtkEndTagClose:
      p.advance()
      # Don't return - continue to parse children
    when compiles(v.clear()):
      v.clear()
    while p.curr.kind != xtkTagClose:
      if p.curr.kind == xtkEof:
        p.error(errorEndOfFile % "CritBitTree")
      if p.curr.kind == xtkTagOpen:
        let key = p.curr.tag
        var item: T
        p.parseHook(item)
        v[key] = item
      else:
        p.advance()
      p.advance()

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

proc parseObjectHook[T, R](p: var XmlParser, v: var T, renameVal: R) =
  ## Shared object parsing with tag name from current element.
  if p.curr.kind != xtkTagOpen:
    p.error(unexpectedTokenExpected % [$p.curr.kind, $xtkTagOpen])

  let containerTag = p.curr.tag
  p.advance() # consume opening tag

  # Parse attributes into fields
  while p.curr.kind in {xtkAttributeName, xtkEquals, xtkAttributeValue}:
    if p.curr.kind == xtkAttributeName:
      let attrName = p.curr.value
      var wireKey = attrName
      when compiles(renameHook(renameVal, wireKey)):
        renameHook(renameVal, wireKey)

      # Skip '=' and value tokens
      p.advance()
      var attrValue = ""
      if p.curr.kind == xtkEquals:
        p.advance()
        if p.curr.kind == xtkAttributeValue:
          attrValue = p.curr.value
          p.advance()

      # Match attribute name to field
      var matched = false
      for objField, objVal in v.fieldPairs:
        if wireKey == objField:
          matched = true
          # variant discriminator handling: initialize correct branch early
          when isObjectVariant(v):
            if wireKey == discriminatorFieldName(v):
              var d: type(discriminatorField(v))
              when d is string:
                d = attrValue
              elif d is enum:
                d = strutils.parseEnum[type(discriminatorField(v))](attrValue)
              elif d is Integers:
                d = cast[type(discriminatorField(v))](attrValue.parseInt())
              let prev = v
              new(v, d)
              copyFieldsBeforeRecCase(v, prev)
              break
          when objVal is string:
            objVal = attrValue
          elif objVal is bool:
            objVal = attrValue.parseBool()
          elif objVal is int or objVal is int64:
            objVal = attrValue.parseInt()
          elif objVal is float32 or objVal is float64:
            objVal = attrValue.parseFloat()
          elif objVal is enum:
            objVal = strutils.parseEnum[type(objVal)](attrValue)
          else:
            discard # can't parse complex types from attributes
          break
      # If no match, just skip the attribute
    else:
      p.advance()

  # Check for self-closing tag after attributes
  if p.curr.kind == xtkSelfClosing:
    p.advance()
    return

  if p.curr.kind == xtkEndTagClose:
    p.advance()
    # Continue to parse child elements (don't return)

  # Parse child elements into fields
  while p.curr.kind != xtkTagClose:
    if p.curr.kind == xtkEof:
      p.error(errorEndOfFile % "object")

    case p.curr.kind
    of xtkTagOpen:
      let childTag = p.curr.tag
      var wireKey = childTag
      when compiles(renameHook(renameVal, wireKey)):
        renameHook(renameVal, wireKey)

      # Match child tag to field
      var matched = false
      for objField, objVal in v.fieldPairs:
        if wireKey == objField:
          matched = true
          p.currentField = some(objField)
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
        skipValue(p)

    of xtkText:
      # Text content in object: skip whitespace, error on non-whitespace
      if isWhitespaceOnly(p.curr.value):
        p.advance()
      else:
        p.advance() # skip non-whitespace text (mixed content ignored)

    of xtkComment:
      p.advance() # skip comments
    of xtkCdata:
      p.advance() # skip CDATA in object context
    else:
      p.advance()

  # Validate closing tag name
  if p.curr.kind == xtkTagClose:
    if p.curr.tag != containerTag:
      p.error("Mismatched closing tag: expected `</" & containerTag & ">`, got `</" & p.curr.tag & ">`")
  p.advance() # consume closing tag

proc parseHook*[T: object](p: var XmlParser, v: var T) =
  parseObjectHook(p, v, v)

proc parseHook*[T: ref object](p: var XmlParser, v: var T) =
  if p.curr.kind == xtkTagOpen:
    p.advance()
    if p.curr.kind == xtkSelfClosing:
      v = nil
      p.advance()
      return
    if p.curr.kind == xtkEndTagClose:
      p.advance()
      v = nil
      return
    if v.isNil:
      new(v)
    parseObjectHook(p, v[], v)
  elif p.curr.kind == xtkText and p.curr.value == "null":
    v = nil
    p.advance()

proc parseHook*(p: var XmlParser, v: var XmlNode) =
  ## Build a DOM tree from XML tokens
  case p.curr.kind
  of xtkTagOpen:
    let tag = p.curr.tag
    var elem = XmlNode(kind: xnElement, tag: tag, attrs: initOrderedTable[string, string](), children: @[])
    p.advance() # consume opening tag

    # Parse attributes
    while p.curr.kind in {xtkAttributeName, xtkEquals, xtkAttributeValue}:
      if p.curr.kind == xtkAttributeName:
        let attrName = p.curr.value
        p.advance()
        if p.curr.kind == xtkEquals:
          p.advance()
          let attrValue = if p.curr.kind == xtkAttributeValue: p.curr.value else: ""
          if p.curr.kind == xtkAttributeValue:
            p.advance()
          elem.attrs[attrName] = attrValue
        else:
          p.advance()
      else:
        p.advance()

    if p.curr.kind == xtkSelfClosing:
      p.advance()
      v = elem
      return

    if p.curr.kind == xtkEndTagClose:
      p.advance()

    # Parse children
    while true:
      if p.curr.kind == xtkEof:
        p.error(errorEndOfFile % "element")
      if p.curr.kind == xtkTagClose:
        if p.curr.tag == tag:
          p.advance()
          break
        p.advance()
        continue

      case p.curr.kind
      of xtkTagOpen:
        var child: XmlNode
        p.parseHook(child)
        elem.children.add(child)
      of xtkText:
        elem.children.add(XmlNode(kind: xnText, text: p.curr.value))
        p.advance()
      of xtkCdata:
        elem.children.add(XmlNode(kind: xnCdata, cdata: p.curr.value))
        p.advance()
      of xtkComment:
        if p.options == nil or p.options.preserveComments:
          elem.children.add(XmlNode(kind: xnComment, comment: p.curr.value))
        p.advance()
      of xtkProlog:
        elem.children.insert(XmlNode(kind: xnProlog, prolog: p.curr.value), 0)
        p.advance()
      of xtkDoctype:
        elem.children.insert(XmlNode(kind: xnDoctype, doctype: p.curr.value), 0)
        p.advance()
      else:
        p.advance()

    v = elem
  of xtkText:
    v = XmlNode(kind: xnText, text: p.curr.value)
    p.advance()
  of xtkComment:
    v = XmlNode(kind: xnComment, comment: p.curr.value)
    p.advance()
  of xtkCdata:
    v = XmlNode(kind: xnCdata, cdata: p.curr.value)
    p.advance()
  of xtkProlog:
    v = XmlNode(kind: xnProlog, prolog: p.curr.value)
    p.advance()
  of xtkDoctype:
    v = XmlNode(kind: xnDoctype, doctype: p.curr.value)
    p.advance()
  else:
    p.error(unexpectedToken % [$p.curr.kind])

# ---------------------------------------------------------------------------
# DOM constructors and accessors
# ---------------------------------------------------------------------------

proc newXmlElement*(tag: string): XmlNode =
  XmlNode(kind: xnElement, tag: tag, attrs: initOrderedTable[string, string](), children: @[])

proc newXmlText*(text: string): XmlNode =
  XmlNode(kind: xnText, text: text)

proc newXmlComment*(comment: string): XmlNode =
  XmlNode(kind: xnComment, comment: comment)

proc newXmlCdata*(cdata: string): XmlNode =
  XmlNode(kind: xnCdata, cdata: cdata)

proc newXmlProlog*(prolog: string): XmlNode =
  XmlNode(kind: xnProlog, prolog: prolog)

proc newXmlDoctype*(doctype: string): XmlNode =
  XmlNode(kind: xnDoctype, doctype: doctype)

proc addAttr*(elem: XmlNode, key, value: string) =
  ## Add an attribute to an element node
  elem.attrs[key] = value

proc addChild*(elem: XmlNode, child: XmlNode) =
  ## Add a child node to an element node
  elem.children.add(child)

proc `[]`*(elem: XmlNode, tag: string): XmlNode =
  ## Get the first child element with the given tag
  for child in elem.children:
    if child.kind == xnElement and child.tag == tag:
      return child
  nil

proc `[]`*(elem: XmlNode, index: int): XmlNode =
  ## Get the child at the given index
  elem.children[index]

proc len*(elem: XmlNode): int =
  ## Get the number of children
  elem.children.len

proc items*(elem: XmlNode): seq[XmlNode] =
  ## Get all children
  elem.children

proc getStr*(node: XmlNode): string =
  ## Get text value or "" if not a text node
  if node != nil and node.kind == xnText:
    result = node.text

proc getAttr*(elem: XmlNode, key: string): string =
  ## Get an attribute value or "" if not present
  elem.attrs.getOrDefault(key)

proc `$`*(node: XmlNode): string =
  ## Convert a XmlNode to its XML string representation
  result.dumpHook(node)

# ---------------------------------------------------------------------------
# XML Parsing to Nim Objects
# ---------------------------------------------------------------------------

proc initParser(lexer: XmlLexer): XmlParser =
  result = XmlParser(lexer: lexer)
  result.curr = result.nextToken()
  result.next = result.nextToken()

proc nextToken(p: var XmlParser): XmlToken =
  p.lexer.nextToken()

proc parseXml[T: object|ref object](parser: var XmlParser, v: var T) =
  case parser.curr.kind
  of xtkTagOpen:
    parser.parseHook(v)
  else:
    parser.error(unexpectedToken % [$parser.curr.kind])

proc parseXml(parser: var XmlParser, v: var bool) =
  parser.parseHook(v)

proc parseXml(parser: var XmlParser, v: var string) =
  parser.parseHook(v)

proc parseXml[T: SomeInteger](parser: var XmlParser, v: var T) =
  parser.parseHook(v)

proc parseXml[T: SomeFloat](parser: var XmlParser, v: var T) =
  parser.parseHook(v)

proc parseXml(parser: var XmlParser, v: var XmlNode) =
  parser.parseHook(v)

proc parseXmlRoot(parser: var XmlParser, v: var XmlNode) =
  ## Parse the root of an XML document
  case parser.curr.kind
  of xtkTagOpen:
    parser.parseHook(v)
  of xtkProlog:
    # Skip prolog, parse next element
    parser.advance()
    parser.parseHook(v)
  of xtkDoctype:
    parser.advance()
    parser.parseHook(v)
  of xtkComment:
    parser.advance()
    parser.parseHook(v)
  else:
    parser.error(unexpectedToken % [$parser.curr.kind])

macro fromXmlMacro(x: typed, str: typed): untyped =
  var t = x.getTypeInst()[1]
  var
    blockStmtList = newStmtList()
    blockStmtId = genSym(nskLabel, "openparserXml")
  add blockStmtList, quote do:
    var
      tmp: `t`
      parser = XmlParser(lexer: newXmlLexer(`str`))
    parser.curr = parser.nextToken()
    parser.next = parser.nextToken()
    # Skip leading prolog/doctype/comments
    while parser.curr.kind in {xtkProlog, xtkDoctype, xtkComment}:
      parser.advance()
    parser.parseXml(tmp)
    ensureMove(tmp)
  var blockStmt = newBlockStmt(blockStmtId, blockStmtList)
  result = newStmtList().add(blockStmt)

proc fromXml*[T](s: string, t: typedesc[T]): T =
  ## Parse XML string into a Nim object or type `T`
  when t is XmlNode:
    var parser = XmlParser(lexer: newXmlLexer(s))
    parser.curr = parser.nextToken()
    parser.next = parser.nextToken()
    while parser.curr.kind in {xtkProlog, xtkDoctype, xtkComment}:
      parser.advance()
    var result: XmlNode
    parser.parseXmlRoot(result)
    result
  else:
    fromXmlMacro(t, s)

proc fromXml*(s: string): XmlNode =
  ## Parse XML string into a DOM tree
  var parser = XmlParser(lexer: newXmlLexer(s))
  parser.curr = parser.nextToken()
  parser.next = parser.nextToken()
  while parser.curr.kind in {xtkProlog, xtkDoctype, xtkComment}:
    parser.advance()
  var res: XmlNode
  parser.parseXmlRoot(res)
  res

proc fromXml*(mapped: MemFile): XmlNode =
  ## Parse XML from a memory-mapped file
  var parser = XmlParser(lexer: newXmlLexer(mapped.mem, mapped.size))
  parser.curr = parser.nextToken()
  parser.next = parser.nextToken()
  while parser.curr.kind in {xtkProlog, xtkDoctype, xtkComment}:
    parser.advance()
  var res: XmlNode
  parser.parseXmlRoot(res)
  res

proc fromXml*[T](mapped: MemFile, t: typedesc[T]): T =
  ## Parse XML from a memory-mapped file into type `T`
  var parser = XmlParser(lexer: newXmlLexer(mapped.mem, mapped.size))
  parser.curr = parser.nextToken()
  parser.next = parser.nextToken()
  while parser.curr.kind in {xtkProlog, xtkDoctype, xtkComment}:
    parser.advance()
  when t is XmlNode:
    var result: XmlNode
    parser.parseXmlRoot(result)
    result
  else:
    var tmp: t
    parser.parseXml(tmp)
    tmp

proc fromXmlFile*(filename: string): XmlNode =
  ## Parse XML from a file on disk using memory-mapped I/O
  var mf = memfiles.open(filename, fmRead)
  defer: mf.close()
  fromXml(mf)

proc fromXmlFile*[T](filename: string, t: typedesc[T]): T =
  ## Parse XML from a file on disk into type `T`
  var mf = memfiles.open(filename, fmRead)
  defer: mf.close()
  fromXml(mf, t)

proc toXml*[T](v: T, opts: XmlOptions = nil): string =
  ## Convert a Nim object to its XML string representation
  var s = ""
  let tag = if opts != nil and opts.rootTag.len > 0: opts.rootTag else: name(type(v))
  dumpHook(s, v, v, tag)
  result = s

proc toXml*(v: XmlNode, opts: XmlOptions = nil): string =
  ## Convert a XmlNode to its XML string representation
  result.dumpHook(v)

proc toXmlNode*[T](v: T): XmlNode =
  ## Convert a Nim value to an XmlNode
  var s = ""
  let tag = name(type(v))
  dumpHook(s, v, v, tag)
  var parser = XmlParser(lexer: newXmlLexer(s))
  parser.curr = parser.nextToken()
  parser.next = parser.nextToken()
  var node: XmlNode
  parser.parseXmlRoot(node)
  node
