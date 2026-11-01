# A collection of tiny parsers and dumpers
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/openparser

## This module implements a TOML parser and serializer for Nim,
## allowing you to read and write TOML configuration files with ease.
##
## The parser targets **TOML v1.0.0**. It
## parses TOML format into Nim data structures, like tables, sequences,
## and basic types, and serializes data structures back into TOML format.
##
## Parsing to pre-defined Toml AST nodes is supported as well, so you can work with
## a structured representation of the TOML document if you need more control or want to
## implement custom validation rules beyond what the direct-to-struct parsing provides
import std/[strutils, tables, sets, unicode, times, options, critbits, typetraits, macros]
import ./private/types
import ./json

type
  TOML* = string

  TomlDateKind* = enum
    ## TOML has four distinct date/time types and the difference is
    ## significant: only the offset date-time names an absolute point in time.
    tdkOffsetDateTime  ## full-date + full-time, e.g. `1979-05-27T07:32:00Z`
    tdkLocalDateTime   ## full-date + partial-time, e.g. `1979-05-27T07:32:00`
    tdkLocalDate       ## full-date, e.g. `1979-05-27`
    tdkLocalTime       ## partial-time, e.g. `07:32:00`

  TomlLexer* = object of OpenLexer
    ## The TomlLexer is responsible for tokenizing a TOML input string.
    ## It produces a stream of TomlTokens that can be consumed by a parser.
    ## The `date*` fields carry the components of the date/time token that is
    ## currently being scanned.
    dateYear, dateMonth, dateDay: int
    dateHour, dateMinute, dateSecond: int
    dateKind: TomlDateKind
    hasTime, hasSeconds: bool

  TomlTokenKind* = enum
    ## The different kinds of tokens that can be encountered in a TOML file
    ttkEOF = "EOF"
    ttkError = "Error"
    ttkString
    ttkBareKey
    ttkInteger
    ttkFloat
    ttkBoolean
    ttkDateTime
    ttkEquals = "="
    ttkDot = "."
    ttkComma = ","
    ttkLB = "["
    ttkRB = "]"
    ttkLC = "{"
    ttkRC = "}"
    ttkComment

  TomlToken* = ref object of OpenToken
    ## The kind of token, which can be a string, number, boolean, bare key or
    ## punctuation
    kind*: TomlTokenKind
    indent*: int

  TomlCtx* = enum
    ## What the parser expects at the cursor. A bare word lexes differently
    ## depending on whether it sits in key position (`1 = 2` keys `1`) or in
    ## value position (`1` is an integer), so the lexer is told which to expect.
    tcKey
    tcValue

  OpenParserTomlError* = object of CatchableError
    ## Exception type for errors that occur during TOML parsing

const
  ## Characters that may follow a bare value: whitespace, a comment or a
  ## structural delimiter. Anything else means the value is malformed.
  tomlDelims = {' ', '\t', '\n', '\r', ',', ']', '}', '=', '#', '\0'}

  ## Characters that make up a bare key: ALPHA / DIGIT / '-' / '_'
  bareKeyChars = {'a'..'z', 'A'..'Z', '0'..'9', '-', '_'}

  ## Characters that can begin a bare value
  valueStartChars = {'a'..'z', 'A'..'Z', '0'..'9', '_', '+', '-'}

#
# Lexer
#

proc charAt(l: TomlLexer, idx: int): char {.inline.} =
  if idx < 0 or idx >= l.len: '\0' else: l.input[idx]

proc peekAt(l: TomlLexer, offset: int): char {.inline.} =
  l.charAt(l.pos + offset)

proc isValidUtf8(s: string): bool =
  ## Strict UTF-8 validation. Overlong encodings, surrogate code points and
  ## anything above U+10FFFF are rejected too, which a permissive check misses.
  var i = 0
  while i < s.len:
    let lead = s[i].uint8
    var extra, code, minCode: int
    if lead < 0x80:
      inc i
      continue
    elif lead >= 0xC2 and lead <= 0xDF:
      extra = 1; code = (lead and 0x1F).int; minCode = 0x80
    elif lead >= 0xE0 and lead <= 0xEF:
      extra = 2; code = (lead and 0x0F).int; minCode = 0x800
    elif lead >= 0xF0 and lead <= 0xF4:
      extra = 3; code = (lead and 0x07).int; minCode = 0x10000
    else:
      return false
    if i + extra >= s.len:
      return false
    for k in 1 .. extra:
      let b = s[i + k].uint8
      if b < 0x80 or b > 0xBF:
        return false
      code = (code shl 6) or (b and 0x3F).int
    if code < minCode: return false                    # overlong encoding
    if code >= 0xD800 and code <= 0xDFFF: return false # surrogate half
    if code > 0x10FFFF: return false
    i += extra + 1
  true

proc newTomlLexer*(input: string): TomlLexer =
  ## Initializes a new TomlLexer with the given input string
  ## Sets up the initial state for lexing, including position and current character
  var src = input
  var start = 0
  # A UTF-8 byte order mark is permitted, but only at the very start.
  if src.len >= 3 and src[0] == '\xEF' and src[1] == '\xBB' and src[2] == '\xBF':
    start = 3
  result = TomlLexer(input: src, len: src.len, line: 1, col: 1, pos: start)
  result.current = result.charAt(start)

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
  raise newException(OpenParserTomlError,
    ("\n" & context & "\n" & "Error ($1:$2) " % [$l.line, $l.col]) & msg)

proc advance(l: var TomlLexer) {.inline.} =
  if l.pos < l.len - 1:
    inc l.pos
    l.current = l.input[l.pos]
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

proc skipWhitespace(l: var TomlLexer, wsBeforeToken: var int,
    allowNewline: bool = true): int =
  # Skip whitespace and newlines. `allowNewline` is cleared where TOML forbids
  # a line break, such as inside a table header or an inline table.
  wsBeforeToken = 0
  while true:
    case l.current
    of ' ', '\t':
      inc wsBeforeToken
      advance(l)
    of '\n':
      if not allowNewline: break
      inc l.line
      l.col = 0
      advance(l)
      wsBeforeToken = 0
    of '\r':
      if not allowNewline: break
      if l.peekAt(1) != '\n':
        l.error("A carriage return is only valid as part of a CRLF newline")
      inc l.line
      l.col = 0
      advance(l)
      advance(l)
      wsBeforeToken = 0
    else:
      break
  if l.pos >= l.len:
    return 0
  result = lineIndentAt(l, l.pos)

proc peekChar*(lex: TomlLexer, offset: int): char =
  # Lookahead character at current position + offset without advancing
  lex.charAt(lex.pos + offset)

proc readBareKey(l: var TomlLexer): string =
  # A bare key is 1*( ALPHA / DIGIT / '-' / '_' ) per the TOML ABNF.
  while l.current in bareKeyChars:
    result.add(l.current)
    advance(l)

proc readComment(l: var TomlLexer): string =
  # Read from '#' to end of line, excluding the newline
  let start = l.pos
  advance(l)
  while l.pos < l.len and l.current notin {'\n', '\r'}:
    if (l.current < ' ' and l.current != '\t') or l.current == '\x7F':
      l.error("Invalid control character in a comment")
    advance(l)
  let raw = l.input[start ..< l.pos]
  if not isValidUtf8(raw):
    l.error("Comment is not valid UTF-8")

proc hexValue(c: char): int64 {.inline.} =
  ## The numeric value of a hexadecimal digit; `c` must be in `HexDigits`.
  if c in {'0'..'9'}: c.ord - '0'.ord
  elif c in {'a'..'f'}: c.ord - 'a'.ord + 10
  else: c.ord - 'A'.ord + 10

proc readUnicodeEscape(l: var TomlLexer, digits: int): string =
  # Read exactly `digits` hex digits and decode them into one UTF-8 sequence.
  advance(l) # consume the `u` or `U`
  var value = 0'i64
  for _ in 0 ..< digits:
    if l.current notin HexDigits:
      l.error("A unicode escape needs " & $digits & " hexadecimal digits")
    value = value shl 4 or hexValue(l.current)
    advance(l)
  if value > 0x10FFFF or (value >= 0xD800 and value <= 0xDFFF):
    l.error("Unicode escape U+" & toHex(value, 8).toUpperAscii() & " is out of range")
  result = $Rune(value.int)

proc readEscape(l: var TomlLexer): string =
  # Decode a single `\` escape inside a basic string. `readUnicodeEscape`
  # consumes its own digits; every other case consumes exactly one character.
  advance(l) # consume the backslash
  case l.current
  of '"':
    result = "\""
    advance(l)
  of '\\':
    result = "\\"
    advance(l)
  of 'b':
    result = "\b"
    advance(l)
  of 'f':
    result = "\f"
    advance(l)
  of 'n':
    result = "\n"
    advance(l)
  of 'r':
    result = "\r"
    advance(l)
  of 't':
    result = "\t"
    advance(l)
  of 'u': result = readUnicodeEscape(l, 4)
  of 'U': result = readUnicodeEscape(l, 8)
  of '\0': l.error("Unterminated escape sequence")
  else:
    l.error("Unknown escape sequence `\\" & $l.current & "`")

proc readEscapeOrNewline(l: var TomlLexer): bool =
  # Inside a multi-line basic string, `\` ws newline *( wschar / newline )
  # trims the escape along with all the whitespace that follows it.
  var i = 1
  while l.peekAt(i) in {' ', '\t'}: inc i
  var newlines = 0
  if l.peekAt(i) == '\r' and l.peekAt(i + 1) == '\n':
    i += 2
    newlines = 1
  elif l.peekAt(i) == '\n':
    i += 1
    newlines = 1
  else:
    return false
  while true:
    let c = l.peekAt(i)
    if c in {' ', '\t'}:
      inc i
    elif c == '\r' and l.peekAt(i + 1) == '\n':
      i += 2
      inc newlines
    elif c == '\n':
      i += 1
      inc newlines
    else:
      break
  inc l.line, newlines
  while i > 0:
    advance(l)
    dec i
  true

proc checkStringChar(l: var TomlLexer) =
  # basic-char / literal-char both exclude the C0 controls other than tab, and
  # U+007F. Newlines are handled separately because multi-line strings allow
  # them.
  let c = l.current
  if (c < ' ' and c != '\t') or c == '\x7F':
    l.error("Invalid control character in a string; escape it instead")

proc readString(l: var TomlLexer, quote: char): string =
  # Read a basic (`"`) or literal (`'`) string, in any of the four TOML forms.
  let basic = quote == '"'
  let multiline = l.peekAt(1) == quote and l.peekAt(2) == quote

  if multiline:
    advance(l); advance(l); advance(l)
    # A newline immediately after the opening delimiter is trimmed.
    if l.current == '\r' and l.peekAt(1) == '\n':
      inc l.line
      l.col = 0
      advance(l)
      advance(l)
    elif l.current == '\n':
      inc l.line
      l.col = 0
      advance(l)
  else:
    advance(l) # opening delimiter

  let rawStart = l.pos

  while true:
    if l.pos >= l.len:
      l.error("Unterminated string literal")
    if l.current == quote:
      if not multiline:
        advance(l)
        break
      var run = 0
      while l.peekAt(run) == quote: inc run
      if run >= 6:
        l.error("Too many consecutive quotes inside a multi-line string")
      if run >= 3:
        # Up to two trailing quotes are content; the last three close.
        for _ in 0 ..< run - 3:
          result.add(quote)
          advance(l)
        advance(l); advance(l); advance(l)
        break
      for _ in 0 ..< run:
        result.add(quote)
        advance(l)
      continue
    if l.current == '\r':
      if not multiline:
        l.error("Unescaped carriage return in a string")
      if l.peekAt(1) != '\n':
        l.error("A carriage return is only valid as part of a CRLF newline")
      result.add('\n')
      inc l.line
      l.col = 0
      advance(l)
      advance(l)
      continue
    if l.current == '\n':
      if not multiline:
        l.error("Unescaped newline in a string; use a multi-line string instead")
      result.add('\n')
      inc l.line
      l.col = 0
      advance(l)
      continue
    if l.current == '\\' and basic:
      if multiline and readEscapeOrNewline(l): continue
      result.add(readEscape(l))
      continue
    l.checkStringChar()
    result.add(l.current)
    advance(l)

  if not isValidUtf8(l.input[rawStart ..< l.pos]):
    l.error("String literal is not valid UTF-8")

proc isDigit(c: char): bool {.inline.} = c in {'0'..'9'}

proc readFixedDigits(l: var TomlLexer, count: int): int =
  # Read exactly `count` digits, rejecting anything else.
  var n = 0
  while n < count and l.current.isDigit:
    result = result * 10 + (l.current.ord - '0'.ord)
    inc n
    advance(l)
  if n < count:
    l.error("Expected " & $count & " digit(s) in a date/time value")

proc daysInMonth(year, month: int): int =
  const lengths = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
  result = lengths[month - 1]
  if month == 2 and ((year mod 4 == 0 and year mod 100 != 0) or year mod 400 == 0):
    result = 29

proc readDate(l: var TomlLexer) =
  # full-date = 4DIGIT "-" 2DIGIT "-" 2DIGIT
  l.dateYear = l.readFixedDigits(4)
  if l.dateYear == 0:
    l.error("A date needs a four-digit year of 0001 or greater")
  if l.current != '-':
    l.error("Expected `-` after the year")
  advance(l)
  l.dateMonth = l.readFixedDigits(2)
  if l.dateMonth < 1 or l.dateMonth > 12:
    l.error("Month " & $l.dateMonth & " is out of range")
  if l.current != '-':
    l.error("Expected `-` after the month")
  advance(l)
  l.dateDay = l.readFixedDigits(2)
  if l.dateDay < 1 or l.dateDay > daysInMonth(l.dateYear, l.dateMonth):
    l.error("Day " & $l.dateDay & " is out of range for that month")

proc readTime(l: var TomlLexer) =
  # partial-time = time-hour ":" time-minute [ ":" time-second [ time-secfrac ] ]
  l.dateHour = l.readFixedDigits(2)
  if l.dateHour > 23:
    l.error("Hour " & $l.dateHour & " is out of range")
  if l.current != ':':
    l.error("Expected `:` after the hour")
  advance(l)
  l.dateMinute = l.readFixedDigits(2)
  if l.dateMinute > 59:
    l.error("Minute " & $l.dateMinute & " is out of range")
  if l.current != ':':
    l.error("Expected `:` and seconds in a time value")
  advance(l)
  l.dateSecond = l.readFixedDigits(2)
  # 60 is permitted, for leap seconds.
  if l.dateSecond > 60:
    l.error("Second " & $l.dateSecond & " is out of range")
  if l.current == '.':
    advance(l)
    if not l.current.isDigit:
      l.error("Expected at least one digit in the fractional seconds")
    while l.current.isDigit: advance(l)
  l.hasSeconds = true
  l.hasTime = true

proc readOffset(l: var TomlLexer) =
  # time-offset = "Z" / time-numoffset
  if l.current == 'Z':
    advance(l)
    return
  advance(l)
  let offsetHour = l.readFixedDigits(2)
  if l.current != ':':
    l.error("Expected `:` in the UTC offset")
  advance(l)
  let offsetMinute = l.readFixedDigits(2)
  if offsetHour > 23:
    l.error("UTC offset hour " & $offsetHour & " is out of range")
  if offsetMinute > 59:
    l.error("UTC offset minute " & $offsetMinute & " is out of range")

proc readDateTime(l: var TomlLexer, hasDate: bool): TomlDateKind =
  # Accepts the four TOML date/time shapes, validating every component here.
  # std/times' own constructors take range-constrained parameters, so handing
  # them unchecked text aborts the process instead of raising a catchable error.
  l.dateYear = 1970
  l.dateMonth = 1
  l.dateDay = 1
  l.dateHour = 0
  l.dateMinute = 0
  l.dateSecond = 0
  l.hasTime = false
  l.hasSeconds = false

  if not hasDate:
    l.readTime()
    return tdkLocalTime

  l.readDate()
  result = tdkLocalDate
  # A space is a legal delimiter too, but it has to be told apart from the
  # whitespace that separates a date from a trailing comment.
  let hasTime = if l.current in {'T', 't'}: true
                elif l.current == ' ': l.peekAt(1).isDigit and l.peekAt(2).isDigit and
                                  l.peekAt(3) == ':'
                else: false
  if not hasTime: return
  advance(l)
  if l.pos >= l.len:
    l.error("Unexpected end of input after a date/time delimiter")
  l.readTime()
  result = tdkLocalDateTime
  if l.current in {'Z', 'z'}:
    advance(l)
    result = tdkOffsetDateTime
  elif l.current in {'+', '-'}:
    l.readOffset()
    result = tdkOffsetDateTime

proc readSpecialFloat(l: var TomlLexer): string =
  # special-float = [ minus / plus ] ( inf / nan )
  if l.current in {'+', '-'}:
    result.add(l.current)
    advance(l)
  let word = (if l.current == 'i': "inf" else: "nan")
  for c in word:
    if l.current != c:
      l.error("Expected `" & word & "`")
    result.add(c)
    advance(l)

proc readRadixInteger(l: var TomlLexer, prefixLen: int,
    digitOk: proc (c: char): bool, radixName: string): string =
  # hex-int / oct-int / bin-int, with `_` allowed only between digits.
  if l.current == '-':
    result.add('-')
    advance(l)
  for _ in 0 ..< prefixLen:
    result.add(l.current)
    advance(l)
  var seenDigit = false
  var lastWasDigit = false
  while true:
    let c = l.current
    if c.isDigit or digitOk(c):
      result.add(c)
      seenDigit = true
      lastWasDigit = true
      advance(l)
    elif c == '_':
      if not lastWasDigit:
        l.error("Underscores must be surrounded by digits")
      lastWasDigit = false
      advance(l)
    else:
      break
  if not seenDigit:
    l.error("Expected at least one " & radixName & " digit")
  if not lastWasDigit:
    l.error("Underscores must be surrounded by digits")

proc readDecimalInteger(l: var TomlLexer): string =
  # unsigned-dec-int = DIGIT / digit1-9 1*( DIGIT / underscore DIGIT )
  if l.current == '-':
    result.add('-')
    advance(l)
  elif l.current == '+':
    result.add('+')
    advance(l)
  if not l.current.isDigit:
    l.error("Expected a digit")
  let first = l.current
  result.add(first)
  advance(l)
  var lastWasDigit = true
  var digitCount = 1
  while true:
    let c = l.current
    if c.isDigit:
      result.add(c)
      inc digitCount
      lastWasDigit = true
      advance(l)
    elif c == '_':
      if not lastWasDigit:
        l.error("Underscores must be surrounded by digits")
      lastWasDigit = false
      advance(l)
    else:
      break
  if not lastWasDigit:
    l.error("Underscores must be surrounded by digits")
  if first == '0' and digitCount > 1:
    l.error("Leading zeros are not allowed in numbers")

proc readDigitsWithUnderscores(l: var TomlLexer, what: string): string =
  # A zero-prefixable-int: DIGIT *( DIGIT / underscore DIGIT )
  if not l.current.isDigit:
    l.error("Expected at least one digit " & what)
  var lastWasDigit = false
  while true:
    let c = l.current
    if c.isDigit:
      result.add(c)
      lastWasDigit = true
      advance(l)
    elif c == '_':
      if not lastWasDigit:
        l.error("Underscores must be surrounded by digits")
      lastWasDigit = false
      advance(l)
    else:
      break
  if not lastWasDigit:
    l.error("Underscores must be surrounded by digits")

proc readNumber(l: var TomlLexer, kind: var TomlTokenKind): string =
  # Dispatch on the shape of the value. Radix-prefixed integers are checked
  # before decimals so `0x` is never mistaken for a leading zero, and a date
  # (four digits then `-`) or a local time (two digits then `:`) is told apart
  # from a number by its digit run.
  kind = ttkInteger
  let start = l.pos

  if l.current == '0' and l.peekAt(1) in {'x', 'o', 'b'}:
    case l.peekAt(1)
    of 'x': result = readRadixInteger(l, 2, proc (c: char): bool = c in HexDigits, "hexadecimal")
    of 'o': result = readRadixInteger(l, 2, proc (c: char): bool = false, "octal")
    else:    result = readRadixInteger(l, 2, proc (c: char): bool = false, "binary")
    return

  if l.current in {'i', 'n'} or (l.current in {'+', '-'} and l.peekAt(1) in {'i', 'n'}):
    result = readSpecialFloat(l)
    kind = ttkFloat
    return

  if l.current in {'+', '-'} and not l.peekAt(1).isDigit:
    l.error("Expected a value after the sign")

  var digitRun = 0
  var probe = 0
  while l.peekAt(probe).isDigit:
    inc probe
    inc digitRun
  let signOffset = if l.current in {'+', '-'}: 1 else: 0

  if (digitRun == 4 and l.peekAt(probe + signOffset) == '-') or
     (digitRun == 2 and l.peekAt(probe + signOffset) == ':'):
    l.dateKind = readDateTime(l, digitRun == 4)
    # `pos` now sits on the delimiter that ended the token, so the literal is
    # exactly the span that was consumed.
    result = l.input[start ..< l.pos]
    kind = ttkDateTime
    return

  result = readDecimalInteger(l)

  if l.current == '.':
    kind = ttkFloat
    result.add('.')
    advance(l)
    result.add(l.readDigitsWithUnderscores("after the decimal point"))

  if l.current in {'e', 'E'}:
    kind = ttkFloat
    result.add(l.current)
    advance(l)
    if l.current in {'+', '-'}:
      result.add(l.current)
      advance(l)
    result.add(l.readDigitsWithUnderscores("in the exponent"))

proc readBareValue(l: var TomlLexer, kind: var TomlTokenKind): string =
  # Bare values are booleans, special floats, numbers and date/times.
  if l.current in {'t', 'f'}:
    let word = (if l.current == 't': "true" else: "false")
    for c in word:
      if l.current != c:
        l.error("Expected `" & word & "`")
      result.add(c)
      advance(l)
    kind = ttkBoolean
  else:
    result = readNumber(l, kind)

proc singleCharTokenKind(c: char): TomlTokenKind =
  ## Maps a single-character token to its kind. A `case` (instead of a lookup
  ## table) keeps the lexer evaluable at compile time (NimVM).
  case c
  of '=': ttkEquals
  of '.': ttkDot
  of ',': ttkComma
  of '[': ttkLB
  of ']': ttkRB
  of '{': ttkLC
  of '}': ttkRC
  else: ttkError

#
# AST
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
      ## The wall-clock value, with no zone attached. `std/times` cannot hold a
      ## UTC offset, so read `dateKind` and `dateRaw` to tell the four TOML
      ## date/time types apart and to recover the offset.
      dateKind*: TomlDateKind
      ## The literal exactly as written in the source, which makes dumping
      ## lossless.
      dateRaw*: string
    of tvkArray:
      arrayVal*: seq[TomlNode]
      tableArray*: bool
      ## True when the array came from a `[[array of tables]]` header rather
      ## than from an inline array literal. The two serialize differently.

    of tvkTable:
      tableVal*: OrderedTableRef[string, TomlNode]

  TomlDocument* = TomlNode
    ## The root of a TOML document is a table mapping keys to values

  TomlOptions* = ref object
    ## Options controlling typed TOML mapping.
    maxDepth*: int = 0
      ## Maximum nesting depth for objects/arrays. 0 means no limit.
    skipUnknownFields*: bool = true
      ## When true (default) unknown table keys are ignored, mirroring
      ## `json.JsonOptions.skipUnknownFields`. When false they raise.

  TomlParser* = object
    ## The TomlParser takes a TomlLexer and produces a Nim data structure
    ## representing the TOML content
    lex*: TomlLexer
    curr*: TomlToken
    currentField*: Option[string]
      ## Name of the field currently being parsed, for context-aware
      ## `parseHook`s. Set before each field/element value is parsed.
    options*: TomlOptions
      ## Runtime options (max depth, unknown-field handling).
    depth*: int
      ## Current nesting depth, enforced against `options.maxDepth`.
    strictLines*: bool
    ## Set while reading an inline table, where TOML v1.0.0 forbids any newline
    ## between the braces.
    pathStack*: seq[string]
    ## Dotted paths of the tables currently being filled, outermost first.
    ## TOML's redefinition rules need to know how each table came to exist:
    ## a super-table created implicitly by another header may still be defined
    ## later with `[x]`, but one created by a dotted key may not.
    byHeader*: HashSet[string]
    ## Dotted paths defined by a `[table]` or `[[array of tables]]` header.
    byDotted*: HashSet[string]
    ## Dotted paths created as an intermediate step of a dotted key.
    sealed*: HashSet[string]
    ## Dotted paths that belong to an inline table. Inline tables are closed
    ## the moment they are written, so nothing may be added to them afterwards.
    arraysOfTables*: HashSet[string]
    ## Dotted paths that are arrays of tables created by a `[[header]]`, as
    ## opposed to inline arrays. Only the former may be appended to.

template toml*(name: static[string]) {.pragma.}
  ## Field mapping pragma. `name {.toml: "wireName".}: string`.
  ## `renameHook` supersedes this pragma. `{.json.}` is accepted as fallback.

template skippable*() {.pragma.}
  ## Marks a field skippable (API parity with `json`).

const
  tomlErrorMaxDepth* = "Maximum nesting depth exceeded"
  tomlErrorUnexpected* = "Unexpected token `$1`"

proc checkMaxDepth(p: var TomlParser) =
  if p.options != nil and p.options.maxDepth > 0:
    if p.depth > p.options.maxDepth:
      raise newException(OpenParserTomlError, tomlErrorMaxDepth)

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

proc newTomlDateTime*(dt: DateTime, dateKind: TomlDateKind = tdkLocalDateTime,
    dateRaw: string = ""): TomlNode =
  ## Helper to create a TomlNode of kind datetime. `dateKind` and `dateRaw`
  ## preserve the TOML type and the original spelling; when `dateRaw` is empty
  ## it is derived from `dateKind` and `dt`.
  var raw = dateRaw
  if raw.len == 0:
    let stamp = dt.format("yyyy-MM-dd'T'HH:mm:ss")
    case dateKind
    of tdkOffsetDateTime: raw = stamp & "Z"
    of tdkLocalDateTime: raw = stamp
    of tdkLocalDate: raw = dt.format("yyyy-MM-dd")
    of tdkLocalTime: raw = dt.format("HH:mm:ss")
  TomlNode(kind: tvkDateTime, dateTimeVal: dt, dateKind: dateKind, dateRaw: raw)

proc newTomlArray*: TomlNode =
  ## Helper to create a TomlNode of kind array
  TomlNode(kind: tvkArray)

proc newTomlTableArray*: TomlNode =
  ## Helper to create an array of tables, as a `[[header]]` does
  TomlNode(kind: tvkArray, tableArray: true)

proc newTomlTable*: TomlNode =
  ## Helper to create a TomlNode of kind table
  TomlNode(kind: tvkTable, tableVal: newOrderedTable[string, TomlNode]())

#
# Value accessors
#

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
    result = v.dateRaw
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
# Parser
#

proc nextToken*(p: var TomlParser, ctx: TomlCtx = tcValue,
    allowNewline: bool = true): TomlToken =
  ## Lexical analysis to produce the next token from the input. `ctx` says
  ## whether a bare word should be read as a key or as a value, and
  ## `allowNewline` is cleared where TOML forbids a line break, such as inside a
  ## table header or an inline table.
  var wsBefore = 0
  let lineIndent = skipWhitespace(p.lex, wsBefore, allowNewline)

  result = TomlToken()
  result.line = p.lex.line
  result.col = p.lex.col
  result.pos = p.lex.pos
  result.indent = lineIndent
  result.wsno = wsBefore
  case p.lex.current
  of '\0':
    if p.lex.pos >= p.lex.len:
      result.kind = ttkEOF
    else:
      p.lex.error("Invalid character `\0`")
  of '#':
    result.kind = ttkComment
    result.value = p.lex.readComment()
  of '"', '\'':
    if ctx == tcKey and p.lex.peekAt(1) == p.lex.current and
       p.lex.peekAt(2) == p.lex.current:
      p.lex.error("A multi-line string cannot be used as a key")
    result.kind = ttkString
    result.value = p.lex.readString(p.lex.current)
  of valueStartChars:
    if ctx == tcKey:
      if p.lex.current == '+':
        p.lex.error("`+` is not valid in a bare key")
      result.kind = ttkBareKey
      result.value = p.lex.readBareKey()
    elif p.lex.current in {'t', 'f', 'i', 'n', '+', '-'} or p.lex.current.isDigit:
      result.value = p.lex.readBareValue(result.kind)
      if p.lex.current notin tomlDelims:
        p.lex.error("Unexpected `" & $p.lex.current & "` after a value")
    else:
      p.lex.error("Unexpected `" & $p.lex.current & "` in a value")
  of '.', '=', ',', '[', ']', '{', '}':
    result.kind = singleCharTokenKind(p.lex.current)
    advance(p.lex)
  else:
    p.lex.error("Invalid character `" & $p.lex.current & "`")

proc error(p: var TomlParser, msg: string) =
  # Prefer current token coordinates over the lexer cursor.
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

proc advance(p: var TomlParser, ctx: TomlCtx = tcValue,
    allowNewline: bool = true) {.inline.} =
  let multilineOk = allowNewline and not p.strictLines
  p.curr = p.nextToken(ctx, multilineOk)
  # A comment runs to the end of its line, so it can only be skipped where a
  # newline is allowed to follow.
  while multilineOk and p.curr.kind == ttkComment:
    p.curr = p.nextToken(ctx, true)

proc makeDateTime(year, month, day, hour, minute, second: int): DateTime =
  # `DateTime`'s fields are private, so the only constructor is `dateTime`,
  # whose parameters are range-constrained: handing it an out-of-range value
  # aborts the process rather than raising. The lexer has already validated
  # every component, and the clamps below keep that guarantee local.
  var y = max(1, min(9999, year))
  var mo = max(1, min(12, month))
  var d = max(1, min(31, day))
  var h = max(0, min(23, hour))
  var mi = max(0, min(59, minute))
  # std/times has no leap-second representation, so clamp rather than abort.
  var s = max(0, min(59, second))
  dateTime(y, Month(mo), MonthdayRange(d), HourRange(h), MinuteRange(mi),
    SecondRange(s), NanosecondRange(0), utc())

proc parseDateTimeToken(l: TomlLexer, raw: string): TomlNode =
  # Turn the components the lexer validated into a TomlNode.
  var hour, minute, second = 0
  if l.hasTime:
    hour = l.dateHour
    minute = l.dateMinute
    second = l.dateSecond
  newTomlDateTime(
    makeDateTime(l.dateYear, l.dateMonth, l.dateDay, hour, minute, second),
    l.dateKind, raw)

proc digitValue(c: char, radix: int): int64 =
  var v = -1
  if c in {'0'..'9'}: v = c.ord - '0'.ord
  elif c in {'a'..'f'}: v = c.ord - 'a'.ord + 10
  elif c in {'A'..'F'}: v = c.ord - 'A'.ord + 10
  if v < 0 or v >= radix:
    raise newException(OpenParserTomlError,
      "`" & $c & "` is not a valid base-" & $radix & " digit")
  v

const
  ## The magnitude an int64 can hold depends on the sign: a negative value
  ## reaches one further than a positive one.
  int64Max = uint64(high(int64))
  int64MinMagnitude = uint64(high(int64)) + 1

proc applySign(magnitude: uint64, negative: bool, source: string): int64 =
  let limit = if negative: int64MinMagnitude else: int64Max
  if magnitude > limit:
    raise newException(OpenParserTomlError, "Integer " & source & " is out of range")
  # Wrapping unsigned arithmetic is what gives the two's complement bit pattern
  # for the int64 minimum, which has no positive counterpart.
  if negative: cast[int64](0'u64 - magnitude) else: cast[int64](magnitude)

proc parseRadixValue(s: string, radix: int, negative: bool): int64 =
  # Accumulate a radix-prefixed integer, checking the magnitude as it grows.
  # Only the leading sign, `0` and radix letter are skipped: `b` and `o` are
  # perfectly ordinary digits inside a hexadecimal literal.
  var i = 0
  if i < s.len and s[i] in {'+', '-'}: inc i
  if i < s.len and s[i] == '0': inc i
  if i < s.len and s[i] in {'x', 'o', 'b'}: inc i
  var value = 0'u64
  while i < s.len:
    let c = s[i]
    if c != '_':
      let digit = digitValue(c, radix).uint64
      if value > (high(uint64) - digit) div radix.uint64:
        raise newException(OpenParserTomlError, "Integer " & s & " is out of range")
      value = value * radix.uint64 + digit
    inc i
  applySign(value, negative, s)

proc stripUnderscores(s: string): string =
  result = newStringOfCap(s.len)
  for c in s:
    if c != '_': result.add(c)

proc parseIntValue(s: string): int64 =
  var body = stripUnderscores(s)
  var negative = false
  if body.len > 0 and body[0] in {'+', '-'}:
    negative = body[0] == '-'
    body = body[1 .. ^1]
  if body.len > 1 and body[0] == '0':
    case body[1]
    of 'x': return parseRadixValue(body, 16, negative)
    of 'o': return parseRadixValue(body, 8, negative)
    of 'b': return parseRadixValue(body, 2, negative)
    else:
      raise newException(OpenParserTomlError, "Invalid integer: " & s)
  var magnitude: uint64
  try:
    magnitude = parseBiggestUInt(body)
  except ValueError:
    raise newException(OpenParserTomlError, "Integer " & s & " is out of range")
  result = applySign(magnitude, negative, s)

proc parseFloatValue(s: string): float64 =
  case s.toLowerAscii()
  of "inf", "+inf": return Inf
  of "-inf": return -Inf
  of "nan", "+nan", "-nan": return NaN
  else: discard
  try:
    result = parseFloat(stripUnderscores(s))
  except ValueError:
    raise newException(OpenParserTomlError, "Invalid float: " & s)

proc joinPath(base, part: string): string =
  if base.len == 0: part else: base & "." & part

proc fullPath(path: seq[string]): string =
  for i, part in path:
    if i > 0: result.add(".")
    result.add(part)

proc currentPath(p: TomlParser): string =
  ## The absolute dotted path of the table currently being filled.
  for part in p.pathStack:
    if part.len == 0: continue
    if result.len > 0: result.add(".")
    result.add(part)

proc keyPath(p: var TomlParser, allowNewline: bool = false): seq[string] =
  ## Consume a key path - bare or quoted identifiers separated by dots.
  while true:
    case p.curr.kind
    of ttkBareKey, ttkString:
      result.add(p.curr.value)
      p.advance(tcKey, allowNewline)
    else:
      break
    if p.curr.kind == ttkDot:
      p.advance(tcKey, allowNewline)
      if p.curr.kind notin {ttkBareKey, ttkString}:
        p.error("Expected a key after `.`")
    else:
      break

proc expectLineEnd(p: var TomlParser, valueLine: int) =
  ## A TOML line holds at most one key/value pair, so whatever follows a value
  ## has to begin a new line, open a table header, or end the document.
  if p.curr.kind == ttkEOF: return
  if p.curr.kind == ttkLB and p.curr.line > valueLine: return
  if p.curr.line <= valueLine:
    p.error("Only one key/value pair is allowed per line")

proc expectLineBreak(p: var TomlParser, headerLine: int) =
  ## A table header occupies its own line, so a key/value pair may not follow it
  ## on the same line.
  if p.curr.kind == ttkEOF or p.curr.kind == ttkLB: return
  if p.curr.line <= headerLine:
    p.error("A table header must be on a line of its own")

proc expectEquals(p: var TomlParser, allowNewline: bool = false) =
  if p.curr.kind != ttkEquals:
    p.error("Expected `=` after a key, got " & $p.curr.kind)
  p.advance(tcValue, allowNewline)

proc asTable(p: var TomlParser, n: TomlNode, path: string): TomlNode =
  ## Narrow a node to a table, reporting a clean error rather than reading the
  ## wrong branch of the variant object.
  if n.isNil or n.kind != tvkTable:
    p.error("`" & path & "` is not a table and cannot be extended")
  n

proc sealInline(p: var TomlParser, val: TomlNode, base: string) =
  # Mark every table inside an inline table as closed to later additions.
  case val.kind
  of tvkTable:
    if base.len > 0:
      p.sealed.incl(base)
    for k, v in val.tableVal:
      p.sealInline(v, joinPath(base, k))
  of tvkArray:
    for v in val.arrayVal:
      p.sealInline(v, base)
  else:
    discard

proc setAtPath(p: var TomlParser, target: TomlNode, path: seq[string],
    val: TomlNode, base: string) =
  ## Set a value at a (possibly dotted) key path, creating intermediate tables.
  ## A dotted key may traverse a table that another dotted key created, but not
  ## one that a `[header]` defined or one sealed by an inline table.
  var cur = target
  var curPath = base
  for i, part in path:
    let childPath = joinPath(curPath, part)
    if i == path.len - 1:
      if cur.tableVal.hasKey(part):
        p.error("Duplicate key `" & childPath & "`")
      cur.tableVal[part] = val
      p.byDotted.incl(childPath)
      if val.kind == tvkTable:
        p.sealInline(val, childPath)
      return
    if not cur.tableVal.hasKey(part):
      cur.tableVal[part] = newTomlTable()
      p.byDotted.incl(childPath)
      cur = cur.tableVal[part]
      curPath = childPath
      continue
    if childPath in p.byHeader:
      p.error("Dotted key `" & childPath &
        "` cannot extend a table that was already defined")
    if childPath in p.sealed:
      p.error("Dotted key `" & childPath &
        "` cannot extend a table inside an inline table")
    cur = p.asTable(cur.tableVal[part], childPath)
    curPath = childPath

proc parseHook*(p: var TomlParser, v: var TomlNode)

proc parseInlineTable(p: var TomlParser): TomlNode =
  # inline-table = "{" [ keyval *( "," keyval ) ] "}"
  # Newlines are not permitted anywhere inside, in TOML v1.0.0.
  result = newTomlTable()
  let base = currentPath(p)
  let outerStrict = p.strictLines
  p.strictLines = true
  p.advance(tcKey, false)
  if p.curr.kind == ttkRC:
    p.strictLines = outerStrict
    p.advance(tcKey)
    return
  while true:
    if p.curr.kind notin {ttkBareKey, ttkString}:
      p.error("Expected a key inside an inline table, got " & $p.curr.kind)
    let path = p.keyPath(false)
    if path.len == 0:
      p.error("Expected a key inside an inline table")
    p.expectEquals(false)
    var val: TomlNode
    p.parseHook(val)
    setAtPath(p, result, path, val, base)
    if p.curr.kind == ttkComma:
      p.advance(tcKey, false)
      if p.curr.kind == ttkRC:
        p.error("A trailing comma is not allowed in an inline table")
    elif p.curr.kind != ttkRC:
      p.error("Expected `,` or `}` inside an inline table, got " & $p.curr.kind)
    else:
      break
  p.strictLines = outerStrict
  p.advance(tcKey)

proc parseHook*(p: var TomlParser, v: var TomlNode) =
  case p.curr.kind
  of ttkString:
    v = newTomlString(p.curr.value)
    p.advance(tcKey)
  of ttkInteger:
    v = newTomlInteger(parseIntValue(p.curr.value))
    p.advance(tcKey)
  of ttkFloat:
    v = newTomlFloat(parseFloatValue(p.curr.value))
    p.advance(tcKey)
  of ttkBoolean:
    v = newTomlBoolean(p.curr.value == "true")
    p.advance(tcKey)
  of ttkDateTime:
    v = parseDateTimeToken(p.lex, p.curr.value)
    p.advance(tcKey)
  of ttkLC:
    v = p.parseInlineTable()
  of ttkLB:
    # array value: [ v1, v2, ... ]. An array may span lines, even inside an
    # inline table, so the no-newline rule is lifted for its body.
    let outerStrict = p.strictLines
    p.strictLines = false
    p.advance(tcValue)
    v = newTomlArray()
    if p.curr.kind != ttkRB:
      while true:
        var item: TomlNode
        p.parseHook(item)
        v.arrayVal.add(item)
        if p.curr.kind == ttkComma:
          p.advance(tcValue)
          if p.curr.kind == ttkRB:
            break
        elif p.curr.kind == ttkRB:
          break
        else:
          p.error("Expected `,` or `]` in an array, got " & $p.curr.kind)
    p.advance(tcKey)
    p.strictLines = outerStrict
  else:
    p.error("Expected a value, got " & $p.curr.kind)

#
# Streaming typed hooks (value position) + context helpers
#

proc skipValue*(p: var TomlParser) =
  ## Skip a single TOML value, leaving `curr` at the following delimiter.
  var tmp: TomlNode
  p.parseHook(tmp)

proc parseHook*(p: var TomlParser, v: var string) =
  if p.curr.kind != ttkString:
    p.error("Expected a TOML string, got " & $p.curr.kind)
  v = p.curr.value
  p.advance(tcKey)

proc parseHook*(p: var TomlParser, v: var bool) =
  if p.curr.kind != ttkBoolean:
    p.error("Expected a TOML boolean, got " & $p.curr.kind)
  v = p.curr.value == "true"
  p.advance(tcKey)

proc parseHook*[T: Integers](p: var TomlParser, v: var T) =
  if p.curr.kind != ttkInteger:
    p.error("Expected a TOML integer, got " & $p.curr.kind)
  let raw = p.curr.value
  p.advance(tcKey)
  try:
    v = T(parseIntValue(raw))
  except RangeDefect:
    raise newException(OpenParserTomlError, "Integer out of range")
  except OpenParserTomlError as e:
    raise e

proc parseHook*[T: float|float32|float64](p: var TomlParser, v: var T) =
  case p.curr.kind
  of ttkFloat:
    let raw = p.curr.value
    p.advance(tcKey)
    v = T(parseFloatValue(raw))
  of ttkInteger:
    let raw = p.curr.value
    p.advance(tcKey)
    v = T(parseIntValue(raw))
  else:
    p.error("Expected a TOML float, got " & $p.curr.kind)

proc parseHook*(p: var TomlParser, v: var DateTime) =
  if p.curr.kind != ttkDateTime:
    p.error("Expected a TOML date/time, got " & $p.curr.kind)
  let raw = p.curr.value
  let lexCopy = p.lex
  v = parseDateTimeToken(lexCopy, raw).dateTimeVal
  p.advance(tcKey)

proc parseHook*[T: enum](p: var TomlParser, v: var T) =
  case p.curr.kind
  of ttkString:
    let s = p.curr.value
    p.advance(tcKey)
    try:
      v = strutils.parseEnum[T](s)
    except ValueError:
      p.error("Cannot parse `" & s & "` as " & $T)
  of ttkInteger:
    let raw = p.curr.value
    p.advance(tcKey)
    v = T(parseIntValue(raw))
  else:
    p.error("Expected a string or integer for enum, got " & $p.curr.kind)

proc parseHook*[T: distinct](p: var TomlParser, v: var T) =
  var tmp: T.distinctBase
  p.parseHook(tmp)
  v = T(tmp)

proc parseHook*(p: var TomlParser, v: var char) =
  if p.curr.kind == ttkString and p.curr.value.len == 1:
    v = p.curr.value[0]
    p.advance(tcKey)
  elif p.curr.kind == ttkInteger:
    let raw = p.curr.value
    p.advance(tcKey)
    v = char(parseIntValue(raw))
  else:
    p.error("Expected a single-character string, got " & $p.curr.kind)

proc parseHook*[T](p: var TomlParser, v: var seq[T]) =
  inc p.depth
  checkMaxDepth(p)
  defer: dec p.depth
  if p.curr.kind != ttkLB:
    p.error("Expected a TOML array, got " & $p.curr.kind)
  let outerStrict = p.strictLines
  p.strictLines = false
  p.advance(tcValue)
  v.setLen(0)
  if p.curr.kind != ttkRB:
    while true:
      var item: T
      p.parseHook(item)
      v.add(item)
      if p.curr.kind == ttkComma:
        p.advance(tcValue)
        if p.curr.kind == ttkRB:
          break
      elif p.curr.kind == ttkRB:
        break
      else:
        p.error("Expected `,` or `]` in an array, got " & $p.curr.kind)
  p.advance(tcKey)
  p.strictLines = outerStrict

proc parseHook*[N: static[int]; T](p: var TomlParser, v: var array[N, T]) =
  inc p.depth
  checkMaxDepth(p)
  defer: dec p.depth
  if p.curr.kind != ttkLB:
    p.error("Expected a TOML array, got " & $p.curr.kind)
  let outerStrict = p.strictLines
  p.strictLines = false
  p.advance(tcValue)
  var idx = 0
  if p.curr.kind != ttkRB:
    while true:
      if idx >= N:
        p.error("Sequence has more items than array size (" & $N & ")")
      var item: T
      p.parseHook(item)
      v[idx] = item
      inc idx
      if p.curr.kind == ttkComma:
        p.advance(tcValue)
        if p.curr.kind == ttkRB:
          break
      elif p.curr.kind == ttkRB:
        break
      else:
        p.error("Expected `,` or `]` in an array, got " & $p.curr.kind)
  p.advance(tcKey)
  p.strictLines = outerStrict
  if idx < N:
    p.error("Sequence has fewer items (" & $idx & ") than array size (" & $N & ")")

proc parseHook*[T](p: var TomlParser, v: var set[T]) =
  inc p.depth
  checkMaxDepth(p)
  defer: dec p.depth
  v = {}
  if p.curr.kind != ttkLB:
    p.error("Expected a TOML array, got " & $p.curr.kind)
  let outerStrict = p.strictLines
  p.strictLines = false
  p.advance(tcValue)
  if p.curr.kind != ttkRB:
    while true:
      var item: T
      p.parseHook(item)
      v.incl(item)
      if p.curr.kind == ttkComma:
        p.advance(tcValue)
        if p.curr.kind == ttkRB:
          break
      elif p.curr.kind == ttkRB:
        break
      else:
        p.error("Expected `,` or `]` in an array, got " & $p.curr.kind)
  p.advance(tcKey)
  p.strictLines = outerStrict

proc parseHook*[T](p: var TomlParser, v: var Option[T]) =
  var tmp: T
  p.parseHook(tmp)
  v = some(tmp)

proc tomlNodeToJson(n: TomlNode): JsonNode =
  case n.kind
  of tvkString: result = newJString(n.strVal)
  of tvkInteger: result = newJInt(n.intVal)
  of tvkFloat: result = newJFloat(n.floatVal)
  of tvkBoolean: result = newJBool(n.boolVal)
  of tvkDateTime: result = newJString(n.dateRaw)
  of tvkArray:
    result = newJArray()
    for item in n.arrayVal:
      result.add(tomlNodeToJson(item))
  of tvkTable:
    result = newJObject()
    for k, val in n.tableVal:
      result[k] = tomlNodeToJson(val)

proc jsonNodeToToml(j: JsonNode): TomlNode =
  case j.kind
  of JNull: result = newTomlString("")
  of JBool: result = newTomlBoolean(j.getBool())
  of JInt: result = newTomlInteger(j.getInt().int64)
  of JFloat: result = newTomlFloat(j.getFloat())
  of JString:
    # Try datetime round-trip when the string looks like a TOML datetime,
    # otherwise keep it a plain string.
    try:
      var lp = TomlParser(lex: newTomlLexer("v = " & j.getStr()))
      lp.curr = lp.nextToken(tcKey)
      discard lp.keyPath()
      lp.expectEquals()
      var tmp: TomlNode
      lp.parseHook(tmp)
      if tmp != nil and tmp.kind == tvkDateTime:
        result = tmp
      else:
        result = newTomlString(j.getStr())
    except CatchableError:
      result = newTomlString(j.getStr())
  of JArray:
    result = newTomlArray()
    for item in j.elems:
      result.arrayVal.add(jsonNodeToToml(item))
  of JObject:
    result = newTomlTable()
    for k, val in j.fields:
      result.tableVal[k] = jsonNodeToToml(val)

proc parseHook*(p: var TomlParser, v: var JsonNode) =
  var node: TomlNode
  p.parseHook(node)
  v = tomlNodeToJson(node)

proc parseObjectInto(p: var TomlParser, target: TomlNode) =
  ## Parse key = value entries into `target`, stopping at a table header or EOF.
  while p.curr.kind != ttkEOF and p.curr.kind != ttkLB:
    case p.curr.kind
    of ttkBareKey, ttkString:
      let path = p.keyPath()
      if path.len == 0:
        p.error("Expected a key")
      p.expectEquals()
      let valueLine = p.curr.line
      var val: TomlNode
      p.parseHook(val)
      p.expectLineEnd(valueLine)
      p.setAtPath(target, path, val, currentPath(p))
    of ttkComment:
      p.advance(tcKey)
    else:
      p.error("Expected a key or the start of the next table, got " & $p.curr.kind)

proc parseObject*(p: var TomlParser, ln: int): TomlNode =
  ## Parse a sequence of key = value entries into a table and return it.
  p.pathStack = @[""]
  result = newTomlTable()
  parseObjectInto(p, result)

proc descend(p: var TomlParser, node: TomlNode, path: seq[string],
    upto: int, base: string): TomlNode =
  ## Walk `path[0 ..< upto]`, creating implicit tables as needed and stepping
  ## into the most recent element whenever an array of tables is met.
  var cur = node
  var curPath = base
  for i in 0 ..< upto:
    let part = path[i]
    let childPath = joinPath(curPath, part)
    if not cur.tableVal.hasKey(part):
      cur.tableVal[part] = newTomlTable()
      cur = cur.tableVal[part]
      curPath = childPath
      continue
    let existing = cur.tableVal[part]
    if existing.kind == tvkArray:
      # `[[a]]` followed by `[a.b]` targets the last element of `a`.
      if childPath notin p.arraysOfTables:
        p.error("`" & childPath & "` is an array, not a table")
      if existing.arrayVal.len == 0:
        p.error("`" & childPath & "` is an empty array of tables")
      cur = existing.arrayVal[^1]
      curPath = childPath
    elif existing.kind == tvkTable:
      if childPath in p.sealed:
        p.error("Cannot extend `" & childPath & "`, it lives inside an inline table")
      cur = existing
      curPath = childPath
    else:
      p.error("`" & childPath & "` is already defined as a value")
  result = cur

proc parseArrayOfTables(p: var TomlParser, root: TomlNode, path: seq[string],
    base: string) =
  let parent = p.descend(root, path, path.len - 1, base)
  let lastPath = fullPath(path)
  if parent.tableVal.hasKey(path[^1]):
    let existing = parent.tableVal[path[^1]]
    if existing.kind != tvkArray:
      p.error("`" & lastPath & "` is already defined and is not an array of tables")
    if lastPath notin p.arraysOfTables:
      p.error("`" & lastPath & "` is an inline array and cannot be extended")
  else:
    parent.tableVal[path[^1]] = newTomlTableArray()
    p.arraysOfTables.incl(lastPath)
  p.byHeader.incl(lastPath)
  let arr = parent.tableVal[path[^1]]
  arr.arrayVal.add(newTomlTable())
  p.pathStack.add(lastPath)
  parseObjectInto(p, arr.arrayVal[^1])
  p.pathStack.setLen(p.pathStack.len - 1)

proc parseRoot*(p: var TomlParser): TomlNode =
  ## Parses the entire TOML document and returns a TomlDocument
  result = newTomlTable()
  p.pathStack = @[""]
  while p.curr.kind != ttkEOF:
    case p.curr.kind
    of ttkBareKey, ttkString:
      let path = p.keyPath()
      if path.len == 0:
        p.error("Expected a key")
      p.expectEquals()
      let valueLine = p.curr.line
      var val: TomlNode
      p.parseHook(val)
      p.expectLineEnd(valueLine)
      p.setAtPath(result, path, val, "")
    of ttkLB:
      # `array-table-open = "[" "["` requires the two brackets to be adjacent,
      # whereas `std-table-open = "[" ws` allows whitespace.
      let adjacent = p.lex.charAt(p.curr.pos + 1) == '['
      let headerLine = p.curr.line
      p.advance(tcKey, false)
      if adjacent:
        # [[a.b]] array of tables
        p.advance(tcKey, false)
        let path = p.keyPath(false)
        if path.len == 0:
          p.error("Expected a key inside `[[`")
        if p.curr.kind != ttkRB:
          p.error("Expected `]]` after an array-of-tables header, got " & $p.curr.kind)
        # `array-table-close` is two adjacent brackets, not `[ ]`.
        if p.lex.charAt(p.curr.pos + 1) != ']':
          p.error("Expected two adjacent `]` to close an array of tables")
        p.advance(tcValue, false)
        if p.curr.kind != ttkRB:
          p.error("Expected `]]` after an array-of-tables header, got " & $p.curr.kind)
        p.advance(tcKey)
        p.expectLineBreak(headerLine)
        p.parseArrayOfTables(result, path, "")
      else:
        # [a.b.c] table header
        let path = p.keyPath(false)
        if path.len == 0:
          p.error("Expected a key inside `[`")
        if p.curr.kind != ttkRB:
          p.error("Expected `]` after a table header, got " & $p.curr.kind)
        p.advance(tcKey)
        p.expectLineBreak(headerLine)
        let lastPath = fullPath(path)
        let parent = p.descend(result, path, path.len - 1, "")
        if parent.tableVal.hasKey(path[^1]):
          let existing = parent.tableVal[path[^1]]
          if existing.kind != tvkTable:
            p.error("`" & lastPath & "` is already defined and is not a table")
          if lastPath in p.byHeader or lastPath in p.byDotted:
            p.error("Duplicate table `" & lastPath & "`")
          if lastPath in p.sealed:
            p.error("`" & lastPath & "` lives inside an inline table")
        else:
          parent.tableVal[path[^1]] = newTomlTable()
        p.byHeader.incl(lastPath)
        p.pathStack.add(lastPath)
        parseObjectInto(p, parent.tableVal[path[^1]])
        p.pathStack.setLen(p.pathStack.len - 1)
    of ttkComment:
      p.advance(tcKey)
    else:
      p.error("Unexpected " & $p.curr.kind & " in a TOML document")

proc parseTOML*(input: TOML): TomlDocument =
  ## Parses a TOML string into a `TomlDocument`,
  ## which is a table mapping keys to `TomlNode` nodes
  ##
  ## For direct-to-struct parsing, use the `parseTOML(input, typedesc[T])` overload instead
  var parser = TomlParser(lex: newTomlLexer(input))
  parser.curr = parser.nextToken(tcKey)
  parser.parseRoot()

proc parseTOMLFile*(filename: string): TomlDocument =
  ## Parses the TOML file at `filename` into a `TomlDocument`
  parseTOML(readFile(filename))

#
# Typed mapping API
#

proc fromTomlNode[T](n: TomlNode, v: var T, path: string,
    p: var TomlParser, hasParser: bool)
proc fromTomlNodeTable[T](n: TomlNode, v: var T, path: string,
    p: var TomlParser, hasParser: bool)

macro copyTomlFieldsBeforeRecCase(dst, src: typed): untyped =
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

proc tomlSkipUnknown(p: TomlParser): bool =
  if p.options == nil: true else: p.options.skipUnknownFields

proc dumpTomlValue*(n: TomlNode): string

proc fromTomlNode[T](n: TomlNode, v: var Option[T], path: string,
    p: var TomlParser, hasParser: bool)
proc fromTomlNode[T](n: TomlNode, v: var set[T], path: string,
    p: var TomlParser, hasParser: bool)
proc fromTomlNode[K: string, V](n: TomlNode, v: var Table[K, V], path: string,
    p: var TomlParser, hasParser: bool)
proc fromTomlNode[K: string, V](n: TomlNode, v: var OrderedTable[K, V],
    path: string, p: var TomlParser, hasParser: bool)
proc fromTomlNode[K: string, V](n: TomlNode, v: var TableRef[K, V],
    path: string, p: var TomlParser, hasParser: bool)
proc fromTomlNode[K: string, V](n: TomlNode, v: var OrderedTableRef[K, V],
    path: string, p: var TomlParser, hasParser: bool)
proc fromTomlNode[T](n: TomlNode, v: var CritBitTree[T], path: string,
    p: var TomlParser, hasParser: bool)

proc fromTomlNode[T](n: TomlNode, v: var Option[T], path: string,
    p: var TomlParser, hasParser: bool) =
  if n == nil:
    return
  var inner: T
  fromTomlNode(n, inner, path, p, hasParser)
  v = some(inner)

proc fromTomlNode[T](n: TomlNode, v: var set[T], path: string,
    p: var TomlParser, hasParser: bool) =
  if n == nil or n.kind != tvkArray:
    raise newException(OpenParserTomlError,
      "Expected a TOML array at `" & path & "`")
  v = {}
  for i, item in n.arrayVal:
    var e: T
    fromTomlNode(item, e, path & "[" & $i & "]", p, hasParser)
    v.incl(e)

proc fromTomlNode[K: string, V](n: TomlNode, v: var Table[K, V], path: string,
    p: var TomlParser, hasParser: bool) =
  if n == nil or n.kind != tvkTable:
    raise newException(OpenParserTomlError,
      "Expected a TOML table at `" & path & "`")
  v = initTable[K, V]()
  for k, val in n.tableVal:
    var tmp: V
    let child = if path.len == 0: k else: path & "." & k
    if hasParser:
      p.currentField = some(k)
    fromTomlNode(val, tmp, child, p, hasParser)
    v[k] = tmp

proc fromTomlNode[K: string, V](n: TomlNode, v: var OrderedTable[K, V],
    path: string, p: var TomlParser, hasParser: bool) =
  if n == nil or n.kind != tvkTable:
    raise newException(OpenParserTomlError,
      "Expected a TOML table at `" & path & "`")
  v = initOrderedTable[K, V]()
  for k, val in n.tableVal:
    var tmp: V
    let child = if path.len == 0: k else: path & "." & k
    if hasParser:
      p.currentField = some(k)
    fromTomlNode(val, tmp, child, p, hasParser)
    v[k] = tmp

proc fromTomlNode[K: string, V](n: TomlNode, v: var TableRef[K, V],
    path: string, p: var TomlParser, hasParser: bool) =
  if n == nil or n.kind != tvkTable:
    raise newException(OpenParserTomlError,
      "Expected a TOML table at `" & path & "`")
  if v.isNil:
    v = newTable[K, V]()
  else:
    v[].clear()
  for k, val in n.tableVal:
    var tmp: V
    let child = if path.len == 0: k else: path & "." & k
    if hasParser:
      p.currentField = some(k)
    fromTomlNode(val, tmp, child, p, hasParser)
    v[k] = tmp

proc fromTomlNode[K: string, V](n: TomlNode, v: var OrderedTableRef[K, V],
    path: string, p: var TomlParser, hasParser: bool) =
  if n == nil or n.kind != tvkTable:
    raise newException(OpenParserTomlError,
      "Expected a TOML table at `" & path & "`")
  if v.isNil:
    v = newOrderedTable[K, V]()
  else:
    v[].clear()
  for k, val in n.tableVal:
    var tmp: V
    let child = if path.len == 0: k else: path & "." & k
    if hasParser:
      p.currentField = some(k)
    fromTomlNode(val, tmp, child, p, hasParser)
    v[k] = tmp

proc fromTomlNode[T](n: TomlNode, v: var CritBitTree[T], path: string,
    p: var TomlParser, hasParser: bool) =
  if n == nil or n.kind != tvkTable:
    raise newException(OpenParserTomlError,
      "Expected a TOML table at `" & path & "`")
  when compiles(v.clear()):
    v.clear()
  for k, val in n.tableVal:
    var tmp: T
    let child = if path.len == 0: k else: path & "." & k
    if hasParser:
      p.currentField = some(k)
    fromTomlNode(val, tmp, child, p, hasParser)
    v[k] = tmp

proc fromTomlNodeTable[T](n: TomlNode, v: var T, path: string, p: var TomlParser,
    hasParser: bool) =
  ## Shared object mapping with renameHook/currentField/skipUnknown support.
  ## Iterates document keys (like json's parseObjectHook) so variant
  ## discriminators are handled before field matching and never passed as `var`.
  if n == nil or n.kind != tvkTable:
    raise newException(OpenParserTomlError,
      "Expected a TOML table at `" & path & "`")
  when isObjectVariant(v):
    const discName = discriminatorFieldName(v)
    var discNode: TomlNode = nil
    for k, val in n.tableVal:
      var wk = k
      when compiles(renameHook(v, wk)):
        renameHook(v, wk)
      if wk == discName:
        discNode = val
        break
    if discNode != nil:
      var d: typeof(discriminatorField(v))
      if hasParser:
        p.currentField = some(discName)
      fromTomlNode(discNode, d, if path.len == 0: discName else: path & "." & discName, p, hasParser)
      let prev = v
      new(v, d)
      copyTomlFieldsBeforeRecCase(v, prev)
  for k, val in n.tableVal:
    var wk = k
    when compiles(renameHook(v, wk)):
      renameHook(v, wk)
    when isObjectVariant(v):
      if wk == discriminatorFieldName(v):
        continue
    var matched = false
    for fieldName, fieldVal in v.fieldPairs:
      if wk == fieldName:
        let child = if path.len == 0: fieldName else: path & "." & fieldName
        if hasParser:
          p.currentField = some(fieldName)
          inc p.depth
          checkMaxDepth(p)
        try:
          when compiles(fromTomlNode(val, fieldVal, child, p, hasParser)):
            fromTomlNode(val, fieldVal, child, p, hasParser)
          else:
            var tmp: typeof(fieldVal)
            fromTomlNode(val, tmp, child, p, hasParser)
            when compiles(fieldVal = tmp):
              fieldVal = tmp
        finally:
          if hasParser:
            dec p.depth
        matched = true
        break
    if not matched:
      if hasParser and not tomlSkipUnknown(p):
        raise newException(OpenParserTomlError,
          "Unknown field `" & k & "` at `" & path & "`")
      # Unknown keys ignored by default; missing keys keep defaults.

proc fromTomlNode[T](n: TomlNode, v: var T, path: string) =
  ## Map a single `TomlNode` into `v`. `path` is the dotted key path used
  ## in error messages.
  var dummy = TomlParser()
  fromTomlNode(n, v, path, dummy, false)

proc fromTomlNode[T](n: TomlNode, v: var T, path: string, p: var TomlParser) =
  fromTomlNode(n, v, path, p, true)

proc fromTomlNode[T](n: TomlNode, v: var T, path: string, p: var TomlParser,
    hasParser: bool) =
  when T is TomlNode:
    v = n
  elif T is JsonNode:
    if n == nil:
      v = newJNull()
    else:
      v = tomlNodeToJson(n)
  elif T is string:
    if n == nil or n.kind != tvkString:
      raise newException(OpenParserTomlError,
        "Expected a TOML string at `" & path & "`")
    v = n.strVal
  elif T is bool:
    if n == nil or n.kind != tvkBoolean:
      raise newException(OpenParserTomlError,
        "Expected a TOML boolean at `" & path & "`")
    v = n.boolVal
  elif T is char:
    if n == nil:
      raise newException(OpenParserTomlError,
        "Expected a TOML string at `" & path & "`")
    case n.kind
    of tvkString:
      if n.strVal.len != 1:
        raise newException(OpenParserTomlError,
          "Expected a single character at `" & path & "`")
      v = n.strVal[0]
    of tvkInteger:
      v = char(n.intVal)
    else:
      raise newException(OpenParserTomlError,
        "Expected a TOML string at `" & path & "`")
  elif T is DateTime:
    if n == nil or n.kind != tvkDateTime:
      raise newException(OpenParserTomlError,
        "Expected a TOML date/time at `" & path & "`")
    v = n.dateTimeVal
  elif T is enum:
    if n == nil:
      raise newException(OpenParserTomlError,
        "Expected a TOML string or integer at `" & path & "`")
    case n.kind
    of tvkString:
      try:
        v = strutils.parseEnum[T](n.strVal)
      except ValueError:
        raise newException(OpenParserTomlError,
          "Cannot parse `" & n.strVal & "` as " & $T & " at `" & path & "`")
    of tvkInteger:
      v = T(n.intVal)
    else:
      raise newException(OpenParserTomlError,
        "Expected a TOML string or integer at `" & path & "`")
  elif T is SomeInteger:
    if n == nil or n.kind != tvkInteger:
      raise newException(OpenParserTomlError,
        "Expected a TOML integer at `" & path & "`")
    try:
      v = T(n.intVal)
    except RangeDefect:
      raise newException(OpenParserTomlError,
        "Integer out of range at `" & path & "`")
  elif T is SomeFloat:
    if n == nil:
      raise newException(OpenParserTomlError,
        "Expected a TOML float at `" & path & "`")
    case n.kind
    of tvkFloat:
      v = T(n.floatVal)
    of tvkInteger:
      v = T(n.intVal)
    else:
      raise newException(OpenParserTomlError,
        "Expected a TOML float at `" & path & "`")
  elif T is seq:
    if n == nil or n.kind != tvkArray:
      raise newException(OpenParserTomlError,
        "Expected a TOML array at `" & path & "`")
    v.setLen(0)
    if hasParser:
      inc p.depth
      checkMaxDepth(p)
    try:
      for i, item in n.arrayVal:
        var e: typeof(v[0])
        if hasParser:
          p.currentField = some("[" & $i & "]")
        fromTomlNode(item, e, path & "[" & $i & "]", p, hasParser)
        v.add(e)
    finally:
      if hasParser:
        dec p.depth
  elif T is array:
    if n == nil or n.kind != tvkArray:
      raise newException(OpenParserTomlError,
        "Expected a TOML array at `" & path & "`")
    if n.arrayVal.len != len(v):
      raise newException(OpenParserTomlError,
        "Sequence has " & $n.arrayVal.len & " items, expected " & $len(v) &
        " at `" & path & "`")
    for i, item in n.arrayVal:
      fromTomlNode(item, v[i], path & "[" & $i & "]", p, hasParser)
  elif T is tuple:
    if n == nil or n.kind != tvkTable:
      raise newException(OpenParserTomlError,
        "Expected a TOML table at `" & path & "`")
    for fieldName, fieldVal in v.fieldPairs:
      for k, val in n.tableVal:
        var wk = k
        when compiles(renameHook(v, wk)):
          renameHook(v, wk)
        if wk == fieldName:
          let child = if path.len == 0: fieldName else: path & "." & fieldName
          if hasParser:
            p.currentField = some(fieldName)
          fromTomlNode(val, fieldVal, child, p, hasParser)
          break
    if hasParser and not tomlSkipUnknown(p):
      for k in n.tableVal.keys:
        var wk = k
        when compiles(renameHook(v, wk)):
          renameHook(v, wk)
        var found = false
        for fName, fVal in v.fieldPairs:
          if wk == fName:
            found = true
            break
        if not found:
          raise newException(OpenParserTomlError,
            "Unknown field `" & k & "` at `" & path & "`")
  elif T is (ref object):
    if n == nil or n.kind != tvkTable:
      raise newException(OpenParserTomlError,
        "Expected a TOML table at `" & path & "`")
    if v.isNil:
      new(v)
    fromTomlNodeTable(n, v[], path, p, hasParser)
  elif T is object:
    fromTomlNodeTable(n, v, path, p, hasParser)
  else:
    # Custom-type bridge: try streaming parseHook via a temp document.
    when compiles((var tmpP = TomlParser(); parseHook(tmpP, v))):
      if n == nil:
        raise newException(OpenParserTomlError,
          "Expected a value at `" & path & "`")
      var snippet = "tmp = " & dumpTomlValue(n)
      var tmpP = TomlParser(lex: newTomlLexer(snippet), options: p.options)
      tmpP.curr = tmpP.nextToken(tcKey)
      discard tmpP.keyPath()
      tmpP.expectEquals()
      if hasParser:
        tmpP.currentField = p.currentField
        tmpP.depth = p.depth
      tmpP.parseHook(v)
    else:
      {.error: "fromToml: unsupported field type".}

proc fromTomlNode[T](n: TomlNode, v: var Option[T], path: string) =
  if n == nil:
    return
  var dummy = TomlParser()
  var inner: T
  fromTomlNode(n, inner, path, dummy, false)
  v = some(inner)

proc fromTomlNode[T](n: TomlNode, v: var set[T], path: string) =
  var dummy = TomlParser()
  fromTomlNode(n, v, path, dummy, false)

proc fromTomlNode[K: string, V](n: TomlNode, v: var Table[K, V], path: string) =
  var dummy = TomlParser()
  fromTomlNode(n, v, path, dummy, false)

proc fromTomlNode[K: string, V](n: TomlNode, v: var OrderedTable[K, V],
    path: string) =
  var dummy = TomlParser()
  fromTomlNode(n, v, path, dummy, false)

proc fromTomlNode[K: string, V](n: TomlNode, v: var TableRef[K, V],
    path: string) =
  var dummy = TomlParser()
  fromTomlNode(n, v, path, dummy, false)

proc fromTomlNode[K: string, V](n: TomlNode, v: var OrderedTableRef[K, V],
    path: string) =
  var dummy = TomlParser()
  fromTomlNode(n, v, path, dummy, false)

proc fromTomlNode[T](n: TomlNode, v: var CritBitTree[T], path: string) =
  var dummy = TomlParser()
  fromTomlNode(n, v, path, dummy, false)

proc parseHook*[T: tuple](p: var TomlParser, v: var T) =
  inc p.depth
  checkMaxDepth(p)
  defer: dec p.depth
  if p.curr.kind != ttkLC:
    p.error("Expected an inline table for tuple, got " & $p.curr.kind)
  let node = p.parseInlineTable()
  fromTomlNode(node, v, "", p, true)

proc parseHook*[K: string, V](p: var TomlParser, v: var AnyTable[K, V]) =
  inc p.depth
  checkMaxDepth(p)
  defer: dec p.depth
  if p.curr.kind != ttkLC:
    p.error("Expected an inline table, got " & $p.curr.kind)
  let node = p.parseInlineTable()
  fromTomlNode(node, v, "", p, true)

proc parseHook*[T](p: var TomlParser, v: var CritBitTree[T]) =
  inc p.depth
  checkMaxDepth(p)
  defer: dec p.depth
  if p.curr.kind != ttkLC:
    p.error("Expected an inline table, got " & $p.curr.kind)
  let node = p.parseInlineTable()
  fromTomlNode(node, v, "", p, true)

proc parseHook*[T: object](p: var TomlParser, v: var T) =
  inc p.depth
  checkMaxDepth(p)
  defer: dec p.depth
  if p.curr.kind == ttkLC:
    let node = p.parseInlineTable()
    fromTomlNode(node, v, "", p, true)
  else:
    let doc = p.parseRoot()
    fromTomlNode(doc, v, "", p, true)

proc parseHook*[T: ref object](p: var TomlParser, v: var T) =
  inc p.depth
  checkMaxDepth(p)
  defer: dec p.depth
  if p.curr.kind == ttkLC:
    if v.isNil:
      new(v)
    let node = p.parseInlineTable()
    fromTomlNode(node, v[], "", p, true)
  else:
    let doc = p.parseRoot()
    if v.isNil:
      new(v)
    fromTomlNode(doc, v[], "", p, true)

proc fromToml*[T](doc: TomlDocument, v: var T) =
  ## Map a parsed TOML document into an existing `v`.
  ## Keys absent from the document keep their current values, so callers
  ## can pre-fill `v` with defaults and override from a partial file.
  ## Unknown keys are ignored; type mismatches raise `OpenParserTomlError`.
  if doc == nil or doc.kind != tvkTable:
    raise newException(OpenParserTomlError, "Expected a TOML table document")
  fromTomlNode(doc, v, "")

proc fromToml*[T](doc: TomlDocument, v: var T, opts: TomlOptions) =
  var p = TomlParser(options: opts)
  if doc == nil or doc.kind != tvkTable:
    raise newException(OpenParserTomlError, "Expected a TOML table document")
  fromTomlNode(doc, v, "", p, true)

proc parseTOML*[T: object|ref object](p: var TomlParser, v: var T) =
  ## Consume the remaining document from `p` and map it into `v`.
  ## Keys absent from the document keep their current values in `v`.
  let doc = p.parseRoot()
  fromTomlNode(doc, v, "", p, true)

proc parseTOML*[T](input: TOML, t: typedesc[T]): T =
  ## Parses a TOML string into a Nim data structure of type T.
  ## Supports objects, seqs, tables and all scalar types, not just objects.
  when T is TomlNode:
    return parseTOML(input)
  elif T is object or T is ref object:
    var parser = TomlParser(lex: newTomlLexer(input))
    parser.curr = parser.nextToken(tcKey)
    var tmp: T
    parser.parseTOML(tmp)
    result = ensureMove(tmp)
  else:
    # Scalar/seq/table roots: TOML documents must be tables, so wrap
    # bare values as `value = ...` for uniform handling, except when the
    # input already looks like a document.
    let doc = parseTOML(input)
    fromToml(doc, result)

proc parseTOML*[T](input: TOML, t: typedesc[T], opts: TomlOptions): T =
  when T is TomlNode:
    return parseTOML(input)
  elif T is object or T is ref object:
    var parser = TomlParser(lex: newTomlLexer(input), options: opts)
    parser.curr = parser.nextToken(tcKey)
    var tmp: T
    let doc = parser.parseRoot()
    fromToml(doc, tmp, opts)
    result = ensureMove(tmp)
  else:
    let doc = parseTOML(input)
    fromToml(doc, result, opts)

proc parseTOMLFile*[T](filename: string, t: typedesc[T]): T =
  parseTOML(readFile(filename), t)

proc parseTOMLFile*[T](filename: string, t: typedesc[T],
    opts: TomlOptions): T =
  parseTOML(readFile(filename), t, opts)

proc fromTomlFile*[T](filename: string, v: var T) =
  fromToml(parseTOMLFile(filename), v)

proc fromTomlFile*[T](filename: string, v: var T, opts: TomlOptions) =
  fromToml(parseTOMLFile(filename), v, opts)

#
# Serialization
#

proc dumpTOML*(doc: TomlDocument): string =
  ## Serialize a `TomlDocument` back to TOML.
  proc isBareKey(k: string): bool =
    if k.len == 0: return false
    for c in k:
      if c notin bareKeyChars:
        return false
    true

  proc escapeString(s: string): string =
    result = newStringOfCap(s.len + 2)
    for c in s:
      if c in {'\0'..'\x1F', '\x7F'}:
        case c
        of '\b': result.add("\\b")
        of '\t': result.add("\\t")
        of '\n': result.add("\\n")
        of '\f': result.add("\\f")
        of '\r': result.add("\\r")
        else: result.add("\\u" & $c.ord.toHex(4).toUpperAscii())
      elif c == '"':
        result.add("\\\"")
      elif c == '\\':
        result.add("\\\\")
      else:
        result.add(c)

  proc qKey(k: string): string =
    if isBareKey(k): k else: "\"" & escapeString(k) & "\""

  proc qPath(path: seq[string]): string =
    for i, part in path:
      if i > 0: result.add(".")
      result.add(qKey(part))

  proc dumpValue(n: TomlNode, s: var string)
  proc isTableArray(v: TomlNode): bool =
    v.kind == tvkArray and v.tableArray and v.arrayVal.len > 0

  proc dumpTable(tbl: TomlNode, s: var string, path: seq[string], header: bool) =
    if header:
      s.add("[" & qPath(path) & "]\n")
    # A table's own keys first: TOML binds a bare key to whichever header was
    # written last, so emitting a sub-table first would capture them.
    for k, v in tbl.tableVal:
      if v.kind != tvkTable and not isTableArray(v):
        s.add(qKey(k) & " = ")
        dumpValue(v, s)
        s.add("\n")
    for k, v in tbl.tableVal:
      case v.kind
      of tvkTable:
        dumpTable(v, s, path & @[k], true)
      of tvkArray:
        if isTableArray(v):
          for item in v.arrayVal:
            s.add("[[" & qPath(path & @[k]) & "]]\n")
            dumpTable(item, s, path & @[k], false)
      else:
        discard
  proc dumpValue(n: TomlNode, s: var string) =
    case n.kind
    of tvkString:
      s.add("\"" & escapeString(n.strVal) & "\"")
    of tvkInteger:
      s.add($n.intVal)
    of tvkFloat:
      s.add($n.floatVal)
    of tvkBoolean:
      s.add($n.boolVal)
    of tvkDateTime:
      s.add(n.dateRaw)
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
        s.add(qKey(kk) & " = ")
        dumpValue(vv, s)
      s.add("}")
  result = ""
  dumpTable(doc, result, @[], false)

proc dumpTomlValue*(n: TomlNode): string =
  ## Dump a single TOML value (not a full document) to its literal form.
  ## Used by custom `parseHook` bridging and `dumpHook`.
  if n == nil:
    return ""
  proc esc(s: string): string =
    result = newStringOfCap(s.len + 2)
    for c in s:
      if c in {'\0'..'\x1F', '\x7F'}:
        case c
        of '\b': result.add("\\b")
        of '\t': result.add("\\t")
        of '\n': result.add("\\n")
        of '\f': result.add("\\f")
        of '\r': result.add("\\r")
        else: result.add("\\u" & $c.ord.toHex(4).toUpperAscii())
      elif c == '"': result.add("\\\"")
      elif c == '\\': result.add("\\\\")
      else: result.add(c)
  proc bare(k: string): bool =
    if k.len == 0: return false
    for c in k:
      if c notin bareKeyChars: return false
    true
  proc qk(k: string): string =
    if bare(k): k else: "\"" & esc(k) & "\""
  proc val(v: TomlNode, s: var string) =
    case v.kind
    of tvkString: s.add("\"" & esc(v.strVal) & "\"")
    of tvkInteger: s.add($v.intVal)
    of tvkFloat: s.add($v.floatVal)
    of tvkBoolean: s.add($v.boolVal)
    of tvkDateTime: s.add(v.dateRaw)
    of tvkArray:
      s.add("[")
      for i, item in v.arrayVal:
        if i > 0: s.add(", ")
        val(item, s)
      s.add("]")
    of tvkTable:
      s.add("{")
      var first = true
      for kk, vv in v.tableVal:
        if not first: s.add(", ")
        first = false
        s.add(qk(kk) & " = ")
        val(vv, s)
      s.add("}")
  val(n, result)

proc toTomlNode*[T](v: T): TomlNode
proc toTomlNodeTable[T](v: T): TomlNode

proc toTomlNode*[T](v: Option[T]): TomlNode =
  if v.isNone:
    result = nil
  else:
    result = toTomlNode(v.get())

proc toTomlNode*[T](v: set[T]): TomlNode =
  result = newTomlArray()
  for item in v:
    let node = toTomlNode(item)
    if node != nil:
      result.arrayVal.add(node)

proc toTomlNode*[K: string, V](v: Table[K, V]): TomlNode =
  result = newTomlTable()
  for k, item in v:
    let node = toTomlNode(item)
    if node != nil:
      result.tableVal[k] = node

proc toTomlNode*[K: string, V](v: OrderedTable[K, V]): TomlNode =
  result = newTomlTable()
  for k, item in v:
    let node = toTomlNode(item)
    if node != nil:
      result.tableVal[k] = node

proc toTomlNode*[K: string, V](v: TableRef[K, V]): TomlNode =
  result = newTomlTable()
  if not v.isNil:
    for k, item in v[]:
      let node = toTomlNode(item)
      if node != nil:
        result.tableVal[k] = node

proc toTomlNode*[K: string, V](v: OrderedTableRef[K, V]): TomlNode =
  result = newTomlTable()
  if not v.isNil:
    for k, item in v[]:
      let node = toTomlNode(item)
      if node != nil:
        result.tableVal[k] = node

proc toTomlNode*[T](v: CritBitTree[T]): TomlNode =
  result = newTomlTable()
  for k, item in v:
    let node = toTomlNode(item)
    if node != nil:
      result.tableVal[k] = node

proc toTomlNode*[T](v: T): TomlNode =
  when T is TomlNode:
    result = v
  elif T is JsonNode:
    result = jsonNodeToToml(v)
  elif T is string:
    result = newTomlString(v)
  elif T is bool:
    result = newTomlBoolean(v)
  elif T is char:
    result = newTomlString($v)
  elif T is DateTime:
    result = newTomlDateTime(v)
  elif T is enum:
    result = newTomlString($v)
  elif T is SomeInteger:
    result = newTomlInteger(int64(v))
  elif T is SomeFloat:
    result = newTomlFloat(float64(v))
  elif T is seq:
    result = newTomlArray()
    # Idiomatic TOML: sequences of tables become `[[array-of-tables]]`.
    when T is seq:
      when compiles((var e: typeof(v[0]); discard)):
        discard
    var allTables = true
    if v.len == 0:
      allTables = false
    else:
      for item in v:
        let node = toTomlNode(item)
        if node == nil or node.kind != tvkTable:
          allTables = false
          break
    if allTables:
      result.tableArray = true
    for item in v:
      let node = toTomlNode(item)
      if node != nil:
        result.arrayVal.add(node)
  elif T is array:
    result = newTomlArray()
    for item in v:
      let node = toTomlNode(item)
      if node != nil:
        result.arrayVal.add(node)
  elif T is tuple:
    result = newTomlTable()
    for fieldName, fieldVal in v.fieldPairs:
      var wire = fieldName
      when compiles(renameHook(v, wire)):
        renameHook(v, wire)
      let child = toTomlNode(fieldVal)
      if child != nil:
        result.tableVal[wire] = child
  elif T is (ref object):
    if v.isNil:
      result = newTomlTable()
    else:
      result = toTomlNodeTable(v[])
  elif T is object:
    result = toTomlNodeTable(v)
  else:
    when compiles((var ss: string; dumpHook(ss, v))):
      var ss2 = ""
      dumpHook(ss2, v)
      if ss2.len == 0:
        raise newException(OpenParserTomlError, "toToml: unsupported type")
      else:
        try:
          result = parseTOML("tmp = " & ss2).get("tmp")
        except CatchableError:
          raise newException(OpenParserTomlError, "toToml: unsupported type")
    else:
      {.error: "toToml: unsupported field type".}

proc toTomlNodeTable[T](v: T): TomlNode =
  result = newTomlTable()
  for fieldName, fieldVal in v.fieldPairs:
    var skip = false
    when compiles(fieldVal.isNone):
      when compiles(fieldVal.isSome):
        if fieldVal.isNone:
          skip = true
    if not skip:
      var wire = fieldName
      when compiles(renameHook(v, wire)):
        renameHook(v, wire)
      let child = toTomlNode(fieldVal)
      if child != nil:
        result.tableVal[wire] = child

proc dumpHook*(s: var string, v: TomlNode) =
  s.add(dumpTomlValue(v))

proc dumpHook*[T](s: var string, v: T) =
  when T is distinct:
    var base: T.distinctBase = v.distinctBase
    dumpHook(s, base)
    return
  let node = toTomlNode(v)
  if node == nil:
    return
  if node.kind == tvkTable:
    # Value context: inline table.
    s.add(dumpTomlValue(node))
  else:
    s.add(dumpTomlValue(node))

proc toToml*[T](v: T): string =
  ## Serialize a Nim value to a TOML document.
  let node = toTomlNode(v)
  if node == nil:
    return ""
  if node.kind == tvkTable:
    result = dumpTOML(node)
  else:
    result = dumpTomlValue(node)

proc dumpTOML*[T: object|ref object](v: T): string =
  ## Typed overload alongside `dumpTOML(doc)`.
  toToml(v)

proc toTomlFile*[T](v: T, filename: string) =
  writeFile(filename, toToml(v))

macro toStaticToml*(v: typed): untyped =
  ## Compile-time TOML dump honouring `{.toml: "wire".}` (fallback `{.json.}`)
  ## plus runtime `renameHook`, mirroring `json.toStaticJson`.
  let tInst = v.getTypeInst()
  if tInst.kind == nnkSym and tInst.strVal == "TomlNode":
    return quote do:
      dumpTomlValue(`v`)
  var valImpl = tInst.getImpl()
  var objBody: NimNode = nil
  var isRef = false
  case valImpl.kind
  of nnkTypeDef:
    let body = valImpl[2]
    if body.kind == nnkRefTy:
      isRef = true
      var inner = body[0]
      if inner.kind == nnkSym:
        inner = inner.getTypeImpl()
      objBody = inner
    elif body.kind == nnkObjectTy:
      objBody = body
  of nnkObjectTy:
    objBody = valImpl
  else:
    return quote do:
      toToml(`v`)
  if objBody == nil or objBody.kind != nnkObjectTy:
    return quote do:
      toToml(`v`)
  for field in objBody[2]:
    if field.kind == nnkRecCase:
      return quote do:
        toToml(`v`)
  # Build table via toTomlNodeTable logic but with pragma wire names.
  let res = genSym(nskVar, "tomlRes")
  let wireSym = genSym(nskVar, "wire")
  let nodeSym = genSym(nskLet, "node")
  var stmts = newStmtList()
  stmts.add quote do:
    var `res` = newTomlTable()
  for field in objBody[2]:
    case field.kind
    of nnkSym:
      let fname = field.strVal
      stmts.add quote do:
        block:
          var `wireSym` = `fname`
          when compiles(renameHook(`v`, `wireSym`)):
            renameHook(`v`, `wireSym`)
          let `nodeSym` = toTomlNode(`v`.`field`)
          if `nodeSym` != nil:
            `res`.tableVal[`wireSym`] = `nodeSym`
    of nnkIdentDefs:
      for idx in 0 ..< field.len - 2:
        let nameNode = field[idx]
        var actual: NimNode = nil
        var pragmaNode: NimNode = nil
        case nameNode.kind
        of nnkPostfix:
          actual = nameNode[1]
        of nnkPragmaExpr:
          let inner = nameNode[0]
          case inner.kind
          of nnkPostfix: actual = inner[1]
          else: actual = inner
          pragmaNode = nameNode[1]
        of nnkIdent, nnkSym:
          actual = nameNode
        else:
          continue
        if actual == nil or actual.kind notin {nnkIdent, nnkSym}:
          continue
        let fname = actual.strVal
        var wireLit = newLit(fname)
        if pragmaNode != nil and pragmaNode.kind == nnkPragma:
          for pc in pragmaNode:
            if pc.kind in {nnkCall, nnkExprColonExpr}:
              let pn = pc[0]
              let pName = if pn.kind == nnkSym: pn.strVal else: $pn
              if pName == "toml" or pName == "json":
                wireLit = pc[1]
                break
        let fIdent = ident(fname)
        stmts.add quote do:
          block:
            var `wireSym` = `wireLit`
            when compiles(renameHook(`v`, `wireSym`)):
              renameHook(`v`, `wireSym`)
            let `nodeSym` = toTomlNode(`v`.`fIdent`)
            if `nodeSym` != nil:
              `res`.tableVal[`wireSym`] = `nodeSym`
    else:
      discard
  stmts.add quote do:
    dumpTOML(`res`)
  result = newStmtList()
  result.add quote do:
    block:
      `stmts`
