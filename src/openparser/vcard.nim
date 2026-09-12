# A collection of tiny parsers and dumpers
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/openparser

## RFC 6350 (vCard 4.0) + RFC 2426 (vCard 3.0) reader and writer.
##
## Parses both 3.0 and 4.0 input, emits 4.0 by default (downgrade to 3.0
## via `VCardOptions`). Line unfolding/folding at 75 octets (UTF-8 safe),
## TEXT escaping, caret unescaping for params (RFC 6868), groups
## (`item1.TEL`), structured `N`/`ADR`, `TYPE`/`PREF` handling for both
## versions, `ENCODING=b` (v3) to `data:` URI (v4) upgrade, and
## `extraProps` fallback for `X-` and unknown properties.
##
## ```nim
## import openparser/vcard
## let cards = parseVCards(readFile("contacts.vcf"))
## echo cards[0].fn
## for t in cards[0].tels: echo t.value, " ", t.types
## writeFile("out.vcf", toVCards(cards))
## ```

import std/[strutils, options, base64]

type
  OpenParserVCardError* = object of CatchableError

  VCardVersion* = enum
    vv30 = "3.0"
    vv40 = "4.0"

  VCardOptions* = object
    ## `targetVersion` controls `toVCard`/`toVCards` emission.
    ## Parsing always accepts both 3.0 and 4.0.
    targetVersion*: VCardVersion

  VCardParam* = object
    name*: string
    values*: seq[string]

  VCardProp* = object
    group*: string   ## e.g. "item1" in "item1.TEL", else ""
    name*: string    ## upper-cased on parse? preserved as-is, compared case-insensitively
    params*: seq[VCardParam]
    value*: string   ## raw value (still escaped for TEXT types)

  VCardName* = object
    family*, given*, additional*, prefix*, suffix*: string

  VCardAdr* = object
    poBox*, ext*, street*, locality*, region*, postal*, country*: string
    label*: Option[string]
    geo*: Option[string]
    tz*: Option[string]
    altId*: Option[string]
    pref*: Option[int]
    types*: seq[string]
    params*: seq[VCardParam]

  VCardTel* = object
    value*: string
    types*: seq[string]
    pref*: Option[int]
    altId*: Option[string]
    label*: Option[string]
    params*: seq[VCardParam]

  VCardEmail* = object
    value*: string
    types*: seq[string]
    pref*: Option[int]
    altId*: Option[string]
    params*: seq[VCardParam]

  VCardImpp* = object
    value*: string
    types*: seq[string]
    pref*: Option[int]
    altId*: Option[string]
    params*: seq[VCardParam]

  VCardLang* = object
    value*: string
    types*: seq[string]
    pref*: Option[int]
    altId*: Option[string]
    params*: seq[VCardParam]

  VCardUrl* = object
    value*: string
    types*: seq[string]
    pref*: Option[int]
    altId*: Option[string]
    params*: seq[VCardParam]
    label*: Option[string]

  VCardPhoto* = object
    ## v4: `value` is a URI (often `data:`). v3 `ENCODING=b` inline
    ## base64 is upgraded to a `data:` URI on parse; `wasInlineB`
    ## remembers that so a 3.0 downgrade can restore inline form.
    value*: string
    mediaType*: Option[string]
    types*: seq[string]
    pref*: Option[int]
    altId*: Option[string]
    params*: seq[VCardParam]
    wasInlineB*: bool

  VCardOrg* = object
    name*: string
    units*: seq[string]

  VCardRelated* = object
    value*: string
    relType*: Option[string]  ## RELATED `TYPE=` (e.g. friend, spouse)
    types*: seq[string]
    pref*: Option[int]
    altId*: Option[string]
    params*: seq[VCardParam]

  VCardMember* = object
    value*: string
    pref*: Option[int]
    altId*: Option[string]
    params*: seq[VCardParam]

  VCardGender* = object
    sex*: string       ## M, F, O, N, U (or empty)
    identity*: string  ## free text after ';'

  VCardDateProp* = object
    ## BDAY / ANNIVERSARY. `value` is the raw (unescaped) value,
    ## `valueType` is the VALUE param or "" when absent.
    value*: string
    valueType*: string
    altId*: Option[string]
    calscale*: Option[string]
    params*: seq[VCardParam]

  VCardClientPid* = object
    pid*: int
    uri*: string

  VCardKind* = enum
    vkIndividual, vkGroup, vkOrg, vkLocation, vkApplication, vkCustom

  VCardKindValue* = object
    ## Typed KIND (RFC 6350 §6.1.4). The five registered tokens map to
    ## the enum; `x-` names and future iana-tokens land in `vkCustom`
    ## with the raw token preserved in `custom` for round-trip fidelity.
    case kind*: VCardKind
    of vkCustom: custom*: string
    else: discard

  VCard* = ref object
    version*: VCardVersion
    fn*: string
    n*: Option[VCardName]
    nicknames*: seq[string]
    photos*: seq[VCardPhoto]
    bday*: Option[VCardDateProp]
    anniversary*: Option[VCardDateProp]
    gender*: Option[VCardGender]
    adrs*: seq[VCardAdr]
    tels*: seq[VCardTel]
    emails*: seq[VCardEmail]
    impps*: seq[VCardImpp]
    langs*: seq[VCardLang]
    tz*: Option[string]
    geo*: Option[string]
    title*: Option[string]
    role*: Option[string]
    logo*: Option[string]
    org*: Option[VCardOrg]
    members*: seq[VCardMember]
    related*: seq[VCardRelated]
    categories*: seq[string]
    note*: Option[string]
    prodId*: Option[string]
    rev*: Option[string]
    sortString*: Option[string]
    sound*: Option[string]
    uid*: Option[string]
    kind*: Option[VCardKindValue]  ## KIND: individual|group|org|location|application|x-...
    clientPidMaps*: seq[VCardClientPid]
    urls*: seq[VCardUrl]
    key*: Option[string]
    fbUrl*: Option[string]
    calAdrUri*: Option[string]
    calUri*: Option[string]
    xml*: seq[string]
    extraProps*: seq[VCardProp]

const VCardCrlf* = "\r\n"

proc defaultVCardOptions*(): VCardOptions = VCardOptions(targetVersion: vv40)

# ---------------------------------------------------------------------------
# helpers

proc norm*(s: string): string {.inline.} = s.toUpperAscii()

proc failVCard*(lineNo: int, lineText, msg: string) {.noreturn.} =
  raise newException(OpenParserVCardError,
    "\n" & lineText & "\n^\nError (line " & $lineNo & ") " & msg)

proc vcardError*(msg: string) {.noreturn.} =
  raise newException(OpenParserVCardError, msg)

proc getParam*(prop: VCardProp, name: string): Option[VCardParam] =
  let n = norm(name)
  for p in prop.params:
    if norm(p.name) == n: return some(p)
  none(VCardParam)

proc hasParam*(prop: VCardProp, name: string): bool =
  getParam(prop, name).isSome

proc paramFirst*(prop: VCardProp, name: string): Option[string] =
  let o = getParam(prop, name)
  if o.isSome and o.get.values.len > 0: some(o.get.values[0])
  else: none(string)

proc paramAll*(prop: VCardProp, name: string): seq[string] =
  ## Merges repeated params (Apple emits `;type=CELL;type=VOICE`).
  let n = norm(name)
  for p in prop.params:
    if norm(p.name) == n:
      result.add(p.values)

# TEXT codecs ---------------------------------------------------------------

proc unescapeVCardText*(s: string): string =
  ## TEXT unescape: `\\n/\\N -> LF`, `\\, \\; \\\\` literals.
  ## `\\r` is not standard; map to LF for leniency.
  result = newStringOfCap(s.len)
  var i = 0
  while i < s.len:
    if s[i] == '\\' and i + 1 < s.len:
      case s[i+1]
      of 'n', 'N': result.add('\n'); i += 2
      of 'r', 'R': result.add('\n'); i += 2
      of '\\': result.add('\\'); i += 2
      of ';': result.add(';'); i += 2
      of ',': result.add(','); i += 2
      else: result.add(s[i+1]); i += 2
    else:
      result.add(s[i]); inc i

proc escapeVCardText*(s: string): string =
  result = newStringOfCap(s.len + 8)
  for c in s:
    case c
    of '\\': result.add("\\\\")
    of ';': result.add("\\;")
    of ',': result.add("\\,")
    of '\n': result.add("\\n")
    of '\r': discard
    else: result.add(c)

proc splitUnescaped*(s: string, sep: char): seq[string] =
  ## Split on unescaped `sep`, then unescape each part.
  result = @[]
  var cur = newStringOfCap(32)
  var i = 0
  while i < s.len:
    if s[i] == '\\' and i + 1 < s.len:
      cur.add(s[i]); cur.add(s[i+1]); i += 2
    elif s[i] == sep:
      result.add(unescapeVCardText(cur)); cur.setLen(0); inc i
    else:
      cur.add(s[i]); inc i
  result.add(unescapeVCardText(cur))

proc splitEscapedComma*(s: string): seq[string] {.inline.} =
  splitUnescaped(s, ',')

proc splitEscapedSemi*(s: string): seq[string] {.inline.} =
  splitUnescaped(s, ';')

proc joinEscapedComma*(items: seq[string]): string =
  result = ""
  for i, it in items:
    if i > 0: result.add(',')
    result.add(escapeVCardText(it))

proc joinEscapedSemi*(items: seq[string]): string =
  result = ""
  for i, it in items:
    if i > 0: result.add(';')
    result.add(escapeVCardText(it))

# RFC 6868 caret handling for parameter values ------------------------------

proc unescapeParamValue*(s: string): string =
  result = newStringOfCap(s.len)
  var i = 0
  while i < s.len:
    if s[i] == '^' and i + 1 < s.len:
      case s[i+1]
      of 'n', 'N': result.add('\n'); i += 2
      of '\'': result.add('\''); i += 2
      of '^': result.add('^'); i += 2
      else: result.add('^'); inc i
    else:
      result.add(s[i]); inc i

proc escapeParamValue*(s: string): string =
  result = newStringOfCap(s.len)
  for c in s:
    case c
    of '^': result.add("^^")
    of '\n': result.add("^n")
    of '\'': result.add("^'")
    else: result.add(c)

# DATE / TIME / TIMESTAMP / UTC-OFFSET validators ---------------------------

proc isDigits(s: string): bool =
  if s.len == 0: return false
  for c in s:
    if c notin {'0'..'9'}: return false
  true

proc validDatePart(y, m, d: string): bool =
  if y.len != 4 or m.len != 2 or d.len != 2: return false
  if not (isDigits(y) and isDigits(m) and isDigits(d)): return false
  let mi = parseInt(m); let di = parseInt(d)
  mi >= 1 and mi <= 12 and di >= 1 and di <= 31

proc isVCardDate*(s: string): bool =
  ## YYYYMMDD | YYYY-MM-DD | --MMDD | ---DD
  if s.len == 8 and isDigits(s): return validDatePart(s[0..3], s[4..5], s[6..7])
  if s.len == 10 and s[4] == '-' and s[7] == '-':
    return validDatePart(s[0..3], s[5..6], s[8..9])
  if s.len == 6 and s[0] == '-' and s[1] == '-':
    let mi = s[2..3]; let di = s[4..5]
    if not (isDigits(mi) and isDigits(di)): return false
    parseInt(mi) in 1..12 and parseInt(di) in 1..31
  elif s.len == 5 and s[0] == '-' and s[1] == '-' and s[2] == '-':
    isDigits(s[3..4]) and parseInt(s[3..4]) in 1..31
  else: false

proc isVCardTime*(s: string): bool =
  ## HHMMSS | HH-MM-SS, each optionally followed by Z.
  var v = s
  if v.endsWith("Z"): v = v[0..^2]
  if v.len == 6 and isDigits(v):
    parseInt(v[0..1]) <= 23 and parseInt(v[2..3]) <= 59 and parseInt(v[4..5]) <= 60
  elif v.len == 8 and v[2] == '-' and v[5] == '-':
    isDigits(v[0..1]) and isDigits(v[3..4]) and isDigits(v[6..7]) and
      parseInt(v[0..1]) <= 23 and parseInt(v[3..4]) <= 59 and parseInt(v[6..7]) <= 60
  else: false

proc isVCardDateTime*(s: string): bool =
  var v = s
  if v.endsWith("Z"): v = v[0..^2]
  let tPos = v.find('T')
  if tPos < 0: return false
  let dp = v[0..<tPos]; let tp = v[tPos+1..^1]
  if dp.len == 0 or tp.len == 0: return false
  # date part may be basic YYYYMMDD or extended YYYY-MM-DD
  let dateOk =
    if dp.len == 8 and isDigits(dp): validDatePart(dp[0..3], dp[4..5], dp[6..7])
    elif dp.len == 10 and dp[4] == '-' and dp[7] == '-':
      validDatePart(dp[0..3], dp[5..6], dp[8..9])
    else: false
  dateOk and isVCardTime(tp)

proc isVCardTimestamp*(s: string): bool =
  ## RFC 6350 TIMESTAMP is UTC: YYYYMMDDTHHMMSSZ (hyphens allowed).
  if not s.endsWith("Z"): return false
  isVCardDateTime(s)

proc isVCardUtcOffset*(s: string): bool =
  ## [+/-]HHMM[SS] | [+/-]HH:MM[:SS]
  if s.len == 0 or s[0] notin {'+', '-'}: return false
  let v = s[1..^1]
  if v.len == 4 and isDigits(v):
    parseInt(v[0..1]) <= 23 and parseInt(v[2..3]) <= 59
  elif v.len == 6 and isDigits(v):
    parseInt(v[0..1]) <= 23 and parseInt(v[2..3]) <= 59 and parseInt(v[4..5]) <= 60
  elif v.len == 5 and v[2] == ':' and isDigits(v[0..1]) and isDigits(v[3..4]):
    parseInt(v[0..1]) <= 23 and parseInt(v[3..4]) <= 59
  elif v.len == 8 and v[2] == ':' and v[5] == ':' and
      isDigits(v[0..1]) and isDigits(v[3..4]) and isDigits(v[6..7]):
    parseInt(v[0..1]) <= 23 and parseInt(v[3..4]) <= 59 and parseInt(v[6..7]) <= 60
  else: false

proc validateVCardDateProp*(prop: VCardProp, raw: string) =
  ## Lenient validator for BDAY/ANNIVERSARY/REV: raises only on
  ## clearly contradictory VALUE types.
  let vt = norm(paramFirst(prop, "VALUE").get(""))
  case vt
  of "", "UNKNOWN": discard
  of "DATE":
    if not isVCardDate(raw): vcardError("Invalid DATE value: " & raw)
  of "TIME":
    if not isVCardTime(raw): vcardError("Invalid TIME value: " & raw)
  of "DATE-TIME":
    if not isVCardDateTime(raw): vcardError("Invalid DATE-TIME value: " & raw)
  of "DATE-AND-OR-TIME":
    if not (isVCardDate(raw) or isVCardTime(raw) or isVCardDateTime(raw)):
      vcardError("Invalid DATE-AND-OR-TIME value: " & raw)
  of "TIMESTAMP":
    if not isVCardTimestamp(raw): vcardError("Invalid TIMESTAMP value: " & raw)
  of "TEXT", "URI": discard
  else: discard # forward-compatible VALUE types pass through

# content-line <-> VCardProp -----------------------------------------------

proc needsParamQuote(v: string): bool =
  for c in v:
    if c in {',', ';', ':', '"', ' ', '\n'}: return true
  false

proc parseContentLine*(lineNo: int, text: string): VCardProp =
  ## ` [group "."] name *(";" param) ":" value`.
  ## Group and name are ASCII alnum + `-`; param values may be quoted
  ## and comma-separated; `^`-escapes are decoded per value.
  var i = 0
  var nameEnd = -1
  var inQuote = false
  while i < text.len:
    let c = text[i]
    if c == '"': inQuote = not inQuote
    elif not inQuote and (c == ';' or c == ':'):
      nameEnd = i; break
    inc i
  if nameEnd < 0:
    failVCard(lineNo, text, "Missing ':' in content line")
  var fullName = text[0..<nameEnd].strip()
  if fullName.len == 0:
    failVCard(lineNo, text, "Empty property name")
  result.group = ""
  result.name = fullName
  let dotPos = fullName.find('.')
  if dotPos >= 0:
    result.group = fullName[0..<dotPos]
    result.name = fullName[dotPos+1..^1]
    if result.group.len == 0 or result.name.len == 0:
      failVCard(lineNo, text, "Invalid group prefix in: " & fullName)
    for c in result.group:
      if c notin {'A'..'Z', 'a'..'z', '0'..'9', '-', '_'}:
        failVCard(lineNo, text, "Invalid group name: " & result.group)
  if result.name.len == 0:
    failVCard(lineNo, text, "Empty property name")
  i = nameEnd
  result.params = @[]
  while i < text.len and text[i] == ';':
    inc i
    let pStart = i
    var eqPos = -1
    inQuote = false
    while i < text.len:
      if text[i] == '"': inQuote = not inQuote
      elif not inQuote and text[i] == '=': eqPos = i; break
      elif not inQuote and text[i] == ':': break
      inc i
    if eqPos < 0:
      failVCard(lineNo, text, "Invalid param (missing '=')")
    let pName = text[pStart..<eqPos].strip()
    if pName.len == 0: failVCard(lineNo, text, "Empty param name")
    i = eqPos + 1
    var curVals: seq[string] = @[]
    var buf = newStringOfCap(16)
    var pos = i
    while pos < text.len:
      let c = text[pos]
      if c == '"':
        # quoted chunk: collect verbatim until closing quote
        inc pos
        var qb = newStringOfCap(16)
        var closed = false
        while pos < text.len:
          if text[pos] == '"': closed = true; inc pos; break
          qb.add(text[pos]); inc pos
        if not closed: failVCard(lineNo, text, "Unterminated quoted param value")
        curVals.add(unescapeParamValue(qb))
        buf.setLen(0)
        if pos < text.len and text[pos] == ',':
          inc pos; continue
        elif pos < text.len and text[pos] in {';', ':'}:
          break
        elif pos >= text.len: break
        else: failVCard(lineNo, text, "Unexpected char after quoted param")
      elif c == ',':
        curVals.add(unescapeParamValue(buf)); buf.setLen(0); inc pos
      elif c in {';', ':'}:
        break
      else:
        buf.add(c); inc pos
    if buf.len > 0 or curVals.len == 0:
      if buf.len > 0: curVals.add(unescapeParamValue(buf))
      elif curVals.len == 0: curVals.add("")
    result.params.add(VCardParam(name: pName, values: curVals))
    i = pos
    if i < text.len and text[i] == ';': continue
    elif i < text.len and text[i] == ':': break
    else: break
  if i >= text.len or text[i] != ':':
    failVCard(lineNo, text, "Missing ':' after params")
  inc i
  result.value = if i < text.len: text[i..^1] else: ""

proc propLine*(prop: VCardProp): string =
  result = ""
  if prop.group.len > 0:
    result.add(prop.group)
    result.add('.')
  result.add(prop.name)
  for p in prop.params:
    result.add(';')
    result.add(p.name)
    result.add('=')
    for vi, v in p.values:
      if vi > 0: result.add(',')
      let ev = escapeParamValue(v)
      if needsParamQuote(v):
        result.add('"'); result.add(ev); result.add('"')
      else: result.add(ev)
  result.add(':')
  result.add(prop.value)

# line unfolding + logical lines -------------------------------------------

type LLine = object
  no*: int
  text*: string

proc unfoldLines*(input: string): seq[LLine] =
  ## RFC 6350 3.2: folded as CRLF + single WSP. Accept CRLF or LF.
  var physical: seq[tuple[no: int, txt: string]] = @[]
  var start = 0
  var lno = 1
  var i = 0
  while i <= input.len:
    var eol = -1
    if i < input.len and input[i] == '\r' and i + 1 < input.len and input[i+1] == '\n':
      eol = i
    elif i < input.len and input[i] == '\n':
      eol = i
    elif i == input.len:
      eol = i
    if eol >= 0:
      let line = if eol > start: input[start..<eol] else: ""
      physical.add((lno, line))
      if eol < input.len and input[eol] == '\r': i = eol + 2
      elif eol < input.len: i = eol + 1
      else: i = input.len + 1
      start = i
      inc lno
    else: inc i
  result = @[]
  var curNo = 0
  var curText = ""
  var haveCur = false
  for (no, txt) in physical:
    if txt.len == 0 and not haveCur and result.len == 0:
      continue # skip leading blanks, lenient
    if txt.len > 0 and txt[0] in {' ', '\t'} and haveCur:
      curText.add(txt[1..^1])
    else:
      if haveCur:
        result.add(LLine(no: curNo, text: curText))
      curNo = no
      curText = txt
      haveCur = true
  if haveCur:
    result.add(LLine(no: curNo, text: curText))

# folding on write ----------------------------------------------------------

proc foldLineRaw(line: string): string =
  const MaxOctets = 75
  if line.len <= MaxOctets: return line
  var chunks: seq[string] = @[]
  var idx = 0
  var first = true
  while idx < line.len:
    let budget = if first: MaxOctets else: MaxOctets - 1
    var take = min(budget, line.len - idx)
    while take > 0 and idx + take < line.len and
        (ord(line[idx+take]) and 0xC0) == 0x80:
      dec take
    if take == 0:
      var j = idx + 1
      while j < line.len and (ord(line[j]) and 0xC0) == 0x80: inc j
      take = j - idx
    chunks.add(line[idx..<idx+take])
    idx += take
    first = false
  result = chunks[0]
  for k in 1..<chunks.len:
    result.add(VCardCrlf & " " & chunks[k])

# typed builders ------------------------------------------------------------

proc parsePref(prop: VCardProp): Option[int] =
  let o = paramFirst(prop, "PREF")
  if o.isNone: return none(int)
  let v = o.get.strip()
  # v4: 1..100 ; be lenient with bare "PREF" encoded as "1"?
  try:
    let n = parseInt(v)
    if n < 1 or n > 100: vcardError("Invalid PREF value (want 1..100): " & v)
    some(n)
  except ValueError:
    # v3 uses TYPE=PREF without PREF param; PREF=yes seen in the wild
    if norm(v) in ["YES", "TRUE", "PREF"]: some(1)
    else: vcardError("Invalid PREF value: " & v)

proc extractTypes(prop: VCardProp): seq[string] =
  ## TYPE param values (upper-cased compare, original case kept).
  ## A bare `TYPE=PREF` also implies pref=1.
  result = paramAll(prop, "TYPE")

proc prefFromTypes(types: seq[string]): Option[int] =
  for t in types:
    if norm(t) == "PREF": return some(1)
  none(int)

proc optUnescapeLabel(o: Option[string]): Option[string] =
  if o.isSome: some(unescapeParamValue(o.get))
  else: none(string)

proc optNorm(o: Option[string]): Option[string] =
  if o.isSome: some(norm(o.get))
  else: none(string)

proc buildTel(p: VCardProp): VCardTel =
  result.value = p.value
  result.types = extractTypes(p)
  result.pref = parsePref(p)
  if result.pref.isNone: result.pref = prefFromTypes(result.types)
  result.altId = paramFirst(p, "ALTID")
  result.label = optUnescapeLabel(paramFirst(p, "LABEL"))
  result.params = p.params

proc buildEmail(p: VCardProp): VCardEmail =
  result.value = p.value
  result.types = extractTypes(p)
  result.pref = parsePref(p)
  if result.pref.isNone: result.pref = prefFromTypes(result.types)
  result.altId = paramFirst(p, "ALTID")
  result.params = p.params

proc buildImpp(p: VCardProp): VCardImpp =
  result.value = p.value
  result.types = extractTypes(p)
  result.pref = parsePref(p)
  if result.pref.isNone: result.pref = prefFromTypes(result.types)
  result.altId = paramFirst(p, "ALTID")
  result.params = p.params

proc buildLang(p: VCardProp): VCardLang =
  result.value = p.value.strip()
  result.types = extractTypes(p)
  result.pref = parsePref(p)
  if result.pref.isNone: result.pref = prefFromTypes(result.types)
  result.altId = paramFirst(p, "ALTID")
  result.params = p.params

proc buildUrl(p: VCardProp): VCardUrl =
  result.value = p.value
  result.types = extractTypes(p)
  result.pref = parsePref(p)
  if result.pref.isNone: result.pref = prefFromTypes(result.types)
  result.altId = paramFirst(p, "ALTID")
  result.label = optUnescapeLabel(paramFirst(p, "LABEL"))
  result.params = p.params

proc buildAdr(p: VCardProp): VCardAdr =
  let parts = splitEscapedSemi(p.value)
  proc at(i: int): string = (if i < parts.len: parts[i] else: "")
  result.poBox = at(0); result.ext = at(1); result.street = at(2)
  result.locality = at(3); result.region = at(4)
  result.postal = at(5); result.country = at(6)
  result.label = optUnescapeLabel(paramFirst(p, "LABEL"))
  result.geo = paramFirst(p, "GEO")
  result.tz = paramFirst(p, "TZ")
  result.altId = paramFirst(p, "ALTID")
  result.pref = parsePref(p)
  result.types = extractTypes(p)
  if result.pref.isNone: result.pref = prefFromTypes(result.types)
  result.params = p.params

proc upgradeInlineB(p: VCardProp): tuple[value: string, mediaType: Option[string], wasB: bool] =
  ## v3 `PHOTO;ENCODING=b;TYPE=JPEG:<base64>` -> `data:` URI.
  let enc = optNorm(paramFirst(p, "ENCODING"))
  if enc.isSome and enc.get == "B":
    let t = paramFirst(p, "TYPE").get("octet-stream")
    let mt = "image/" & t.toLowerAscii().strip()
    let b64 = p.value.strip().replace(" ", "").replace("\t", "")
    # validate base64 lightly; keep raw if it fails
    try:
      discard decode(b64)
      return ("data:" & mt & ";base64," & b64, some(mt), true)
    except CatchableError:
      return (p.value, some(mt), true)
  (p.value, paramFirst(p, "MEDIATYPE"), false)

proc buildPhoto(p: VCardProp): VCardPhoto =
  let (v, mt, wasB) = upgradeInlineB(p)
  result.value = v
  result.mediaType = mt
  if result.mediaType.isNone:
    let topt = paramFirst(p, "TYPE")
    if topt.isSome:
      result.mediaType = some("image/" & topt.get.toLowerAscii())
  result.types = extractTypes(p)
  result.pref = parsePref(p)
  if result.pref.isNone: result.pref = prefFromTypes(result.types)
  result.altId = paramFirst(p, "ALTID")
  result.params = p.params
  result.wasInlineB = wasB

proc buildName(raw: string): VCardName =
  let parts = splitEscapedSemi(raw)
  proc at(i: int): string = (if i < parts.len: parts[i] else: "")
  result = VCardName(family: at(0), given: at(1), additional: at(2),
                     prefix: at(3), suffix: at(4))

proc buildOrg(raw: string): VCardOrg =
  let parts = splitEscapedSemi(raw)
  if parts.len == 0 or (parts.len == 1 and parts[0].len == 0):
    return VCardOrg(name: "", units: @[])
  result = VCardOrg(name: parts[0],
                    units: if parts.len > 1: parts[1..^1] else: @[])

proc buildGender(raw: string): VCardGender =
  let parts = splitEscapedSemi(raw)
  if parts.len == 0: return VCardGender(sex: "", identity: "")
  result = VCardGender(sex: parts[0].strip().toUpperAscii(),
                       identity: if parts.len > 1: parts[1] else: "")
  if result.sex notin ["", "M", "F", "O", "N", "U"]:
    vcardError("Invalid GENDER sex (want M/F/O/N/U): " & result.sex)

proc buildDateProp(p: VCardProp): VCardDateProp =
  let raw = unescapeVCardText(p.value)
  validateVCardDateProp(p, p.value.strip())
  result = VCardDateProp(value: raw,
    valueType: paramFirst(p, "VALUE").get(""),
    altId: paramFirst(p, "ALTID"),
    calscale: paramFirst(p, "CALSCALE"),
    params: p.params)

proc parseVCardKind*(s: string): VCardKindValue =
  ## Parse a KIND value (case-insensitive). Unknown tokens (e.g. `x-`
  ## names, future iana-tokens) map to `vkCustom`, preserving raw text.
  let v = s.strip()
  if v.len == 0: vcardError("KIND must not be empty")
  case norm(v)
  of "INDIVIDUAL": VCardKindValue(kind: vkIndividual)
  of "GROUP": VCardKindValue(kind: vkGroup)
  of "ORG": VCardKindValue(kind: vkOrg)
  of "LOCATION": VCardKindValue(kind: vkLocation)
  of "APPLICATION": VCardKindValue(kind: vkApplication)
  else: VCardKindValue(kind: vkCustom, custom: v)

proc vcardKindStr*(k: VCardKindValue): string =
  ## Canonical wire form of a KIND value (lowercase registered tokens).
  case k.kind
  of vkIndividual: "individual"
  of vkGroup: "group"
  of vkOrg: "org"
  of vkLocation: "location"
  of vkApplication: "application"
  of vkCustom: k.custom

proc findProp*(props: seq[VCardProp], name: string): Option[VCardProp] =
  let n = norm(name)
  for p in props:
    if norm(p.name) == n: return some(p)
  none(VCardProp)

# top-level build -----------------------------------------------------------

proc buildVCard*(props: seq[VCardProp]): VCard =
  result = VCard(version: vv40)
  var seenVersion = false
  var seenFn = false
  for p in props:
    let n = norm(p.name)
    case n
    of "VERSION":
      let v = p.value.strip()
      if v == "4.0": result.version = vv40
      elif v == "3.0": result.version = vv30
      else: vcardError("Unsupported VERSION (want 3.0 or 4.0): " & v)
      seenVersion = true
    of "FN":
      if seenFn:
        # multiple FN allowed (e.g. localizations via ALTID); keep first typed, rest as extra
        result.extraProps.add(p)
      else:
        result.fn = unescapeVCardText(p.value)
        seenFn = true
    of "N":
      if result.n.isNone: result.n = some(buildName(p.value))
      else: result.extraProps.add(p)
    of "NICKNAME":
      for it in splitEscapedComma(p.value): result.nicknames.add(it)
    of "PHOTO": result.photos.add(buildPhoto(p))
    of "BDAY":
      if result.bday.isNone: result.bday = some(buildDateProp(p))
      else: result.extraProps.add(p)
    of "ANNIVERSARY":
      if result.anniversary.isNone: result.anniversary = some(buildDateProp(p))
      else: result.extraProps.add(p)
    of "GENDER":
      if result.gender.isNone: result.gender = some(buildGender(p.value))
      else: result.extraProps.add(p)
    of "ADR": result.adrs.add(buildAdr(p))
    of "TEL": result.tels.add(buildTel(p))
    of "EMAIL": result.emails.add(buildEmail(p))
    of "IMPP": result.impps.add(buildImpp(p))
    of "LANG": result.langs.add(buildLang(p))
    of "TZ":
      if result.tz.isNone:
        let vt = norm(paramFirst(p, "VALUE").get(""))
        if vt == "UTC-OFFSET":
          if not isVCardUtcOffset(p.value.strip()):
            vcardError("Invalid TZ UTC-OFFSET: " & p.value)
        result.tz = some(p.value)
      else: result.extraProps.add(p)
    of "GEO":
      if result.geo.isNone: result.geo = some(p.value)
      else: result.extraProps.add(p)
    of "TITLE":
      if result.title.isNone: result.title = some(unescapeVCardText(p.value))
      else: result.extraProps.add(p)
    of "ROLE":
      if result.role.isNone: result.role = some(unescapeVCardText(p.value))
      else: result.extraProps.add(p)
    of "LOGO":
      if result.logo.isNone:
        let (v, _, _) = upgradeInlineB(p)
        result.logo = some(v)
      else: result.extraProps.add(p)
    of "ORG":
      if result.org.isNone: result.org = some(buildOrg(p.value))
      else: result.extraProps.add(p)
    of "MEMBER": result.members.add(VCardMember(value: p.value,
      pref: parsePref(p), altId: paramFirst(p, "ALTID"), params: p.params))
    of "RELATED":
      result.related.add(VCardRelated(value: p.value,
        relType: paramFirst(p, "TYPE"),
        types: extractTypes(p), pref: parsePref(p),
        altId: paramFirst(p, "ALTID"), params: p.params))
    of "CATEGORIES":
      for it in splitEscapedComma(p.value): result.categories.add(it)
    of "NOTE":
      if result.note.isNone: result.note = some(unescapeVCardText(p.value))
      else: result.extraProps.add(p)
    of "PRODID":
      if result.prodId.isNone: result.prodId = some(p.value)
      else: result.extraProps.add(p)
    of "REV":
      if result.rev.isNone:
        validateVCardDateProp(p, p.value.strip())
        result.rev = some(p.value)
      else: result.extraProps.add(p)
    of "SORT-STRING":
      if result.sortString.isNone: result.sortString = some(unescapeVCardText(p.value))
      else: result.extraProps.add(p)
    of "SOUND":
      if result.sound.isNone:
        let (v, _, _) = upgradeInlineB(p)
        result.sound = some(v)
      else: result.extraProps.add(p)
    of "UID":
      if result.uid.isNone: result.uid = some(p.value)
      else: result.extraProps.add(p)
    of "KIND":
      if result.kind.isNone: result.kind = some(parseVCardKind(p.value))
      else: result.extraProps.add(p)
    of "CLIENTPIDMAP":
      let semi = p.value.find(';')
      if semi < 0: vcardError("Invalid CLIENTPIDMAP (want PID;URI): " & p.value)
      try:
        result.clientPidMaps.add(VCardClientPid(pid: parseInt(p.value[0..<semi].strip()),
                                                uri: p.value[semi+1..^1].strip()))
      except ValueError:
        vcardError("Invalid CLIENTPIDMAP PID: " & p.value)
    of "URL": result.urls.add(buildUrl(p))
    of "KEY":
      if result.key.isNone:
        let (v, _, _) = upgradeInlineB(p)
        result.key = some(v)
      else: result.extraProps.add(p)
    of "FBURL":
      if result.fbUrl.isNone: result.fbUrl = some(p.value)
      else: result.extraProps.add(p)
    of "CALADRURI":
      if result.calAdrUri.isNone: result.calAdrUri = some(p.value)
      else: result.extraProps.add(p)
    of "CALURI":
      if result.calUri.isNone: result.calUri = some(p.value)
      else: result.extraProps.add(p)
    of "XML": result.xml.add(p.value)
    else: result.extraProps.add(p)
  if not seenVersion:
    vcardError("Missing required VERSION (want 3.0 or 4.0)")
  if not seenFn:
    vcardError("Missing required FN")
  if result.fn.strip().len == 0:
    vcardError("FN must not be empty")

# public parse ---------------------------------------------------------------

proc parseVCards*(input: string): seq[VCard] =
  ## Parse one or more VCARDs. Raises `OpenParserVCardError` on
  ## malformed framing, missing VERSION/FN, or bad typed values.
  let lls = unfoldLines(input)
  var nonEmpty = false
  for ll in lls:
    if ll.text.strip().len > 0: nonEmpty = true; break
  if not nonEmpty:
    raise newException(OpenParserVCardError, "Empty vCard input")
  result = @[]
  var cur: seq[VCardProp] = @[]
  var inCard = false
  for ll in lls:
    if ll.text.len == 0: continue
    let up = ll.text.toUpperAscii()
    if up.startsWith("BEGIN:"):
      let nm = ll.text[6..^1].strip()
      if norm(nm) != "VCARD":
        failVCard(ll.no, ll.text, "BEGIN without VCARD (got BEGIN:" & nm & ")")
      if inCard:
        failVCard(ll.no, ll.text, "Nested BEGIN:VCARD")
      inCard = true
      cur = @[]
    elif up.startsWith("END:"):
      let nm = ll.text[4..^1].strip()
      if not inCard:
        failVCard(ll.no, ll.text, "END without matching BEGIN: " & nm)
      if norm(nm) != "VCARD":
        failVCard(ll.no, ll.text, "Mismatched END:" & nm & " expected END:VCARD")
      inCard = false
      result.add(buildVCard(cur))
      cur = @[]
    else:
      if not inCard:
        failVCard(ll.no, ll.text, "Property outside VCARD: " & ll.text)
      cur.add(parseContentLine(ll.no, ll.text))
  if inCard:
    vcardError("Unclosed BEGIN:VCARD")

proc parseVCard*(input: string): VCard =
  ## First card of `parseVCards`. Raises if no card found.
  let cards = parseVCards(input)
  if cards.len == 0:
    raise newException(OpenParserVCardError, "No VCARD found")
  cards[0]

proc parseVCardsFile*(path: string): seq[VCard] =
  parseVCards(readFile(path))

proc parseVCardFile*(path: string): VCard =
  parseVCard(readFile(path))

# writers --------------------------------------------------------------------

proc addTypePref(params: var seq[VCardParam], types: seq[string],
                 pref: Option[int], target: VCardVersion) =
  if types.len > 0:
    if target == vv30:
      # v3: PREF is a TYPE value, not a PREF param
      var ts = types
      var hasPref = false
      for t in ts:
        if norm(t) == "PREF": hasPref = true; break
      if pref.isSome and not hasPref:
        ts.add("PREF")
      params.add(VCardParam(name: "TYPE", values: ts))
    else:
      var ts: seq[string] = @[]
      for t in types:
        if norm(t) == "PREF": continue # v4 uses PREF=1, drop legacy marker
        ts.add(t)
      if ts.len > 0:
        params.add(VCardParam(name: "TYPE", values: ts))
      if pref.isSome:
        params.add(VCardParam(name: "PREF", values: @[$pref.get]))
  else:
    if pref.isSome:
      if target == vv30:
        params.add(VCardParam(name: "TYPE", values: @["PREF"]))
      else:
        params.add(VCardParam(name: "PREF", values: @[$pref.get]))

proc copyOtherParams(dst: var seq[VCardParam], src: seq[VCardParam]) =
  for p in src:
    let n = norm(p.name)
    if n in ["TYPE", "PREF", "ALTID", "LABEL", "MEDIATYPE", "ENCODING",
             "VALUE", "CALSCALE", "GEO", "TZ"]: continue
    dst.add(p)

proc downgradePhotoProp(name: string, ph: VCardPhoto,
                        target: VCardVersion): VCardProp =
  ## v4 `data:` URI -> v3 `ENCODING=b` inline when downgrading.
  if target == vv30 and ph.value.startsWith("data:"):
    let semi = ph.value.find(';')
    let comma = ph.value.find(',')
    if semi >= 0 and comma > semi and ph.value[semi+1..^1].startsWith("base64,"):
      let mt = ph.value[5..<semi] # e.g. image/jpeg
      var imgType = "octet-stream"
      let slash = mt.find('/')
      if slash >= 0: imgType = mt[slash+1..^1].toUpperAscii()
      let b64 = ph.value[comma+1..^1]
      var params: seq[VCardParam] = @[]
      params.add(VCardParam(name: "ENCODING", values: @["b"]))
      params.add(VCardParam(name: "TYPE", values: @[imgType]))
      if ph.altId.isSome:
        params.add(VCardParam(name: "ALTID", values: @[ph.altId.get]))
      copyOtherParams(params, ph.params)
      return VCardProp(name: name, params: params, value: b64)
  var params: seq[VCardParam] = @[]
  if ph.mediaType.isSome and target == vv40:
    params.add(VCardParam(name: "MEDIATYPE", values: @[ph.mediaType.get]))
  addTypePref(params, ph.types, ph.pref, target)
  if ph.altId.isSome:
    params.add(VCardParam(name: "ALTID", values: @[ph.altId.get]))
  copyOtherParams(params, ph.params)
  VCardProp(name: name, params: params, value: ph.value)

proc writeOneCard(c: VCard, target: VCardVersion): seq[string] =
  result = @[]
  result.add(foldLineRaw("BEGIN:VCARD"))
  result.add(foldLineRaw("VERSION:" & (if target == vv40: "4.0" else: "3.0")))
  if c.prodId.isSome: result.add(foldLineRaw(propLine(VCardProp(name: "PRODID", value: c.prodId.get))))
  result.add(foldLineRaw("FN:" & escapeVCardText(c.fn)))
  if c.n.isSome:
    let n = c.n.get
    result.add(foldLineRaw("N:" & joinEscapedSemi(@[n.family, n.given,
      n.additional, n.prefix, n.suffix])))
  if c.nicknames.len > 0:
    result.add(foldLineRaw("NICKNAME:" & joinEscapedComma(c.nicknames)))
  for ph in c.photos:
    result.add(foldLineRaw(propLine(downgradePhotoProp("PHOTO", ph, target))))
  if c.bday.isSome:
    let b = c.bday.get
    var params: seq[VCardParam] = @[]
    if b.valueType.len > 0: params.add(VCardParam(name: "VALUE", values: @[b.valueType]))
    if b.altId.isSome: params.add(VCardParam(name: "ALTID", values: @[b.altId.get]))
    if b.calscale.isSome: params.add(VCardParam(name: "CALSCALE", values: @[b.calscale.get]))
    copyOtherParams(params, b.params)
    let vv = if b.valueType.toUpperAscii() in ["TEXT"]: escapeVCardText(b.value) else: b.value
    result.add(foldLineRaw(propLine(VCardProp(name: "BDAY", params: params, value: vv))))
  if c.anniversary.isSome:
    let a = c.anniversary.get
    var params: seq[VCardParam] = @[]
    if a.valueType.len > 0: params.add(VCardParam(name: "VALUE", values: @[a.valueType]))
    if a.altId.isSome: params.add(VCardParam(name: "ALTID", values: @[a.altId.get]))
    copyOtherParams(params, a.params)
    let vv = if a.valueType.toUpperAscii() in ["TEXT"]: escapeVCardText(a.value) else: a.value
    result.add(foldLineRaw(propLine(VCardProp(name: "ANNIVERSARY", params: params, value: vv))))
  if c.gender.isSome:
    let g = c.gender.get
    result.add(foldLineRaw("GENDER:" & escapeVCardText(g.sex) &
      (if g.identity.len > 0: ";" & escapeVCardText(g.identity) else: "")))
  for a in c.adrs:
    var params: seq[VCardParam] = @[]
    addTypePref(params, a.types, a.pref, target)
    if a.label.isSome:
      params.add(VCardParam(name: "LABEL", values: @[escapeParamValue(a.label.get)]))
    if a.geo.isSome: params.add(VCardParam(name: "GEO", values: @[a.geo.get]))
    if a.tz.isSome: params.add(VCardParam(name: "TZ", values: @[a.tz.get]))
    if a.altId.isSome: params.add(VCardParam(name: "ALTID", values: @[a.altId.get]))
    copyOtherParams(params, a.params)
    result.add(foldLineRaw(propLine(VCardProp(name: "ADR", params: params,
      value: joinEscapedSemi(@[a.poBox, a.ext, a.street, a.locality,
                               a.region, a.postal, a.country])))))
  for t in c.tels:
    var params: seq[VCardParam] = @[]
    addTypePref(params, t.types, t.pref, target)
    if t.label.isSome:
      params.add(VCardParam(name: "LABEL", values: @[escapeParamValue(t.label.get)]))
    if t.altId.isSome: params.add(VCardParam(name: "ALTID", values: @[t.altId.get]))
    copyOtherParams(params, t.params)
    result.add(foldLineRaw(propLine(VCardProp(name: "TEL", params: params, value: t.value))))
  for e in c.emails:
    var params: seq[VCardParam] = @[]
    addTypePref(params, e.types, e.pref, target)
    if e.altId.isSome: params.add(VCardParam(name: "ALTID", values: @[e.altId.get]))
    copyOtherParams(params, e.params)
    result.add(foldLineRaw(propLine(VCardProp(name: "EMAIL", params: params, value: e.value))))
  for im in c.impps:
    var params: seq[VCardParam] = @[]
    addTypePref(params, im.types, im.pref, target)
    if im.altId.isSome: params.add(VCardParam(name: "ALTID", values: @[im.altId.get]))
    copyOtherParams(params, im.params)
    result.add(foldLineRaw(propLine(VCardProp(name: "IMPP", params: params, value: im.value))))
  for l in c.langs:
    var params: seq[VCardParam] = @[]
    addTypePref(params, l.types, l.pref, target)
    if l.altId.isSome: params.add(VCardParam(name: "ALTID", values: @[l.altId.get]))
    copyOtherParams(params, l.params)
    result.add(foldLineRaw(propLine(VCardProp(name: "LANG", params: params, value: l.value))))
  if c.tz.isSome: result.add(foldLineRaw("TZ:" & c.tz.get))
  if c.geo.isSome: result.add(foldLineRaw("GEO:" & c.geo.get))
  if c.title.isSome: result.add(foldLineRaw("TITLE:" & escapeVCardText(c.title.get)))
  if c.role.isSome: result.add(foldLineRaw("ROLE:" & escapeVCardText(c.role.get)))
  if c.logo.isSome: result.add(foldLineRaw("LOGO:" & c.logo.get))
  if c.org.isSome:
    let o = c.org.get
    result.add(foldLineRaw("ORG:" & joinEscapedSemi(@[o.name] & o.units)))
  for m in c.members:
    var params: seq[VCardParam] = @[]
    if target == vv40 and m.pref.isSome:
      params.add(VCardParam(name: "PREF", values: @[$m.pref.get]))
    if m.altId.isSome: params.add(VCardParam(name: "ALTID", values: @[m.altId.get]))
    copyOtherParams(params, m.params)
    result.add(foldLineRaw(propLine(VCardProp(name: "MEMBER", params: params, value: m.value))))
  for r in c.related:
    var params: seq[VCardParam] = @[]
    addTypePref(params, r.types, r.pref, target)
    if r.altId.isSome: params.add(VCardParam(name: "ALTID", values: @[r.altId.get]))
    copyOtherParams(params, r.params)
    result.add(foldLineRaw(propLine(VCardProp(name: "RELATED", params: params, value: r.value))))
  if c.categories.len > 0:
    result.add(foldLineRaw("CATEGORIES:" & joinEscapedComma(c.categories)))
  if c.note.isSome: result.add(foldLineRaw("NOTE:" & escapeVCardText(c.note.get)))
  if c.rev.isSome: result.add(foldLineRaw("REV:" & c.rev.get))
  if c.sortString.isSome:
    result.add(foldLineRaw("SORT-STRING:" & escapeVCardText(c.sortString.get)))
  if c.sound.isSome: result.add(foldLineRaw("SOUND:" & c.sound.get))
  if c.uid.isSome: result.add(foldLineRaw("UID:" & c.uid.get))
  if c.kind.isSome: result.add(foldLineRaw("KIND:" & vcardKindStr(c.kind.get)))
  for cm in c.clientPidMaps:
    result.add(foldLineRaw("CLIENTPIDMAP:" & $cm.pid & ";" & cm.uri))
  for u in c.urls:
    var params: seq[VCardParam] = @[]
    addTypePref(params, u.types, u.pref, target)
    if u.label.isSome:
      params.add(VCardParam(name: "LABEL", values: @[escapeParamValue(u.label.get)]))
    if u.altId.isSome: params.add(VCardParam(name: "ALTID", values: @[u.altId.get]))
    copyOtherParams(params, u.params)
    result.add(foldLineRaw(propLine(VCardProp(name: "URL", params: params, value: u.value))))
  if c.key.isSome: result.add(foldLineRaw("KEY:" & c.key.get))
  if c.fbUrl.isSome: result.add(foldLineRaw("FBURL:" & c.fbUrl.get))
  if c.calAdrUri.isSome: result.add(foldLineRaw("CALADRURI:" & c.calAdrUri.get))
  if c.calUri.isSome: result.add(foldLineRaw("CALURI:" & c.calUri.get))
  for x in c.xml: result.add(foldLineRaw("XML:" & x))
  for p in c.extraProps:
    if norm(p.name) in ["VERSION", "FN", "N", "NICKNAME", "PHOTO", "BDAY",
        "ANNIVERSARY", "GENDER", "ADR", "TEL", "EMAIL", "IMPP", "LANG", "TZ",
        "GEO", "TITLE", "ROLE", "LOGO", "ORG", "MEMBER", "RELATED",
        "CATEGORIES", "NOTE", "PRODID", "REV", "SORT-STRING", "SOUND", "UID",
        "KIND", "CLIENTPIDMAP", "URL", "KEY", "FBURL", "CALADRURI", "CALURI",
        "XML"]: continue
    var pp = p
    if target == vv30 and norm(p.name) == "PHOTO":
      # keep as-is; typed photos already emitted
      discard
    result.add(foldLineRaw(propLine(pp)))
  result.add(foldLineRaw("END:VCARD"))

proc toVCards*(cards: seq[VCard], opts = defaultVCardOptions()): string =
  ## Serialize cards with CRLF + folding. Emits `opts.targetVersion`.
  var lines: seq[string] = @[]
  for c in cards:
    lines.add(writeOneCard(c, opts.targetVersion))
  result = lines.join(VCardCrlf) & VCardCrlf

proc toVCard*(card: VCard, opts = defaultVCardOptions()): string =
  toVCards(@[card], opts)

proc `$`*(card: VCard): string = toVCard(card)

# QR bridge -------------------------------------------------------------------

proc toQrPayload*(c: VCard): string =
  ## Minimal vCard 3.0 business-card payload compatible with
  ## `qr/payload.makeVCard` (FN/N/ORG/TITLE/TEL/EMAIL/URL/ADR/NOTE).
  result = "BEGIN:VCARD\r\nVERSION:3.0\r\n"
  if c.fn.len > 0:
    result.add "FN:" & c.fn & "\r\n"
    if c.n.isSome:
      let n = c.n.get
      result.add "N:" & n.family & ";" & n.given & ";" & n.additional &
        ";" & n.prefix & ";" & n.suffix & "\r\n"
    else:
      let parts = c.fn.split(' ')
      var family = ""
      var given = c.fn
      if parts.len > 1:
        family = parts[^1]
        given = c.fn[0..<c.fn.len - family.len - 1]
      result.add "N:" & family & ";" & given & ";;;\r\n"
  if c.org.isSome and c.org.get.name.len > 0:
    result.add "ORG:" & c.org.get.name & "\r\n"
  if c.title.isSome and c.title.get.len > 0:
    result.add "TITLE:" & c.title.get & "\r\n"
  if c.tels.len > 0:
    result.add "TEL;TYPE=CELL:" & c.tels[0].value & "\r\n"
  if c.emails.len > 0:
    result.add "EMAIL:" & c.emails[0].value & "\r\n"
  if c.urls.len > 0:
    result.add "URL:" & c.urls[0].value & "\r\n"
  if c.adrs.len > 0:
    let a = c.adrs[0]
    result.add "ADR:;;" & a.street & ";" & a.locality & ";" & a.region &
      ";" & a.postal & ";" & a.country & "\r\n"
  if c.note.isSome and c.note.get.len > 0:
    result.add "NOTE:" & c.note.get & "\r\n"
  result.add "END:VCARD"
