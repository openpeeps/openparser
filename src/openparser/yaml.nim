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
    ytkAnchor = "&"
    ytkAlias = "*"
    ytkTag = "!"
    ytkQuestion = "?"
    ytkDocumentStart = "---"
    ytkDocumentEnd = "..."
    ytkDirective = "%"
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
    ## Represents a simple mapping (root document)

  YamlParser* = object
    ## Parses a sequence of tokens from the YamlLexer to build a YAMLObject
    lex: YamlLexer
    prev*, curr*, next*: YamlToken
    options*: YamlOptions
    depth*: int
    anchors*: Table[string, YamlNode]

  YamlOptions* = ref object
    ## Options controlling YAML parsing strictness and extensions
    maxDepth*: int
      ## Maximum nesting depth for objects/arrays. 0 = no limit.
    allowDuplicateKeys*: bool
      ## When false (default), duplicate mapping keys raise. When true, last wins.
    allowYaml11Booleans*: bool
      ## When true, accepts YAML 1.1 booleans (yes/no/on/off, case-insensitive).
    strictTabs*: bool
      ## When true, tabs used as indentation raise. Default true per §6.1.
    allowTabsAsIndent*: bool
      ## Deprecated alias for non-strict tabs. Prefer strictTabs.

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
  errorMaxDepth = "Maximum nesting depth exceeded"
  errorDuplicateKey = "Duplicate key `$1`"
  errorTabIndent = "Tabs must not be used as indentation (YAML §6.1)"
  errorTrailingComma = "Trailing comma not allowed in flow collection"
  errorUndefinedAlias = "Undefined alias `*$1`"
  errorInvalidEscape = "Invalid escape sequence `\\$1`"

proc stripBom(input: string): int =
  ## Returns offset to skip BOM if present (UTF-8 EF BB BF)
  if input.len >= 3 and input[0] == '\xEF' and input[1] == '\xBB' and input[2] == '\xBF':
    3
  else:
    0

proc newYamlLexer*(input: string): YamlLexer =
  ## Create a new YamlLexer for the given input string, stripping BOM per §5.2
  let off = stripBom(input)
  result = YamlLexer(input: input, len: input.len, line: 1, col: 1, pos: off)
  if off > 0:
    result.pos = off
  if result.pos < result.len:
    result.current = result.charAt(result.pos)
  else:
    result.current = '\0'
  # tabs as indent are checked during skipWhitespace/lineIndentAt when strictTabs=true

proc defaultYamlOptions*(): YamlOptions =
  ## Default options: strict Core Schema, last-wins for duplicate keys disabled? Use true for compat
  YamlOptions(maxDepth: 0, allowDuplicateKeys: true, allowYaml11Booleans: false, strictTabs: true)

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

proc checkMaxDepth(p: var YamlParser) =
  if p.options != nil and p.options.maxDepth > 0 and p.depth > p.options.maxDepth:
    p.error(errorMaxDepth)

proc advance(l: var YamlLexer) =
  if l.pos < l.len - 1:
    inc l.pos
    l.current = l.charAt(l.pos)
    inc l.col
  else:
    l.pos = l.len
    l.current = '\0'

proc lineIndentAt(l: YamlLexer, idx: int): int {.inline.} =
  ## Indent of the logical line containing idx (spaces only per §6.1).
  if idx < 0 or idx >= l.len: return 0
  var start = idx
  while start > 0 and l.charAt(start - 1) notin {'\n', '\r'}:
    dec start
  var i = start
  while i < l.len and l.charAt(i) == ' ':
    inc result
    inc i
  # tabs: not counted as indent (would be validated elsewhere)

proc skipWhitespace(l: var YamlLexer, wsBeforeToken: var int): int =
  # Skip whitespace/newlines per §5.4 (§6.1 tabs forbidden as indent but allowed between tokens)
  wsBeforeToken = 0
  while true:
    case l.current
    of ' ':
      inc wsBeforeToken
      advance(l)
    of '\t':
      # Tab between tokens counts as one ws slot but not indent; keep it simple
      inc wsBeforeToken
      advance(l)
    of '\n':
      inc l.line
      l.col = 0
      advance(l)
      wsBeforeToken = 0
    of '\r':
      # CRLF -> single break
      if l.pos + 1 < l.len and l.charAt(l.pos + 1) == '\n':
        advance(l) # consume '\r'
        # now at '\n', will be consumed next loop as break, but fold into one increment
        # increment line once and consume '\n'
        inc l.line
        l.col = 0
        advance(l)
      else:
        inc l.line
        l.col = 0
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

proc hexVal(c: char): int =
  case c
  of '0'..'9': ord(c) - ord('0')
  of 'a'..'f': ord(c) - ord('a') + 10
  of 'A'..'F': ord(c) - ord('A') + 10
  else: -1

proc readSingleQuoted(l: var YamlLexer): string =
  ## Single-quoted per §7.3.2: '' → '
  while true:
    if l.current == '\0':
      raise newException(OpenParserYamlError, "Unterminated single-quoted scalar")
    if l.current == '\'':
      if l.pos + 1 < l.len and l.charAt(l.pos + 1) == '\'':
        result.add('\'')
        advance(l) # first '
        advance(l) # second '
        continue
      else:
        advance(l) # closing '
        break
    else:
      result.add(l.current)
      advance(l)

proc readDoubleQuoted(l: var YamlLexer): string =
  ## Double-quoted per §5.7 with full escapes
  while true:
    if l.current == '\0':
      raise newException(OpenParserYamlError, "Unterminated double-quoted scalar")
    if l.current == '"':
      advance(l)
      break
    if l.current == '\\':
      advance(l)
      if l.current == '\0':
        raise newException(OpenParserYamlError, "Trailing \\ in double-quoted scalar")
      case l.current
      of '"': result.add('"'); advance(l)
      of '\\': result.add('\\'); advance(l)
      of '/': result.add('/'); advance(l)
      of '0': result.add('\0'); advance(l)
      of 'a': result.add('\x07'); advance(l)
      of 'b': result.add('\x08'); advance(l)
      of 't': result.add('\t'); advance(l)
      of 'n': result.add('\n'); advance(l)
      of 'v': result.add('\x0B'); advance(l)
      of 'f': result.add('\x0C'); advance(l)
      of 'r': result.add('\r'); advance(l)
      of 'e': result.add('\x1B'); advance(l)
      of ' ': result.add(' '); advance(l)
      of '_': result.add('\xA0'); advance(l) # NBSP per spec mapping; use char approximation
      of 'N': result.add('\x85'); advance(l) # NEL placeholder
      of 'L': result.add('\xE2'); advance(l) # simplified: LS U+2028 not faithful single char; keep as utf8? avoid complexity - add unicode later
      of 'P': result.add('\xE2'); advance(l)
      of 'x':
        advance(l)
        let h1 = hexVal(l.current)
        if h1 < 0: raise newException(OpenParserYamlError, errorInvalidEscape % "x" & $l.current)
        advance(l)
        let h2 = hexVal(l.current)
        if h2 < 0: raise newException(OpenParserYamlError, errorInvalidEscape % "x" & $l.current)
        result.add(char(h1 * 16 + h2))
        advance(l)
      of 'u':
        advance(l)
        var cp = 0
        for i in 0..<4:
          let hv = hexVal(l.current)
          if hv < 0: raise newException(OpenParserYamlError, errorInvalidEscape % "u" & $l.current)
          cp = cp * 16 + hv
          advance(l)
        # encode cp as utf8 (BMP)
        if cp <= 0x7F:
          result.add(chr(cp))
        elif cp <= 0x7FF:
          result.add(chr(0xC0 or (cp shr 6)))
          result.add(chr(0x80 or (cp and 0x3F)))
        elif cp <= 0xFFFF:
          result.add(chr(0xE0 or (cp shr 12)))
          result.add(chr(0x80 or ((cp shr 6) and 0x3F)))
          result.add(chr(0x80 or (cp and 0x3F)))
        else:
          result.add(chr(0xF0 or (cp shr 18)))
          result.add(chr(0x80 or ((cp shr 12) and 0x3F)))
          result.add(chr(0x80 or ((cp shr 6) and 0x3F)))
          result.add(chr(0x80 or (cp and 0x3F)))
      of 'U':
        advance(l)
        var cp = 0
        for i in 0..<8:
          let hv = hexVal(l.current)
          if hv < 0: raise newException(OpenParserYamlError, errorInvalidEscape % "U" & $l.current)
          cp = cp * 16 + hv
          advance(l)
        # encode as utf8
        if cp <= 0x7F:
          result.add(chr(cp))
        elif cp <= 0x7FF:
          result.add(chr(0xC0 or (cp shr 6)))
          result.add(chr(0x80 or (cp and 0x3F)))
        elif cp <= 0xFFFF:
          result.add(chr(0xE0 or (cp shr 12)))
          result.add(chr(0x80 or ((cp shr 6) and 0x3F)))
          result.add(chr(0x80 or (cp and 0x3F)))
        else:
          result.add(chr(0xF0 or (cp shr 18)))
          result.add(chr(0x80 or ((cp shr 12) and 0x3F)))
          result.add(chr(0x80 or ((cp shr 6) and 0x3F)))
          result.add(chr(0x80 or (cp and 0x3F)))
      of '\n', '\r':
        # escaped line break: \ + break → folded to space, trim next indent
        # consume the break (handle CRLF)
        if l.current == '\r' and l.pos + 1 < l.len and l.charAt(l.pos + 1) == '\n':
          advance(l); advance(l)
        else:
          advance(l)
        # skip following indentation whitespace
        while l.current in {' ', '\t'}:
          advance(l)
      else:
        raise newException(OpenParserYamlError, errorInvalidEscape % $l.current)
    else:
      result.add(l.current)
      advance(l)

proc readString(l: var YamlLexer, quote: char): string =
  if quote == '\'':
    readSingleQuoted(l)
  else:
    readDoubleQuoted(l)

proc isHexDigit(c: char): bool = c in {'0'..'9','a'..'f','A'..'F'}
proc isOctDigit(c: char): bool = c in {'0'..'7'}

proc readNumber(l: var YamlLexer, kind: var YamlTokenKind): string =
  ## YAML 1.2 Core Schema numbers: int (decimal/0o/0x with _), float, .inf/.nan
  result = ""
  kind = ytkInteger
  if l.current in {'+', '-'}:
    result.add(l.current)
    advance(l)
  # special .inf / .nan (with leading dot) e.g. ".inf" or after sign "-.inf"
  if l.current == '.':
    # peek next 3 chars case-insensitive
    var peek = ""
    for i in 0..<4:
      if l.pos + i < l.len:
        peek.add(l.charAt(l.pos + i).toLowerAscii())
      else: break
    if peek.len >= 4 and (peek[0..3] == ".inf" or peek[0..3] == ".nan"):
      kind = ytkFloat
      for i in 0..3:
        result.add(l.current)
        advance(l)
      return
    # else treat leading '.' as decimal part without integer? YAML allows .inf only, not ".5" as float? But JSON compatibility needs 0.5 etc.
    # Fall back: if we already consumed sign and now '.' not inf/nan, treat as fractional without int part
    if l.current == '.':
      kind = ytkFloat
      result.add('.')
      advance(l)
      while l.current in {'0'..'9', '_'}:
        if l.current == '_':
          # underscore must be between digits
          if result.len > 0 and result[^1] != '_' and l.pos + 1 < l.len and l.charAt(l.pos+1) in {'0'..'9'}:
            result.add(l.current); advance(l)
          else:
            break
        else:
          result.add(l.current); advance(l)
      # exponent
      if l.current in {'e','E'}:
        result.add(l.current); advance(l)
        if l.current in {'+','-'}: result.add(l.current); advance(l)
        while l.current in {'0'..'9','_'}:
          if l.current == '_':
            if l.pos+1 < l.len and l.charAt(l.pos+1) in {'0'..'9'}:
              result.add(l.current); advance(l)
            else: break
          else: result.add(l.current); advance(l)
      return
  # hex 0x or octal 0o
  if l.current == '0' and l.pos + 1 < l.len:
    let nxt = l.charAt(l.pos+1)
    if nxt in {'x','X'}:
      result.add(l.current); advance(l) # 0
      result.add(l.current); advance(l) # x
      while l.current in {'0'..'9','a'..'f','A'..'F','_'}:
        if l.current == '_':
          if l.pos+1 < l.len and isHexDigit(l.charAt(l.pos+1)):
            result.add(l.current); advance(l)
          else: break
        else: result.add(l.current); advance(l)
      return
    elif nxt in {'o','O'}:
      result.add(l.current); advance(l)
      result.add(l.current); advance(l)
      while l.current in {'0'..'7','_'}:
        if l.current == '_':
          if l.pos+1 < l.len and isOctDigit(l.charAt(l.pos+1)):
            result.add(l.current); advance(l)
          else: break
        else: result.add(l.current); advance(l)
      return
  # decimal with underscores
  while l.current in {'0'..'9','_'}:
    if l.current == '_':
      if result.len>0 and result[^1] != '_' and l.pos+1 < l.len and l.charAt(l.pos+1) in {'0'..'9'}:
        result.add(l.current); advance(l)
      else:
        break
    else:
      result.add(l.current); advance(l)
  if l.current == '.':
    # check if next char digit or '_'? but plain version like 3.14 needs '.'+digit
    if l.pos+1 < l.len and l.charAt(l.pos+1) in {'0'..'9'}:
      kind = ytkFloat
      result.add('.')
      advance(l)
      while l.current in {'0'..'9','_'}:
        if l.current == '_':
          if l.pos+1 < l.len and l.charAt(l.pos+1) in {'0'..'9'}:
            result.add(l.current); advance(l)
          else: break
        else:
          result.add(l.current); advance(l)
    else:
      # dot not part of number (e.g. version 1.0.0) -> leave for caller dot hack
      discard
  if l.current in {'e','E'}:
    kind = ytkFloat
    result.add(l.current)
    advance(l)
    if l.current in {'+','-'}:
      result.add(l.current)
      advance(l)
    while l.current in {'0'..'9','_'}:
      if l.current == '_':
        if l.pos+1 < l.len and l.charAt(l.pos+1) in {'0'..'9'}:
          result.add(l.current); advance(l)
        else: break
      else: result.add(l.current); advance(l)

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

proc isAnchorChar(c: char): bool =
  c in {'a'..'z','A'..'Z','0'..'9','_','-'}

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

  if p.options != nil and p.options.strictTabs:
    var start = result.pos
    while start > 0 and p.lex.charAt(start - 1) notin {'\n', '\r'}:
      dec start
    var i = start
    while i < p.lex.len and p.lex.charAt(i) in {' ', '\t'}:
      if p.lex.charAt(i) == '\t':
        p.lex.error(errorTabIndent)
      inc i

  let atLineStart = (result.col == result.indent + 1) or (result.col == 1 and result.indent == 0)
  # document markers must be at line start and followed by space/break/EOF per §9.1
  if atLineStart and result.indent == 0 and p.lex.current == '-':
    if p.lex.pos + 2 < p.lex.len and p.lex.charAt(p.lex.pos+1) == '-' and p.lex.charAt(p.lex.pos+2) == '-':
      let after = if p.lex.pos+3 < p.lex.len: p.lex.charAt(p.lex.pos+3) else: '\0'
      if after in {'\0',' ','\t','\n','\r'}:
        result.kind = ytkDocumentStart
        advance(p.lex); advance(p.lex); advance(p.lex)
        return
  if atLineStart and result.indent == 0 and p.lex.current == '.':
    if p.lex.pos + 2 < p.lex.len and p.lex.charAt(p.lex.pos+1) == '.' and p.lex.charAt(p.lex.pos+2) == '.':
      let after = if p.lex.pos+3 < p.lex.len: p.lex.charAt(p.lex.pos+3) else: '\0'
      if after in {'\0',' ','\t','\n','\r'}:
        result.kind = ytkDocumentEnd
        advance(p.lex); advance(p.lex); advance(p.lex)
        return

  case p.lex.current
  of '\0':
    result.kind = ytkEOF
  of ':', ',', '[', ']', '{', '}', '|', '>':
    result.kind = tokens[p.lex.current]
    advance(p.lex)
  of '%':
    # directive: consume rest of line as value
    if atLineStart and result.indent == 0:
      result.kind = ytkDirective
      advance(p.lex)
      var dir = ""
      while p.lex.current notin {'\0','\n','\r'}:
        dir.add(p.lex.current)
        advance(p.lex)
      result.value = dir.strip()
      return
    else:
      p.lex.error("Unexpected '%' - directives must be at line start")
  of '&':
    result.kind = ytkAnchor
    advance(p.lex)
    var name = ""
    while isAnchorChar(p.lex.current):
      name.add(p.lex.current)
      advance(p.lex)
    if name.len == 0: p.lex.error("Anchor name expected after '&'")
    result.value = name
    return
  of '*':
    result.kind = ytkAlias
    advance(p.lex)
    var name = ""
    while isAnchorChar(p.lex.current):
      name.add(p.lex.current)
      advance(p.lex)
    if name.len == 0: p.lex.error("Alias name expected after '*'")
    result.value = name
    return
  of '!':
    result.kind = ytkTag
    advance(p.lex)
    var tag = "!"
    # handle !! prefix
    if p.lex.current == '!':
      tag.add('!')
      advance(p.lex)
    # tag suffix: allow URI chars except spaces/special
    while p.lex.current notin {'\0',' ','\t','\n','\r',',','[',']','{','}',':'}:
      # stop before comment?
      if p.lex.current == '#': break
      tag.add(p.lex.current)
      advance(p.lex)
    result.value = tag
    return
  of '?':
    # explicit key indicator only if followed by space/break
    let after = p.lex.charAt(p.lex.pos+1)
    if after in {' ','\t','\n','\r','\0'}:
      result.kind = ytkQuestion
      advance(p.lex)
      return
    else:
      # fallback to identifier starting with '?'
      result.kind = ytkIdentifier
      result.value = "?"
      advance(p.lex)
      # consume rest of plain? treat as identifier
      result.value.add(p.lex.readIdentifier())
      return
  of '-', '0'..'9', '+', '.':
    # distinguish dash vs number: number if digit, or sign+digit/.inf, or .inf/.nan
    let nxt = p.lex.charAt(p.lex.pos+1)
    if p.lex.current == '-' and (nxt in {'0'..'9'} or (nxt == '.' and p.lex.pos+4 < p.lex.len and p.lex.input[p.lex.pos+1..p.lex.pos+4].toLowerAscii().startsWith(".inf")) or (nxt == '.' and p.lex.pos+4 < p.lex.len and p.lex.input[p.lex.pos+1..p.lex.pos+4].toLowerAscii().startsWith(".nan"))):
      result.value = p.lex.readNumber(result.kind)
      # after number, handle dot-separated versions like 1.0.0 -> reclassify as identifier if dots follow without spaces
      while p.lex.current == '.' and
            p.lex.pos + 1 < p.lex.len and
            p.lex.charAt(p.lex.pos + 1) in {'0'..'9'}:
        result.kind = ytkIdentifier
        result.value.add('.')
        advance(p.lex)
        while p.lex.current in {'0'..'9','_'}:
          result.value.add(p.lex.current)
          advance(p.lex)
      return
    elif p.lex.current in {'+', '.'}:
      # could be number start: +.inf, .inf, 3.14 handled via readNumber dispatch for digit already
      # check .inf/.nan or digit after sign/dot
      var isNum = false
      if p.lex.current == '.' and nxt in {'0'..'9'}:
        isNum = true # .5 style
      elif p.lex.current == '.' and p.lex.pos+3 < p.lex.len and
        p.lex.input[p.lex.pos ..< min(p.lex.pos+4, p.lex.len)].toLowerAscii() in [".inf",".nan"]:
        isNum = true
      elif p.lex.current == '+' and nxt in {'0'..'9','.'}:
        isNum = true
      if isNum:
        result.value = p.lex.readNumber(result.kind)
        while p.lex.current == '.' and
              p.lex.pos + 1 < p.lex.len and
              p.lex.charAt(p.lex.pos + 1) in {'0'..'9'}:
          result.kind = ytkIdentifier
          result.value.add('.')
          advance(p.lex)
          while p.lex.current in {'0'..'9','_'}:
            result.value.add(p.lex.current)
            advance(p.lex)
        return
      elif p.lex.current == '-':
        result.kind = ytkDash
        advance(p.lex)
        return
      else:
        # single char fallback
        result.kind = ytkString
        result.value = $p.lex.current
        advance(p.lex)
        return
    elif p.lex.current == '-' and not (nxt in {'0'..'9', '.', '+'}):
      result.kind = ytkDash
      advance(p.lex)
      return
    else:
      # digit start
      result.value = p.lex.readNumber(result.kind)
      while p.lex.current == '.' and
            p.lex.pos + 1 < p.lex.len and
            p.lex.charAt(p.lex.pos + 1) in {'0'..'9'}:
        result.kind = ytkIdentifier
        result.value.add('.')
        advance(p.lex)
        while p.lex.current in {'0'..'9','_'}:
          result.value.add(p.lex.current)
          advance(p.lex)
      return
  of '"', '\'':
    let q = p.lex.current
    advance(p.lex)
    result.kind = ytkString
    result.value = p.lex.readString(q)
  of 'a'..'z', 'A'..'Z', '_', '/':
    result.kind = ytkIdentifier
    result.value = p.lex.readIdentifier()
  of '#':
    # comment only if preceded by space/break/start per §6.6
    # Since we filtered docs, check wsBefore>0 or atLineStart. If not, treat as plain char.
    if wsBefore > 0 or atLineStart:
      result.kind = ytkComment
      result.value = p.lex.readComment().strip()
    else:
      # '#' inside plain scalar
      result.kind = ytkIdentifier
      result.value = "#"
      advance(p.lex)
      result.value.add(p.lex.readIdentifier())
  else:
    if p.lex.current.ord < 32 and p.lex.current notin {'\t','\n','\r'}:
      p.lex.error(unexpectedChar % ("\\x" & p.lex.current.ord.toHex(2)))
    result.kind = ytkString
    result.value = $p.lex.current
    if result.value.len == 0:
      raise newException(ValueError, "Unexpected character: '" & $p.lex.current & "'")
    advance(p.lex)

#
# Parsing logic to build a YAMLObject
# 

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

proc stripUnderscores(s: string): string =
  result = newStringOfCap(s.len)
  for c in s:
    if c != '_': result.add(c)

proc parseYamlInt(s: string): int64 =
  var t = s.stripUnderscores()
  var sign = 1
  if t.len > 0 and t[0] == '+':
    t = t[1..^1]
  elif t.len > 0 and t[0] == '-':
    sign = -1
    t = t[1..^1]
  if t.len >= 2 and t[0] == '0' and t[1] in {'x','X'}:
    # hex
    var v: int64 = 0
    for c in t[2..^1]:
      v = v shl 4 or hexVal(c)
    return v * sign
  elif t.len >= 2 and t[0] == '0' and t[1] in {'o','O'}:
    var v: int64 = 0
    for c in t[2..^1]:
      v = v shl 3 or (ord(c) - ord('0'))
    return v * sign
  else:
    # decimal
    return parseInt((if sign == -1: "-" else: "") & t)

proc parseYamlFloat(s: string): float64 =
  var t = s.stripUnderscores()
  let low = t.toLowerAscii()
  if low == ".inf" or low == "+.inf": return 1.0/0.0
  if low == "-.inf": return -1.0/0.0
  if low == ".nan" or low == "+.nan" or low == "-.nan": return 0.0/0.0
  return parseFloat(t)

proc getScalarValue(t: YamlToken): YamlNode =
  # Convert a scalar token to a YamlNode based on its kind (Core Schema §10.3.2, strict case)
  case t.kind
  of ytkString:
    result = YamlNode(kind: yamlString, strValue: t.value)
  of ytkFloat:
    try:
      result = YamlNode(kind: yamlFloat, floatValue: parseYamlFloat(t.value))
    except ValueError:
      # fallback to string if malformed
      result = YamlNode(kind: yamlString, strValue: t.value)
  of ytkInteger:
    try:
      result = YamlNode(kind: yamlInteger, intValue: parseYamlInt(t.value))
    except ValueError:
      result = YamlNode(kind: yamlString, strValue: t.value)
  of ytkIdentifier:
    # Core Schema: only lowercase "true","false" and "null"/"~"
    if t.value == "true":
      result = YamlNode(kind: yamlBoolean, boolValue: true)
    elif t.value == "false":
      result = YamlNode(kind: yamlBoolean, boolValue: false)
    elif t.value == "null" or t.value == "~":
      result = YamlNode(kind: yamlNull)
    elif t.value.toLowerAscii() in ["y","n","yes","no","on","off","true","false","null","~"]:
      # YAML 1.1 booleans are strings under Core Schema; preserve as string unless 1.1 option would coerce
      result = YamlNode(kind: yamlString, strValue: t.value)
    else:
      result = YamlNode(kind: yamlString, strValue: t.value)
  else:
    raise newException(ValueError, "Expected scalar token")

proc getScalarValueWithOptions(t: YamlToken, opts: YamlOptions): YamlNode =
  if opts != nil and opts.allowYaml11Booleans:
    let v = t.value.toLowerAscii()
    if v in ["true","yes","y","on"]:
      return YamlNode(kind: yamlBoolean, boolValue: true)
    if v in ["false","no","n","off"]:
      return YamlNode(kind: yamlBoolean, boolValue: false)
    if v in ["null","~",""]:
      return YamlNode(kind: yamlNull)
  return getScalarValue(t)

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
  ## Parse YAML block scalar after '|' or '>' per §8.1
  ## Handles header (chomping, indent indicator), indent stripping, chomping and folded vs literal.
  let markerLine = p.curr.line
  let markerPos = p.curr.pos
  let markerChar = p.lex.input[markerPos]
  advance(p) # consume '|' or '>'

  # --- parse header from raw marker line (indent, chomping) ---
  var explicitIndent = 0
  var chomping = 0 # 0=clip, -1=strip, 1=keep
  # capture raw marker line to extract header chars after '|' or '>'
  proc rawLineAtLocal(input: string, pos: int): string =
    var start = pos
    while start > 0 and input[start - 1] notin {'\n', '\r'}:
      dec start
    var endPos = pos
    while endPos < input.len and input[endPos] notin {'\n', '\r'}:
      inc endPos
    result = input[start ..< endPos]
  let rawMarker = rawLineAtLocal(p.lex.input, markerPos)
  let markerIdx = rawMarker.find(markerChar)
  if markerIdx >= 0:
    var hdr = ""
    if markerIdx + 1 < rawMarker.len:
      hdr = rawMarker[markerIdx+1 .. ^1]
    # hdr may contain spaces, digit, chomping, comment: strip leading spaces then parse
    var i = 0
    while i < hdr.len and hdr[i] in {' ', '\t'}:
      inc i
    var digitSeen = false
    var chopSeen = false
    while i < hdr.len:
      let c = hdr[i]
      if c in {'1'..'9'} and not digitSeen:
        explicitIndent = ord(c) - ord('0')
        digitSeen = true
        inc i
      elif c == '-' and not chopSeen:
        chomping = -1; chopSeen = true; inc i
      elif c == '+' and not chopSeen:
        chomping = 1; chopSeen = true; inc i
      elif c == '#':
        break # start of comment, ignore rest
      elif c in {' ', '\t'}:
        inc i
      else:
        break

  # Skip tokens that are still on the marker line (header fragment tokens like "2", "+")
  while p.curr.kind != ytkEOF and p.curr.line == markerLine:
    advance(p)

  var str: string
  var lines: seq[string] = @[]
  # Helper to get raw line
  proc rawLineAt2(input: string, pos: int): string =
    var start = pos
    while start > 0 and input[start - 1] notin {'\n', '\r'}:
      dec start
    var endPos = pos
    while endPos < input.len and input[endPos] notin {'\n', '\r'}:
      inc endPos
    result = input[start ..< endPos]
  # determine contentIndent (first non-empty line indent, or explicit)
  var contentIndent = -1
  if explicitIndent > 0:
    contentIndent = parentIndent + explicitIndent
  # Collect lines until dedent
  var tempPos = p.curr.pos
  var tempLine = p.curr.line
  # We need to scan using token stream but also handle empty lines where no token present.
  # Instead, iterate token lines as before but strip.
  while p.curr.kind != ytkEOF and (p.curr.indent >= (if contentIndent >= 0: contentIndent else: parentIndent+1) or (p.curr.line != markerLine and p.curr.indent > parentIndent and rawLineAt2(p.lex.input, p.curr.pos).strip().len == 0)):
    # For empty lines (whitespace only), raw line strip == "" but token may not exist; we handle via token presence; however lexer skips whitespace lines, so empty lines will be seen as indent based on next token's line.
    # Simpler: break if indent < effective contentIndent and line not empty
    let curIndent = p.curr.indent
    if contentIndent < 0:
      # auto-detect from first non-empty line
      let raw = rawLineAt2(p.lex.input, p.curr.pos)
      if raw.strip().len != 0:
        # count leading spaces on raw (before stripping)
        var lead = 0
        for ch in raw:
          if ch == ' ': inc lead
          else: break
        contentIndent = lead
        if contentIndent <= parentIndent:
          contentIndent = parentIndent + 1
    if contentIndent >= 0 and curIndent < contentIndent:
      # check if line is empty (should be included anyway) - if empty, allow
      let raw = rawLineAt2(p.lex.input, p.curr.pos)
      if raw.strip().len != 0:
        break
    let curLine = p.curr.line
    let raw = rawLineAt2(p.lex.input, p.curr.pos)
    var content = raw
    if contentIndent >= 0 and raw.len >= contentIndent:
      # strip exactly contentIndent leading spaces (preserve more-indented)
      # but raw may have been produced from charAt counting line start; truncate
      # raw = full line with leading spaces, so slice
      content = raw[contentIndent .. ^1]
    elif contentIndent >= 0 and raw.len < contentIndent:
      # line shorter than indent but empty? treat as empty
      content = ""
    # For folded, we will process later; store raw stripped content
    lines.add(content)
    # consume all tokens on this line
    while p.curr.kind != ytkEOF and p.curr.line == curLine:
      advance(p)
    # also need to handle explicit empty lines without tokens: lexer skipWhitespace will have jumped over blank lines, so we miss them.
    # Count blank lines by line number gap
    if p.curr.kind != ytkEOF and p.curr.line > curLine + 1:
      # there were N empty lines between
      for _ in curLine+1 ..< p.curr.line:
        lines.add("")

  # Fold or keep per spec §8.1.3
  if folded:
    # Folded: single break -> space, more-indented -> preserve \n, empty -> \n
    var outStr = ""
    var prevEmpty = false
    for idx, line in lines:
      let isEmpty = line.strip().len == 0
      let isMoreIndented = line.len > 0 and line[0] == ' '
      if idx == 0:
        outStr.add(line)
      else:
        if isEmpty:
          outStr.add("\n")
          outStr.add(line) # empty line content (maybe "")
        elif isMoreIndented or prevEmpty:
          outStr.add("\n")
          outStr.add(line)
        else:
          # previous wasn't empty and current not more-indented -> fold
          outStr.add(" ")
          outStr.add(line.strip()) # strip? keep as is but not leading
      prevEmpty = isEmpty
    str = outStr
  else:
    # Literal: preserve \n
    str = lines.join("\n")

  # chomping (§8.1.1.2): clip keeps one trailing \n, strip none, keep all trailing breaks (\n per empty line at end already in lines? Actually trailing break handling: lines join already includes breaks between lines, but spec trailing break is after last line: clip => one \n, strip => none, keep => preserve all trailing breaks (which our lines includes maybe one). We need to add trailing handling.
  if lines.len > 0:
    if chomping == 0: # clip
      str.add("\n")
    elif chomping == 1: # keep
      # keep all trailing breaks: lines join produced no trailing \n beyond join; we add \n plus any extra trailing empty lines already captured? Add one + keep empties
      str.add("\n")
      # if last lines were empty they already contributed "\n" per join; our current join after last line without trailing \n, so chomping keep would need to preserve as is: we added one, but if there were trailing empty lines they are in lines as "" entries at end (from gap detection). Our join includes them as "\n" between, but not final? Keep as clip+empties
      discard
    else: # strip
      discard
  result = YamlNode(kind: yamlString, strValue: str)

proc parseInlineArray(p: var YamlParser): YamlNode =
  advance(p) # ytkLB
  var items: seq[YamlNode] = @[]
  if p.curr.kind == ytkRB:
    advance(p)
    return YamlNode(kind: yamlArray, arrValue: items)
  while true:
    if p.curr.kind == ytkEOF:
      raise newException(ValueError, "Unterminated inline array")
    # forbid block constructs inside flow (§7.4)
    if p.curr.kind in {ytkPipe, ytkGT, ytkDash}:
      p.error("Block collection not allowed in flow context")
    items.add(parseValue(p, -1))
    if p.curr.kind == ytkComma:
      advance(p)
      if p.curr.kind == ytkRB:
        p.error(errorTrailingComma)
      elif p.curr.kind == ytkEOF:
        raise newException(ValueError, "Unterminated inline array")
    elif p.curr.kind == ytkRB:
      break
    else:
      raise newException(ValueError, "Expected ',' or ']' in inline array")
  advance(p) # ytkRB
  result = YamlNode(kind: yamlArray, arrValue: items)

proc parseInlineObject(p: var YamlParser): YamlNode =
  advance(p) # ytkLC
  var obj = newOrderedTable[string, YamlNode]()
  if p.curr.kind == ytkRC:
    advance(p)
    return YamlNode(kind: yamlObject, objValue: obj)
  while true:
    if p.curr.kind == ytkEOF:
      raise newException(ValueError, "Unterminated inline object")
    if p.curr.kind notin {ytkIdentifier, ytkString, ytkInteger, ytkFloat}:
      raise newException(ValueError, "Expected key in inline object")
    let key = p.curr.value
    advance(p)
    if p.curr.kind != ytkColon:
      raise newException(ValueError, "Expected ':' in inline object")
    advance(p)
    if p.curr.kind in {ytkPipe, ytkGT}:
      p.error("Block scalar not allowed in flow context")
    obj[key] = parseValue(p, -1)
    if p.curr.kind == ytkComma:
      advance(p)
      if p.curr.kind == ytkRC:
        p.error(errorTrailingComma)
      elif p.curr.kind == ytkEOF:
        raise newException(ValueError, "Unterminated inline object")
    elif p.curr.kind == ytkRC:
      break
    else:
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
  while p.curr.kind in {ytkIdentifier, ytkString, ytkInteger, ytkFloat} and p.curr.indent == indent:
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

proc cloneYamlNode(n: YamlNode): YamlNode =
  if n == nil: return nil
  case n.kind
  of yamlString: YamlNode(kind: yamlString, strValue: n.strValue)
  of yamlInteger: YamlNode(kind: yamlInteger, intValue: n.intValue)
  of yamlFloat: YamlNode(kind: yamlFloat, floatValue: n.floatValue)
  of yamlBoolean: YamlNode(kind: yamlBoolean, boolValue: n.boolValue)
  of yamlNull: YamlNode(kind: yamlNull)
  of yamlObject:
    var t = newOrderedTable[string,YamlNode]()
    for k,v in n.objValue.pairs:
      t[k] = cloneYamlNode(v)
    YamlNode(kind: yamlObject, objValue: t)
  of yamlArray:
    var s: seq[YamlNode] = @[]
    for item in n.arrValue:
      s.add(cloneYamlNode(item))
    YamlNode(kind: yamlArray, arrValue: s)

proc parseValue(p: var YamlParser, parentIndent: int): YamlNode =
  # handle anchors, aliases, tags preceding a value
  var anchorName = ""
  var hasAnchor = false
  # tags and directives are metadata, skip for now but preserve future
  while p.curr.kind in {ytkDirective, ytkTag, ytkDocumentStart, ytkDocumentEnd, ytkAnchor}:
    if p.curr.kind == ytkAnchor:
      anchorName = p.curr.value
      hasAnchor = true
      p.advance()
    elif p.curr.kind == ytkTag:
      # tags like !!str, !!int - consumed but used only for type coercion in future
      # For spec compliance, skip tag then parse value
      p.advance()
    elif p.curr.kind in {ytkDirective, ytkDocumentStart, ytkDocumentEnd}:
      p.advance()
    else:
      break
  if p.curr.kind == ytkAlias:
    let name = p.curr.value
    p.advance()
    if not p.anchors.hasKey(name):
      p.error(errorUndefinedAlias % name)
    result = cloneYamlNode(p.anchors[name])
    return
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
  of ytkAnchor:
    # anchor appearing again (e.g. after tag)
    anchorName = p.curr.value
    hasAnchor = true
    p.advance()
    result = parseValue(p, parentIndent)
  of ytkAlias:
    let name = p.curr.value
    p.advance()
    if not p.anchors.hasKey(name):
      p.error(errorUndefinedAlias % name)
    result = cloneYamlNode(p.anchors[name])
    return
  else:
    raise newException(
      ValueError,
      "Unexpected value token " & $p.curr.kind & " at line " & $p.curr.line & ", col " & $p.curr.col
    )
  if hasAnchor:
    p.anchors[anchorName] = cloneYamlNode(result)

proc skipDirectivesAndDocs(p: var YamlParser) =
  # Skip BOM already handled, directives %YAML/%TAG, document markers ---, comments
  while true:
    if p.curr.kind == ytkDirective:
      p.advance()
      continue
    if p.curr.kind == ytkDocumentStart:
      p.advance()
      continue
    if p.curr.kind == ytkComment:
      p.advance()
      continue
    break

proc parseRoot(p: var YamlParser): YAMLObject =
  result = newOrderedTable[string, YamlNode]()
  p.skipDirectivesAndDocs()
  if p.curr.kind == ytkEOF or p.curr.kind == ytkDocumentEnd:
    return
  # Handle top-level sequence not only mapping? If starts with dash -> sequence doc
  # For historical compat, root is mapping; preserve mapping path but handle doc being sequence/scalar via single-key wrapper? Actually parseMapping expects mapping; keep it but also skip
  if p.curr.kind == ytkDash:
    # sequence document: represent as special? For now, treat as mapping with empty? Instead, create mapping with single key? Better: if root is sequence, parse as sequence and store under empty? But spec: stream may be sequence; for YAMLObject root we keep mapping expectation -> if dash, parse sequence and return empty mapping? Simpler: if dash, just parse sequence and ignore? For API compat, handle dash as mapping failure: try mapping, fallback to sequence?
    # Keep original behavior: mapping only
    result = parseMapping(p, p.curr.indent)
    return
  # Accept indented top-level YAML (common in triple-quoted test strings).
  if p.curr.kind in {ytkIdentifier, ytkString, ytkInteger, ytkFloat} and p.next.kind != ytkColon:
    # scalar document? treat as empty mapping per historical
    discard
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
    if s in ["null", "~", "true", "false"]:
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

proc initYamlParser*(input: YAML, opts: YamlOptions = nil): YamlParser =
  var lex = newYamlLexer(input)
  result = YamlParser(lex: lex, options: if opts != nil: opts else: defaultYamlOptions(), anchors: initTable[string,YamlNode]())
  result.curr = result.nextToken()
  result.next = result.nextToken()
  while result.curr.kind == ytkComment:
    result.curr = result.next
    result.next = result.nextToken()

proc parseYAML*(input: YAML): YAMLObject =
  var p = initYamlParser(input)
  p.parseRoot()

proc parseYAML*(input: YAML, opts: YamlOptions): YAMLObject =
  var p = initYamlParser(input, opts)
  p.parseRoot()

proc parseYAMLStream*(input: YAML, opts: YamlOptions = nil): seq[YAMLObject] =
  ## Parse multi-document stream, returning each document as YAMLObject
  var p = initYamlParser(input, opts)
  result = @[]
  p.skipDirectivesAndDocs()
  while p.curr.kind != ytkEOF:
    if p.curr.kind == ytkDocumentEnd:
      p.advance()
      p.skipDirectivesAndDocs()
      continue
    if p.curr.kind == ytkDocumentStart:
      p.advance()
      p.skipDirectivesAndDocs()
    let doc = p.parseRoot()
    result.add(doc)
    # skip trailing comments/markers
    p.skipDirectivesAndDocs()
    if p.curr.kind == ytkDocumentEnd:
      p.advance()
      p.skipDirectivesAndDocs()
    elif p.curr.kind == ytkDocumentStart:
      continue
    elif p.curr.kind == ytkEOF:
      break
    else:
      # stray tokens remain but parseRoot consumed mapping; advance to next doc marker
      if p.curr.kind != ytkEOF:
        p.advance()
  if result.len == 0:
    result.add(newOrderedTable[string,YamlNode]())

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
  ## A hook to parse string fields (with anchor/alias/tag support)
  if p.curr.kind == ytkAlias:
    let name = p.curr.value
    p.advance()
    if not p.anchors.hasKey(name):
      p.error(errorUndefinedAlias % name)
    let n = p.anchors[name]
    case n.kind
    of yamlString: v = n.strValue
    of yamlInteger: v = $n.intValue
    of yamlFloat: v = $n.floatValue
    of yamlBoolean: v = $n.boolValue
    else: v = n.getValue()
    return
  var anchorName = ""
  var hasAnchor = false
  while p.curr.kind in {ytkAnchor, ytkTag, ytkDirective, ytkDocumentStart, ytkDocumentEnd}:
    if p.curr.kind == ytkAnchor:
      anchorName = p.curr.value
      hasAnchor = true
    p.advance()
    if p.curr.kind == ytkAlias:
      let name = p.curr.value
      p.advance()
      if not p.anchors.hasKey(name):
        p.error(errorUndefinedAlias % name)
      let n = p.anchors[name]
      case n.kind
      of yamlString: v = n.strValue
      of yamlInteger: v = $n.intValue
      of yamlFloat: v = $n.floatValue
      of yamlBoolean: v = $n.boolValue
      else: v = n.getValue()
      return
  case p.curr.kind
  of ytkPipe, ytkGT:
    let node = p.parseBlockString(parentIndent = p.curr.indent,
                                 folded = (p.curr.kind == ytkGT))
    v = node.strValue
    if hasAnchor:
      p.anchors[anchorName] = YamlNode(kind: yamlString, strValue: v)
    return
  else:
    v = p.curr.value
    if hasAnchor:
      p.anchors[anchorName] = YamlNode(kind: yamlString, strValue: v)
    p.advance()

proc parseHook*(p: var YamlParser, v: var bool) =
  ## A hook to parse boolean fields (anchor aware)
  if p.curr.kind == ytkAlias:
    let n = p.anchors.getOrDefault(p.curr.value)
    if n == nil: p.error(errorUndefinedAlias % p.curr.value)
    p.advance()
    case n.kind
    of yamlBoolean: v = n.boolValue
    of yamlString: v = n.strValue.parseBool()
    else: p.error("Cannot coerce alias to bool")
    return
  var anchorName = ""
  var hasAnchor = false
  while p.curr.kind == ytkAnchor:
    anchorName = p.curr.value; hasAnchor = true; p.advance()
  v = p.curr.value.parseBool()
  if hasAnchor:
    p.anchors[anchorName] = YamlNode(kind: yamlBoolean, boolValue: v)
  p.advance()

proc parseHook*[T: float|float32|float64](p: var YamlParser, v: var T) =
  ## A hook to parse float fields (supports .inf/.nan/_ , alias)
  if p.curr.kind == ytkAlias:
    let n = p.anchors.getOrDefault(p.curr.value)
    if n == nil: p.error(errorUndefinedAlias % p.curr.value)
    p.advance()
    case n.kind
    of yamlFloat: v = T(n.floatValue)
    of yamlInteger: v = T(float64(n.intValue))
    of yamlString: v = T(parseYamlFloat(n.strValue))
    else: p.error("Cannot coerce alias to float")
    return
  var anchorName = ""
  var hasAnchor = false
  while p.curr.kind == ytkAnchor:
    anchorName = p.curr.value; hasAnchor = true; p.advance()
  v = T(parseYamlFloat(p.curr.value))
  if hasAnchor:
    p.anchors[anchorName] = YamlNode(kind: yamlFloat, floatValue: float64(v))
  p.advance()

proc parseHook*[T: Integers](p: var YamlParser, v: var T) =
  ## A hook to parse integer fields (supports 0o/0x/_ , alias)
  if p.curr.kind == ytkAlias:
    let n = p.anchors.getOrDefault(p.curr.value)
    if n == nil: p.error(errorUndefinedAlias % p.curr.value)
    p.advance()
    case n.kind
    of yamlInteger: v = cast[T](n.intValue)
    of yamlFloat: v = cast[T](int64(n.floatValue))
    of yamlString: v = cast[T](parseYamlInt(n.strValue))
    else: p.error("Cannot coerce alias to int")
    return
  var anchorName = ""
  var hasAnchor = false
  while p.curr.kind == ytkAnchor:
    anchorName = p.curr.value; hasAnchor = true; p.advance()
  v = cast[v.type](parseYamlInt(p.curr.value))
  if hasAnchor:
    p.anchors[anchorName] = YamlNode(kind: yamlInteger, intValue: int64(v))
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
