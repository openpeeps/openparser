# A collection of tiny parsers and dumpers
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/openparser

## NIF Lexer — 2027 spec, memfiles + context errors

import std/[strutils, options, memfiles]
import ./ast
import ../private/lexutils

type
  NifTokenKind* = enum
    ntkEof = "<EOF>"
    ntkLParen = "("
    ntkRParen = ")"
    ntkLBracket = "["
    ntkRBracket = "]"
    ntkLBrace = "{"
    ntkRBrace = "}"
    ntkDot = "<empty>"     # single '.' — empty node
    ntkIdent = "<ident>"
    ntkSymbol = "<symbol>"
    ntkSymbolDef = "<symbolDef>"
    ntkInt = "<int>"
    ntkUInt = "<uint>"
    ntkFloat = "<float>"
    ntkCharLit = "<charLit>"
    ntkStrLit = "<strLit>"
    ntkUnknown = "<unknown>"

  NifToken* = ref object
    kind*: NifTokenKind
    raw*: string        # raw lexeme including escapes as in source
    value*: string      # decoded
    line*, col*, pos*, wsno*: int
    suffix*: NifSuffix
    # for numbers keep raw separate; for symbol/ident value == decoded name

  NifLexer* = ref object
    input: string
    data: ptr UncheckedArray[char]
    len*: int
    pos*: int
    line*, col*: int
    current*: char
    strbuf*: string

const
  invalidToken* = "Invalid token `$1`"
  errorEndOfFile* = "Unexpected EOF while parsing `$1`"
  unexpectedToken* = "Unexpected token `$1`"
  unexpectedChar* = "Unexpected character `$1`"

proc newNifLexer*(input: string): NifLexer =
  result = NifLexer(input: input, data: nil, len: input.len, pos: 0, line: 1, col: 1, strbuf: "")
  result.current = result.charAt(0)

proc newNifLexer*(mem: pointer, size: int): NifLexer =
  result = NifLexer(data: cast[ptr UncheckedArray[char]](mem), len: size, pos: 0, line: 1, col: 1, strbuf: "")
  result.current = result.charAt(0)

proc charAt(l: NifLexer, idx: int): char {.inline.} =
  if idx < 0 or idx >= l.len: return '\0'
  if l.data != nil: l.data[idx] else: l.input[idx]

proc peekAt(l: NifLexer, off: int): char {.inline.} =
  l.charAt(l.pos + off)

proc advance(l: var NifLexer) {.inline.} =
  if l.pos < l.len:
    if l.current == '\n':
      inc l.line
      l.col = 1
    else:
      inc l.col
    inc l.pos
    l.current = l.charAt(l.pos)
  else:
    l.current = '\0'

proc getContextNif(l: NifLexer, posOverride: int = -1): string =
  getContext(l, posOverride)

proc error*(l: var NifLexer, msg: string) =
  let ctx = getContextNif(l)
  raise newException(OpenParserNifError, ("\n" & ctx & "\n" & "Error ($1:$2) " % [$l.line, $l.col]) & msg)

# Helpers

proc isB62(c: char): bool {.inline.} = c in {'0'..'9','A'..'Z','a'..'z'}
proc b62Val(c: char): int {.inline.} =
  case c
  of '0'..'9': ord(c)-ord('0')
  of 'A'..'Z': ord(c)-ord('A')+10
  of 'a'..'z': ord(c)-ord('a')+36
  else: 0

proc decodeB62(s: string): int =
  if s.len == 0: return 0
  var neg = false
  var t = s
  if t[0] == '~':
    neg = true
    t = t[1..^1]
    if t.len == 0: return 0
  var v = 0
  for c in t:
    v = v*62 + b62Val(c)
  if neg: -v else: v

proc isHexUpper(c: char): bool {.inline.} = c in {'0'..'9','A'..'F'}
proc hexVal(c: char): int {.inline.} =
  if c in '0'..'9': ord(c)-ord('0') else: ord(c)-ord('A')+10

proc isAsciiLetter(c: char): bool {.inline.} = c in {'a'..'z','A'..'Z'}
proc isNonAscii(b: char): bool {.inline.} = ord(b) >= 128
proc isIdentStartChar(c: char): bool {.inline.} =
  isAsciiLetter(c) or c == '_' or isNonAscii(c)

proc isControl(c: char): bool {.inline.} =
  c in {'(',')','[',']','{','}','~','#','\'','"','\\',':','@'}

proc skipWhitespaceCount(l: var NifLexer): int =
  result = 0
  while l.current in {' ','\t','\r','\n'}:
    inc result
    l.advance()

# Escape handling — returns decoded byte char and raw string consumed
proc readEscape(l: var NifLexer, decoded: var string, raw: var string): bool =
  ## l.current == '\\' on entry. Consumes escape, appends to decoded/raw. Returns false if not an escape.
  if l.current != '\\': return false
  let nxt = l.peekAt(1)
  if nxt == '\0':
    l.error("Trailing \\ at EOF")
  # shortcut?
  if nxt in {'n','t','r','|','^'}:
    raw.add('\\')
    raw.add(nxt)
    case nxt
    of 'n': decoded.add('\x0A')
    of 't': decoded.add('\x09')
    of 'r': decoded.add('\x0D')
    of '|': decoded.add('\\')
    of '^': decoded.add('"')
    else: discard
    l.advance() # '\'
    l.advance() # shortcut char
    return true
  elif isHexUpper(nxt) and isHexUpper(l.peekAt(2)):
    raw.add('\\')
    raw.add(nxt)
    raw.add(l.peekAt(2))
    let v = hexVal(nxt)*16 + hexVal(l.peekAt(2))
    decoded.add(char(v))
    l.advance()
    l.advance()
    l.advance()
    return true
  else:
    l.error("Invalid escape \\" & $nxt & " — use \\xx (upper hex) or \\n \\t \\r \\| \\^")
    return false

proc readLineDiff(l: var NifLexer, rawOut: var string): string =
  ## Reads B62Digit* or ~B62Digit+ starting at l.current.
  ## Returns raw string consumed, leaves l at first char after diff.
  rawOut = ""
  if l.current == '~':
    rawOut.add('~')
    l.advance()
    var cnt = 0
    while isB62(l.current):
      rawOut.add(l.current)
      l.advance()
      inc cnt
    if cnt == 0:
      l.error("Expected base62 digit after ~")
  else:
    while isB62(l.current):
      rawOut.add(l.current)
      l.advance()
  result = rawOut

proc readEscapedDataUntilHash(l: var NifLexer, decoded, raw: var string) =
  ## Reads EscapedData until next unescaped '#'. Used for comment inner.
  while true:
    if l.current == '\0':
      l.error(errorEndOfFile % "comment")
    elif l.current == '#':
      break
    elif l.current == '\\':
      discard l.readEscape(decoded, raw)
    elif isControl(l.current) and l.current notin {' ', '\t', '\n', '\r'}:
      # control chars must be escaped inside comment — but we already handle \,
      # so error if we encounter unescaped control not allowed? '#' ends, others must be escaped.
      # Allow visible non-controls; error on unescaped control
      l.error("Unescaped control character `" & $l.current & "` inside comment — use \\xx")
    else:
      decoded.add(l.current)
      raw.add(l.current)
      l.advance()

proc readEscapedDataForFilename(l: var NifLexer, decoded, raw: var string) =
  ## Reads filename EscapedData after second comma: stops at '#', whitespace, ')' '(' or EOF
  while true:
    if l.current == '\0' or l.current == '#':
      break
    if l.current in {' ', '\t', '\n', '\r', '(', ')', '[', ']', '{', '}', '"', '\'', ':'}:
      break
    if l.current == '\\':
      discard l.readEscape(decoded, raw)
    elif isControl(l.current):
      l.error("Unescaped control `" & $l.current & "` in filename — use \\xx")
    else:
      decoded.add(l.current)
      raw.add(l.current)
      l.advance()

proc parseSuffix(l: var NifLexer): NifSuffix =
  ## Called immediately after an atom/tag with no intervening whitespace. l.current is first char of suffix or next token delimiter.
  result = NifSuffix()
  var hasLI = false
  var rawLI = ""
  var li = NifLineInfo()
  var colRaw = ""
  var lineRaw = ""
  var fileRaw = ""
  var fileDecoded = ""
  var hadAt = false
  var hadTilde = false
  # check for LineInfo
  if l.current == '@':
    hadAt = true
    rawLI.add('@')
    l.advance()
    # col diff
    let cr = readLineDiff(l, colRaw)
    rawLI.add(cr)
    li.rawCol = cr
    li.colDiff = decodeB62(cr)
    if l.current == ',':
      rawLI.add(',')
      l.advance()
      let lr = readLineDiff(l, lineRaw)
      rawLI.add(lr)
      li.rawLine = lr
      li.lineDiff = decodeB62(lr)
      li.hasLineDiff = true
      if l.current == ',':
        rawLI.add(',')
        l.advance()
        var fDec = ""
        var fRaw = ""
        readEscapedDataForFilename(l, fDec, fRaw)
        rawLI.add(fRaw)
        fileRaw = fRaw
        fileDecoded = fDec
        li.rawFilename = fRaw
        li.filename = if fDec.len>0: some(fDec) else: none(string)
        li.hasFilename = true
    hasLI = true
  elif l.current == '~':
    # shorthand only if ~ is followed by B62 digit — then it's lineInfo without '@'
    if isB62(l.peekAt(1)):
      hadTilde = true
      # treat as col diff with tilde
      let cr = readLineDiff(l, colRaw) # this will consume ~ + digits
      rawLI.add(cr)
      li.rawCol = cr
      li.colDiff = decodeB62(cr)
      # may have ,line ,filename
      if l.current == ',':
        rawLI.add(',')
        l.advance()
        let lr = readLineDiff(l, lineRaw)
        rawLI.add(lr)
        li.rawLine = lr
        li.lineDiff = decodeB62(lr)
        li.hasLineDiff = true
        if l.current == ',':
          rawLI.add(',')
          l.advance()
          var fDec = ""
          var fRaw = ""
          readEscapedDataForFilename(l, fDec, fRaw)
          rawLI.add(fRaw)
          fileRaw = fRaw
          fileDecoded = fDec
          li.rawFilename = fRaw
          li.filename = if fDec.len>0: some(fDec) else: none(string)
          li.hasFilename = true
      hasLI = true
  if hasLI:
    li.hasAt = hadAt
    li.hasTildeShorthand = hadTilde
    # if we had no hasLineDiff, zero it
    result.lineInfo = some(li)
    result.rawLineInfo = rawLI
  # comment?
  if l.current == '#':
    l.advance() # opening #
    var cDec = ""
    var cRaw = ""
    readEscapedDataUntilHash(l, cDec, cRaw)
    if l.current != '#':
      l.error("Unterminated comment — missing closing #")
    l.advance() # closing #
    result.comment = some(cDec)
    result.rawComment = cRaw

# Forward
proc nextNifToken*(l: var NifLexer): NifToken

proc readStringLit(l: var NifLexer): NifToken =
  ## assumes l.current == '"' on entry
  let startLine = l.line
  let startCol = l.col
  let startPos = l.pos
  l.advance() # opening "
  var dec = ""
  var rawInner = ""
  while true:
    if l.current == '\0':
      l.error(errorEndOfFile % "string literal")
    elif l.current == '"':
      l.advance() # closing "
      break
    elif l.current == '\\':
      discard l.readEscape(dec, rawInner)
    elif l.current == '\n' or l.current == '\r':
      # whitespace allowed literally inside string per spec
      if l.current == '\n':
        dec.add('\n')
        rawInner.add('\n')
        l.advance()
      else:
        dec.add('\r')
        rawInner.add('\r')
        l.advance()
    else:
      # per nifspec VisibleChar excludes controls, but practical NIF strings contain
      # ':' '~' '#' '@' etc. Allow any byte except unescaped '"' and '\' inside strings;
      # closing '"' is handled above, '\' handled as escape, so everything else is literal.
      dec.add(l.current)
      rawInner.add(l.current)
      l.advance()
  result = NifToken(kind: ntkStrLit, raw: "\"" & rawInner & "\"", value: dec,
                    line: startLine, col: startCol, pos: startPos, wsno: 0)
  result.suffix = parseSuffix(l)

proc readCharLit(l: var NifLexer): NifToken =
  let sl = l.line; let sc = l.col; let sp = l.pos
  l.advance() # opening '
  var dec = ""
  var rawInner = ""
  if l.current == '\0':
    l.error(errorEndOfFile % "char literal")
  if l.current == '\\':
    discard l.readEscape(dec, rawInner)
  elif isControl(l.current) and l.current != '\'':
    l.error("Unescaped control in char literal")
  elif l.current == '\'':
    l.error("Empty char literal")
  elif ord(l.current) < 32 and l.current notin {'\n','\t','\r'}:
    l.error("Control byte in char literal — must be escaped")
  else:
    dec.add(l.current)
    rawInner.add(l.current)
    l.advance()
  if l.current != '\'':
    l.error("Unterminated char literal — expected '")
  l.advance()
  result = NifToken(kind: ntkCharLit, raw: "'" & rawInner & "'", value: dec,
                    line: sl, col: sc, pos: sp, wsno: 0)
  result.suffix = parseSuffix(l)

proc readNumber(l: var NifLexer): NifToken =
  let sl = l.line; let sc = l.col; let sp = l.pos
  var raw = ""
  if l.current in {'-', '+'}:
    raw.add(l.current)
    l.advance()
    if l.current notin {'0'..'9'}:
      l.error("Expected digit after sign in number")
  # digits
  var digitCount = 0
  while l.current in {'0'..'9'}:
    raw.add(l.current)
    l.advance()
    inc digitCount
  if digitCount == 0:
    l.error("Invalid number — expected digit")
  var kind = ntkInt
  var isFloat = false
  if l.current == '.':
    # need Digit after '.' to be float; otherwise '.' is delimiter (empty) not part of number
    if l.peekAt(1) in {'0'..'9'}:
      isFloat = true
      kind = ntkFloat
      raw.add('.')
      l.advance()
      while l.current in {'0'..'9'}:
        raw.add(l.current)
        l.advance()
      if l.current in {'E','e'}:
        raw.add(l.current)
        l.advance()
        if l.current in {'+','-'}:
          raw.add(l.current)
          l.advance()
        var eCnt=0
        while l.current in {'0'..'9'}:
          raw.add(l.current)
          l.advance()
          inc eCnt
        if eCnt==0: l.error("Expected digit in exponent")
    else:
      discard # leave '.' for next token (empty)
  elif l.current in {'E','e'}:
    isFloat = true
    kind = ntkFloat
    raw.add(l.current)
    l.advance()
    if l.current in {'+','-'}:
      raw.add(l.current)
      l.advance()
    var eCnt=0
    while l.current in {'0'..'9'}:
      raw.add(l.current)
      l.advance()
      inc eCnt
    if eCnt==0: l.error("Expected digit in exponent")
  if not isFloat and l.current == 'u':
    kind = ntkUInt
    raw.add('u')
    l.advance()
  result = NifToken(kind: kind, raw: raw, value: raw, line: sl, col: sc, pos: sp, wsno: 0)
  result.suffix = parseSuffix(l)

proc readIdentSymbol(l: var NifLexer, isSymbolDef: bool): NifToken =
  let sl = l.line; let sc = l.col; let sp = l.pos
  var raw = ""
  var decoded = ""
  # first IdentStart (could be escape)
  if l.current == '\\':
    discard l.readEscape(decoded, raw)
  elif isIdentStartChar(l.current):
    decoded.add(l.current)
    raw.add(l.current)
    l.advance()
  else:
    l.error("Invalid identifier start `" & $l.current & "`")
  # IdentChar*  — include '-' per nifspec examples (background-color, create-table)
  while true:
    if l.current == '\\':
      discard l.readEscape(decoded, raw)
    elif l.current == '_' or l.current == '-' or l.current in {'0'..'9'} or isIdentStartChar(l.current):
      decoded.add(l.current)
      raw.add(l.current)
      l.advance()
    else: break
  # check for Symbol dots? If we are building ident/symbol generic, look ahead for '.' sequences
  var isSymbol = false
  var symbolRaw = raw
  var symbolDec = decoded
  # Symbol requires at least one '.' followed by (IdentChar|'.')*
  # We need to peek greedy for Symbol tail
  while l.current == '.':
    # dot inside symbol — consume and continue. But if next char is not IdentChar|'.'|digit|'_' etc, we still have symbol with trailing dot(s)
    # exactly per grammar: '.' (IdentChar|'.')*
    # The special case of lone '.' is handled at dispatch, not here. Here we start with ident prefix, so dot means symbol start.
    isSymbol = true
    symbolRaw.add('.')
    symbolDec.add('.')
    l.advance()
    # after dot, consume run of IdentChar or '.'
    while true:
      if l.current == '\\':
        discard l.readEscape(symbolDec, symbolRaw)
      elif l.current == '.' :
        symbolRaw.add('.')
        symbolDec.add('.')
        l.advance()
      elif l.current == '_' or l.current == '-' or l.current in {'0'..'9'} or isIdentStartChar(l.current):
        symbolRaw.add(l.current)
        symbolDec.add(l.current)
        l.advance()
      else: break
    # continue outer while to cover multiple segments? inner already consumes all remaining dots/identchars so break
    break
  if isSymbol:
    let k = if isSymbolDef: ntkSymbolDef else: ntkSymbol
    result = NifToken(kind: k, raw: (if isSymbolDef: ":" else: "") & symbolRaw,
                      value: symbolDec,
                      line: sl, col: sc, pos: sp, wsno: 0)
  else:
    if isSymbolDef:
      # allow :Ident without dot as SymbolDef (e.g. :File in spec example)
      result = NifToken(kind: ntkSymbolDef, raw: ":" & raw, value: decoded,
                        line: sl, col: sc, pos: sp, wsno: 0)
    else:
      result = NifToken(kind: ntkIdent, raw: raw, value: decoded, line: sl, col: sc, pos: sp, wsno: 0)
  result.suffix = parseSuffix(l)

proc nextNifToken*(l: var NifLexer): NifToken =
  ## Produce next token, skipping whitespace. Attaches suffix with no ws.
  let wsno = skipWhitespaceCount(l)
  let sl = l.line; let sc = l.col; let sp = l.pos
  case l.current
  of '\0':
    result = NifToken(kind: ntkEof, raw: "", value:"", line: sl, col: sc, pos: sp, wsno: wsno)
  of '(':
    l.advance()
    result = NifToken(kind: ntkLParen, raw:"(", value:"(", line: sl, col: sc, pos: sp, wsno: wsno)
  of ')':
    l.advance()
    result = NifToken(kind: ntkRParen, raw:")", value:")", line: sl, col: sc, pos: sp, wsno: wsno)
  of '[':
    l.advance()
    result = NifToken(kind: ntkLBracket, raw:"[", value:"[", line: sl, col: sc, pos: sp, wsno: wsno)
  of ']':
    l.advance()
    result = NifToken(kind: ntkRBracket, raw:"]", value:"]", line: sl, col: sc, pos: sp, wsno: wsno)
  of '{':
    l.advance()
    result = NifToken(kind: ntkLBrace, raw:"{", value:"{", line: sl, col: sc, pos: sp, wsno: wsno)
  of '}':
    l.advance()
    result = NifToken(kind: ntkRBrace, raw:"}", value:"}", line: sl, col: sc, pos: sp, wsno: wsno)
  of ':':
    l.advance() # consume :
    if l.current == '\\' or isIdentStartChar(l.current):
      var tok = readIdentSymbol(l, true)
      # adjust pos/col to include colon
      tok.line = sl; tok.col = sc; tok.pos = sp; tok.wsno = wsno
      return tok
    else:
      l.error("Expected symbol after :")
  of '"':
    let t = readStringLit(l)
    t.wsno = wsno
    return t
  of '\'':
    let t = readCharLit(l)
    t.wsno = wsno
    return t
  of '.':
    # Empty — single dot. But number starting with '.' not allowed (digits can't start with dot). So emit dot.
    l.advance()
    result = NifToken(kind: ntkDot, raw: ".", value:".", line: sl, col: sc, pos: sp, wsno: wsno)
    result.suffix = parseSuffix(l)
  of '-', '+':
    if l.peekAt(1) in {'0'..'9'}:
      let t = readNumber(l)
      t.wsno = wsno
      return t
    elif l.current == '-':
      l.error(unexpectedChar % $l.current)
    else:
      # '+' alone is not a number — treat as ident-like? fallthrough to ident error
      l.error(unexpectedChar % $l.current)
  of '0'..'9':
    let t = readNumber(l)
    t.wsno = wsno
    return t
  of '@', '~', '#':
    # suffix introducers should not appear standalone at token start (except ~ maybe number? but numbers already). Treat as error.
    l.error(unexpectedChar % $l.current)
  of '\\':
    l.error("Unexpected \\ — escapes only inside literals/identifiers/symbols")
  else:
    if isAsciiLetter(l.current) or l.current == '_' or isNonAscii(l.current) or l.current == '\\':
      let t = readIdentSymbol(l, false)
      t.line = sl; t.col = sc; t.pos = sp; t.wsno = wsno
      return t
    else:
      l.error(unexpectedChar % $l.current)

proc tokenize*(input: string): seq[NifToken] =
  ## Tokenize whole input to seq (including EOF)
  var l = newNifLexer(input)
  while true:
    let t = l.nextNifToken()
    result.add(t)
    if t.kind == ntkEof: break

proc tokenize*(mf: MemFile): seq[NifToken] =
  ## Zero-copy tokenization over MemFile
  var l = newNifLexer(mf.mem, int(mf.size))
  while true:
    let t = l.nextNifToken()
    result.add(t)
    if t.kind == ntkEof: break

iterator tokens*(l: var NifLexer): NifToken =
  while true:
    let t = l.nextNifToken()
    yield t
    if t.kind == ntkEof: break
