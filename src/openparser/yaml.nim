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

import std/[tables, sets, critbits, strutils, macros,
        typetraits, sequtils, options]

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
    ytkString
    ytkFloat
    ytkInteger
    ytkComment
    ytkAnchor = "&"
    ytkAlias = "*"
    ytkTag = "!"
    ytkQuestion = "?"
    ytkDocumentStart = "---"
    ytkDocumentEnd = "..."
    ytkDirective = "%"
    ytkBlockScalar = "|"

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
    indentAtMarker: int
      ## Indentation of the line a block scalar header sits on; used to
      ## compute the auto-detected content indent (§8.1.1.1).

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
    flowDepth*: int
    anchors*: Table[string, YamlNode]
    building*: HashSet[string]
      ## Anchors whose node is still being parsed. An alias to one of these
      ## would be a self-reference (§3.2.2 forbids it).
    tagHandles*: Table[string, string]
      ## Secondary tag handles declared with `%TAG` directives (§6.8.2), mapping
      ## a handle such as `!e!` to its URI prefix. The `!` and `!!` handles are
      ## predefined (§6.8.2).
    flowEndLine*: int
      ## Line of the `]`/`}` that closed the flow collection most recently
      ## parsed, used to reject trailing content after it.

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

proc isPlainFollowedByContent(l: YamlLexer, tokPos: int): bool =
  ## True when the character following the indicator at `tokPos` is plain-safe,
  ## which means a leading `-`, `?` or `:` is part of a plain scalar rather than
  ## an indicator of its own (§7.3.3, `ns-plain-first`).
  let c = l.charAt(tokPos + 1)
  c != '\0' and c notin {' ', '\t', '\n', '\r', '\0'} and
    c notin {',', '[', ']', '{', '}', '#', '&', '*', '!', '|', '>', '\'', '"', '%'}

proc checkFlowEnd(p: var YamlParser) =
  ## Rejects content that follows a flow collection on the same line, such as
  ## the `c` in `a: [1, 2]c` (§7.4: a flow collection ends the node).
  ##
  ## A `:` may still follow, which makes the collection a complex mapping key
  ## such as `[[a]: b]` (§8.2.2), and so may a separator or a closing bracket,
  ## which is how nested flow collections continue (`[[1], 2]`).
  if p.curr.line != p.flowEndLine: return
  if p.curr.kind notin {ytkEOF, ytkComment, ytkDocumentStart, ytkDocumentEnd,
                        ytkDirective, ytkColon, ytkComma, ytkRB, ytkRC}:
    p.error("Unexpected content after a flow collection")

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
  # Read an unquoted identifier (e.g. for keys or unquoted values).
  # `~` is a plain-scalar char mid-token (only a lone `~` is null).
  # Bytes >= 0x80 continue UTF-8 sequences byte-wise (e.g. `café`, `日本語`).
  while l.current in {'a'..'z', 'A'..'Z', '0'..'9', '_', '-', '/', '.', '~'} or
      l.current >= '\x80':
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

proc addCodepoint(s: var string, cp: int) =
  ## Appends a Unicode code point to `s` as UTF-8 (§7.7 escape targets).
  if cp < 0 or cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF):
    addCodepoint(s, 0xFFFD) # replacement character
  elif cp <= 0x7F:
    s.add(char(cp))
  elif cp <= 0x7FF:
    s.add(char(0xC0 or (cp shr 6)))
    s.add(char(0x80 or (cp and 0x3F)))
  elif cp <= 0xFFFF:
    s.add(char(0xE0 or (cp shr 12)))
    s.add(char(0x80 or ((cp shr 6) and 0x3F)))
    s.add(char(0x80 or (cp and 0x3F)))
  else:
    s.add(char(0xF0 or (cp shr 18)))
    s.add(char(0x80 or ((cp shr 12) and 0x3F)))
    s.add(char(0x80 or ((cp shr 6) and 0x3F)))
    s.add(char(0x80 or (cp and 0x3F)))

proc foldQuotedBreak(l: var YamlLexer, dst: var string) =
  ## Folds a line break inside a quoted scalar (§7.3.1, §7.3.2): a single
  ## break becomes a space, and a run of N empty lines becomes N newlines
  ## preceded by a space. The indentation of the next line is stripped.
  var breaks = 0
  var sawAny = false
  while true:
    if l.current == '\r' or l.current == '\n':
      if l.current == '\r' and l.pos + 1 < l.len and l.charAt(l.pos + 1) == '\n':
        advance(l)
      if l.current == '\n': advance(l)
      inc l.line
      l.col = 0
      inc breaks
      sawAny = true
    elif l.current in {' ', '\t'}:
      advance(l)
    else:
      break
  if not sawAny: return
  # Flow folding (§7.3.1): a single break becomes a space; a run of N breaks
  # becomes N-1 newlines. So `a\nb` -> "a b" and `a\n\nb` -> "a\nb".
  for _ in 1 ..< breaks:
    dst.add("\n")
  if breaks == 1:
    dst.add(' ')

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
    if l.current in {'\n', '\r'}:
      foldQuotedBreak(l, result)
      continue
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
      of '\0': result.add('\0'); advance(l)
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
      of '"': result.add('"'); advance(l)
      of '_': addCodepoint(result, 0xA0); advance(l) # NBSP
      of 'N': addCodepoint(result, 0x85); advance(l)
      of 'L': addCodepoint(result, 0x2028); advance(l)
      of 'P': addCodepoint(result, 0x2029); advance(l)
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
        addCodepoint(result, cp)
      of 'U':
        advance(l)
        var cp = 0
        for i in 0..<8:
          let hv = hexVal(l.current)
          if hv < 0: raise newException(OpenParserYamlError, errorInvalidEscape % "U" & $l.current)
          cp = cp * 16 + hv
          advance(l)
        if cp > 0x10FFFF:
          raise newException(OpenParserYamlError,
            "Escape `\\U` is not a Unicode code point (max `10FFFF`)")
        addCodepoint(result, cp)
      of '\n', '\r':
        # An escaped line break is folded away entirely: the `\` removes the
        # break and the following indentation, leaving no space (§7.7).
        var before = result.len
        foldQuotedBreak(l, result)
        if result.len > before and result[^1] == ' ':
          result.setLen(result.len - 1)
        continue
      else:
        raise newException(OpenParserYamlError, errorInvalidEscape % $l.current)
      continue
    elif l.current in {'\n', '\r'}:
      # An unescaped break inside a quoted scalar folds like a plain scalar.
      foldQuotedBreak(l, result)
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

proc leadingSpaces(s: string): int =
  for ch in s:
    if ch != ' ': break
    inc result

proc stripTrailingBlanks(s: string): string =
  var e = s.len
  while e > 0 and s[e - 1] in {' ', '\t'}: dec e
  result = if e == s.len: s else: s[0 ..< e]

proc readBlockScalar(l: var YamlLexer, folded: bool): string =
  ## Reads a `|`/`>` block scalar directly from the raw input (§8.1).
  ##
  ## The lexer is positioned just after the `|`/`>` indicator. This returns
  ## the fully processed content (indent detection, more-indented folding,
  ## chomping) and leaves the lexer at the first line that is not part of
  ## the block.
  var explicitIndent = 0
  var chomping = 0 # 0=clip, -1=strip, 1=keep

  # --- header: [indent digit] [chomping indicator] in either order, then an
  # optional trailing comment (§8.1.1.1) ---
  while l.current in {' ', '\t'}: advance(l)
  if l.current in {'1'..'9'}:
    explicitIndent = ord(l.current) - ord('0')
    advance(l)
    while l.current in {' ', '\t'}: advance(l)
  case l.current
  of '-': chomping = -1; advance(l)
  of '+': chomping = 1; advance(l)
  else: discard
  while l.current in {' ', '\t'}: advance(l)
  if l.current == '#':
    # A comment runs to the end of the header line.
    while l.current notin {'\0', '\n', '\r'}: advance(l)
  elif l.current notin {'\0', '\n', '\r'}:
    l.error("Invalid block scalar header")

  # Move to the start of the next line.
  if l.current == '\r':
    advance(l)
    if l.current == '\n': advance(l)
  elif l.current == '\n':
    advance(l)
  inc l.line
  l.col = 0

  # --- collect the raw lines belonging to the block ---
  var raws: seq[string] = @[]
  var contentIndent = -1
  if explicitIndent > 0:
    contentIndent = l.indentAtMarker + explicitIndent

  while l.pos < l.len:
    var lineEnd = l.pos
    while lineEnd < l.len and l.input[lineEnd] notin {'\n', '\r'}:
      inc lineEnd
    let raw = l.input[l.pos ..< lineEnd]
    let blank = raw.strip().len == 0
    if blank:
      raws.add(raw)
    else:
      let ind = leadingSpaces(raw)
      if contentIndent < 0:
        contentIndent = ind
        if contentIndent <= l.indentAtMarker:
          contentIndent = l.indentAtMarker + 1
      if ind < contentIndent:
        break # dedent ends the block; leave l.pos at this line
      raws.add(raw)
    # advance past this line's break
    l.pos = lineEnd
    l.col = lineEnd
    if l.pos < l.len and l.input[l.pos] == '\r':
      inc l.pos
    if l.pos < l.len and l.input[l.pos] == '\n':
      inc l.pos
      inc l.line
    l.col = 1
    if l.pos < l.len:
      l.current = l.charAt(l.pos)
    else:
      l.current = '\0'
      l.pos = l.len
      break

  # --- split into content lines and trailing breaks ---
  var content: seq[string] = @[]
  var trailingBreaks = 0
  var ci = 0
  while ci < raws.len:
    let raw = raws[ci]
    let blank = raw.strip().len == 0
    if blank:
      # A run of N empty lines contributes N line breaks, whether the scalar is
      # literal or folded (§8.1.3.1: "N empty lines become N line breaks").
      var j = ci
      while j < raws.len and raws[j].strip().len == 0: inc j
      if j == raws.len:
        trailingBreaks = j - ci
        break
      for _ in ci ..< j:
        content.add("")
      ci = j
      continue
    var text = raw
    if text.len >= contentIndent:
      text = text[contentIndent .. ^1]
    else:
      text = ""
    content.add(stripTrailingBlanks(text))
    inc ci

  # Drop trailing empty content lines (they are breaks, not content)
  while content.len > 0 and content[^1].len == 0:
    content.setLen(content.len - 1)
    inc trailingBreaks

  if content.len == 0:
    # Empty block: clip/keep still produce nothing, strip nothing.
    return ""

  # --- folding / literal assembly ---
  var outStr = content[0]
  if folded:
    var prevMore = content[0].len > 0 and content[0][0] == ' '
    var pendingBreaks = 0
    for i in 1 ..< content.len:
      let line = content[i]
      var more = false
      if line.len == 0:
        inc pendingBreaks
        continue
      if pendingBreaks > 0:
        for _ in 0 ..< pendingBreaks: outStr.add("\n")
        pendingBreaks = 0
      else:
        more = line[0] == ' '
        if more or prevMore:
          outStr.add("\n")
        else:
          outStr.add(" ")
      outStr.add(line)
      prevMore = more
  else:
    for i in 1 ..< content.len:
      outStr.add("\n")
      outStr.add(content[i])

  # --- chomping ---
  if chomping == 1: # keep
    for _ in 0 ..< (trailingBreaks + 1): outStr.add("\n")
  elif chomping == 0: # clip
    outStr.add("\n")
  # strip: nothing appended
  result = outStr

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

proc isTagNameChar(c: char): bool =
  ## Characters allowed in a local tag name (§6.8.2, `ns-tag-char`).
  c in {'a'..'z','A'..'Z','0'..'9','-','_','.','+','$',',','/',';','=','?',
        '@','&','%','!','*','\'','(',')','#'} or c.ord >= 0x80

proc isUriChar(c: char): bool =
  ## True for a character that may start or continue a tag prefix URI (§6.8.2).
  c.ord > 0x20 and c.ord != 0x7F and c != ']' and c != '}'

proc atScalarStart(l: YamlLexer): bool =
  ## True when the current character opens a new node rather than continuing
  ## an existing plain scalar.
  ##
  ## A quote only begins a quoted scalar at a node boundary. Inside a plain
  ## scalar an apostrophe is an ordinary character, so `STANDBY LC'S` must not
  ## be lexed as the start of a single-quoted scalar (§7.3.2).
  if l.pos == 0: return true
  l.charAt(l.pos - 1) in {' ', '\t', '\n', '\r', ':', ',', '[', '{', '?', '|', '>'}

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
  of '|', '>':
    # Block scalar indicator. In flow context (§7.4) `|`/`>` are not allowed,
    # so they are reported as plain characters and rejected by the parser.
    if p.lex.atScalarStart():
      p.lex.indentAtMarker = result.indent
      let folded = p.lex.current == '>'
      advance(p.lex)
      result.kind = ytkBlockScalar
      result.value = p.lex.readBlockScalar(folded)
      return
    result.kind = ytkIdentifier
    result.value = $p.lex.current
    advance(p.lex)
    return
  of ':', ',', '[', ']', '{', '}':
    result.kind = tokens[p.lex.current]
    advance(p.lex)
  of '%':
    # A `%` is a directive indicator only in column 0 (§6.4). Elsewhere it is
    # an ordinary plain-scalar character (`50%`, `x%y`).
    if result.col == 1:
      result.kind = ytkDirective
      advance(p.lex)
      var dir = ""
      while p.lex.current notin {'\0','\n','\r'}:
        dir.add(p.lex.current)
        advance(p.lex)
      result.value = dir.strip()
      return
    else:
      result.kind = ytkIdentifier
      result.value = "%"
      advance(p.lex)
      result.value.add(p.lex.readIdentifier())
      return
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
    # A `!` opens a tag only at the start of a node. Mid-scalar it is an
    # ordinary plain character, so `x!y` and `a: !weird` stay plain.
    if not p.lex.atScalarStart():
      result.kind = ytkString
      result.value = "!"
      advance(p.lex)
      return
    result.kind = ytkTag
    advance(p.lex)
    var tag = "!"
    if p.lex.current == '<':
      # verbatim tag: `!<tag:...>` consumes through the closing '>'
      tag = "!<"
      advance(p.lex)
      while p.lex.current notin {'\0', '\n', '\r', '>'}:
        tag.add(p.lex.current)
        advance(p.lex)
      if p.lex.current == '>':
        tag.add('>')
        advance(p.lex)
      result.value = tag
      return
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
        # '.' starting a plain scalar (e.g. `.github/workflows/release.yml`,
        # `.env`): consume the full identifier. A lone '.' or '..' can never
        # be a document-end marker here (`...` is lexed earlier at line 561).
        if p.lex.current == '.':
          result.kind = ytkIdentifier
          result.value = "."
          advance(p.lex)
          result.value.add(p.lex.readIdentifier())
          return
        # single char fallback
        result.kind = ytkString
        result.value = $p.lex.current
        advance(p.lex)
        return
    elif p.lex.current == '-' and not (nxt in {'0'..'9', '.', '+'}):
      # `-` is a block-sequence indicator only when followed by a space or a
      # break (§7.3.3). `-b` is a plain scalar, ` - ` starts an entry.
      if nxt in {' ', '\t', '\n', '\r', '\0'}:
        result.kind = ytkDash
        advance(p.lex)
      else:
        result.kind = ytkIdentifier
        result.value = "-"
        advance(p.lex)
        result.value.add(p.lex.readIdentifier())
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
      # A plain scalar may start with digits and continue with letters
      # (`040s`, `12abc`). Such a token is never a number: reclassify it and
      # keep reading so the whole word stays a single scalar.
      if p.lex.current in {'a'..'z', 'A'..'Z', '_', '-', '/'} or
          p.lex.current >= '\x80':
        result.kind = ytkIdentifier
        result.value.add(p.lex.readIdentifier())
      return
  of '"', '\'':
    let q = p.lex.current
    if not p.lex.atScalarStart():
      # Mid-scalar quote: an ordinary plain character, not a quoted scalar.
      result.kind = ytkString
      result.value = $q
      advance(p.lex)
      return
    advance(p.lex)
    result.kind = ytkString
    result.value = p.lex.readString(q)
  of '~':
    # lone `~` (blank/break/EOF/flow-end after) is null per Core Schema;
    # otherwise it starts a plain scalar (e.g. `~/.ssh/id_ed25519`).
    let afterTilde = p.lex.charAt(p.lex.pos + 1)
    if afterTilde in {' ', '\t', '\n', '\r', '\0', ',', ']', '}'}:
      result.kind = ytkIdentifier
      result.value = "~"
      advance(p.lex)
    else:
      result.kind = ytkIdentifier
      result.value = "~"
      advance(p.lex)
      result.value.add(p.lex.readIdentifier())
    return
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
    if p.lex.current >= '\x80':
      # unquoted unicode plain scalar (e.g. `café`, `日本語`)
      result.kind = ytkIdentifier
      result.value = p.lex.readIdentifier()
      return
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
  ## An empty key is valid YAML (the empty scalar), so only `n == nil` short-
  ## circuits here.
  if n == nil:
    return nil
  if key.len == 0:
    if n.kind == yamlObject and n.objValue.hasKey(""):
      return n.objValue[""]
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

proc get*(obj: YAMLObject, key: string): YamlNode =
  ## Retrieves a value by key, supporting dot notation for nested access.
  ## Missing keys return `nil` (never raises `KeyError`).
  if obj.isNil:
    return nil
  if key.contains("."):
    let parts = key.split('.', maxsplit = 1)
    result = obj.get(parts[0]).get(parts[1])
  else:
    if obj.hasKey(key):
      result = obj[key]
    else:
      result = nil

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

type YamlParserState = tuple[lex: YamlLexer, prev, curr, nxt: YamlToken,
                             anchors: Table[string, YamlNode]]

proc snapshot*(p: YamlParser): YamlParserState =
  ## Captures the lexer and token window so a speculative parse can be undone.
  (p.lex, p.prev, p.curr, p.next, p.anchors)

proc restore*(p: var YamlParser, s: YamlParserState) =
  ## Restores a state captured by `snapshot`.
  p.lex = s.lex
  p.prev = s.prev
  p.curr = s.curr
  p.next = s.nxt
  p.anchors = s.anchors

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

proc getScalarValue(t: YamlToken, opts: YamlOptions = nil): YamlNode =
  # Convert a scalar token to a YamlNode based on its kind (Core Schema
  # §10.3.2). `opts.allowYaml11Booleans` widens the boolean/null resolution
  # set to the YAML 1.1 rules. Quoted scalars are never resolved (§7.3.3).
  if t.kind != ytkString and opts != nil and opts.allowYaml11Booleans:
    let low = t.value.toLowerAscii
    if low in ["true", "yes", "y", "on"]:
      return YamlNode(kind: yamlBoolean, boolValue: true)
    if low in ["false", "no", "n", "off"]:
      return YamlNode(kind: yamlBoolean, boolValue: false)
    if low in ["null", "~", ""]:
      return YamlNode(kind: yamlNull)
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
    # Core Schema (§10.3.2): the null, bool and float forms below are matched
    # with the exact case alternatives the spec lists, so `True` and `NULL`
    # resolve while `yes`/`no`/`on`/`off` stay strings.
    case t.value
    of "null", "Null", "NULL", "~": result = newYamlNull()
    of "true", "True", "TRUE": result = YamlNode(kind: yamlBoolean, boolValue: true)
    of "false", "False", "FALSE": result = YamlNode(kind: yamlBoolean, boolValue: false)
    else: result = YamlNode(kind: yamlString, strValue: t.value)
  else:
    raise newException(ValueError, "Expected scalar token")

proc parseValue(p: var YamlParser, parentIndent: int): YamlNode
proc parseMapping(p: var YamlParser, indent: int): YAMLObject
proc parseInlineArray(p: var YamlParser): YamlNode
proc parseInlineObject(p: var YamlParser): YamlNode

proc isStructuralToken(k: YamlTokenKind): bool {.inline.} =
  ## Tokens that can never be part of a plain scalar or plain key.
  k in {ytkEOF, ytkComment, ytkDocumentStart, ytkDocumentEnd, ytkDirective,
        ytkBlockScalar, ytkAnchor, ytkAlias, ytkTag, ytkQuestion}

proc stopsPlainScalar(t: YamlToken, input: string, inlineMode: bool): bool =
  ## True when `t` cannot continue a plain scalar on the current line.
  if t.kind == ytkColon:
    # A `:` ends a plain scalar only when followed by a space, a break or the
    # end of input. `a:b` is one scalar; `a: b` is a mapping entry (§7.3.3).
    let after = if t.pos + 1 < input.len: input[t.pos + 1] else: '\0'
    return after in {' ', '\t', '\n', '\r', '\0'}
  if isStructuralToken(t.kind): return true
  if inlineMode and t.kind in {ytkComma, ytkRB, ytkRC}: return true
  if t.kind in {ytkLB, ytkLC}: return true
  false

proc collectPlainLine(p: var YamlParser, inlineMode: bool, firstToken: YamlToken): (string, int) =
  ## Collects the tokens of the current line that form a plain scalar.
  ## Returns the joined text and the number of tokens consumed.
  # The line is captured by value: `YamlToken` is a ref and the parser's
  # lookahead may recycle it while this loop advances.
  let firstLine = firstToken.line
  var count = 0
  var buf = ""
  while p.curr.kind != ytkEOF and p.curr.line == firstLine:
    if stopsPlainScalar(p.curr, p.lex.input, inlineMode): break
    if count > 0 and p.curr.wsno > 0:
      buf.add(repeat(' ', p.curr.wsno))
    let part = if p.curr.value.len > 0: p.curr.value else: tokenText(p.curr)
    buf.add(part)
    inc count
    advance(p)
  result = (buf, count)

proc plainCanContinue(p: YamlParser, parentIndent: int): bool =
  ## True when the current token continues a plain scalar on a following line
  ## (§7.3.3: continuation lines are more indented than the parent node and
  ## must not start a new node).
  if p.curr.kind == ytkEOF: return false
  if isStructuralToken(p.curr.kind): return false
  if p.curr.kind in {ytkLB, ytkLC}: return false
  if p.curr.indent <= parentIndent: return false
  if p.curr.kind == ytkDash: return false
  # `key: value` on the continuation line starts a new mapping entry
  if p.next.kind == ytkColon and p.next.wsno == 0: return false
  true

proc parsePlainUnquoted(p: var YamlParser, inlineMode = false, parentIndent = -1): YamlNode =
  ## Parses a plain scalar (§7.3.3), folding continuation lines that are more
  ## indented than `parentIndent` into single spaces.
  let firstTok = p.curr
  let (firstLine, firstCount) = p.collectPlainLine(inlineMode, firstTok)
  var buf = firstLine

  if not inlineMode and parentIndent >= 0:
    # Fold continuation lines (§7.3.3 multi-line plain scalars).
    while p.plainCanContinue(parentIndent):
      let contTok = p.curr
      let (contLine, contCount) = p.collectPlainLine(inlineMode, contTok)
      if contCount == 0: break
      buf.add(" ")
      buf.add(contLine)
      # `firstCount` stays put so a single-token value is still coerced below.
      if firstCount == 0: break

  if firstCount == 1 and buf == firstTok.value:
    # A single token still gets Core Schema coercion (bool/int/float/null).
    result = getScalarValue(firstTok, p.options)
  else:
    result = YamlNode(kind: yamlString, strValue: buf)

proc collectPlainKey(p: var YamlParser, inlineMode = false): string =
  ## Collects a plain or quoted mapping key, which may span several tokens and
  ## is terminated by `:` followed by a space (§7.3.3).
  ##
  ## Flow indicators (`[`, `]`, `{`, `}`, `,`) only end a key in a flow
  ## context; a block key like `/users/{id}` contains them literally.
  var buf = ""
  var count = 0
  while p.curr.kind != ytkEOF:
    if p.curr.kind == ytkColon: break
    if isStructuralToken(p.curr.kind) and count > 0: break
    if inlineMode and p.curr.kind in {ytkLB, ytkRC, ytkLC, ytkComma}: break
    if p.curr.kind == ytkDash: break
    if count > 0 and p.curr.wsno > 0:
      buf.add(repeat(' ', p.curr.wsno))
    let part = if p.curr.value.len > 0: p.curr.value else: tokenText(p.curr)
    buf.add(part)
    inc count
    advance(p)
  result = buf


proc parseBlockString(p: var YamlParser, parentIndent: int, folded: bool): YamlNode =
  ## Returns the block scalar whose content the lexer already read (§8.1).
  ## `folded` is accepted for call-site compatibility; the lexer already
  ## folded the content when the indicator was `>`.
  discard folded
  result = YamlNode(kind: yamlString, strValue: p.curr.value)
  advance(p) # consume the block-scalar token

proc putMapping(result: var YAMLObject, p: var YamlParser, key: string, value: YamlNode) =
  ## Inserts `key`, honouring `allowDuplicateKeys` (§3.2.1).
  if result.hasKey(key):
    if p.options != nil and not p.options.allowDuplicateKeys:
      p.error(errorDuplicateKey % key)
  result[key] = value

proc mergeInto(result: var YAMLObject, src: OrderedTableRef[string, YamlNode]) =
  ## Applies a `<<` merge key. Existing keys win over merged ones (§10.2).
  if src != nil:
    for k, v in src.pairs:
      if not result.hasKey(k): result[k] = v

proc renderKey(n: YamlNode): string =
  ## Renders a node for use as a mapping key. Scalars use their plain text;
  ## collections use a compact flow form so the key round-trips (§8.2.2).
  if n == nil: return ""
  case n.kind
  of yamlString: result = n.strValue
  of yamlInteger: result = $n.intValue
  of yamlFloat: result = $n.floatValue
  of yamlBoolean: result = $n.boolValue
  of yamlNull: result = "null"
  of yamlArray:
    var buf = "["
    for i, item in n.arrValue:
      if i > 0: buf.add(", ")
      buf.add(renderKey(item))
    buf.add("]")
    result = buf
  of yamlObject:
    var buf = "{"
    var first = true
    for k, v in n.objValue.pairs:
      if not first: buf.add(", ")
      first = false
      buf.add(k & ": " & renderKey(v))
    buf.add("}")
    result = buf

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
    if p.curr.kind == ytkBlockScalar:
      p.error("Block scalar not allowed in flow context")
    if p.curr.kind == ytkDash:
      p.error("Block collection not allowed in flow context")
    if p.curr.kind == ytkComma:
      # Two commas in a row would mean an empty entry; only a single trailing
      # separator before `]` is legal (§7.4.1).
      p.error("Missing value between commas in flow sequence")
    let entryLine = p.curr.line
    var item = parseValue(p, -1)
    if p.curr.kind == ytkColon and p.curr.line == entryLine:
      # A single `key: value` pair used as a sequence entry: `[x: y]`, or a
      # complex key such as `[[a]: b]` (§7.4.1, §8.2.2).
      var pair = newOrderedTable[string, YamlNode]()
      pair.putMapping(p, renderKey(item), newYamlNull())
      advance(p) # ':'
      if p.curr.line == entryLine and p.curr.kind notin {ytkComma, ytkRC, ytkEOF}:
        pair.putMapping(p, renderKey(item), parseValue(p, -1))
      item = YamlNode(kind: yamlObject, objValue: pair)
    items.add(item)
    if p.curr.kind == ytkComma:
      advance(p)
      if p.curr.kind == ytkEOF:
        raise newException(ValueError, "Unterminated inline array")
      if p.curr.kind == ytkRB:
        break # a final separator before `]` is allowed (§7.4.1)
      if p.curr.kind == ytkComma:
        p.error("Missing value between commas in flow sequence")
    elif p.curr.kind == ytkRB:
      break
    else:
      raise newException(ValueError, "Expected ',' or ']' in inline array")
  p.flowEndLine = p.curr.line
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
    if p.curr.kind == ytkBlockScalar:
      p.error("Block scalar not allowed in flow context")
    if p.curr.kind == ytkDash:
      p.error("Block collection not allowed in flow context")

    var key = ""
    if p.curr.kind == ytkQuestion:
      # Explicit key in a flow mapping (§8.2.2): `{? a : 1}`.
      advance(p)
      if p.curr.kind == ytkColon:
        key = ""
      elif p.curr.kind in {ytkLB, ytkLC}:
        key = renderKey(parseValue(p, -1))
      else:
        key = p.collectPlainKey()
      if p.curr.kind != ytkColon:
        p.error(unexpectedTokenExpected % [$p.curr.kind, $ytkColon])
      advance(p)
      if p.curr.kind == ytkRC:
        obj.putMapping(p, key, newYamlNull())
      else:
        obj.putMapping(p, key, parseValue(p, -1))
    elif p.curr.kind == ytkColon:
      # `{: 1}` - an empty (null) key.
      advance(p)
      if p.curr.kind == ytkRC:
        obj.putMapping(p, "", newYamlNull())
      else:
        obj.putMapping(p, "", parseValue(p, -1))
    elif p.curr.kind in {ytkIdentifier, ytkString, ytkInteger, ytkFloat}:
      key = p.collectPlainKey(inlineMode = true)
      if p.curr.kind != ytkColon:
        p.error(unexpectedTokenExpected % [$p.curr.kind, $ytkColon])
      advance(p)
      var entry = newYamlNull()
      if p.curr.kind != ytkRC:
        entry = parseValue(p, -1)
      if key == "<<" and entry != nil and entry.kind == yamlObject:
        obj.mergeInto(entry.objValue)
      else:
        obj.putMapping(p, key, entry)
    else:
      p.error(unexpectedTokenExpected % [$p.curr.kind, "mapping key"])

    if p.curr.kind == ytkComma:
      advance(p)
      if p.curr.kind == ytkEOF:
        raise newException(ValueError, "Unterminated inline object")
      if p.curr.kind == ytkRC:
        break # a final separator before `}` is allowed (§7.4.2)
      if p.curr.kind == ytkComma:
        p.error("Missing key between commas in flow mapping")
    elif p.curr.kind == ytkRC:
      break
    else:
      raise newException(ValueError, "Expected ',' or '}' in inline object")

  p.flowEndLine = p.curr.line
  advance(p) # consume '}'
  result = YamlNode(kind: yamlObject, objValue: obj)

proc parseSequence(p: var YamlParser, dashCol: int): seq[YamlNode]
proc applyTag(tag: string, n: YamlNode, p: var YamlParser): YamlNode
proc expandTagHandle(p: YamlParser, tag: string): string

proc parseCompactMapping(p: var YamlParser, keyIndent, dashCol: int): YamlNode =
  ## Parses the mapping that starts at `keyIndent`, then absorbs any further
  ## keys indented past the dash's column. Used for both `- key: value` and
  ## `-` followed by an indented block on the next line (§8.2.1).
  var obj = parseMapping(p, keyIndent)
  while p.curr.indent > dashCol and
      p.curr.kind in {ytkIdentifier, ytkString, ytkInteger, ytkFloat, ytkQuestion}:
    let more = parseMapping(p, p.curr.indent)
    for k, v in more.pairs:
      obj.putMapping(p, k, v)
  result = YamlNode(kind: yamlObject, objValue: obj)

proc parseSequenceItem(p: var YamlParser, dashCol: int, dashLine: int): YamlNode =
  ## Parses the node that follows a `-` indicator at column `dashCol`. The
  ## node may be on the dash's own line or on following, more indented lines
  ## (§8.2.1).
  if p.curr.kind == ytkEOF:
    return newYamlNull()
  if p.curr.kind == ytkDash and p.curr.line == dashLine:
    # `- - a`: a nested sequence on the same line.
    return YamlNode(kind: yamlArray, arrValue: parseSequence(p, p.curr.col - 1))
  if p.curr.line == dashLine:
    if p.curr.kind in {ytkIdentifier, ytkString, ytkInteger, ytkFloat} and
        p.next.kind == ytkColon:
      # A compact mapping: `- name: Bob` plus continuation keys that are
      # indented deeper than the dash.
      return p.parseCompactMapping(p.curr.indent, dashCol)
    return parseValue(p, dashCol)
  # The node is on a following line. It belongs to this entry when it is
  # indented past the dash's column; a `-` deeper than the dash starts an
  # entry of a nested sequence.
  if p.curr.indent > dashCol:
    if p.curr.kind == ytkDash:
      return YamlNode(kind: yamlArray, arrValue: parseSequence(p, p.curr.col - 1))
    if p.curr.kind in {ytkIdentifier, ytkString, ytkInteger, ytkFloat} and
        p.next.kind == ytkColon:
      return p.parseCompactMapping(p.curr.indent, dashCol)
    return parseValue(p, dashCol)
  # A `-` with nothing after it is an empty (null) item.
  newYamlNull()

proc parseSequence(p: var YamlParser, dashCol: int): seq[YamlNode] =
  ## Parses a block sequence (§8.2.1). `dashCol` is the column (0-based) a `-`
  ## indicator must start at, which is how sibling entries are told apart from
  ## entries of a nested sequence (`- - a`).
  result = @[]
  while p.curr.kind == ytkDash and p.curr.col - 1 == dashCol:
    let dashLine = p.curr.line
    advance(p) # ytkDash
    result.add(p.parseSequenceItem(dashCol, dashLine))


proc parseExplicitKey(p: var YamlParser, indent: int): (string, bool) =
  ## Parses `? <node>` used as an explicit mapping key (§8.2.2). Returns the
  ## rendered key and whether a key was actually present.
  let markerLine = p.curr.line
  advance(p) # consume '?'
  if p.curr.kind == ytkEOF or (p.curr.line != markerLine and p.curr.indent <= indent):
    return ("", false)
  elif p.curr.line == markerLine and p.curr.kind in {ytkColon, ytkComma, ytkRC, ytkRB}:
    # A `?` with no node after it: `? : 1` is an entry with an empty key.
    return ("", false)
  if p.curr.kind == ytkTag:
    # A tag may precede the explicit key: `? !!str a : 1`.
    let keyTag = p.expandTagHandle(p.curr.value)
    advance(p)
    if p.curr.kind == ytkEOF:
      return ("", false)
    let (k, ok) = p.parseExplicitKey(indent)
    if not ok: return ("", false)
    var node = newYamlString(k)
    if keyTag.len > 0: node = applyTag(keyTag, node, p)
    return (node.getStr(), true)
  case p.curr.kind
  of ytkLB, ytkLC:
    # A flow collection as an explicit key. The parser already sits on the
    # opening bracket, which is where `parseValue` expects to start.
    return (renderKey(parseValue(p, indent)), true)
  of ytkDash:
    let arr = parseSequence(p, p.curr.col - 1)
    return (renderKey(YamlNode(kind: yamlArray, arrValue: arr)), true)
  of ytkBlockScalar:
    return (parseBlockString(p, indent, folded = false).strValue, true)
  else:
    if p.curr.kind in {ytkIdentifier, ytkString, ytkInteger, ytkFloat} and
        p.next.kind == ytkColon and p.next.line == markerLine and
        p.curr.line == markerLine:
      # `? key: value` is really an implicit single-pair mapping
      let obj = parseMapping(p, p.curr.indent)
      return (renderKey(YamlNode(kind: yamlObject, objValue: obj)), true)
    return (p.collectPlainKey(), true)

proc parseMappingValue(p: var YamlParser, indent, colonLine: int): YamlNode =
  ## Reads the value of a mapping entry whose `:` sits on `colonLine`.
  ## An empty value is null (§8.2.2, `key:` with nothing after it).
  if p.curr.kind == ytkEOF:
    return newYamlNull()
  if p.curr.kind == ytkBlockScalar:
    return parseBlockString(p, indent, folded = false)
  if p.curr.line != colonLine:
    # Value lives on a following line.
    if p.curr.indent > indent:
      return parseValue(p, indent)
    if p.curr.kind == ytkDash and p.curr.col - 1 == indent:
      # A block sequence may sit at the same indent as its key (§8.2.1).
      return YamlNode(kind: yamlArray, arrValue: parseSequence(p, p.curr.col - 1))
    return newYamlNull()

  # A `-` or `?` indicator cannot follow a `:` on the same line: a block
  # sequence or an explicit key needs its own, more indented line (§8.2.1).
  if p.curr.kind in {ytkDash, ytkQuestion} and p.curr.line == colonLine:
    p.error("`" & $p.curr.kind & "` cannot start a value on the same line as `:`")

  # A value on the same line as its `:` may not itself be `key: value`; a
  # nested block mapping needs its own line (§8.2.1). Quoted scalars are
  # always values, never keys, so they are excluded.
  if p.curr.kind in {ytkIdentifier, ytkInteger, ytkFloat} and
      p.next.kind == ytkColon and p.next.line == p.curr.line and
      p.next.pos + 1 < p.lex.input.len and
      p.lex.input[p.next.pos + 1] in {' ', '\t', '\n', '\r'}:
    p.error("A mapping value cannot contain a nested `key: value` pair on the same line")

  return parseValue(p, indent)

proc parseMapping(p: var YamlParser, indent: int): YAMLObject =
  result = newOrderedTable[string, YamlNode]()
  while true:
    # An entry may be prefixed by a tag and/or an anchor (§7.1).
    while p.curr.kind in {ytkTag, ytkAnchor, ytkDirective}:
      advance(p)
    if p.curr.kind == ytkEOF: break
    if p.curr.indent != indent: break
    if p.curr.kind in {ytkDocumentStart, ytkDocumentEnd, ytkComma}: break

    var value: YamlNode
    if p.curr.kind == ytkQuestion:
      # Explicit key: `? <node>` then an explicit `: <node>` (§8.2.2).
      let (key, haveKey) = p.parseExplicitKey(indent)
      if not haveKey: break
      if p.curr.kind == ytkEOF:
        result.putMapping(p, key, newYamlNull())
        continue
      if p.curr.kind == ytkColon:
        let colonLine = p.curr.line
        advance(p)
        value = p.parseMappingValue(indent, colonLine)
      else:
        # A `? key` with the value on a following, more indented line.
        if p.curr.indent > indent:
          value = parseValue(p, indent)
        else:
          value = newYamlNull()
      if key == "<<" and value != nil and value.kind == yamlObject:
        result.mergeInto(value.objValue)
      else:
        result.putMapping(p, key, value)
      continue

    if p.curr.kind == ytkColon:
      # `: value` with no key: a null key (§8.2.2).
      let colonLine = p.curr.line
      advance(p)
      result.putMapping(p, "", p.parseMappingValue(indent, colonLine))
      continue

    if p.curr.kind == ytkBlockScalar:
      # Block scalar used as a key.
      let key = parseBlockString(p, indent, folded = false).strValue
      if p.curr.kind == ytkEOF:
        result.putMapping(p, key, newYamlNull())
        continue
      if p.curr.kind == ytkColon:
        let colonLine = p.curr.line
        advance(p)
        value = p.parseMappingValue(indent, colonLine)
      else:
        value = newYamlNull()
      result.putMapping(p, key, value)
      continue

    if p.curr.kind notin {ytkIdentifier, ytkString, ytkInteger, ytkFloat}:
      break

    let key = p.collectPlainKey()
    if p.curr.kind != ytkColon:
      if p.curr.kind == ytkEOF:
        result.putMapping(p, key, newYamlNull())
        break
      p.error(unexpectedTokenExpected % [$p.curr.kind, $ytkColon])
    let colonLine = p.curr.line
    advance(p)
    value = p.parseMappingValue(indent, colonLine)
    if key == "<<" and value != nil and value.kind == yamlObject:
      result.mergeInto(value.objValue)
    else:
      result.putMapping(p, key, value)


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

proc applyTag(tag: string, n: YamlNode, p: var YamlParser): YamlNode =
  ## Applies a tag to a parsed node (§10.2, §7.1).
  ##
  ## `!!`-prefixed tags are Core Schema resolutions. Any other tag is
  ## application-specific: a scalar keeps its raw text, so `!foo 12` is the
  ## string "12" rather than the integer 12.
  if n == nil or tag.len == 0: return n
  if tag == "!":
    # `!` is the non-specific tag: resolve by kind exactly as an untagged node
    # would (§10.3.2), which for a plain scalar means the Core Schema rules.
    return n
  if not (tag.startsWith("!!") or tag.startsWith("tag:yaml.org,2002:")):
    if n.kind in {yamlString, yamlInteger, yamlFloat, yamlBoolean, yamlNull}:
      return YamlNode(kind: yamlString, strValue: n.getValue())
    return n
  var suffix = tag
  if suffix.startsWith("!!"): suffix = suffix[2..^1]
  else: suffix = suffix[18..^1]
  # `!!str` and friends only restate a scalar's type. Applied to a collection
  # they cannot be honoured, so the node is left alone rather than being
  # stringified: `!!str a: 1` tags the key `a`, not the mapping (§7.1).
  if n.kind in {yamlObject, yamlArray}: return n
  case suffix
  of "str":
    result = YamlNode(kind: yamlString, strValue: n.getValue())
  of "null":
    result = newYamlNull()
  of "bool":
    let low = n.getValue().toLowerAscii()
    if low in ["true", "yes", "on", "y"]:
      result = YamlNode(kind: yamlBoolean, boolValue: true)
    elif low in ["false", "no", "off", "n"]:
      result = YamlNode(kind: yamlBoolean, boolValue: false)
    else:
      p.error("Cannot resolve `!!bool " & n.getValue() & "`")
  of "int":
    try:
      result = YamlNode(kind: yamlInteger, intValue: parseYamlInt(n.getValue()))
    except ValueError:
      p.error("Cannot resolve `!!int " & n.getValue() & "`")
  of "float":
    try:
      result = YamlNode(kind: yamlFloat, floatValue: parseYamlFloat(n.getValue()))
    except ValueError:
      p.error("Cannot resolve `!!float " & n.getValue() & "`")
  of "seq":
    if n.kind == yamlArray: result = n
    elif n.kind == yamlNull: result = newYamlArray()
    else: p.error("Cannot resolve `!!seq` from " & $n.kind)
  of "map":
    if n.kind == yamlObject: result = n
    elif n.kind == yamlNull: result = newYamlObject()
    else: p.error("Cannot resolve `!!map` from " & $n.kind)
  else:
    result = n

proc parseValue(p: var YamlParser, parentIndent: int): YamlNode =
  ## Parses one node: optional anchor/tag, then an alias, scalar, block
  ## scalar, flow collection or block collection (§7.1, §8.2.3).
  inc p.depth
  defer: dec p.depth
  p.checkMaxDepth()

  var anchorName = ""
  var hasAnchor = false
  var tag = ""
  var inProgress = ""

  # Node properties may appear in any order: `&a !!str x`, `!!str &a x`, ...
  while true:
    case p.curr.kind
    of ytkAnchor:
      anchorName = p.curr.value
      hasAnchor = true
      inProgress = anchorName
      p.building.incl(anchorName)
      advance(p)
    of ytkTag:
      tag = p.expandTagHandle(p.curr.value)
      advance(p)
    of ytkDirective, ytkDocumentStart, ytkDocumentEnd:
      advance(p)
    else:
      break

  let inlineMode = parentIndent < 0
  # In a flow collection a node ends at `,`, the closing bracket or a comment,
  # so properties with nothing after them yield an empty node there. In block
  # context those characters cannot start a node, so they are errors instead.
  if inlineMode and p.curr.kind in {ytkEOF, ytkComma, ytkRC, ytkRB, ytkDocumentStart,
                                    ytkDocumentEnd, ytkComment} or
     (p.prev != nil and p.curr.line != p.prev.line and p.curr.indent <= parentIndent):
    result =
      if tag.len == 0: newYamlNull()
      else: applyTag(tag, newYamlString(""), p)
    if hasAnchor:
      p.anchors[anchorName] = cloneYamlNode(result)
      p.building.excl(anchorName)
    return

  if not inlineMode and p.curr.kind in {ytkComma, ytkRC, ytkRB}:
    p.error("`" & $p.curr.kind & "` cannot start a node in block context")

  if p.curr.kind == ytkAlias:
    let name = p.curr.value
    advance(p)
    if name in p.building or name == inProgress:
      p.error("Anchor `&" & name & "` cannot refer to itself")
    if not p.anchors.hasKey(name):
      p.error(errorUndefinedAlias % name)
    result = cloneYamlNode(p.anchors[name])
  else:
    case p.curr.kind
    of ytkIdentifier, ytkString, ytkInteger, ytkFloat:
      # A key may span several tokens, so decide between a mapping and a
      # scalar by collecting the key and rewinding if no `:` follows.
      let save = p.snapshot()
      let keyIndent = p.curr.indent
      discard p.collectPlainKey()
      if not inlineMode and p.curr.kind == ytkColon and keyIndent > parentIndent:
        p.restore(save)
        result = YamlNode(kind: yamlObject, objValue: parseMapping(p, keyIndent))
      else:
        p.restore(save)
        result = parsePlainUnquoted(p, inlineMode, parentIndent)
    of ytkLB:
      result = parseInlineArray(p)
      p.checkFlowEnd()
    of ytkLC:
      result = parseInlineObject(p)
      p.checkFlowEnd()
    of ytkColon:
      # A `:` not followed by whitespace begins a plain scalar such as `:x`,
      # since `ns-plain-first` allows `:` when a plain-safe character follows
      # it (§7.3.3).
      if p.lex.isPlainFollowedByContent(p.curr.pos):
        result = parsePlainUnquoted(p, inlineMode, parentIndent)
      else:
        p.error(unexpectedTokenExpected % [$p.curr.kind, "value"])
    of ytkDash:
      result = YamlNode(kind: yamlArray, arrValue: parseSequence(p, p.curr.col - 1))
    of ytkBlockScalar:
      result = parseBlockString(p, parentIndent, folded = false)
    of ytkQuestion:
      let obj = parseMapping(p, p.curr.indent)
      result = YamlNode(kind: yamlObject, objValue: obj)
    else:
      p.error(unexpectedTokenExpected % [$p.curr.kind, "value"])

  if tag.len > 0:
    result = applyTag(tag, result, p)
  if hasAnchor:
    p.anchors[anchorName] = cloneYamlNode(result)
    p.building.excl(anchorName)


proc parseDirective(p: var YamlParser) =
  ## Validates a `%YAML` or `%TAG` directive and applies it (§6.8).
  ##
  ## Any other directive name is reserved and rejected: only these two are
  ## defined by the 1.2 specification (§3.2.3.4).
  let raw = p.curr.value
  let nameEnd = raw.find(' ')
  let name = if nameEnd < 0: raw.strip() else: raw[0..<nameEnd]
  let rest = if nameEnd < 0: "" else: raw[nameEnd..^1].strip()
  case name
  of "YAML":
    let parts = rest.split('.')
    if parts.len != 2 or parts[0].len == 0 or parts[1].len == 0 or
        parts[0].anyIt(not (it in {'0'..'9'})) or parts[1].anyIt(not (it in {'0'..'9'})):
      p.error("`%YAML` requires a version such as `%YAML 1.2`")
    let major = parseInt(parts[0])
    let minor = parseInt(parts[1])
    # A 1.2 processor must accept 1.1 and 1.2 documents; a higher major version
    # is rejected, a higher minor version is accepted (§6.8.1).
    if major != 1 or minor > 2:
      if major > 1:
        p.error("Incompatible YAML version `%YAML " & rest & "`")
  of "TAG":
    let parts = rest.split(' ')
    if parts.len != 2:
      p.error("`%TAG` requires a handle and a prefix, e.g. `%TAG !e! tag:example.com,2000:app/`")
    let handle = parts[0]
    let prefix = parts[1]
    if handle == "":
      p.error("Empty tag handle in `%TAG`")
    if handle != "!":
      if handle.len < 3 or handle[0] != '!' or handle[^1] != '!' or
          handle[1..^2].anyIt(not isTagNameChar(it)):
        p.error("Invalid tag handle `" & handle & "` in `%TAG`")
    if prefix.len == 0 or not isUriChar(prefix[0]):
      p.error("Invalid tag prefix `" & prefix & "` in `%TAG`")
    p.tagHandles[handle] = prefix
  of "":
    p.error("Empty directive name after `%`")
  else:
    p.error("Unknown directive `%`" & name & "`; only `%YAML` and `%TAG` are defined")


proc expandTagHandle(p: YamlParser, tag: string): string =
  ## Resolves a tag token's value to a full tag URI using the `%TAG` handles
  ## declared for the current document (§6.8.2).
  if tag.len == 0 or tag[0] != '!': return tag
  if tag == "!" or tag == "!!" or tag.startsWith("!<"): return tag
  if tag[1] != '!': return tag # the `!` handle: the tag is already a URI
  let bang = tag.find('!', 1)
  if bang < 0: return tag
  let handle = tag[0..bang]
  if not p.tagHandles.hasKey(handle): return tag
  p.tagHandles[handle] & tag[bang + 1..^1]


proc skipDirectivesAndDocs(p: var YamlParser) =
  ## Consume the directives, document markers and comments that may precede a
  ## document's content (§9.1, §9.2).
  while true:
    if p.curr.kind == ytkDirective:
      p.parseDirective()
      advance(p)
      continue
    if p.curr.kind == ytkDocumentStart:
      advance(p)
      continue
    if p.curr.kind == ytkComment:
      advance(p)
      continue
    break

proc parseDocument(p: var YamlParser): YamlNode =
  ## Parse exactly one document, which may be a block mapping, a block
  ## sequence, a flow collection or a bare scalar.
  ##
  ## This is root-aware: `parseValue` alone cannot distinguish a block
  ## sequence from a block mapping without inspecting the leading token.
  p.skipDirectivesAndDocs()
  if p.curr.kind == ytkEOF or p.curr.kind == ytkDocumentEnd:
    return newYamlNull()

  # Node properties may precede the document's root node (§7.1).
  var rootAnchor = ""
  var hasRootAnchor = false
  var rootTag = ""
  while p.curr.kind in {ytkAnchor, ytkTag, ytkDirective}:
    case p.curr.kind
    of ytkAnchor:
      rootAnchor = p.curr.value
      hasRootAnchor = true
      p.building.incl(rootAnchor)
    of ytkTag:
      rootTag = p.expandTagHandle(p.curr.value)
    else:
      discard
    advance(p)
  if p.curr.kind == ytkEOF or p.curr.kind == ytkDocumentEnd:
    result =
      if rootTag.len == 0: newYamlNull()
      else: applyTag(rootTag, newYamlNull(), p)
    if hasRootAnchor: p.building.excl(rootAnchor)
    return result

  case p.curr.kind
  of ytkDash:
    # A block sequence as the document root.
    result = YamlNode(kind: yamlArray, arrValue: parseSequence(p, p.curr.col - 1))
  of ytkLC:
    result = parseInlineObject(p)
  of ytkLB:
    result = parseInlineArray(p)
  of ytkQuestion, ytkColon, ytkTag, ytkAnchor:
    # A mapping whose first entry uses an explicit key or a null key (§8.2.2).
    result = YamlNode(kind: yamlObject, objValue: parseMapping(p, p.curr.indent))
  of ytkIdentifier, ytkString, ytkInteger, ytkFloat:
    # A plain key may span several tokens (`a b c: v`), so the decision is
    # made after collecting the key rather than from the second token alone.
    let save = p.snapshot()
    discard p.collectPlainKey()
    let isMapping = p.curr.kind == ytkColon
    p.restore(save)
    if isMapping:
      result = YamlNode(kind: yamlObject, objValue: parseMapping(p, save.curr.indent))
    else:
      # Bare scalar document. Pass a non-negative parent indent so the scalar
      # is not treated as a flow scalar (a root scalar may contain commas).
      # `p.prev` is dropped: after the rewind it still points at the token
      # before the document, and `parseValue` uses it to detect an empty value.
      p.prev = nil
      result = parseValue(p, 0)
  of ytkBlockScalar:
    result = parseBlockString(p, p.curr.indent, folded = false)
  else:
    p.error(unexpectedTokenExpected % [$p.curr.kind, "document"])
  if rootTag.len > 0:
    result = applyTag(rootTag, result, p)
  if hasRootAnchor:
    p.anchors[rootAnchor] = cloneYamlNode(result)
    p.building.excl(rootAnchor)

proc parseRoot(p: var YamlParser): YAMLObject =
  ## Parse the first document and return it as a mapping.
  ##
  ## Backwards-compatible wrapper: a document whose root is a sequence or a
  ## scalar has no mapping to return, so an empty table is produced. Use
  ## `parseYAMLNode` to read sequence and scalar documents.
  result = newOrderedTable[string, YamlNode]()
  let doc = p.parseDocument()
  if doc.kind == yamlObject:
    result = doc.objValue

proc nimStringLiteral(s: string): string =
  result = "\""
  for ch in s:
    case ch
    of '\\': result.add("\\")
    of '"': result.add("\\\"")
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

proc toYamlNode*(j: JsonNode): YamlNode =
  ## Converts a `JsonNode` into a `YamlNode` so both share one emitter.
  case j.kind
  of JNull:
    result = newYamlNull()
  of JBool:
    result = YamlNode(kind: yamlBoolean, boolValue: j.getBool)
  of JInt:
    result = YamlNode(kind: yamlInteger, intValue: j.getInt)
  of JFloat:
    result = YamlNode(kind: yamlFloat, floatValue: j.getFloat)
  of JString:
    result = YamlNode(kind: yamlString, strValue: j.getStr)
  of JArray:
    var items: seq[YamlNode] = @[]
    for item in j: items.add(toYamlNode(item))
    result = YamlNode(kind: yamlArray, arrValue: items)
  of JObject:
    var obj = newOrderedTable[string, YamlNode]()
    for k, v in j: obj[k] = toYamlNode(v)
    result = YamlNode(kind: yamlObject, objValue: obj)

proc yamlStringLiteral*(s: string): string =
  ## Renders `s` as a double-quoted YAML scalar (§7.3.3, §7.7). Always safe:
  ## any content is escaped, so the result never depends on context.
  result = "\""
  for ch in s:
    case ch
    of '\\': result.add("\\")
    of '"': result.add("\\\"")
    of '\n': result.add("\\n")
    of '\r': result.add("\\r")
    of '\t': result.add("\\t")
    of '\0': result.add("\\0")
    of '\x07': result.add("\\a")
    of '\x08': result.add("\\b")
    of '\x0B': result.add("\\v")
    of '\x0C': result.add("\\f")
    of '\x1B': result.add("\\e")
    else:
      let o = ord(ch)
      if o < 0x20 or o == 0x7F:
        result.add("\\x" & toHex(o, 2))
      else:
        result.add(ch)
  result.add("\"")

proc yamlPlainSafe(s: string): bool =
  ## True when `s` can be written as a plain (unquoted) YAML scalar in any
  ## position: it must not look like another node, must not contain a `: ` or
  ## ` #` pair, and must not start or end with whitespace (§7.3.3).
  if s.len == 0: return false
  if s != s.strip(): return false
  # Indicators that may not open a plain scalar (§7.3.3).
  const indicators = {'-', '?', ':', ',', '[', ']', '{', '}', '#', '&', '*',
                      '!', '|', '>', '\'', '"', '%', '@', '`'}
  if s[0] in indicators:
    # `-`, `?` and `:` are only indicators when followed by a space.
    if s[0] in {'-', '?', ':'} and s.len > 1 and s[1] notin {' ', '\t'}:
      discard
    else:
      return false
  for i, ch in s:
    if ch in {'\n', '\r', '\t'}: return false
    if ch == ':' and i + 1 < s.len and s[i + 1] in {' ', '\t'}: return false
    if ch == '#' and i > 0 and s[i - 1] in {' ', '\t'}: return false
  # Would resolve to a non-string type under the Core Schema (§10.3.2).
  let probe = s.toLowerAscii()
  if probe in ["true", "false", "null", "~"]:
    return false
  if probe in [".inf", "-.inf", "+.inf", ".nan"]:
    return false
  # Plain scalars that would be read back as a number.
  var looksNumeric = true
  for ch in s:
    if ch notin {'0'..'9', '+', '-', '.', '_'}:
      looksNumeric = false
      break
  if looksNumeric and (s[0].isDigit or s[0] in {'+', '-', '.'}): return false
  true

proc yamlEmitScalar(s: string): string =
  ## Renders a string as a YAML scalar, quoting only when required.
  if yamlPlainSafe(s): s else: yamlStringLiteral(s)

proc yamlBlockScalarHeader(s: string, folded: bool): string =
  ## Returns the `|`/`>` header line for a block scalar holding `s`, or ""
  ## when block style would not round-trip `s`. Keeps generated YAML readable
  ## for the common case of a value that is mostly prose (§8.1).
  if s.len == 0: return ""
  if not s.contains('\n'): return ""
  # The block body must not be empty once indentation is stripped.
  if s.strip(chars = {'\n', ' ', '\t'}).len == 0: return ""
  # Trailing spaces on any line are lost in block style.
  for line in s.split('\n'):
    if line.len > 0 and line[^1] in {' ', '\t'}: return ""
  # Chomping: the value's own trailing break decides strip/clip/keep.
  var trailing = 0
  var body = s
  while body.len > 0 and body[^1] == '\n':
    body.setLen(body.len - 1)
    inc trailing
  body.add('\n')
  # Leading spaces on the first line are content, and a first line of only
  # spaces would be read as indentation, so those need an explicit indicator.
  # An explicit indent indicator is needed only when the first body line
  # starts with a space, or is empty. Later empty lines are unambiguous
  # because the first line fixes the detected indent.
  var indicator = ""
  if body.len == 0 or body[0] == ' ' or body[0] == '\n':
    indicator = "2"
  let chomp =
    if trailing == 0: "-"
    elif trailing == 1: ""
    else: "+"
  result = (if folded: ">" else: "|") & indicator & chomp

proc yamlBlockIndent(s: string): int =
  ## The indent a block scalar body must be written at to preserve `s`.
  for line in s.split('\n'):
    if line.len > 0: return leadingSpaces(line)
  0

proc yamlEmitKey(s: string): string =
  ## Renders a mapping key. Keys are quoted whenever a plain form would be
  ## ambiguous: whitespace, a `:` that could read as the key/value separator,
  ## or any character a plain scalar may not contain (§7.3.3).
  for ch in s:
    if ch in {' ', '\t', '\n', '\r', ':', '#'}: return yamlStringLiteral(s)
  yamlEmitScalar(s)

proc yamlFloatText(f: float64): string =
  ## Formats a float so the Core Schema reads it back unchanged (§10.3.2).
  if f != f: return ".nan"
  if f == Inf: return ".inf"
  if f == -Inf: return "-.inf"
  var t = $f
  if t in ["inf", "Inf", "-inf", "-Inf", "nan", "NaN"]:
    return if f != f: ".nan"
    elif f > 0: ".inf" else: "-.inf"
  # YAML 1.2 requires a digit on both sides of the decimal point.
  if t.startsWith("."): t = "0" & t
  elif t.startsWith("-."): t = "-0" & t[1..^1]
  if not t.contains("e") and not t.contains("E") and
      not t.contains(".") and not t.contains("inf"):
    t.add(".0")
  result = t

proc isNonEmptyCollection(n: YamlNode): bool =
  ## True for a mapping or sequence that needs its own indented block.
  case n.kind
  of yamlArray: n.arrValue.len > 0
  of yamlObject: n.objValue.len > 0
  else: false


proc dumpYamlNode(node: YamlNode, indent: int, buf: var string, sameLine: bool) =
  ## Writes `node` as a block YAML node.
  ##
  ## `indent` is the column block content is written at. `sameLine` is true
  ## when the caller already wrote the space that separates `node` from a
  ## preceding `-` or `key:`, which lets the first character of `node`
  ## continue that line. A non-empty collection always starts a fresh
  ## indented block; a leaf or an empty collection is written directly.
  case node.kind
  of yamlNull:
    buf.add("null")
  of yamlBoolean:
    buf.add($node.boolValue)
  of yamlInteger:
    buf.add($node.intValue)
  of yamlFloat:
    buf.add(yamlFloatText(node.floatValue))
  of yamlString:
    # Prose reads better as a block scalar than as one long quoted line.
    let header = yamlBlockScalarHeader(node.strValue, folded = false)
    if header.len > 0:
      buf.add(header)
      let bodyIndent = max(indent + 2, yamlBlockIndent(node.strValue) + indent)
      for line in node.strValue.split('\n'):
        if line.len == 0:
          if node.strValue[^1] == '\n': buf.add("\n")
        else:
          buf.add("\n")
          buf.add(repeat(' ', bodyIndent))
          buf.add(line)
    else:
      buf.add(yamlEmitScalar(node.strValue))
  of yamlArray:
    if node.arrValue.len == 0:
      buf.add("[]")
      return
    for i, item in node.arrValue:
      # The first entry may continue a line the caller already opened
      # (`key: - x`); later entries always start their own line.
      if not (i == 0 and sameLine):
        buf.add("\n")
        buf.add(repeat(' ', indent))
      buf.add("-")
      if isNonEmptyCollection(item):
        dumpYamlNode(item, indent + 2, buf, false)
      else:
        buf.add(" ")
        dumpYamlNode(item, indent + 2, buf, true)
  of yamlObject:
    if node.objValue.len == 0:
      buf.add("{}")
      return
    # A mapping entry either continues the caller's line (`key: v`) or starts
    # its own, depending on `sameLine`.
    var first = true
    for k, v in node.objValue.pairs:
      if not (first and sameLine):
        buf.add("\n")
        buf.add(repeat(' ', indent))
      first = false
      buf.add(yamlEmitKey(k))
      buf.add(":")
      # A non-empty collection goes on its own indented block under the key;
      # a scalar or an empty collection shares the key's line after a space.
      if isNonEmptyCollection(v):
        dumpYamlNode(v, indent + 2, buf, false)
      else:
        buf.add(" ")
        dumpYamlNode(v, indent + 2, buf, true)

proc dumpYamlDocument(node: YamlNode): YAML =
  ## Renders a node as a standalone YAML document.
  var buf = ""
  # Nothing precedes the root: the first line has no opening prefix, so a
  # collection's first entry still needs its own line.
  dumpYamlNode(node, 0, buf, false)
  result = buf.strip(chars = {'\n'})

proc dump*(json: JsonNode): YAML =
  ## Serializes a `JsonNode` to a YAML document.
  result = dumpYamlDocument(toYamlNode(json))

proc dump*(node: YamlNode): YAML =
  ## Serializes a `YamlNode` to a YAML document.
  result = dumpYamlDocument(node)

proc dump*(obj: YAMLObject): YAML =
  ## Serializes a `YAMLObject` to a YAML document.
  if obj == nil: return "{}\n"
  dump(YamlNode(kind: yamlObject, objValue: obj))

proc dump*(docs: seq[YamlNode]): YAML =
  ## Serializes a multi-document stream, separating documents with `---`.
  for i, doc in docs:
    if i > 0: result.add("---\n")
    result.add(dump(doc))
    result.add("\n")

proc `$`*(node: YamlNode): string =
  ## Canonical flow form of a node; stable and re-parsable.
  case node.kind
  of yamlNull: "null"
  of yamlBoolean: $node.boolValue
  of yamlInteger: $node.intValue
  of yamlFloat: $node.floatValue
  of yamlString: node.strValue
  of yamlObject: renderKey(node)
  of yamlArray: renderKey(node)


proc initYamlParser*(input: YAML, opts: YamlOptions = nil): YamlParser =
  var lex = newYamlLexer(input)
  var options = if opts != nil: opts else: defaultYamlOptions()
  # `allowTabsAsIndent` is the deprecated spelling of `strictTabs = false`.
  if options.allowTabsAsIndent: options.strictTabs = false
  result = YamlParser(lex: lex,
    options: options,
    anchors: initTable[string, YamlNode](),
    building: initHashSet[string](),
    tagHandles: initTable[string, string]())
  result.curr = result.nextToken()
  result.next = result.nextToken()
  while result.curr.kind == ytkComment:
    result.curr = result.next
    result.next = result.nextToken()

proc parseYAML*(input: YAML): YAMLObject =
  ## Parse the first document of a YAML string as a mapping.
  var p = initYamlParser(input)
  p.parseRoot()

proc parseYAML*(input: YAML, opts: YamlOptions): YAMLObject =
  var p = initYamlParser(input, opts)
  p.parseRoot()

proc parseYAMLNode*(input: YAML): YamlNode =
  ## Parse the first document of a YAML string into a `YamlNode`.
  ##
  ## Unlike `parseYAML`, this preserves documents whose root is a sequence or
  ## a scalar, which YAML permits and `YAMLObject` cannot represent.
  var p = initYamlParser(input)
  p.parseDocument()

proc parseYAMLNode*(input: YAML, opts: YamlOptions): YamlNode =
  ## Parse the first document of a YAML string into a `YamlNode`.
  var p = initYamlParser(input, opts)
  p.parseDocument()

type
  YamlFrontmatter* = object
    ## The result of splitting a document into its frontmatter block and body.
    ##
    ## A frontmatter block is delimited by a `---` line at the very start of a
    ## document and closed by a `---` or `...` line, the convention used by
    ## Jekyll, Hugo, Obsidian and static site generators. It is not part of the
    ## YAML specification, which is why `parseYAML` ignores it.
    found*: bool
      ## True when a well-formed frontmatter block was present.
    frontmatter*: string
      ## The raw text between the delimiters, with no leading or trailing
      ## newline. Empty when `found` is false.
    body*: string
      ## Everything after the closing delimiter, with the line break that ended
      ## the frontmatter removed.
    bodyOffset*: int
      ## Byte offset in the original input where `body` starts, so a caller can
      ## splice the document back together.

const
  yamlFrontmatterError* = "Unterminated YAML frontmatter block"

proc splitFrontmatter*(input: YAML): YamlFrontmatter =
  ## Splits `input` into an optional YAML frontmatter block and the body that
  ## follows it.
  ##
  ## A block must open on the very first line with `---` (a BOM is tolerated) and
  ## is closed by a line containing only `---` or `...`. This is a widespread
  ## convention rather than part of YAML 1.2, so frontmatter is only recognised
  ## by this procedure and by `parseYAMLFrontmatter`; `parseYAML` treats a
  ## leading `---` as an ordinary document start marker.
  ##
  ## Raises `OpenParserYamlError` when a block opens but never closes, which
  ## would otherwise silently swallow the whole document.
  result.body = input
  let off = stripBom(input)
  if off >= input.len: return

  # The opening delimiter is a line consisting of exactly `---` (§9.2 allows
  # trailing content after it, but a frontmatter opener must be alone).
  var i = off
  if input[i] == '-':
    var eol = i
    while eol < input.len and input[eol] notin {'\n', '\r'}: inc eol
    if input[i..<eol] != "---": return
    i = eol
    while i < input.len and input[i] in {'\n', '\r'}: inc i

    # Scan for the closing delimiter at the start of a line.
    var lineStart = i
    while lineStart < input.len:
      var eol = lineStart
      while eol < input.len and input[eol] notin {'\n', '\r'}: inc eol
      let line = input[lineStart..<eol]
      if line == "---" or line == "...":
        result.found = true
        var fmEnd = lineStart
        # Drop the line break that ends the frontmatter block, but keep any
        # blank lines inside it.
        while fmEnd > i and input[fmEnd - 1] in {'\n', '\r'}: dec fmEnd
        result.frontmatter = input[i..<fmEnd]
        var bodyStart = eol
        if bodyStart < input.len and input[bodyStart] == '\r': inc bodyStart
        if bodyStart < input.len and input[bodyStart] == '\n': inc bodyStart
        result.body = input[bodyStart..^1]
        result.bodyOffset = bodyStart
        return
      if eol >= input.len: break
      # Step past this line's break, honouring CRLF as one break.
      inc eol
      if eol < input.len and input[eol] == '\n' and eol > 0 and input[eol - 1] == '\r':
        inc eol
      lineStart = eol
    raise newException(OpenParserYamlError, yamlFrontmatterError)

proc parseYAMLFrontmatter*(input: YAML, opts: YamlOptions = nil): YamlNode =
  ## Parses the frontmatter block of `input` as YAML, returning the body
  ## unchanged.
  ##
  ## Raises `OpenParserYamlError` when there is no frontmatter block, since
  ## silently returning a null node would hide a malformed document. Use
  ## `splitFrontmatter` first to tell the two cases apart.
  let fm = splitFrontmatter(input)
  if not fm.found:
    raise newException(OpenParserYamlError, "No YAML frontmatter block found")
  var p = initYamlParser(fm.frontmatter, opts)
  p.parseDocument()

proc parseYAMLFrontmatter*(input: YAML, opts: YamlOptions,
                           body: var string): YamlNode =
  ## Parses the frontmatter block of `input` as YAML, assigning the remaining
  ## body to `body`.
  let fm = splitFrontmatter(input)
  if not fm.found:
    raise newException(OpenParserYamlError, "No YAML frontmatter block found")
  body = fm.body
  var p = initYamlParser(fm.frontmatter, opts)
  p.parseDocument()

proc parseYAMLStreamNodes*(input: YAML, opts: YamlOptions = nil): seq[YamlNode] =
  ## Parse a multi-document stream, preserving sequence and scalar documents.
  var p = initYamlParser(input, opts)
  result = @[]
  while true:
    p.skipDirectivesAndDocs()
    if p.curr.kind == ytkEOF: break
    if p.curr.kind == ytkDocumentEnd:
      p.advance()
      continue
    if p.curr.kind == ytkDocumentStart:
      p.advance()
      p.skipDirectivesAndDocs()
      if p.curr.kind == ytkEOF: break
    # `parseDocument` consumes a whole document, so there is nothing left to
    # skip afterwards. Advancing here would eat the next document's first token.
    let before = p.curr
    result.add(p.parseDocument())
    # A document that consumed nothing would spin this loop forever.
    if p.curr == before:
      p.advance()
  if result.len == 0:
    result.add(newYamlNull())

proc parseYAMLStream*(input: YAML, opts: YamlOptions = nil): seq[YAMLObject] =
  ## Parse multi-document stream, returning each document as YAMLObject
  ##
  ## A document whose root is a sequence or a scalar has no mapping to
  ## return, so an empty table is used for those. Use `parseYAMLStreamNodes`
  ## to read them.
  var p = initYamlParser(input, opts)
  result = @[]
  while true:
    p.skipDirectivesAndDocs()
    if p.curr.kind == ytkEOF: break
    if p.curr.kind == ytkDocumentEnd:
      p.advance()
      continue
    if p.curr.kind == ytkDocumentStart:
      p.advance()
      p.skipDirectivesAndDocs()
      if p.curr.kind == ytkEOF: break
    let doc = p.parseDocument()
    if doc.kind == yamlObject:
      result.add(doc.objValue)
    else:
      result.add(newOrderedTable[string,YamlNode]())
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
    inc p.flowDepth
    while p.curr.kind != ytkRC:
      if p.curr.kind == ytkEOF:
        dec p.flowDepth
        p.error(errorEndOfFile % ["inline object"])
      if p.curr.kind notin {ytkIdentifier, ytkString, ytkInteger, ytkFloat}:
        dec p.flowDepth
        p.error(unexpectedTokenExpected % [$p.curr.kind, "mapping key"])

      let key {.inject.} = p.curr.value
      let yamlMapIndent {.inject.} = -1
      p.advance()

      if p.curr.kind != ytkColon:
        dec p.flowDepth
        p.error(unexpectedTokenExpected % [$p.curr.kind, $ytkColon])
      p.advance()

      body

      if p.curr.kind == ytkComma:
        p.advance()
      elif p.curr.kind != ytkRC:
        dec p.flowDepth
        p.error(unexpectedTokenExpected % [$p.curr.kind, "comma or }"])
    dec p.flowDepth
    p.advance() # '}'
  else:
    # Any scalar may be a mapping key (YAML 1.2), not just identifiers and
    # quoted strings: `02: "Canillo"` is a valid entry.
    if p.curr.kind notin {ytkIdentifier, ytkString, ytkInteger, ytkFloat, ytkEOF}:
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
    while p.curr.kind in {ytkIdentifier, ytkString, ytkInteger, ytkFloat} and
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
          p.curr.kind in {ytkIdentifier, ytkString, ytkInteger, ytkFloat} and
          p.curr.indent > baseIndent:
        effectiveIndent = p.curr.indent

#
# Parse Hooks
#
proc collectTypedPlainLine(p: var YamlParser, parentIndent = -1): string =
  ## Collects the tokens of a plain scalar into a single string, preserving
  ## original spacing via `wsno`. Mirrors `parsePlainUnquoted` but always
  ## returns a string (no bool/int coercion). In flow context (`flowDepth > 0`)
  ## it stops before ',', ']' and '}' so inline delimiters stay for the
  ## caller. Continuation lines that are more indented than `parentIndent` are
  ## folded in with a single space (§7.3.3).
  var buf = collectPlainLine(p, p.flowDepth > 0, p.curr)[0]
  if parentIndent < 0 or p.flowDepth > 0:
    return buf
  while p.plainCanContinue(parentIndent):
    let contTok = p.curr
    let cont = collectPlainLine(p, false, contTok)[0]
    if cont.len == 0: break
    buf.add(" ")
    buf.add(cont)
  return buf

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
  if isYamlNullToken(p.curr):
    # An unquoted `null` or `~` is a null scalar, not the four letters "null".
    # A quoted `"null"` arrives as ytkString and is kept verbatim.
    v = ""
    p.advance()
    return
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
  of ytkBlockScalar:
    let node = p.parseBlockString(parentIndent = p.curr.indent, folded = false)
    v = node.strValue
    if hasAnchor:
      p.anchors[anchorName] = YamlNode(kind: yamlString, strValue: v)
    return
  of ytkEOF:
    v = ""
    if hasAnchor:
      p.anchors[anchorName] = YamlNode(kind: yamlString, strValue: v)
    return
  else:
    # Empty value: `key:` with nothing on the same line. prev is the ':' (or
    # anchor/tag following it). If curr is on a later line at same/shallower
    # indent it is a sibling key, treat as empty without consuming.
    if p.prev != nil and p.curr.line != p.prev.line:
      if p.curr.indent <= p.prev.indent:
        v = ""
        if hasAnchor:
          p.anchors[anchorName] = YamlNode(kind: yamlString, strValue: v)
        return
      # Indented content on the next line: either a nested mapping/sequence
      # (type error for a string) or a plain scalar continuation.
      if p.curr.kind == ytkDash:
        p.error(unexpectedTokenExpected % [$p.curr.kind, "string scalar"])
      if (p.curr.kind in {ytkIdentifier, ytkString}) and p.next.kind == ytkColon:
        p.error(unexpectedTokenExpected % [p.curr.value, "string scalar"])
      if p.curr.kind in {ytkLB, ytkLC}:
        p.error(unexpectedTokenExpected % [$p.curr.kind, "string scalar"])
      # Otherwise fall through and collect the indented plain line(s).
    v = p.collectTypedPlainLine(p.prev.indent)
    if hasAnchor:
      p.anchors[anchorName] = YamlNode(kind: yamlString, strValue: v)
    return

proc parseHook*(p: var YamlParser, v: var bool) =
  ## A hook to parse boolean fields (anchor aware).
  ## A `null` scalar yields `false`; an empty value leaves the default.
  if p.curr.kind == ytkEOF:
    v = false
    return
  if p.curr.kind == ytkIdentifier and
      (p.curr.value == "null" or p.curr.value == "~"):
    v = false
    p.advance()
    return
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
  ## A hook to parse float fields (supports .inf/.nan/_ , alias).
  ## A `null` scalar yields 0.0; an empty value leaves the default.
  if p.curr.kind == ytkEOF:
    v = T(0)
    return
  if p.curr.kind == ytkIdentifier and
      (p.curr.value == "null" or p.curr.value == "~"):
    v = T(0)
    p.advance()
    return
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
  ## A hook to parse integer fields (supports 0o/0x/_ , alias).
  ## A `null` scalar yields 0; an empty value leaves the default.
  if p.curr.kind == ytkEOF:
    v = 0
    return
  if p.curr.kind == ytkIdentifier and
      (p.curr.value == "null" or p.curr.value == "~"):
    v = 0
    p.advance()
    return
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
    inc p.flowDepth
    while p.curr.kind != ytkRB:
      if p.curr.kind == ytkEOF:
        dec p.flowDepth
        p.error(errorEndOfFile % ["inline array"])
      var item: T
      p.parseHook(item)
      v.incl(item)
      if p.curr.kind == ytkComma:
        p.advance()
      elif p.curr.kind != ytkRB:
        dec p.flowDepth
        p.error(unexpectedTokenExpected % [$p.curr.kind, "comma or ]"])
    dec p.flowDepth
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
  # `key:` with no value is an empty sequence, mirroring how the string hook
  # treats the same shape. Without this a field whose value is omitted would
  # be mistaken for the following sibling key.
  if p.curr.kind != ytkEOF and
      p.curr.kind in {ytkIdentifier, ytkString, ytkInteger, ytkFloat} and
      p.next.kind == ytkColon and p.prev != nil and
      p.curr.line != p.prev.line and p.curr.indent <= p.prev.indent:
    return
  case p.curr.kind
  of ytkLB:
    # inline: [a, b, c]
    p.advance() # '['
    inc p.flowDepth
    while p.curr.kind != ytkRB:
      if p.curr.kind == ytkEOF:
        dec p.flowDepth
        p.error(errorEndOfFile % ["inline array"])
      var item: T
      p.parseHook(item)
      v.add(item)

      if p.curr.kind == ytkComma:
        p.advance()
      elif p.curr.kind != ytkRB:
        dec p.flowDepth
        p.error(unexpectedTokenExpected % [$p.curr.kind, "comma or ]"])
    dec p.flowDepth
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
    inc p.flowDepth
    while p.curr.kind != ytkRB:
      if p.curr.kind == ytkEOF:
        dec p.flowDepth
        p.error(errorEndOfFile % ["inline array"])
      
      if idx >= N:
        dec p.flowDepth
        p.error("Sequence has more items than array size (" & $N & ")")
      
      var item: T
      p.parseHook(item)
      v[idx] = item
      inc idx

      if p.curr.kind == ytkComma:
        p.advance()
      elif p.curr.kind != ytkRB:
        dec p.flowDepth
        p.error(unexpectedTokenExpected % [$p.curr.kind, "comma or ]"])
    dec p.flowDepth
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

proc parseYAML*[T](p: var YamlParser, v: var seq[T]) =
  ## Parse a top-level YAML sequence into `v`.
  ##
  ## A document whose root is a block sequence cannot be read into a single
  ## object, so `parseYAML[T]` for `object` rejects it. This overload accepts
  ## `seq[T]` and fills it item by item.
  v.setLen(0)
  case p.curr.kind
  of ytkEOF:
    return
  of ytkLB:
    p.parseHook(v)
    return
  of ytkDash:
    discard
  else:
    p.error(unexpectedTokenExpected % [$p.curr.kind, "sequence"])
  let seqIndent = p.curr.indent
  while p.curr.kind == ytkDash and p.curr.indent == seqIndent:
    let dashLine = p.curr.line
    p.advance() # '-'
    if p.curr.kind == ytkEOF:
      break
    var item: T
    if p.curr.line == dashLine or p.curr.indent > seqIndent:
      p.parseHook(item)
    v.add(item)

macro parseYamlMacro(x: typed, str: typed): untyped =
  var objIdent = x.getTypeImpl()[1]
  var
    blockStmtList = newStmtList()
    blockStmtId = genSym(nskLabel, "openparserYaml")
  add blockStmtList, quote do:
    var
      tmp: `objIdent`
      p = initYamlParser(`str`)

    p.parseYAML(tmp)
    ensureMove(tmp) # return the parsed object
  var blockStmt = newBlockStmt(blockStmtId, blockStmtList)
  result = newStmtList().add(blockStmt)

proc parseYAML*[T](input: YAML, t: typedesc[T]): T =
  ## Parse YAML string into a Nim object or sequence of type `T`
  parseYamlMacro(T, input)

proc parseYAMLFrontmatter*[T: object|ref object](input: YAML,
                                                 body: var string,
                                                 opts: YamlOptions = nil): T =
  ## Parses the frontmatter block of `input` into `T`, assigning the remaining
  ## body to `body`.
  ##
  ## To read only the metadata, use `parseYAML[T](splitFrontmatter(src).frontmatter)`
  ## or ignore `body` here.
  let fm = splitFrontmatter(input)
  if not fm.found:
    raise newException(OpenParserYamlError, "No YAML frontmatter block found")
  body = fm.body
  var p = initYamlParser(fm.frontmatter, opts)
  p.parseYAML(result)
