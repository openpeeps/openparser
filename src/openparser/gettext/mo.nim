import std/[memfiles, tables, strutils]

type
  MoParseError* = object of CatchableError

  MoSpan* = object
    a*: int
    b*: int  # [a, b)

  MoMessage* = object
    msgctxt*: MoSpan
    msgid*: MoSpan
    msgidPlural*: MoSpan
    forms*: seq[MoSpan]

  MoCatalog* = ref object
    mf*: MemFile
    data*: ptr UncheckedArray[char]
    len*: int
    bigEndian*: bool
    revision*: uint32
    nStrings*: int
    offOrig*: int
    offTrans*: int
    nHash*: int
    offHash*: int
    messages*: seq[MoMessage]
    headers*: Table[string, string]
    index*: Table[string, int]

const
  MoMagicLE = 0x950412DE'u32
  MoMagicBE = 0xDE120495'u32
  CtxSep = '\x04'

proc fail(msg: string): ref MoParseError =
  newException(MoParseError, msg)

proc spanLen(s: MoSpan): int {.inline.} = s.b - s.a
proc isEmpty(s: MoSpan): bool {.inline.} = s.a >= s.b

proc toString*(cat: MoCatalog; s: MoSpan): string =
  result = newString(max(0, spanLen(s)))
  for i in 0 ..< result.len:
    result[i] = cat.data[s.a + i]

proc u32At(cat: MoCatalog; off: int; big: bool): uint32 =
  if off < 0 or off + 4 > cat.len:
    raise fail("invalid .mo: out-of-bounds u32 read")
  let b0 = uint32(uint8(cat.data[off + 0]))
  let b1 = uint32(uint8(cat.data[off + 1]))
  let b2 = uint32(uint8(cat.data[off + 2]))
  let b3 = uint32(uint8(cat.data[off + 3]))
  if big:
    (b0 shl 24) or (b1 shl 16) or (b2 shl 8) or b3
  else:
    b0 or (b1 shl 8) or (b2 shl 16) or (b3 shl 24)

proc findByte(cat: MoCatalog; s: MoSpan; c: char; start = 0): int =
  var i = s.a + start
  while i < s.b:
    if cat.data[i] == c: return i
    inc i
  -1

proc splitNul(cat: MoCatalog; s: MoSpan): seq[MoSpan] =
  result = @[]
  var p = s.a
  var i = s.a
  while i < s.b:
    if cat.data[i] == '\0':
      result.add MoSpan(a: p, b: i)
      p = i + 1
    inc i
  result.add MoSpan(a: p, b: s.b)

proc makeKey(ctx, id: string): string =
  if ctx.len == 0: id else: ctx & $CtxSep & id

proc parseHeadersBlock(s: string): Table[string, string] =
  result = initTable[string, string]()
  for line in s.splitLines():
    if line.len == 0: continue
    let p = line.find(':')
    if p <= 0: continue
    let k = line[0 ..< p].strip()
    let v = line[p + 1 .. ^1].strip()
    if k.len > 0: result[k] = v

proc parseOrig(cat: MoCatalog; s: MoSpan; msg: var MoMessage) =
  # orig format:
  #   msgid
  #   msgid\0msgid_plural
  #   msgctxt\x04msgid
  #   msgctxt\x04msgid\0msgid_plural
  msg.msgctxt = MoSpan(a: 0, b: 0)
  msg.msgid = s
  msg.msgidPlural = MoSpan(a: 0, b: 0)

  let ctxPos = findByte(cat, s, CtxSep)
  let nulPos = findByte(cat, s, '\0')

  if ctxPos >= 0 and (nulPos < 0 or ctxPos < nulPos):
    msg.msgctxt = MoSpan(a: s.a, b: ctxPos)
    if nulPos >= 0:
      msg.msgid = MoSpan(a: ctxPos + 1, b: nulPos)
      msg.msgidPlural = MoSpan(a: nulPos + 1, b: s.b)
    else:
      msg.msgid = MoSpan(a: ctxPos + 1, b: s.b)
  else:
    if nulPos >= 0:
      msg.msgid = MoSpan(a: s.a, b: nulPos)
      msg.msgidPlural = MoSpan(a: nulPos + 1, b: s.b)

proc openMoCatalog*(path: string): MoCatalog =
  ## Open and parse a GNU MO file. Throws MoParseError on failure.
  result = MoCatalog()
  result.mf = memfiles.open(path, mode = fmRead)
  result.data = cast[ptr UncheckedArray[char]](result.mf.mem)
  result.len = result.mf.size
  result.headers = initTable[string, string]()
  result.index = initTable[string, int]()
  result.messages = @[]

  # GNU MO header is 7 uint32 values
  if result.len < 28:
    raise fail("invalid .mo: too small")

  let magicRaw = u32At(result, 0, false)
  if magicRaw == MoMagicLE:
    result.bigEndian = false
  elif magicRaw == MoMagicBE:
    result.bigEndian = true
  else:
    raise fail("invalid .mo: bad magic")

  result.revision = u32At(result, 4, result.bigEndian)
  # GNU revision major in high 16 bits should be 0
  if (result.revision shr 16) != 0'u32:
    raise fail("invalid .mo: unsupported major revision")

  result.nStrings = int(u32At(result, 8, result.bigEndian))
  result.offOrig = int(u32At(result, 12, result.bigEndian))
  result.offTrans = int(u32At(result, 16, result.bigEndian))
  result.nHash = int(u32At(result, 20, result.bigEndian))
  result.offHash = int(u32At(result, 24, result.bigEndian))

  if result.nStrings < 0 or result.offOrig < 0 or result.offTrans < 0:
    raise fail("invalid .mo: negative table values")
  if result.offOrig + result.nStrings * 8 > result.len or
     result.offTrans + result.nStrings * 8 > result.len:
    raise fail("invalid .mo: table out of bounds")
  if result.nHash < 0 or result.offHash < 0:
    raise fail("invalid .mo: invalid hash table fields")
  if result.nHash > 0 and result.offHash + result.nHash * 4 > result.len:
    raise fail("invalid .mo: hash table out of bounds")

  result.messages.setLen(result.nStrings)

  for i in 0 ..< result.nStrings:
    let oLen = int(u32At(result, result.offOrig + i * 8 + 0, result.bigEndian))
    let oOff = int(u32At(result, result.offOrig + i * 8 + 4, result.bigEndian))
    let tLen = int(u32At(result, result.offTrans + i * 8 + 0, result.bigEndian))
    let tOff = int(u32At(result, result.offTrans + i * 8 + 4, result.bigEndian))

    if oOff < 0 or tOff < 0 or oLen < 0 or tLen < 0:
      raise fail("invalid .mo: negative string span")
    if oOff + oLen > result.len or tOff + tLen > result.len:
      raise fail("invalid .mo: string span out of bounds")

    let orig = MoSpan(a: oOff, b: oOff + oLen)
    let tr = MoSpan(a: tOff, b: tOff + tLen)

    var msg: MoMessage
    parseOrig(result, orig, msg)
    msg.forms = splitNul(result, tr)
    result.messages[i] = msg

    if isEmpty(msg.msgid):
      if msg.forms.len > 0:
        result.headers = parseHeadersBlock(toString(result, msg.forms[0]))
      continue

    let key = makeKey(toString(result, msg.msgctxt), toString(result, msg.msgid))
    result.index[key] = i

proc close*(cat: var MoCatalog) =
  if cat.mf.mem != nil:
    memfiles.close(cat.mf)
  cat.data = nil
  cat.len = 0
  cat.messages.setLen(0)
  cat.headers.clear()
  cat.index.clear()

proc translate*(cat: MoCatalog; msgid: string; msgctxt = ""): string =
  let key = makeKey(msgctxt, msgid)
  if not cat.index.hasKey(key):
    return msgid
  let m = cat.messages[cat.index[key]]
  if m.forms.len == 0:
    return msgid
  let v = toString(cat, m.forms[0])
  if v.len == 0: msgid else: v

proc form*(cat: MoCatalog; msgid: string; formIdx: int; msgctxt = ""): string =
  ## Raw form access (plural index chosen by caller).
  let key = makeKey(msgctxt, msgid)
  if not cat.index.hasKey(key):
    return msgid
  let m = cat.messages[cat.index[key]]
  if formIdx < 0 or formIdx >= m.forms.len:
    return msgid
  toString(cat, m.forms[formIdx])

#
# MO Compiler
#
type
  McNodeKind = enum
    mnNum, mnVarN, mnNeg, mnNot,
    mnMul, mnDiv, mnMod, mnAdd, mnSub,
    mnLt, mnLe, mnGt, mnGe, mnEq, mnNe, mnAnd, mnOr, mnTernary

  McNode = ref object
    k: McNodeKind
    n: int
    a, b, c: McNode

  MoCompiledMessage* = object
    msgctxt*: string
    msgid*: string
    msgidPlural*: string
    forms*: seq[string]

  MoCompiledCatalog* = object
    headers*: Table[string, string]
    nplurals*: int
    pluralExprRaw*: string
    messages*: seq[MoCompiledMessage]
    index*: Table[string, int]
    pluralAst: McNode

type
  Tk = enum
    tEof, tNum, tN, tLPar, tRPar, tQ, tColon, tOr, tAnd,
    tEq, tNe, tLt, tLe, tGt, tGe, tAdd, tSub, tMul, tDiv, tMod, tNot

  Tok = object
    k: Tk
    v: int

  Lexer = object
    s: string
    i: int
    t: Tok

proc nd(k: McNodeKind; a: McNode = nil; b: McNode = nil; c: McNode = nil; n = 0): McNode =
  McNode(k: k, a: a, b: b, c: c, n: n)

proc next(lx: var Lexer)
proc expr(lx: var Lexer): McNode

proc skipWs(lx: var Lexer) =
  while lx.i < lx.s.len and lx.s[lx.i] in {' ', '\t', '\r', '\n'}: inc lx.i

proc next(lx: var Lexer) =
  skipWs(lx)
  if lx.i >= lx.s.len: lx.t = Tok(k: tEof); return
  let c = lx.s[lx.i]
  if c in {'0'..'9'}:
    var n = 0
    while lx.i < lx.s.len and lx.s[lx.i] in {'0'..'9'}:
      n = n * 10 + (ord(lx.s[lx.i]) - ord('0')); inc lx.i
    lx.t = Tok(k: tNum, v: n); return
  if c == 'n': inc lx.i; lx.t = Tok(k: tN); return

  template two(ch: char; yes, no: Tk) =
    if lx.i + 1 < lx.s.len and lx.s[lx.i + 1] == ch:
      lx.i += 2; lx.t = Tok(k: yes)
    else:
      inc lx.i; lx.t = Tok(k: no)
    return

  case c
  of '(':
    inc lx.i; lx.t = Tok(k: tLPar)
  of ')':
    inc lx.i; lx.t = Tok(k: tRPar)
  of '?':
    inc lx.i; lx.t = Tok(k: tQ)
  of ':':
    inc lx.i; lx.t = Tok(k: tColon)
  of '|': two('|', tOr, tEof)
  of '&': two('&', tAnd, tEof)
  of '=': two('=', tEq, tEof)
  of '!': two('=', tNe, tNot)
  of '<': two('=', tLe, tLt)
  of '>': two('=', tGe, tGt)
  of '+': inc lx.i; lx.t = Tok(k: tAdd)
  of '-': inc lx.i; lx.t = Tok(k: tSub)
  of '*': inc lx.i; lx.t = Tok(k: tMul)
  of '/': inc lx.i; lx.t = Tok(k: tDiv)
  of '%': inc lx.i; lx.t = Tok(k: tMod)
  else:
    inc lx.i; lx.t = Tok(k: tEof)

proc prim(lx: var Lexer): McNode =
  case lx.t.k
  of tNum: result = nd(mnNum, n = lx.t.v); next(lx)
  of tN: result = nd(mnVarN); next(lx)
  of tLPar:
    next(lx); result = expr(lx)
    if lx.t.k == tRPar: next(lx)
  else:
    result = nd(mnNum, n = 0)

proc unary(lx: var Lexer): McNode =
  case lx.t.k
  of tSub: next(lx); result = nd(mnNeg, unary(lx))
  of tNot: next(lx); result = nd(mnNot, unary(lx))
  else: result = prim(lx)

proc mul(lx: var Lexer): McNode =
  result = unary(lx)
  while lx.t.k in {tMul, tDiv, tMod}:
    let op = lx.t.k; next(lx)
    let r = unary(lx)
    case op
    of tMul: result = nd(mnMul, result, r)
    of tDiv: result = nd(mnDiv, result, r)
    of tMod: result = nd(mnMod, result, r)
    else: discard

proc add(lx: var Lexer): McNode =
  result = mul(lx)
  while lx.t.k in {tAdd, tSub}:
    let op = lx.t.k; next(lx)
    let r = mul(lx)
    if op == tAdd: result = nd(mnAdd, result, r)
    else: result = nd(mnSub, result, r)

proc cmp(lx: var Lexer): McNode =
  result = add(lx)
  while lx.t.k in {tLt, tLe, tGt, tGe}:
    let op = lx.t.k; next(lx)
    let r = add(lx)
    case op
    of tLt: result = nd(mnLt, result, r)
    of tLe: result = nd(mnLe, result, r)
    of tGt: result = nd(mnGt, result, r)
    of tGe: result = nd(mnGe, result, r)
    else: discard

proc eqn(lx: var Lexer): McNode =
  result = cmp(lx)
  while lx.t.k in {tEq, tNe}:
    let op = lx.t.k; next(lx)
    let r = cmp(lx)
    if op == tEq: result = nd(mnEq, result, r)
    else: result = nd(mnNe, result, r)

proc land(lx: var Lexer): McNode =
  result = eqn(lx)
  while lx.t.k == tAnd:
    next(lx); result = nd(mnAnd, result, eqn(lx))

proc lor(lx: var Lexer): McNode =
  result = land(lx)
  while lx.t.k == tOr:
    next(lx); result = nd(mnOr, result, land(lx))

proc expr(lx: var Lexer): McNode =
  result = lor(lx)
  if lx.t.k == tQ:
    next(lx)
    let y = expr(lx)
    if lx.t.k == tColon: next(lx)
    let n = expr(lx)
    result = nd(mnTernary, result, y, n)

proc eval(n: McNode; x: int): int =
  if n.isNil: return 0
  case n.k
  of mnNum: n.n
  of mnVarN: x
  of mnNeg: -eval(n.a, x)
  of mnNot: (if eval(n.a, x) == 0: 1 else: 0)
  of mnMul: eval(n.a, x) * eval(n.b, x)
  of mnDiv:
    let d = eval(n.b, x); if d == 0: 0 else: eval(n.a, x) div d
  of mnMod:
    let d = eval(n.b, x); if d == 0: 0 else: eval(n.a, x) mod d
  of mnAdd: eval(n.a, x) + eval(n.b, x)
  of mnSub: eval(n.a, x) - eval(n.b, x)
  of mnLt: (if eval(n.a, x) < eval(n.b, x): 1 else: 0)
  of mnLe: (if eval(n.a, x) <= eval(n.b, x): 1 else: 0)
  of mnGt: (if eval(n.a, x) > eval(n.b, x): 1 else: 0)
  of mnGe: (if eval(n.a, x) >= eval(n.b, x): 1 else: 0)
  of mnEq: (if eval(n.a, x) == eval(n.b, x): 1 else: 0)
  of mnNe: (if eval(n.a, x) != eval(n.b, x): 1 else: 0)
  of mnAnd: (if eval(n.a, x) != 0 and eval(n.b, x) != 0: 1 else: 0)
  of mnOr: (if eval(n.a, x) != 0 or eval(n.b, x) != 0: 1 else: 0)
  of mnTernary: (if eval(n.a, x) != 0: eval(n.b, x) else: eval(n.c, x))

proc parsePluralForms(headers: Table[string, string]): tuple[np: int, ex: string, ast: McNode] =
  var np = 2
  var ex = "(n != 1)"
  var raw = ""

  if headers.hasKey("Plural-Forms"): raw = headers["Plural-Forms"]
  else:
    for k, v in headers.pairs:
      if k.toLowerAscii() == "plural-forms": raw = v; break

  if raw.len > 0:
    var p = raw.find("nplurals=")
    if p >= 0:
      p += "nplurals=".len
      while p < raw.len and raw[p] in {' ', '\t'}: inc p
      var q = p
      while q < raw.len and raw[q] in {'0'..'9'}: inc q
      if q > p:
        try: np = parseInt(raw[p ..< q]) except: discard

    p = raw.find("plural=")
    if p >= 0:
      p += "plural=".len
      while p < raw.len and raw[p] in {' ', '\t'}: inc p
      var q = p
      var depth = 0
      while q < raw.len:
        let c = raw[q]
        if c == '(':
          inc depth
        elif c == ')' and depth > 0:
          dec depth
        elif c == ';' and depth == 0:
          break
        inc q
      let e = raw[p ..< q].strip()
      if e.len > 0: ex = e

  var lx = Lexer(s: ex, i: 0)
  next(lx)
  result = ((if np > 0: np else: 1), ex, expr(lx))

proc compileMo*(cat: MoCatalog): MoCompiledCatalog =
  result.headers = cat.headers
  result.index = initTable[string, int]()
  result.messages = @[]

  let (np, ex, ast) = parsePluralForms(result.headers)
  result.nplurals = np
  result.pluralExprRaw = ex
  result.pluralAst = ast

  var observedMax = 0

  for m in cat.messages:
    let id = toString(cat, m.msgid)
    if id.len == 0: continue # header
    let ctx = toString(cat, m.msgctxt)
    let pid = toString(cat, m.msgidPlural)

    var forms: seq[string] = @[]
    for s in m.forms: forms.add toString(cat, s)
    if forms.len > 0 and forms.len - 1 > observedMax:
      observedMax = forms.len - 1

    let k = makeKey(ctx, id)
    result.index[k] = result.messages.len
    result.messages.add MoCompiledMessage(msgctxt: ctx, msgid: id, msgidPlural: pid, forms: forms)

  let inferred = observedMax + 1
  if inferred > result.nplurals:
    result.nplurals = inferred

proc pluralIndex*(cc: MoCompiledCatalog; n: int): int =
  if cc.nplurals <= 1: return 0
  var i = eval(cc.pluralAst, n)
  if i < 0: i = 0
  if i >= cc.nplurals: i = cc.nplurals - 1
  i

proc translate*(cc: MoCompiledCatalog; msgid: string; msgctxt = ""): string =
  let k = makeKey(msgctxt, msgid)
  if not cc.index.hasKey(k): return msgid
  let m = cc.messages[cc.index[k]]
  if m.forms.len == 0 or m.forms[0].len == 0: return msgid
  m.forms[0]

proc ntranslate*(cc: MoCompiledCatalog; singular, plural: string; n: int; msgctxt = ""): string =
  let k = makeKey(msgctxt, singular)
  if not cc.index.hasKey(k):
    return (if n == 1: singular else: plural)
  let m = cc.messages[cc.index[k]]
  let pi = pluralIndex(cc, n)
  if pi >= 0 and pi < m.forms.len and m.forms[pi].len > 0:
    return m.forms[pi]
  if n == 1: singular else: plural