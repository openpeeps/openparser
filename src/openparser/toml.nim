# A collection of tiny parsers and dumpers
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/openparser

## This module implements a TOML parser and serializer for Nim,
## allowing you to read and write TOML configuration files with ease.
##
## The parser targets **TOML v1.0.0** and is validated against the official
## [toml-test](https://github.com/toml-lang/toml-test) fixture corpus. It
## parses TOML format into Nim data structures, like tables, sequences,
## and basic types, and serializes data structures back into TOML format.
##
## Parsing to pre-defined Toml AST nodes is supported as well, so you can work with
## a structured representation of the TOML document if you need more control or want to
## implement custom validation rules beyond what the direct-to-struct parsing provides
import std/[strutils, tables, sets, unicode, times]
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

  TomlParser* = object
    ## The TomlParser takes a TomlLexer and produces a Nim data structure
    ## representing the TOML content
    lex*: TomlLexer
    curr*: TomlToken
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

proc fromTomlNode[T](n: TomlNode, v: var T, path: string) =
  ## Map a single `TomlNode` into `v`. `path` is the dotted key path used
  ## in error messages.
  when T is string:
    if n == nil or n.kind != tvkString:
      raise newException(OpenParserTomlError,
        "Expected a TOML string at `" & path & "`")
    v = n.strVal
  elif T is bool:
    if n == nil or n.kind != tvkBoolean:
      raise newException(OpenParserTomlError,
        "Expected a TOML boolean at `" & path & "`")
    v = n.boolVal
  elif T is DateTime:
    if n == nil or n.kind != tvkDateTime:
      raise newException(OpenParserTomlError,
        "Expected a TOML date/time at `" & path & "`")
    v = n.dateTimeVal
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
    for i, item in n.arrayVal:
      var e: typeof(v[0])  # unevaluated; safe on the empty seq
      fromTomlNode(item, e, path & "[" & $i & "]")
      v.add(e)
  elif T is (ref object):
    if n == nil or n.kind != tvkTable:
      raise newException(OpenParserTomlError,
        "Expected a TOML table at `" & path & "`")
    if v.isNil:
      new(v)
    for fieldName, fieldVal in v[].fieldPairs:
      if n.tableVal.hasKey(fieldName):
        let child = if path.len == 0: fieldName else: path & "." & fieldName
        fromTomlNode(n.tableVal[fieldName], fieldVal, child)
  elif T is object:
    if n == nil or n.kind != tvkTable:
      raise newException(OpenParserTomlError,
        "Expected a TOML table at `" & path & "`")
    for fieldName, fieldVal in v.fieldPairs:
      if n.tableVal.hasKey(fieldName):
        let child = if path.len == 0: fieldName else: path & "." & fieldName
        fromTomlNode(n.tableVal[fieldName], fieldVal, child)
  else:
    {.error: "fromToml: unsupported field type".}

proc fromToml*[T](doc: TomlDocument, v: var T) =
  ## Map a parsed TOML document into an existing `v`.
  ## Keys absent from the document keep their current values, so callers
  ## can pre-fill `v` with defaults and override from a partial file.
  ## Unknown keys are ignored; type mismatches raise `OpenParserTomlError`.
  if doc == nil or doc.kind != tvkTable:
    raise newException(OpenParserTomlError, "Expected a TOML table document")
  fromTomlNode(doc, v, "")

proc parseTOML*[T: object|ref object](p: var TomlParser, v: var T) =
  ## Consume the remaining document from `p` and map it into `v`.
  ## Keys absent from the document keep their current values in `v`.
  let doc = p.parseRoot()
  fromToml(doc, v)

proc parseTOML*[T](input: TOML, t: typedesc[T]): T =
  ## Parses a TOML string into a Nim data structure of type T
  var parser = TomlParser(lex: newTomlLexer(input))
  parser.curr = parser.nextToken(tcKey)
  var tmp: T
  parser.parseTOML(tmp)
  result = ensureMove(tmp)

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
