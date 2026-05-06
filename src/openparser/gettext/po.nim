import std/[memfiles, tables, strutils]

type
  Span* = object
    ## Half-open byte span in the mapped file: [a, b)
    a*: int
    b*: int

  PoCommentKind* = enum
    pckTranslator,   # "# "
    pckExtracted,    # "#."
    pckReference,    # "#:"
    pckFlag,         # "#,"
    pckPrevious,     # "#|"
    pckOther         # "#"

  PoComment* = object
    kind*: PoCommentKind
    text*: Span

  PoStringField* = object
    ## String is stored as multiple quoted chunks.
    chunks*: seq[Span]

  PoMsgStr* = object
    idx*: int
    value*: PoStringField

  PoEntry* = object
    ## Represents a single entry in the .po file, which may contain `msgctxt`,
    ## `msgid`, `msgid_plural`, and multiple `msgstr` forms, along with comments.
    line*: int
    obsolete*: bool
      ## Whether this entry is marked as obsolete (starts with "#~"). Obsolete entries are ignored by the compiler.
    comments*: seq[PoComment]
      ## Comments associated with this entry. This includes translator comments,
      ## extracted comments, references, flags, and previous references.

    prevMsgctxt*: PoStringField
      ## The previous `msgctxt` value, if this entry is a fuzzy update to an existing entry.
      ## This is used for reference and comparison during fuzzy matching.
    prevMsgid*: PoStringField
      ## The previous `msgid` value, if this entry is a fuzzy update to an existing entry.
    prevMsgidPlural*: PoStringField
      ## The previous `msgid_plural` value, if this entry is a fuzzy update to an existing entry.

    msgctxt*: PoStringField
      ## The `msgctxt` field of this entry, representing the message context. This is optional and may be empty.
    msgid*: PoStringField
      ## The `msgid` field of this entry, representing the original untranslated string.
      ## This is required for non-header entries.
    msgidPlural*: PoStringField
      ## The `msgid_plural` field of this entry, representing the plural form of
      ## the original string. This is optional and only used for plural entries.
    msgstr*: seq[PoMsgStr]
      ## The `msgstr` field(s) of this entry, representing the translated string(s).
      ## For singular entries, there is typically one `msgstr` with `idx = 0`.
      ## 
      ## For plural entries, there are multiple `msgstr` forms indexed from 0 to nplurals-1.

  PoCatalog* = ref object
    ## Represents a parsed .po file, backed by a memory-mapped file for efficient access.
    ## The `entries` field contains the parsed entries, while `data` and `len` provide
    ## access to the raw file contents for lazy decoding of strings.
    mf*: MemFile
    data*: ptr UncheckedArray[char]
    len*: int
    entries*: seq[PoEntry]

  PoParseError* = object of CatchableError
    ## Represents an error that occurred during parsing of a .po file

  TargetKind = enum
    tkNone,
    tkMsgctxt, tkMsgid, tkMsgidPlural, tkMsgstr,
    tkPrevMsgctxt, tkPrevMsgid, tkPrevMsgidPlural

  ActiveTarget = object
    kind: TargetKind
    idx: int

proc fail(line, col: int, msg: string): ref PoParseError =
  newException(PoParseError, "line " & $line & ", col " & $col & ": " & msg)

proc isSpace(c: char): bool {.inline.} =
  c == ' ' or c == '\t' or c == '\r'

proc skipSpaces(cat: PoCatalog; i, e: int): int =
  result = i
  while result < e and isSpace(cat.data[result]):
    inc result

proc trimSpan(cat: PoCatalog; s: Span): Span =
  var i = s.a
  var j = s.b
  while i < j and isSpace(cat.data[i]): inc i
  while j > i and isSpace(cat.data[j - 1]): dec j
  Span(a: i, b: j)

proc spanLen(s: Span): int {.inline.} = s.b - s.a
proc isEmpty(s: Span): bool {.inline.} = s.a >= s.b

proc spanEq(cat: PoCatalog; s: Span; lit: string): bool =
  if spanLen(s) != lit.len: return false
  for k in 0 ..< lit.len:
    if cat.data[s.a + k] != lit[k]: return false
  true

proc startsWith(cat: PoCatalog; s: Span; lit: string): bool =
  if spanLen(s) < lit.len: return false
  for k in 0 ..< lit.len:
    if cat.data[s.a + k] != lit[k]: return false
  true

proc toString*(cat: PoCatalog; s: Span): string =
  result = newString(max(0, spanLen(s)))
  for i in 0 ..< result.len:
    result[i] = cat.data[s.a + i]

proc parseQuotedSpan(cat: PoCatalog; i0, e, line: int): tuple[chunk: Span, nextI: int] =
  var i = skipSpaces(cat, i0, e)
  if i >= e or cat.data[i] != '"':
    raise fail(line, i - i0 + 1, "expected quoted string")
  inc i
  let start = i
  var esc = false
  while i < e:
    let c = cat.data[i]
    if esc:
      esc = false
    else:
      if c == '\\':
        esc = true
      elif c == '"':
        let inner = Span(a: start, b: i)
        inc i
        i = skipSpaces(cat, i, e)
        if i != e:
          raise fail(line, i - i0 + 1, "trailing characters after quoted string")
        return (inner, i)
    inc i
  raise fail(line, e - i0 + 1, "unterminated quoted string")

proc addChunk(field: var PoStringField; s: Span) =
  field.chunks.add s

proc getOrCreateMsgStrIdx(entry: var PoEntry; idx: int): int =
  for i in 0 ..< entry.msgstr.len:
    if entry.msgstr[i].idx == idx:
      return i
  entry.msgstr.add PoMsgStr(idx: idx)
  result = entry.msgstr.len - 1

proc addRefTokens(entry: var PoEntry; s: Span; line: int; kind: PoCommentKind) =
  ## Keep whole line as a comment span; caller can split lazily if needed.
  entry.comments.add PoComment(kind: kind, text: s)

proc hasContent(e: PoEntry): bool =
  e.comments.len > 0 or
  e.msgid.chunks.len > 0 or
  e.msgstr.len > 0 or
  e.msgctxt.chunks.len > 0 or
  e.msgidPlural.chunks.len > 0 or
  e.prevMsgid.chunks.len > 0 or
  e.prevMsgctxt.chunks.len > 0 or
  e.prevMsgidPlural.chunks.len > 0

proc decodeHex(cat: PoCatalog; i: var int; e, maxDigits: int): int =
  var n = 0
  var d = 0
  while i < e and d < maxDigits:
    let c = cat.data[i]
    var v = -1
    if c >= '0' and c <= '9': v = ord(c) - ord('0')
    elif c >= 'a' and c <= 'f': v = 10 + ord(c) - ord('a')
    elif c >= 'A' and c <= 'F': v = 10 + ord(c) - ord('A')
    else: break
    n = (n shl 4) or v
    inc i
    inc d
  if d == 0: return -1
  n

proc appendRuneUtf8(output: var string; cp: int) =
  if cp <= 0x7F:
    output.add char(cp)
  elif cp <= 0x7FF:
    output.add char(0xC0 or (cp shr 6))
    output.add char(0x80 or (cp and 0x3F))
  elif cp <= 0xFFFF:
    output.add char(0xE0 or (cp shr 12))
    output.add char(0x80 or ((cp shr 6) and 0x3F))
    output.add char(0x80 or (cp and 0x3F))
  else:
    output.add char(0xF0 or (cp shr 18))
    output.add char(0x80 or ((cp shr 12) and 0x3F))
    output.add char(0x80 or ((cp shr 6) and 0x3F))
    output.add char(0x80 or (cp and 0x3F))

proc decodeChunk(cat: PoCatalog; s: Span; output: var string) =
  var i = s.a
  while i < s.b:
    let c = cat.data[i]
    if c != '\\':
      output.add c
      inc i
      continue

    inc i
    if i >= s.b:
      output.add '\\'
      break
    let e = cat.data[i]
    case e
    of 'n': output.add '\n'; inc i
    of 'r': output.add '\r'; inc i
    of 't': output.add '\t'; inc i
    of 'b': output.add '\b'; inc i
    of 'f': output.add '\f'; inc i
    of 'v': output.add '\v'; inc i
    of 'a': output.add '\a'; inc i
    of '\\': output.add '\\'; inc i
    of '"': output.add '"'; inc i
    of 'x':
      inc i
      var j = i
      let v = decodeHex(cat, j, s.b, 2)
      if v < 0:
        output.add 'x'
      else:
        output.add char(v and 0xFF)
        i = j
    of 'u':
      inc i
      var j = i
      let v = decodeHex(cat, j, s.b, 4)
      if v < 0: output.add 'u'
      else:
        appendRuneUtf8(output, v)
        i = j
    of 'U':
      inc i
      var j = i
      let v = decodeHex(cat, j, s.b, 8)
      if v < 0: output.add 'U'
      else:
        appendRuneUtf8(output, v)
        i = j
    of '0'..'7':
      var v = ord(e) - ord('0')
      inc i
      var k = 0
      while i < s.b and k < 2 and cat.data[i] in {'0'..'7'}:
        v = (v shl 3) or (ord(cat.data[i]) - ord('0'))
        inc i
        inc k
      output.add char(v and 0xFF)
    else:
      ## gettext/C-like behavior: unknown escape keeps escaped char
      output.add e
      inc i

proc decodeField*(cat: PoCatalog; f: PoStringField): string =
  var total = 0
  for c in f.chunks: total += spanLen(c)
  result = newStringOfCap(total)
  for c in f.chunks:
    decodeChunk(cat, c, result)

proc decodeMsgStr*(cat: PoCatalog; e: PoEntry; idx = 0): string =
  for m in e.msgstr:
    if m.idx == idx:
      return decodeField(cat, m.value)
  ""

proc parseKeyword(cat: PoCatalog; s: Span): tuple[ok: bool, key: string, idx: int, rest: Span] =
  var i = s.a
  while i < s.b and not isSpace(cat.data[i]): inc i
  let keySpan = Span(a: s.a, b: i)
  var idx = 0
  var key = ""
  if spanEq(cat, keySpan, "msgctxt"): key = "msgctxt"
  elif spanEq(cat, keySpan, "msgid"): key = "msgid"
  elif spanEq(cat, keySpan, "msgid_plural"): key = "msgid_plural"
  elif startsWith(cat, keySpan, "msgstr"):
    if spanLen(keySpan) == 6:
      key = "msgstr"
    else:
      if cat.data[keySpan.a + 6] != '[' or cat.data[keySpan.b - 1] != ']':
        return (false, "", 0, s)
      var j = keySpan.a + 7
      let je = keySpan.b - 1
      if j >= je: return (false, "", 0, s)
      var n = 0
      while j < je:
        let c = cat.data[j]
        if c < '0' or c > '9': return (false, "", 0, s)
        n = n * 10 + (ord(c) - ord('0'))
        inc j
      key = "msgstr"
      idx = n
  else:
    return (false, "", 0, s)

  let rest = Span(a: i, b: s.b)
  (true, key, idx, rest)

proc parsePoInternal(cat: PoCatalog) =
  var pos = 0
  var lineNo = 1
  if cat.len >= 3 and cat.data[0] == '\xEF' and cat.data[1] == '\xBB' and cat.data[2] == '\xBF':
    pos = 3

  var cur = PoEntry(line: 1)
  var target = ActiveTarget(kind: tkNone)
  var prevTarget = ActiveTarget(kind: tkNone)

  proc flushEntry() =
    if hasContent(cur):
      cat.entries.add cur
    cur = PoEntry(line: lineNo)
    target = ActiveTarget(kind: tkNone)
    prevTarget = ActiveTarget(kind: tkNone)

  while pos <= cat.len:
    let ls = pos
    var le = pos
    while le < cat.len and cat.data[le] != '\n': inc le
    pos = if le < cat.len: le + 1 else: le

    var line = Span(a: ls, b: le)
    if not isEmpty(line) and cat.data[line.b - 1] == '\r':
      dec line.b

    let trimmed = trimSpan(cat, line)
    if isEmpty(trimmed):
      flushEntry()
      inc lineNo
      if pos >= cat.len and isEmpty(line): break
      continue

    if not hasContent(cur):
      cur.line = lineNo

    var i = trimmed.a
    var modeObsolete = false
    var modePrevious = false

    if cat.data[i] == '#':
      inc i
      if i < trimmed.b and cat.data[i] == '~':
        modeObsolete = true
        cur.obsolete = true
        inc i
        i = skipSpaces(cat, i, trimmed.b)
        if i < trimmed.b and cat.data[i] == '#':
          # obsolete comment
          var cpos = i
          inc cpos
          var kind = pckOther
          if cpos < trimmed.b:
            case cat.data[cpos]
            of ' ': kind = pckTranslator; inc cpos
            of '.': kind = pckExtracted; inc cpos
            of ':': kind = pckReference; inc cpos
            of ',': kind = pckFlag; inc cpos
            of '|': kind = pckPrevious; inc cpos
            else: discard
          cpos = skipSpaces(cat, cpos, trimmed.b)
          addRefTokens(cur, Span(a: cpos, b: trimmed.b), lineNo, kind)
          inc lineNo
          continue
      elif i < trimmed.b and cat.data[i] == '|':
        modePrevious = true
        inc i
        i = skipSpaces(cat, i, trimmed.b)
      else:
        # regular comment
        var kind = pckOther
        if i < trimmed.b:
          case cat.data[i]
          of ' ': kind = pckTranslator; inc i
          of '.': kind = pckExtracted; inc i
          of ':': kind = pckReference; inc i
          of ',': kind = pckFlag; inc i
          of '|': kind = pckPrevious; inc i
          else: discard
        i = skipSpaces(cat, i, trimmed.b)
        addRefTokens(cur, Span(a: i, b: trimmed.b), lineNo, kind)
        inc lineNo
        continue

    let stmt = Span(a: i, b: trimmed.b)

    if cat.data[stmt.a] == '"':
      let (chunk, _) = parseQuotedSpan(cat, stmt.a, stmt.b, lineNo)
      if modePrevious:
        case prevTarget.kind
        of tkPrevMsgctxt: cur.prevMsgctxt.addChunk(chunk)
        of tkPrevMsgid: cur.prevMsgid.addChunk(chunk)
        of tkPrevMsgidPlural: cur.prevMsgidPlural.addChunk(chunk)
        else: raise fail(lineNo, 1, "previous-string continuation without active previous field")
      else:
        case target.kind
        of tkMsgctxt: cur.msgctxt.addChunk(chunk)
        of tkMsgid: cur.msgid.addChunk(chunk)
        of tkMsgidPlural: cur.msgidPlural.addChunk(chunk)
        of tkMsgstr:
          let msi = getOrCreateMsgStrIdx(cur, target.idx)
          cur.msgstr[msi].value.addChunk(chunk)
        else:
          raise fail(lineNo, 1, "string continuation without active field")
      inc lineNo
      continue

    let (ok, key, idx, rest) = parseKeyword(cat, stmt)
    if not ok:
      raise fail(lineNo, 1, "invalid token in .po entry")

    let (chunk, _) = parseQuotedSpan(cat, rest.a, rest.b, lineNo)

    if modePrevious:
      if key == "msgctxt":
        cur.prevMsgctxt = PoStringField()
        cur.prevMsgctxt.addChunk(chunk)
        prevTarget = ActiveTarget(kind: tkPrevMsgctxt)
      elif key == "msgid":
        cur.prevMsgid = PoStringField()
        cur.prevMsgid.addChunk(chunk)
        prevTarget = ActiveTarget(kind: tkPrevMsgid)
      elif key == "msgid_plural":
        cur.prevMsgidPlural = PoStringField()
        cur.prevMsgidPlural.addChunk(chunk)
        prevTarget = ActiveTarget(kind: tkPrevMsgidPlural)
      else:
        raise fail(lineNo, 1, "only msgctxt/msgid/msgid_plural allowed in previous (#|) lines")
      inc lineNo
      continue

    # Tolerant boundary: flush only if we already started a real message body.
    # Do NOT flush on msgctxt -> msgid (that's the normal order for contextual entries).
    if key == "msgid" and (
      cur.msgid.chunks.len > 0 or
      cur.msgstr.len > 0 or
      cur.msgidPlural.chunks.len > 0
    ):
      flushEntry()
      cur.line = lineNo
    
    if key == "msgctxt":
      cur.msgctxt = PoStringField()
      cur.msgctxt.addChunk(chunk)
      target = ActiveTarget(kind: tkMsgctxt)
    elif key == "msgid":
      cur.msgid = PoStringField()
      cur.msgid.addChunk(chunk)
      target = ActiveTarget(kind: tkMsgid)
    elif key == "msgid_plural":
      cur.msgidPlural = PoStringField()
      cur.msgidPlural.addChunk(chunk)
      target = ActiveTarget(kind: tkMsgidPlural)
    else:
      let msi = getOrCreateMsgStrIdx(cur, idx)
      cur.msgstr[msi].value = PoStringField()
      cur.msgstr[msi].value.addChunk(chunk)
      target = ActiveTarget(kind: tkMsgstr, idx: idx)

    inc lineNo

  if hasContent(cur):
    cat.entries.add(cur)

proc openPoCatalog*(path: string): PoCatalog =
  ## Open a .po file and parse its contents into a PoCatalog structure
  ## The file is memory-mapped for efficient access.
  result = PoCatalog()
  result.mf = memfiles.open(path, mode = fmRead)
  result.data = cast[ptr UncheckedArray[char]](result.mf.mem)
  result.len = result.mf.size
  result.entries = @[]
  parsePoInternal(result)

proc close*(cat: PoCatalog) =
  ## Close the catalog and release resources. After this, the catalog should not be used.
  if cat.mf.mem != nil:
    memfiles.close(cat.mf)
  cat.data = nil
  cat.len = 0
  cat.entries.setLen(0)

#
# Po Compiler
#
type
  PlNodeKind = enum
    pnkNum, pnkVarN,
    pnkNeg, pnkNot,
    pnkMul, pnkDiv, pnkMod,
    pnkAdd, pnkSub,
    pnkLt, pnkLe, pnkGt, pnkGe, pnkEq, pnkNe,
    pnkAnd, pnkOr,
    pnkTernary

  PlNode = ref object
    kind: PlNodeKind
    num: int
    a, b, c: PlNode

  PoCompiledMessage* = object
    msgctxt*: string
    msgid*: string
    msgidPlural*: string
    forms*: seq[string]

  PoCompiledCatalog* = object
    headers*: Table[string, string]
    nplurals*: int
    pluralExprRaw*: string
    messages*: seq[PoCompiledMessage]
    index*: Table[string, int]
    pluralAst: PlNode

const CtxSep = '\x04'

proc makeKey(msgctxt, msgid: string): string {.inline.} =
  if msgctxt.len == 0: msgid else: msgctxt & $CtxSep & msgid

proc spanToStr(cat: PoCatalog; s: Span): string {.inline.} = toString(cat, s)

proc isFuzzy(cat: PoCatalog; e: PoEntry): bool =
  for c in e.comments:
    if c.kind == pckFlag:
      let t = spanToStr(cat, c.text)
      for flag in t.split(','):
        if flag.strip().toLowerAscii() == "fuzzy":
          return true
  false

proc parseHeadersBlock(s: string): Table[string, string] =
  result = initTable[string, string]()
  for line in s.splitLines():
    if line.len == 0: continue
    let p = line.find(':')
    if p <= 0: continue
    let k = line[0 ..< p].strip()
    let v = line[p + 1 .. ^1].strip()
    if k.len > 0:
      result[k] = v

type
  PlTokKind = enum
    tkEof, tkNum, tkN,
    tkLPar, tkRPar, tkQ, tkColon,
    tkOr, tkAnd,
    tkEq, tkNe, tkLt, tkLe, tkGt, tkGe,
    tkAdd, tkSub, tkMul, tkDiv, tkMod, tkNot

  PlTok = object
    kind: PlTokKind
    num: int

  PlLexer = object
    s: string
    i: int
    t: PlTok

proc plSkipWs(lx: var PlLexer) =
  while lx.i < lx.s.len and lx.s[lx.i] in {' ', '\t', '\r', '\n'}: inc lx.i

proc plNext(lx: var PlLexer) =
  plSkipWs(lx)
  if lx.i >= lx.s.len:
    lx.t = PlTok(kind: tkEof)
    return

  let c = lx.s[lx.i]
  if c in {'0'..'9'}:
    var n = 0
    while lx.i < lx.s.len and lx.s[lx.i] in {'0'..'9'}:
      n = n * 10 + (ord(lx.s[lx.i]) - ord('0'))
      inc lx.i
    lx.t = PlTok(kind: tkNum, num: n)
    return

  if c == 'n':
    inc lx.i
    lx.t = PlTok(kind: tkN)
    return

  template two(ch: char, yes: PlTokKind, no: PlTokKind) =
    if lx.i + 1 < lx.s.len and lx.s[lx.i + 1] == ch:
      lx.i += 2
      lx.t = PlTok(kind: yes)
    else:
      inc lx.i
      lx.t = PlTok(kind: no)
    return

  case c
  of '(':
    inc lx.i; lx.t = PlTok(kind: tkLPar)
  of ')':
    inc lx.i; lx.t = PlTok(kind: tkRPar)
  of '?':
    inc lx.i; lx.t = PlTok(kind: tkQ)
  of ':':
    inc lx.i; lx.t = PlTok(kind: tkColon)
  of '|': two('|', tkOr, tkEof)
  of '&': two('&', tkAnd, tkEof)
  of '=': two('=', tkEq, tkEof)
  of '!': two('=', tkNe, tkNot)
  of '<': two('=', tkLe, tkLt)
  of '>': two('=', tkGe, tkGt)
  of '+':
    inc lx.i; lx.t = PlTok(kind: tkAdd)
  of '-':
    inc lx.i; lx.t = PlTok(kind: tkSub)
  of '*':
    inc lx.i; lx.t = PlTok(kind: tkMul)
  of '/':
    inc lx.i; lx.t = PlTok(kind: tkDiv)
  of '%':
    inc lx.i; lx.t = PlTok(kind: tkMod)
  else:
    inc lx.i
    lx.t = PlTok(kind: tkEof)

proc node(kind: PlNodeKind; a: PlNode = nil; b: PlNode = nil; c: PlNode = nil; num = 0): PlNode =
  PlNode(kind: kind, a: a, b: b, c: c, num: num)

proc parseExpr(lx: var PlLexer): PlNode

proc parsePrimary(lx: var PlLexer): PlNode =
  case lx.t.kind
  of tkNum:
    result = node(pnkNum, num = lx.t.num)
    plNext(lx)
  of tkN:
    result = node(pnkVarN)
    plNext(lx)
  of tkLPar:
    plNext(lx)
    result = parseExpr(lx)
    if lx.t.kind == tkRPar: plNext(lx)
  else:
    result = node(pnkNum, num = 0)

proc parseUnary(lx: var PlLexer): PlNode =
  case lx.t.kind
  of tkSub:
    plNext(lx)
    result = node(pnkNeg, parseUnary(lx))
  of tkNot:
    plNext(lx)
    result = node(pnkNot, parseUnary(lx))
  else:
    result = parsePrimary(lx)

proc parseMul(lx: var PlLexer): PlNode =
  result = parseUnary(lx)
  while lx.t.kind in {tkMul, tkDiv, tkMod}:
    let op = lx.t.kind
    plNext(lx)
    let rhs = parseUnary(lx)
    case op
    of tkMul: result = node(pnkMul, result, rhs)
    of tkDiv: result = node(pnkDiv, result, rhs)
    of tkMod: result = node(pnkMod, result, rhs)
    else: discard

proc parseAdd(lx: var PlLexer): PlNode =
  result = parseMul(lx)
  while lx.t.kind in {tkAdd, tkSub}:
    let op = lx.t.kind
    plNext(lx)
    let rhs = parseMul(lx)
    if op == tkAdd: result = node(pnkAdd, result, rhs)
    else: result = node(pnkSub, result, rhs)

proc parseCmp(lx: var PlLexer): PlNode =
  result = parseAdd(lx)
  while lx.t.kind in {tkLt, tkLe, tkGt, tkGe}:
    let op = lx.t.kind
    plNext(lx)
    let rhs = parseAdd(lx)
    case op
    of tkLt: result = node(pnkLt, result, rhs)
    of tkLe: result = node(pnkLe, result, rhs)
    of tkGt: result = node(pnkGt, result, rhs)
    of tkGe: result = node(pnkGe, result, rhs)
    else: discard

proc parseEqNode(lx: var PlLexer): PlNode =
  result = parseCmp(lx)
  while lx.t.kind in {tkEq, tkNe}:
    let op = lx.t.kind
    plNext(lx)
    let rhs = parseCmp(lx)
    if op == tkEq: result = node(pnkEq, result, rhs)
    else: result = node(pnkNe, result, rhs)

proc parseAnd(lx: var PlLexer): PlNode =
  result = parseEqNode(lx)
  while lx.t.kind == tkAnd:
    plNext(lx)
    result = node(pnkAnd, result, parseEqNode(lx))

proc parseOr(lx: var PlLexer): PlNode =
  result = parseAnd(lx)
  while lx.t.kind == tkOr:
    plNext(lx)
    result = node(pnkOr, result, parseAnd(lx))

proc parseExpr(lx: var PlLexer): PlNode =
  result = parseOr(lx)
  if lx.t.kind == tkQ:
    plNext(lx)
    let yes = parseExpr(lx)
    if lx.t.kind == tkColon: plNext(lx)
    let no = parseExpr(lx)
    result = node(pnkTernary, result, yes, no)

proc eval(node: PlNode; n: int): int =
  if node.isNil: return 0
  case node.kind
  of pnkNum: node.num
  of pnkVarN: n
  of pnkNeg: -eval(node.a, n)
  of pnkNot: (if eval(node.a, n) == 0: 1 else: 0)
  of pnkMul: eval(node.a, n) * eval(node.b, n)
  of pnkDiv:
    let d = eval(node.b, n)
    if d == 0: 0 else: eval(node.a, n) div d
  of pnkMod:
    let d = eval(node.b, n)
    if d == 0: 0 else: eval(node.a, n) mod d
  of pnkAdd: eval(node.a, n) + eval(node.b, n)
  of pnkSub: eval(node.a, n) - eval(node.b, n)
  of pnkLt: (if eval(node.a, n) <  eval(node.b, n): 1 else: 0)
  of pnkLe: (if eval(node.a, n) <= eval(node.b, n): 1 else: 0)
  of pnkGt: (if eval(node.a, n) >  eval(node.b, n): 1 else: 0)
  of pnkGe: (if eval(node.a, n) >= eval(node.b, n): 1 else: 0)
  of pnkEq: (if eval(node.a, n) == eval(node.b, n): 1 else: 0)
  of pnkNe: (if eval(node.a, n) != eval(node.b, n): 1 else: 0)
  of pnkAnd: (if eval(node.a, n) != 0 and eval(node.b, n) != 0: 1 else: 0)
  of pnkOr: (if eval(node.a, n) != 0 or  eval(node.b, n) != 0: 1 else: 0)
  of pnkTernary:
    if eval(node.a, n) != 0: eval(node.b, n) else: eval(node.c, n)

proc parsePluralForms(headers: Table[string, string]): tuple[nplurals: int, exprRaw: string, ast: PlNode] =
  var np = 2
  var ex = "(n != 1)"

  # case-insensitive lookup
  var raw = ""
  if headers.hasKey("Plural-Forms"):
    raw = headers["Plural-Forms"]
  else:
    for k, v in headers.pairs:
      if k.toLowerAscii() == "plural-forms":
        raw = v
        break

  if raw.len > 0:
    # robust token scan: nplurals=<digits>
    var i = raw.find("nplurals=")
    if i >= 0:
      i += "nplurals=".len
      while i < raw.len and raw[i] in {' ', '\t'}: inc i
      var j = i
      while j < raw.len and raw[j] in {'0'..'9'}: inc j
      if j > i:
        try: np = parseInt(raw[i ..< j]) except: discard

    # robust token scan: plural=<expr up to ';'>
    i = raw.find("plural=")
    if i >= 0:
      i += "plural=".len
      while i < raw.len and raw[i] in {' ', '\t'}: inc i
      var j = i
      var depth = 0
      while j < raw.len:
        let c = raw[j]
        if c == '(':
          inc depth
        elif c == ')':
          if depth > 0: dec depth
        elif c == ';' and depth == 0:
          break
        inc j
      var expr = raw[i ..< j].strip()
      if expr.endsWith("\\n"): expr.setLen(expr.len - 2)
      expr = expr.strip()
      if expr.len > 0: ex = expr

  var lx = PlLexer(s: ex, i: 0)
  plNext(lx)
  let ast = parseExpr(lx)
  result = ((if np > 0: np else: 1), ex, ast)

proc headerEntryIndex*(cat: PoCatalog): int =
  ## Return index of the canonical PO header entry:
  ## msgid "" + msgstr[0] containing header lines.
  for i, e in cat.entries:
    if e.obsolete: continue
    if decodeField(cat, e.msgid) == "":
      for m in e.msgstr:
        if m.idx == 0:
          return i
  return -1

proc parsePoHeaders*(cat: PoCatalog): Table[string, string] =
  ## Parse PO headers from the header entry (if present).
  result = initTable[string, string]()
  let hi = headerEntryIndex(cat)
  if hi < 0: return
  let raw = decodeMsgStr(cat, cat.entries[hi], 0)
  result = parseHeadersBlock(raw)


proc compilePo*(cat: PoCatalog; skipFuzzy = true): PoCompiledCatalog =
  result.headers = initTable[string, string]()
  result.index = initTable[string, int]()
  result.messages = @[]

  let (dnp, dex, dast) = parsePluralForms(result.headers)
  result.nplurals = dnp
  result.pluralExprRaw = dex
  result.pluralAst = dast


  # Use parser-level header extraction
  result.headers = parsePoHeaders(cat)
  if result.headers.len > 0:
    let (np, ex, ast) = parsePluralForms(result.headers)
    result.nplurals = np
    result.pluralExprRaw = ex
    result.pluralAst = ast

  var observedMaxForm = 0

  for e in cat.entries:
    if e.obsolete: continue
    if skipFuzzy and isFuzzy(cat, e): continue

    let msgid = decodeField(cat, e.msgid)
    if msgid == "": continue

    let ctx = decodeField(cat, e.msgctxt)
    let pid = decodeField(cat, e.msgidPlural)

    var maxIdx = 0
    for m in e.msgstr:
      if m.idx > maxIdx: maxIdx = m.idx
    if maxIdx > observedMaxForm: observedMaxForm = maxIdx

    var forms = newSeq[string](max(maxIdx + 1, 1))
    for m in e.msgstr:
      if m.idx >= 0 and m.idx < forms.len:
        forms[m.idx] = decodeField(cat, m.value)

    let key = makeKey(ctx, msgid)
    let idx = result.messages.len
    result.index[key] = idx
    result.messages.add PoCompiledMessage(
      msgctxt: ctx,
      msgid: msgid,
      msgidPlural: pid,
      forms: forms
    )

  # fallback: if header is missing/bad, infer from observed plural slots
  let inferred = observedMaxForm + 1
  if inferred > result.nplurals:
    result.nplurals = inferred

proc pluralIndex*(cc: PoCompiledCatalog; n: int): int =
  if cc.nplurals <= 1: return 0
  var i = eval(cc.pluralAst, n)
  if i < 0: i = 0
  if i >= cc.nplurals: i = cc.nplurals - 1
  i

proc translate*(cc: PoCompiledCatalog; msgid: string; msgctxt = ""): string =
  let key = makeKey(msgctxt, msgid)
  if not cc.index.hasKey(key): return msgid
  let m = cc.messages[cc.index[key]]
  if m.forms.len == 0 or m.forms[0].len == 0: return msgid
  m.forms[0]

proc ntranslate*(cc: PoCompiledCatalog; singular, plural: string; n: int; msgctxt = ""): string =
  let key = makeKey(msgctxt, singular)
  if not cc.index.hasKey(key):
    return (if n == 1: singular else: plural)
  let m = cc.messages[cc.index[key]]
  let pi = pluralIndex(cc, n)
  if pi < m.forms.len and m.forms[pi].len > 0:
    return m.forms[pi]
  if n == 1: singular else: plural

proc writeMoFile*(cat: PoCompiledCatalog; path: string) =
  ## Write the compiled catalog to a GNU .mo file (little-endian, no hash table).
  var f = syncio.open(path, fmWrite)
  defer: f.close()
  proc writeU32Le(v: uint32) =
    var b: array[4, char]
    b[0] = char(v and 0xFF'u32)
    b[1] = char((v shr 8) and 0xFF'u32)
    b[2] = char((v shr 16) and 0xFF'u32)
    b[3] = char((v shr 24) and 0xFF'u32)
    discard f.writeBuffer(addr b[0], 4)

  type MoPair = tuple[orig: string, trans: string]
  var pairs: seq[MoPair] = @[]

  if cat.headers.len > 0:
    var hdr = ""
    for k, v in cat.headers.pairs:
      hdr.add(k & ": " & v & "\n")
    pairs.add((orig: "", trans: hdr))

  for m in cat.messages:
    var orig = if m.msgctxt.len > 0: m.msgctxt & "\x04" & m.msgid else: m.msgid
    if m.msgidPlural.len > 0:
      orig &= "\0" & m.msgidPlural
    pairs.add((orig: orig, trans: m.forms.join("\0")))

  proc lessBytes(a, b: string): bool =
    let lim = min(a.len, b.len)
    for i in 0 ..< lim:
      let ca = uint8(a[i])
      let cb = uint8(b[i])
      if ca < cb: return true
      if ca > cb: return false
    a.len < b.len

  for i in 1 ..< pairs.len:
    let x = pairs[i]
    var j = i
    while j > 0 and lessBytes(x.orig, pairs[j - 1].orig):
      pairs[j] = pairs[j - 1]
      dec j
    pairs[j] = x

  let n = pairs.len
  let headerSize = 7 * 4
  let offOrig = headerSize
  let offTrans = offOrig + n * 8
  let poolStart = offTrans + n * 8

  var origMeta: seq[(int, int)] = @[]
  var transMeta: seq[(int, int)] = @[]

  var pos = poolStart
  for p in pairs:
    origMeta.add((p.orig.len, pos))
    pos += p.orig.len

  for p in pairs:
    transMeta.add((p.trans.len, pos))
    pos += p.trans.len

  writeU32Le(0x950412DE'u32)
  writeU32Le(0'u32)
  writeU32Le(uint32(n))
  writeU32Le(uint32(offOrig))
  writeU32Le(uint32(offTrans))
  writeU32Le(0'u32)
  writeU32Le(0'u32)

  for (ln, off) in origMeta:
    writeU32Le(uint32(ln))
    writeU32Le(uint32(off))

  for (ln, off) in transMeta:
    writeU32Le(uint32(ln))
    writeU32Le(uint32(off))

  for p in pairs:
    f.write(p.orig)

  for p in pairs:
    f.write(p.trans)