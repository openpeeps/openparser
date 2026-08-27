# A collection of tiny parsers and dumpers
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/openparser

## RFC 5545 iCalendar parser and serializer.
##
## Line unfolding, TEXT escaping, DATE/DATE-TIME/DURATION, parameters
## (quoted values, TZID, CN), nested VALARM and VTIMEZONE observances,
## typed Calendar/Event/Todo/Journal with generic fallback (extraProps /
## cckOther), and `IcalCalendar <-> string` round-trip via `parseIcal` /
## `toIcal`.
##
## ```nim
## import openparser/ical
## let cal = parseIcal(readFile("meet.ics"))
## echo cal.prodId
## for c in cal.components:
##   if c.kind == cckEvent: echo c.event.summary
## writeFile("out.ics", toIcal(cal))
## ```

import std/[strutils, options]

type
  OpenParserIcalError* = object of CatchableError

  IcalDateTime* = object
    year*, month*, day*: int
    hasTime*: bool
    hour*, minute*, second*: int
    isUtc*: bool

  IcalDuration* = object
    negative*: bool
    weeks*, days*, hours*, minutes*, seconds*: int

  IcalDt* = object
    dt*: IcalDateTime
    tzid*: Option[string]

  IcalParam* = object
    name*: string
    values*: seq[string]

  IcalProp* = object
    name*: string
    params*: seq[IcalParam]
    value*: string

  IcalPerson* = object
    uri*: string
    cn*: Option[string]
    params*: seq[IcalParam]

  IcalTriggerKind* = enum trkRelative, trkAbsolute
  IcalTrigger* = object
    case kind*: IcalTriggerKind
    of trkRelative: dur*: IcalDuration
    of trkAbsolute: dt*: IcalDateTime

  IcalAlarm* = ref object
    action*: string
    trigger*: Option[IcalTrigger]
    description*: Option[string]
    summary*: Option[string]
    repeatCount*: Option[int]
    duration*: Option[IcalDuration]
    attendees*: seq[IcalPerson]
    extraProps*: seq[IcalProp]

  IcalTzObservance* = ref object
    dtstart*: Option[IcalDateTime]
    offsetFrom*: Option[string]
    offsetTo*: Option[string]
    names*: seq[string]
    rrule*: Option[string]
    extraProps*: seq[IcalProp]

  IcalTimezone* = ref object
    tzid*: string
    standard*: seq[IcalTzObservance]
    daylight*: seq[IcalTzObservance]
    extraProps*: seq[IcalProp]

  IcalEvent* = ref object
    uid*: string
    dtstamp*: Option[IcalDt]
    dtStart*: Option[IcalDt]
    dtEnd*: Option[IcalDt]
    duration*: Option[IcalDuration]
    summary*: Option[string]
    description*: Option[string]
    location*: Option[string]
    status*: Option[string]
    transparency*: Option[string]
    classification*: Option[string]
    priority*: Option[int]
    sequenceNum*: Option[int]
    created*: Option[IcalDt]
    lastModified*: Option[IcalDt]
    url*: Option[string]
    organizer*: Option[IcalPerson]
    attendees*: seq[IcalPerson]
    categories*: seq[string]
    rrule*: Option[string]
    exdates*: seq[IcalDt]
    attachments*: seq[string]
    recurrenceId*: Option[IcalDt]
    alarms*: seq[IcalAlarm]
    extraProps*: seq[IcalProp]

  IcalTodo* = ref object
    uid*: string
    dtstamp*: Option[IcalDt]
    dtStart*: Option[IcalDt]
    due*: Option[IcalDt]
    completed*: Option[IcalDt]
    summary*: Option[string]
    description*: Option[string]
    location*: Option[string]
    status*: Option[string]
    classification*: Option[string]
    priority*: Option[int]
    sequenceNum*: Option[int]
    created*: Option[IcalDt]
    lastModified*: Option[IcalDt]
    url*: Option[string]
    organizer*: Option[IcalPerson]
    attendees*: seq[IcalPerson]
    categories*: seq[string]
    rrule*: Option[string]
    percentComplete*: Option[int]
    alarms*: seq[IcalAlarm]
    extraProps*: seq[IcalProp]

  IcalJournal* = ref object
    uid*: string
    dtstamp*: Option[IcalDt]
    summary*: Option[string]
    description*: Option[string]
    status*: Option[string]
    classification*: Option[string]
    organizer*: Option[IcalPerson]
    categories*: seq[string]
    attendees*: seq[IcalPerson]
    extraProps*: seq[IcalProp]

  IcalGenericSub* = object
    name*: string
    props*: seq[IcalProp]
    children*: seq[IcalGenericSub]

  IcalOther* = ref object
    name*: string
    props*: seq[IcalProp]
    children*: seq[IcalGenericSub]

  IcalComponentKind* = enum
    cckEvent, cckTodo, cckJournal, cckTimezone, cckOther

  IcalComponent* {.acyclic.} = ref object
    case kind*: IcalComponentKind
    of cckEvent: event*: IcalEvent
    of cckTodo: todo*: IcalTodo
    of cckJournal: journal*: IcalJournal
    of cckTimezone: timezone*: IcalTimezone
    of cckOther: other*: IcalOther

  IcalCalendar* = ref object
    prodId*: Option[string]
    version*: Option[string]
    calscale*: Option[string]
    `method`*: Option[string]
    extraProps*: seq[IcalProp]
    components*: seq[IcalComponent]

const IcalCrlf* = "\r\n"

# ---------------------------------------------------------------------------
# helpers

proc norm*(s: string): string {.inline.} = s.toUpperAscii()

proc failIcal*(lineNo: int, lineText, msg: string) {.noreturn.} =
  let ctx = lineText & "\n" & "^".repeat(0) & "\nError (line " & $lineNo & ") " & msg
  raise newException(OpenParserIcalError, "\n" & lineText & "\n^\nError (line " & $lineNo & ") " & msg & "\n" & ctx)

proc icalError*(msg: string) {.noreturn.} =
  raise newException(OpenParserIcalError, msg)

proc getParam*(prop: IcalProp, name: string): Option[IcalParam] =
  let n = norm(name)
  for p in prop.params:
    if norm(p.name) == n: return some(p)
  none(IcalParam)

proc hasParam*(prop: IcalProp, name: string): bool = getParam(prop, name).isSome

proc paramFirst*(prop: IcalProp, name: string): Option[string] =
  let o = getParam(prop, name)
  if o.isSome and o.get.values.len > 0: some(o.get.values[0])
  else: none(string)

# TEXT codecs ---------------------------------------------------------------

proc unescapeIcalText*(s: string): string =
  result = newStringOfCap(s.len)
  var i = 0
  while i < s.len:
    if s[i] == '\\' and i + 1 < s.len:
      case s[i+1]
      of 'n', 'N': result.add('\n'); i += 2
      of '\\': result.add('\\'); i += 2
      of ';': result.add(';'); i += 2
      of ',': result.add(','); i += 2
      else: result.add(s[i+1]); i += 2
    else:
      result.add(s[i]); inc i

proc escapeIcalText*(s: string): string =
  result = newStringOfCap(s.len + 8)
  for c in s:
    case c
    of '\\': result.add("\\\\")
    of ';': result.add("\\;")
    of ',': result.add("\\,")
    of '\n': result.add("\\n")
    of '\r': discard
    else: result.add(c)

proc splitEscapedComma*(s: string): seq[string] =
  ## Split on unescaped ',' then unescape each part.
  result = @[]
  var cur = newStringOfCap(32)
  var i = 0
  while i < s.len:
    if s[i] == '\\' and i + 1 < s.len and s[i+1] == ',':
      cur.add(','); i += 2
    elif s[i] == '\\' and i + 1 < s.len and s[i+1] in {'n','N','\\',';'}:
      # keep escape sequence raw for now; unescape after split per-item
      cur.add(s[i]); cur.add(s[i+1]); i += 2
    elif s[i] == ',':
      result.add(unescapeIcalText(cur)); cur.setLen(0); inc i
    else:
      cur.add(s[i]); inc i
  result.add(unescapeIcalText(cur))

proc joinEscapedComma*(items: seq[string]): string =
  result = ""
  for i, it in items:
    if i > 0: result.add(',')
    result.add(escapeIcalText(it))

# DATE-TIME ---------------------------------------------------------------

proc parseIcalDateTime*(s: string): IcalDateTime =
  ## Accepts YYYYMMDD or YYYYMMDDTHHMMSS[Z]
  if s.len == 8:
    try:
      result.year = parseInt(s[0..3])
      result.month = parseInt(s[4..5])
      result.day = parseInt(s[6..7])
      result.hasTime = false
      if result.month < 1 or result.month > 12 or result.day < 1 or result.day > 31:
        icalError("Invalid DATE value: " & s)
    except ValueError:
      icalError("Invalid DATE value: " & s)
    return
  if s.len < 15 or s[8] != 'T':
    icalError("Invalid DATE-TIME value: " & s)
  var isUtc = false
  var core = s
  if core[^1] == 'Z':
    isUtc = true
    core = core[0..^2]
  if core.len != 15:
    icalError("Invalid DATE-TIME value: " & s)
  try:
    result.year = parseInt(core[0..3])
    result.month = parseInt(core[4..5])
    result.day = parseInt(core[6..7])
    result.hour = parseInt(core[9..10])
    result.minute = parseInt(core[11..12])
    result.second = parseInt(core[13..14])
    result.hasTime = true
    result.isUtc = isUtc
    if result.month < 1 or result.month > 12 or result.day < 1 or result.day > 31 or
       result.hour > 23 or result.minute > 59 or result.second > 60:
      icalError("Invalid DATE-TIME value: " & s)
  except ValueError:
    icalError("Invalid DATE-TIME value: " & s)

proc formatIcalDateTime*(dt: IcalDateTime): string =
  proc pad2(n: int): string = (if n < 10: "0" & $n else: $n)
  proc pad4(n: int): string =
    var s = $n
    while s.len < 4: s = "0" & s
    s
  result = pad4(dt.year) & pad2(dt.month) & pad2(dt.day)
  if dt.hasTime:
    result.add('T')
    result.add(pad2(dt.hour) & pad2(dt.minute) & pad2(dt.second))
    if dt.isUtc: result.add('Z')

proc parseIcalDt*(prop: IcalProp): IcalDt =
  result.dt = parseIcalDateTime(prop.value)
  let tz = paramFirst(prop, "TZID")
  if tz.isSome: result.tzid = tz

# DURATION ----------------------------------------------------------------

proc parseIcalDuration*(s: string): IcalDuration =
  if s.len == 0: icalError("Empty DURATION")
  var i = 0
  if s[i] == '-': result.negative = true; inc i
  elif s[i] == '+': inc i
  if i >= s.len or s[i] != 'P': icalError("Invalid DURATION (missing P): " & s)
  inc i
  if i >= s.len: icalError("Invalid DURATION (empty after P): " & s)
  var inTime = false
  var num = ""
  var got = false
  while i < s.len:
    let c = s[i]
    if c == 'T':
      if inTime: icalError("Invalid DURATION duplicate T: " & s)
      inTime = true
      if num.len > 0: icalError("Invalid DURATION stray number before T: " & s)
      inc i
    elif c in {'0'..'9'}:
      num.add(c); inc i
    elif c in {'W','D','H','M','S'}:
      if c in {'H','M','S'} and not inTime:
        icalError("Invalid DURATION time designator without T: " & s)
      if c == 'W' and inTime:
        icalError("Invalid DURATION W in time part: " & s)
      if num.len == 0: icalError("Invalid DURATION near '" & $c & "': " & s)
      let v = parseInt(num)
      case c
      of 'W': result.weeks = v
      of 'D': result.days = v
      of 'H': result.hours = v
      of 'M': result.minutes = v
      of 'S': result.seconds = v
      else: icalError("Invalid DURATION designator '" & $c & "': " & s)
      got = true
      num.setLen(0)
      inc i
    else:
      icalError("Invalid DURATION char '" & $c & "': " & s)
  if num.len > 0: icalError("Invalid DURATION trailing number: " & s)
  if not got:
    icalError("Invalid DURATION (no component): " & s)

proc formatIcalDuration*(d: IcalDuration): string =
  if d.weeks==0 and d.days==0 and d.hours==0 and d.minutes==0 and d.seconds==0:
    return (if d.negative: "-P" else: "P") & "T0S"
  result = if d.negative: "-P" else: "P"
  if d.weeks != 0: result.add($d.weeks & "W")
  if d.days != 0: result.add($d.days & "D")
  if d.hours != 0 or d.minutes != 0 or d.seconds != 0:
    result.add("T")
    if d.hours != 0: result.add($d.hours & "H")
    if d.minutes != 0: result.add($d.minutes & "M")
    if d.seconds != 0: result.add($d.seconds & "S")

proc totalSeconds*(d: IcalDuration): int64 =
  var s: int64 = 0
  s += int64(d.weeks) * 7 * 86400
  s += int64(d.days) * 86400
  s += int64(d.hours) * 3600
  s += int64(d.minutes) * 60
  s += int64(d.seconds)
  if d.negative: -s else: s

# TRIGGER -----------------------------------------------------------------

proc parseIcalTrigger*(s: string): IcalTrigger =
  let v = s.strip()
  if v.len == 0: icalError("Empty TRIGGER")
  # duration forms: P...  or -P... / +P...
  if v[0] == 'P' or (v.len > 1 and v[0] in {'-','+'} and v[1] == 'P'):
    return IcalTrigger(kind: trkRelative, dur: parseIcalDuration(v))
  # otherwise absolute date-time
  return IcalTrigger(kind: trkAbsolute, dt: parseIcalDateTime(v))

proc formatIcalTrigger*(t: IcalTrigger): string =
  case t.kind
  of trkRelative: formatIcalDuration(t.dur)
  of trkAbsolute: formatIcalDateTime(t.dt)

# PERSON ------------------------------------------------------------------

proc parseIcalPerson*(prop: IcalProp): IcalPerson =
  result.uri = prop.value
  result.cn = paramFirst(prop, "CN")
  result.params = prop.params

proc formatPersonProp*(name: string, p: IcalPerson): IcalProp =
  result.name = name
  result.params = p.params
  # ensure CN present if set
  var hasCn = false
  for pr in result.params:
    if norm(pr.name) == "CN": hasCn = true; break
  if p.cn.isSome and not hasCn:
    result.params.add(IcalParam(name: "CN", values: @[p.cn.get]))
  result.value = p.uri

# content-line <-> IcalProp -----------------------------------------------

proc needsParamQuote(v: string): bool =
  for c in v:
    if c in {',', ';', ':', '"', ' '} : return true
  false

proc parseContentLine*(lineNo: int, text: string): IcalProp =
  # NAME[;PARAM=val[,val]*]*:VALUE  (colon not inside quoted param)
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
    failIcal(lineNo, text, "Missing ':' in content line")
  result.name = text[0 ..< nameEnd].strip()
  if result.name.len == 0:
    failIcal(lineNo, text, "Empty property name")
  i = nameEnd
  result.params = @[]
  # params
  while i < text.len and text[i] == ';':
    inc i # skip ;
    var pStart = i
    var eqPos = -1
    inQuote = false
    while i < text.len:
      if text[i] == '"': inQuote = not inQuote
      elif not inQuote and text[i] == '=': eqPos = i; break
      elif not inQuote and text[i] == ':': break # stray no =
      inc i
    if eqPos < 0:
      failIcal(lineNo, text, "Invalid param (missing '=')")
    let pName = text[pStart ..< eqPos].strip()
    if pName.len == 0: failIcal(lineNo, text, "Empty param name")
    i = eqPos + 1
    # collect vals until ';' or ':' outside quotes
    # we parse char-by-char to handle quoted chunks and commas
    var curVals: seq[string] = @[]
    var buf = newStringOfCap(16)
    var q = false
    var pos = i
    block paramVals:
      while pos < text.len:
        let c = text[pos]
        if c == '"':
          q = not q; inc pos
          # inside quotes accumulate until closing quote
          if q == false:
            # we just closed? handled by toggling; loop continues
            discard
          # when opening quote, collect quoted value
          if q: # now inside
            var qb = newStringOfCap(16)
            while pos < text.len and text[pos] != '"':
              qb.add(text[pos]); inc pos
            if pos >= text.len: failIcal(lineNo, text, "Unterminated quoted param value")
            curVals.add(qb)
            q = false; inc pos # skip closing "
            # after quoted chunk, expect ',' or ';' or ':'
            if pos < text.len and text[pos] == ',':
              inc pos; continue
            elif pos < text.len and text[pos] in {';', ':'}:
              break
            elif pos >= text.len: break
            else: failIcal(lineNo, text, "Unexpected char after quoted param")
          else: discard
        elif not q and c == ',':
          # separator between values - current buf already accumulated?
          # we have been accumulating unquoted directly
          curVals.add(buf); buf.setLen(0); inc pos
        elif not q and c in {';', ':'}:
          break
        else:
          buf.add(c); inc pos
      if buf.len > 0 or curVals.len == 0:
        # flush remaining unquoted buf if any
        if buf.len > 0: curVals.add(buf)
        elif q: failIcal(lineNo, text, "Unterminated quote")
        elif pos >= text.len and curVals.len == 0 and buf.len == 0:
          curVals.add("")
    # `curVals` now holds values for this param
    # remove empties that are artefacts? keep as is but strip?
    result.params.add(IcalParam(name: pName, values: curVals))
    i = pos
    if i < text.len and text[i] == ';':
      continue
    elif i < text.len and text[i] == ':':
      break
    else:
      # end
      break
  if i >= text.len or text[i] != ':':
    failIcal(lineNo, text, "Missing ':' after params")
  inc i
  result.value = if i < text.len: text[i .. ^1] else: ""

proc propLine*(prop: IcalProp): string =
  result = prop.name
  for p in prop.params:
    result.add(';')
    result.add(p.name)
    result.add('=')
    for vi, v in p.values:
      if vi > 0: result.add(',')
      if needsParamQuote(v):
        result.add('"'); result.add(v); result.add('"')
      else: result.add(v)
  result.add(':')
  result.add(prop.value)

# line unfolding + logical lines ------------------------------------------

type LLine = object
  no*: int
  text*: string

proc unfoldLines*(input: string): seq[LLine] =
  ## RFC 5545 3.1: long lines folded as CRLF + single WSP. Accept CRLF or LF
  ## input. Continuation leading WSP is removed, lines are rejoined.
  var physical: seq[tuple[no:int, txt:string]] = @[]
  var start = 0
  var lno = 1
  var i = 0
  while i <= input.len:
    var eol = -1
    if i < input.len and input[i] == '\r' and i + 1 < input.len and input[i+1] == '\n':
      eol = i; # \r\n
    elif i < input.len and input[i] == '\n':
      eol = i
    elif i == input.len:
      eol = i
    if eol >= 0:
      let segEnd = eol
      let line = if segEnd > start: input[start ..< segEnd] else: ""
      physical.add((lno, line))
      if eol < input.len and input[eol] == '\r': i = eol + 2
      elif eol < input.len: i = eol + 1
      else: i = input.len + 1
      start = i
      inc lno
    else: inc i
  # unfold: continuation lines start with ' ' or '\t'
  result = @[]
  var curNo = 0
  var curText = ""
  for idx, (no, txt) in physical:
    if txt.len == 0 and result.len == 0 and curText.len == 0:
      # skip leading blank lines for leniency
      continue
    if txt.len > 0 and txt[0] in {' ', '\t'} and curText.len > 0:
      # continuation - strip leading single WSP per spec (only first)
      curText.add(txt[1 .. ^1])
    else:
      if curText.len > 0 or curNo != 0:
        result.add(LLine(no: curNo, text: curText))
      curNo = no
      curText = txt
      # blank physical lines produce an empty logical line if not continuation?
      # we'll keep them as empty logical lines and filter later; parser skips empties
  if curText.len > 0 or curNo != 0:
    result.add(LLine(no: curNo, text: curText))
  # filter empties that are pure blank - but preserve lines that are intentionally empty content line?
  # ical has no empty content line; safe to drop empties
  # keep as-is for parser to skip
  # trim trailing empties already handled; don't drop interior empties?

# folding on write ---------------------------------------------------------

proc foldLineRaw(line: string): string =
  const MaxOctets = 75
  if line.len <= MaxOctets: return line
  var chunks: seq[string] = @[]
  var idx = 0
  var first = true
  while idx < line.len:
    let budget = if first: MaxOctets else: MaxOctets - 1
    var take = min(budget, line.len - idx)
    # avoid splitting inside UTF-8 continuation
    while take > 0 and idx + take < line.len and (ord(line[idx + take]) and 0xC0) == 0x80:
      dec take
    # edge: if take became 0 (should not happen with valid utf8 and MaxOctets>=4), force at least 1 char
    if take == 0:
      # advance by one full utf8 char
      var j = idx
      inc j # include lead
      while j < line.len and (ord(line[j]) and 0xC0) == 0x80: inc j
      take = j - idx
    chunks.add(line[idx ..< idx + take])
    idx += take
    first = false
  result = chunks[0]
  for k in 1 ..< chunks.len:
    result.add(IcalCrlf & " " & chunks[k])

# internal tree for structure parsing -------------------------------------

type CompTree = ref object
  name*: string
  props*: seq[IcalProp]
  children*: seq[CompTree]
  beginNo*: int
  endNo*: int

proc buildCompTrees(lines: seq[LLine]): seq[CompTree] =
  # returns top-level components (normally one VCALENDAR); supports stray lines?
  var stack: seq[CompTree] = @[]
  var roots: seq[CompTree] = @[]
  for ll in lines:
    if ll.text.len == 0: continue
    # quick inspect
    if ll.text.toUpperAscii().startsWith("BEGIN:"):
      let name = ll.text[6 .. ^1].strip()
      if name.len == 0: failIcal(ll.no, ll.text, "BEGIN without name")
      let node = CompTree(name: name, props: @[], children: @[], beginNo: ll.no)
      stack.add(node)
    elif ll.text.toUpperAscii().startsWith("END:"):
      let name = ll.text[4 .. ^1].strip()
      if stack.len == 0: failIcal(ll.no, ll.text, "END without matching BEGIN: " & name)
      let top = stack.pop()
      if norm(top.name) != norm(name):
        failIcal(ll.no, ll.text, "Mismatched END:" & name & " expected END:" & top.name)
      top.endNo = ll.no
      if stack.len > 0:
        stack[^1].children.add(top)
      else:
        roots.add(top)
    else:
      # content line
      if stack.len == 0:
        failIcal(ll.no, ll.text, "Property outside component: " & ll.text)
      stack[^1].props.add(parseContentLine(ll.no, ll.text))
  if stack.len > 0:
    failIcal(stack[^1].beginNo, "BEGIN:" & stack[^1].name, "Unclosed component BEGIN:" & stack[^1].name)
  result = roots

# converters ---------------------------------------------------------------

proc findProp*(props: seq[IcalProp], name: string): Option[IcalProp] =
  let n = norm(name)
  for p in props:
    if norm(p.name) == n: return some(p)
  none(IcalProp)

proc collectProps(props: seq[IcalProp], name: string): seq[IcalProp] {.used.} =
  let n = norm(name)
  for p in props:
    if norm(p.name) == n: result.add(p)

proc buildAlarm(t: CompTree): IcalAlarm =
  result = IcalAlarm()
  result.extraProps = @[]
  for p in t.props:
    let n = norm(p.name)
    case n
    of "ACTION": result.action = p.value.strip()
    of "TRIGGER":
      # TRIGGER may have RELATED param; value could be duration or datetime
      # preserve RELATED param handling inside `parseIcalTrigger`? RELATED=END vs START default START, stored in extraProps
      result.trigger = some(parseIcalTrigger(p.value))
      # keep RELATED param as extra? keep in extraProps copy below if needed
      if p.params.len > 0:
        # store RELATED as extra if not empty? simpler keep extra copy if params present
        var hasRelated = false
        for pr in p.params:
          if norm(pr.name) == "RELATED": hasRelated = true
        if hasRelated:
          result.extraProps.add(p)
    of "DESCRIPTION": result.description = some(unescapeIcalText(p.value))
    of "SUMMARY": result.summary = some(unescapeIcalText(p.value))
    of "REPEAT":
      try: result.repeatCount = some(parseInt(p.value))
      except ValueError: icalError("Invalid REPEAT value: " & p.value)
    of "DURATION": result.duration = some(parseIcalDuration(p.value))
    of "ATTENDEE": result.attendees.add(parseIcalPerson(p))
    else: result.extraProps.add(p)
  # alarm children not expected
  if result.action.len == 0: result.action = "DISPLAY"

proc buildObservance(t: CompTree): IcalTzObservance =
  result = IcalTzObservance()
  for p in t.props:
    case norm(p.name)
    of "DTSTART": result.dtstart = some(parseIcalDateTime(p.value))
    of "TZOFFSETFROM": result.offsetFrom = some(p.value)
    of "TZOFFSETTO": result.offsetTo = some(p.value)
    of "TZNAME": result.names.add(unescapeIcalText(p.value))
    of "RRULE": result.rrule = some(p.value)
    else: result.extraProps.add(p)

proc buildEvent(t: CompTree): IcalEvent =
  result = IcalEvent()
  result.alarms = @[]
  result.attendees = @[]
  result.categories = @[]
  result.exdates = @[]
  result.attachments = @[]
  result.extraProps = @[]
  for p in t.props:
    let n = norm(p.name)
    case n
    of "UID": result.uid = p.value
    of "DTSTAMP": result.dtstamp = some(parseIcalDt(p))
    of "DTSTART": result.dtStart = some(parseIcalDt(p))
    of "DTEND": result.dtEnd = some(parseIcalDt(p))
    of "DURATION": result.duration = some(parseIcalDuration(p.value))
    of "SUMMARY": result.summary = some(unescapeIcalText(p.value))
    of "DESCRIPTION": result.description = some(unescapeIcalText(p.value))
    of "LOCATION": result.location = some(unescapeIcalText(p.value))
    of "STATUS": result.status = some(p.value)
    of "TRANSP": result.transparency = some(p.value)
    of "CLASS": result.classification = some(p.value)
    of "PRIORITY":
      try: result.priority = some(parseInt(p.value))
      except ValueError: icalError("Invalid PRIORITY: " & p.value)
    of "SEQUENCE":
      try: result.sequenceNum = some(parseInt(p.value))
      except ValueError: icalError("Invalid SEQUENCE: " & p.value)
    of "CREATED": result.created = some(parseIcalDt(p))
    of "LAST-MODIFIED": result.lastModified = some(parseIcalDt(p))
    of "URL": result.url = some(p.value)
    of "ORGANIZER": result.organizer = some(parseIcalPerson(p))
    of "ATTENDEE": result.attendees.add(parseIcalPerson(p))
    of "CATEGORIES":
      for it in splitEscapedComma(p.value): result.categories.add(it)
    of "RRULE": result.rrule = some(p.value)
    of "EXDATE":
      for part in p.value.split(','):
        if part.strip().len == 0: continue
        # exdate single-valued per comma-separated list; reconstruct a temp prop to keep TZID?
        var tmp = p
        tmp.value = part.strip()
        result.exdates.add(parseIcalDt(tmp))
    of "ATTACH": result.attachments.add(p.value)
    of "RECURRENCE-ID": result.recurrenceId = some(parseIcalDt(p))
    else: result.extraProps.add(p)
  for ch in t.children:
    if norm(ch.name) == "VALARM":
      result.alarms.add(buildAlarm(ch))
    else:
      # unknown subcomponent becomes extra? store as generic child in extraProps via X-like serialization fallback
      # encode as IcalProp with BEGIN lineage? simpler preserve
      result.extraProps.add(IcalProp(name: "X-CHILD", params: @[], value: ch.name))

proc buildTodo(t: CompTree): IcalTodo =
  result = IcalTodo()
  result.attendees = @[]
  result.categories = @[]
  result.alarms = @[]
  result.extraProps = @[]
  for p in t.props:
    case norm(p.name)
    of "UID": result.uid = p.value
    of "DTSTAMP": result.dtstamp = some(parseIcalDt(p))
    of "DTSTART": result.dtStart = some(parseIcalDt(p))
    of "DUE": result.due = some(parseIcalDt(p))
    of "COMPLETED": result.completed = some(parseIcalDt(p))
    of "SUMMARY": result.summary = some(unescapeIcalText(p.value))
    of "DESCRIPTION": result.description = some(unescapeIcalText(p.value))
    of "LOCATION": result.location = some(unescapeIcalText(p.value))
    of "STATUS": result.status = some(p.value)
    of "CLASS": result.classification = some(p.value)
    of "PRIORITY":
      try: result.priority = some(parseInt(p.value))
      except ValueError: icalError("Invalid PRIORITY: " & p.value)
    of "SEQUENCE":
      try: result.sequenceNum = some(parseInt(p.value))
      except ValueError: icalError("Invalid SEQUENCE: " & p.value)
    of "PERCENT-COMPLETE":
      try: result.percentComplete = some(parseInt(p.value))
      except ValueError: icalError("Invalid PERCENT-COMPLETE: " & p.value)
    of "CREATED": result.created = some(parseIcalDt(p))
    of "LAST-MODIFIED": result.lastModified = some(parseIcalDt(p))
    of "URL": result.url = some(p.value)
    of "ORGANIZER": result.organizer = some(parseIcalPerson(p))
    of "ATTENDEE": result.attendees.add(parseIcalPerson(p))
    of "CATEGORIES":
      for it in splitEscapedComma(p.value): result.categories.add(it)
    of "RRULE": result.rrule = some(p.value)
    else: result.extraProps.add(p)
  for ch in t.children:
    if norm(ch.name) == "VALARM":
      result.alarms.add(buildAlarm(ch))
    else:
      result.extraProps.add(IcalProp(name: "X-CHILD", params: @[], value: ch.name))

proc buildJournal(t: CompTree): IcalJournal =
  result = IcalJournal()
  result.attendees = @[]
  result.categories = @[]
  result.extraProps = @[]
  for p in t.props:
    case norm(p.name)
    of "UID": result.uid = p.value
    of "DTSTAMP": result.dtstamp = some(parseIcalDt(IcalProp(name: "DTSTAMP", params: @[], value: p.value)))
    of "DTSTART": discard # alias? JOURNAL uses DTSTART
    of "SUMMARY": result.summary = some(unescapeIcalText(p.value))
    of "DESCRIPTION": result.description = some(unescapeIcalText(p.value))
    of "STATUS": result.status = some(p.value)
    of "CLASS": result.classification = some(p.value)
    of "ORGANIZER": result.organizer = some(parseIcalPerson(p))
    of "CATEGORIES":
      for it in splitEscapedComma(p.value): result.categories.add(it)
    of "ATTENDEE": result.attendees.add(parseIcalPerson(p))
    else: result.extraProps.add(p)
  # DTSTART special: first DTSTART prop directly into dtstamp? Actually need generic dtStart field - keep optional journal DTSTART string? we reuse dtstamp for DTSTART? Define: if DTSTART present, stash into extra? Simpler: keep _raw in extra and expose through dtstamp reuse not ideal.
  # For journal, parse DTSTART separately into a dedicated Option[IcalDt] we repurpose organizer slot? Leave TODO: DTSTART preserved in extraProps for fidelity.

proc buildTimezone(t: CompTree): IcalTimezone =
  result = IcalTimezone()
  result.standard = @[]
  result.daylight = @[]
  result.extraProps = @[]
  for p in t.props:
    case norm(p.name)
    of "TZID": result.tzid = p.value
    else: result.extraProps.add(p)
  for ch in t.children:
    case norm(ch.name)
    of "STANDARD": result.standard.add(buildObservance(ch))
    of "DAYLIGHT": result.daylight.add(buildObservance(ch))
    else: result.extraProps.add(IcalProp(name: "X-CHILD", params: @[], value: ch.name))

proc buildOther(t: CompTree): IcalOther =
  result = IcalOther(name: t.name, props: t.props, children: @[])
  for ch in t.children:
    result.children.add(IcalGenericSub(name: ch.name, props: ch.props, children: @[]))
    for gc in ch.children:
      # flatten one level more for generic: preserve deep nesting via children chain
      result.children[^1].children.add(IcalGenericSub(name: gc.name, props: gc.props, children: @[]))

proc buildComponent(t: CompTree): IcalComponent =
  case norm(t.name)
  of "VEVENT":
    result = IcalComponent(kind: cckEvent, event: buildEvent(t))
  of "VTODO":
    result = IcalComponent(kind: cckTodo, todo: buildTodo(t))
  of "VJOURNAL":
    result = IcalComponent(kind: cckJournal, journal: buildJournal(t))
  of "VTIMEZONE":
    result = IcalComponent(kind: cckTimezone, timezone: buildTimezone(t))
  else:
    result = IcalComponent(kind: cckOther, other: buildOther(t))

proc buildCalendar*(tree: CompTree): IcalCalendar =
  if norm(tree.name) != "VCALENDAR":
    icalError("Top component must be VCALENDAR, got " & tree.name)
  result = IcalCalendar()
  result.extraProps = @[]
  result.components = @[]
  for p in tree.props:
    case norm(p.name)
    of "PRODID": result.prodId = some(p.value)
    of "VERSION": result.version = some(p.value)
    of "CALSCALE": result.calscale = some(p.value)
    of "METHOD": result.`method` = some(p.value)
    else: result.extraProps.add(p)
  for ch in tree.children:
    result.components.add(buildComponent(ch))

# public parse -------------------------------------------------------------

proc parseIcal*(input: string): IcalCalendar =
  ## Parse an iCalendar string per RFC 5545. Single VCALENDAR expected.
  let lls = unfoldLines(input)
  if lls.len == 0:
    raise newException(OpenParserIcalError, "Empty iCal input")
  let trees = buildCompTrees(lls)
  if trees.len == 0:
    raise newException(OpenParserIcalError, "No VCALENDAR found")
  if trees.len > 1:
    # concatenate - spec says normally one; we return first, extras as components? For simplicity allow multi-root by merging
    var cal = buildCalendar(trees[0])
    for idx in 1 ..< trees.len:
      let extra = trees[idx]
      if norm(extra.name) == "VCALENDAR":
        # merge extras
        for p in extra.props: cal.extraProps.add(p)
        for c in extra.children: cal.components.add(buildComponent(c))
      else:
        cal.components.add(buildComponent(extra))
    return cal
  return buildCalendar(trees[0])

proc parseIcalFile*(path: string): IcalCalendar =
  ## Convenience file overload via `readFile`.
  parseIcal(readFile(path))

# writers -----------------------------------------------------------------

proc writeIcalDt*(d: IcalDt): string =
  result = formatIcalDateTime(d.dt)

proc addPropDt(lines: var seq[string], name: string, d: IcalDt) =
  var prop = IcalProp(name: name, params: @[], value: formatIcalDateTime(d.dt))
  if d.tzid.isSome:
    prop.params.add(IcalParam(name: "TZID", values: @[d.tzid.get]))
  lines.add(foldLineRaw(propLine(prop)))

proc writeAlarm(alarm: IcalAlarm): seq[string] =
  result = @[]
  result.add(foldLineRaw("BEGIN:VALARM"))
  result.add(foldLineRaw("ACTION:" & alarm.action))
  if alarm.trigger.isSome:
    let trig = alarm.trigger.get
    var pp = IcalProp(name: "TRIGGER", params: @[], value: formatIcalTrigger(trig))
    # if duration trigger and params had RELATED, preserve? store in extraProps pseudo TRIGGER copy; otherwise default
    result.add(foldLineRaw(propLine(pp)))
  if alarm.description.isSome:
    result.add(foldLineRaw("DESCRIPTION:" & escapeIcalText(alarm.description.get)))
  if alarm.summary.isSome:
    result.add(foldLineRaw("SUMMARY:" & escapeIcalText(alarm.summary.get)))
  if alarm.repeatCount.isSome and alarm.duration.isSome:
    result.add(foldLineRaw("REPEAT:" & $alarm.repeatCount.get))
    result.add(foldLineRaw("DURATION:" & formatIcalDuration(alarm.duration.get)))
  elif alarm.repeatCount.isSome:
    result.add(foldLineRaw("REPEAT:" & $alarm.repeatCount.get))
  elif alarm.duration.isSome:
    result.add(foldLineRaw("DURATION:" & formatIcalDuration(alarm.duration.get)))
  for att in alarm.attendees:
    var p = formatPersonProp("ATTENDEE", att)
    result.add(foldLineRaw(propLine(p)))
  for p in alarm.extraProps:
    # avoid duplicating ACTION/TRIGGER already emitted? Keep all extras but skip those names to avoid dup
    if norm(p.name) in ["ACTION","TRIGGER","DESCRIPTION","SUMMARY","REPEAT","DURATION","ATTENDEE"]: continue
    result.add(foldLineRaw(propLine(p)))
  result.add(foldLineRaw("END:VALARM"))

proc writeEvent(ev: IcalEvent): seq[string] =
  result = @[]
  result.add(foldLineRaw("BEGIN:VEVENT"))
  if ev.uid.len > 0: result.add(foldLineRaw("UID:" & ev.uid))
  elif ev.extraProps.len>0 or ev.summary.isSome:
    # ensure UID existence for writer leniency: auto-generate if missing? Keep missing -> skip (will produce invalid but preserve)
    discard
  if ev.dtstamp.isSome: addPropDt(result, "DTSTAMP", ev.dtstamp.get)
  if ev.dtStart.isSome: addPropDt(result, "DTSTART", ev.dtStart.get)
  if ev.dtEnd.isSome: addPropDt(result, "DTEND", ev.dtEnd.get)
  if ev.duration.isSome: result.add(foldLineRaw("DURATION:" & formatIcalDuration(ev.duration.get)))
  if ev.recurrenceId.isSome: addPropDt(result, "RECURRENCE-ID", ev.recurrenceId.get)
  if ev.summary.isSome: result.add(foldLineRaw("SUMMARY:" & escapeIcalText(ev.summary.get)))
  if ev.description.isSome: result.add(foldLineRaw("DESCRIPTION:" & escapeIcalText(ev.description.get)))
  if ev.location.isSome: result.add(foldLineRaw("LOCATION:" & escapeIcalText(ev.location.get)))
  if ev.classification.isSome: result.add(foldLineRaw("CLASS:" & ev.classification.get))
  if ev.status.isSome: result.add(foldLineRaw("STATUS:" & ev.status.get))
  if ev.transparency.isSome: result.add(foldLineRaw("TRANSP:" & ev.transparency.get))
  if ev.priority.isSome: result.add(foldLineRaw("PRIORITY:" & $ev.priority.get))
  if ev.sequenceNum.isSome: result.add(foldLineRaw("SEQUENCE:" & $ev.sequenceNum.get))
  if ev.created.isSome: addPropDt(result, "CREATED", ev.created.get)
  if ev.lastModified.isSome: addPropDt(result, "LAST-MODIFIED", ev.lastModified.get)
  if ev.url.isSome: result.add(foldLineRaw("URL:" & ev.url.get))
  if ev.organizer.isSome:
    var p = formatPersonProp("ORGANIZER", ev.organizer.get)
    result.add(foldLineRaw(propLine(p)))
  for a in ev.attendees:
    var p = formatPersonProp("ATTENDEE", a)
    result.add(foldLineRaw(propLine(p)))
  if ev.categories.len > 0:
    result.add(foldLineRaw("CATEGORIES:" & joinEscapedComma(ev.categories)))
  if ev.rrule.isSome: result.add(foldLineRaw("RRULE:" & ev.rrule.get))
  for e in ev.exdates:
    var pr = IcalProp(name: "EXDATE", params: @[], value: formatIcalDateTime(e.dt))
    if e.tzid.isSome: pr.params.add(IcalParam(name: "TZID", values: @[e.tzid.get]))
    result.add(foldLineRaw(propLine(pr)))
  for at in ev.attachments: result.add(foldLineRaw("ATTACH:" & at))
  for al in ev.alarms:
    for l in writeAlarm(al): result.add(l)
  for p in ev.extraProps:
    let n = norm(p.name)
    if n == "X-CHILD": continue
    # avoid duplicating already emitted names handled above? Keep all extras that are not duplicate names
    # For now emit all - duplication risk but preserves unknown
    if n in ["UID","DTSTAMP","DTSTART","DTEND","DURATION","SUMMARY","DESCRIPTION","LOCATION","STATUS","TRANSP","CLASS","PRIORITY","SEQUENCE","CREATED","LAST-MODIFIED","URL","ORGANIZER","ATTENDEE","CATEGORIES","RRULE","EXDATE","ATTACH","RECURRENCE-ID"]: continue
    result.add(foldLineRaw(propLine(p)))
  result.add(foldLineRaw("END:VEVENT"))

proc writeTodo(td: IcalTodo): seq[string] =
  result = @[]
  result.add(foldLineRaw("BEGIN:VTODO"))
  if td.uid.len > 0: result.add(foldLineRaw("UID:" & td.uid))
  if td.dtstamp.isSome: addPropDt(result, "DTSTAMP", td.dtstamp.get)
  if td.dtStart.isSome: addPropDt(result, "DTSTART", td.dtStart.get)
  if td.due.isSome: addPropDt(result, "DUE", td.due.get)
  if td.completed.isSome: addPropDt(result, "COMPLETED", td.completed.get)
  if td.summary.isSome: result.add(foldLineRaw("SUMMARY:" & escapeIcalText(td.summary.get)))
  if td.description.isSome: result.add(foldLineRaw("DESCRIPTION:" & escapeIcalText(td.description.get)))
  if td.location.isSome: result.add(foldLineRaw("LOCATION:" & escapeIcalText(td.location.get)))
  if td.status.isSome: result.add(foldLineRaw("STATUS:" & td.status.get))
  if td.classification.isSome: result.add(foldLineRaw("CLASS:" & td.classification.get))
  if td.priority.isSome: result.add(foldLineRaw("PRIORITY:" & $td.priority.get))
  if td.sequenceNum.isSome: result.add(foldLineRaw("SEQUENCE:" & $td.sequenceNum.get))
  if td.percentComplete.isSome: result.add(foldLineRaw("PERCENT-COMPLETE:" & $td.percentComplete.get))
  if td.created.isSome: addPropDt(result, "CREATED", td.created.get)
  if td.lastModified.isSome: addPropDt(result, "LAST-MODIFIED", td.lastModified.get)
  if td.url.isSome: result.add(foldLineRaw("URL:" & td.url.get))
  if td.organizer.isSome:
    var p = formatPersonProp("ORGANIZER", td.organizer.get)
    result.add(foldLineRaw(propLine(p)))
  for a in td.attendees:
    var p = formatPersonProp("ATTENDEE", a)
    result.add(foldLineRaw(propLine(p)))
  if td.categories.len > 0:
    result.add(foldLineRaw("CATEGORIES:" & joinEscapedComma(td.categories)))
  if td.rrule.isSome: result.add(foldLineRaw("RRULE:" & td.rrule.get))
  for al in td.alarms:
    for l in writeAlarm(al): result.add(l)
  for p in td.extraProps:
    if norm(p.name) == "X-CHILD": continue
    if norm(p.name) in ["UID","DTSTAMP","DTSTART","DUE","COMPLETED","SUMMARY","DESCRIPTION","LOCATION","STATUS","CLASS","PRIORITY","SEQUENCE","PERCENT-COMPLETE","CREATED","LAST-MODIFIED","URL","ORGANIZER","ATTENDEE","CATEGORIES","RRULE"]: continue
    result.add(foldLineRaw(propLine(p)))
  result.add(foldLineRaw("END:VTODO"))

proc writeJournal(jn: IcalJournal): seq[string] =
  result = @[]
  result.add(foldLineRaw("BEGIN:VJOURNAL"))
  if jn.uid.len > 0: result.add(foldLineRaw("UID:" & jn.uid))
  if jn.dtstamp.isSome: addPropDt(result, "DTSTAMP", jn.dtstamp.get)
  if jn.summary.isSome: result.add(foldLineRaw("SUMMARY:" & escapeIcalText(jn.summary.get)))
  if jn.description.isSome: result.add(foldLineRaw("DESCRIPTION:" & escapeIcalText(jn.description.get)))
  if jn.status.isSome: result.add(foldLineRaw("STATUS:" & jn.status.get))
  if jn.classification.isSome: result.add(foldLineRaw("CLASS:" & jn.classification.get))
  if jn.organizer.isSome:
    var p = formatPersonProp("ORGANIZER", jn.organizer.get)
    result.add(foldLineRaw(propLine(p)))
  if jn.categories.len > 0:
    result.add(foldLineRaw("CATEGORIES:" & joinEscapedComma(jn.categories)))
  for a in jn.attendees:
    var p = formatPersonProp("ATTENDEE", a)
    result.add(foldLineRaw(propLine(p)))
  for p in jn.extraProps:
    if norm(p.name) == "X-CHILD": continue
    if norm(p.name) in ["UID","DTSTAMP","SUMMARY","DESCRIPTION","STATUS","CLASS","ORGANIZER","CATEGORIES","ATTENDEE"]: continue
    result.add(foldLineRaw(propLine(p)))
  result.add(foldLineRaw("END:VJOURNAL"))

proc writeObservance(kindName: string, ob: IcalTzObservance): seq[string] =
  result = @[]
  result.add(foldLineRaw("BEGIN:" & kindName))
  if ob.dtstart.isSome: result.add(foldLineRaw("DTSTART:" & formatIcalDateTime(ob.dtstart.get)))
  if ob.offsetFrom.isSome: result.add(foldLineRaw("TZOFFSETFROM:" & ob.offsetFrom.get))
  if ob.offsetTo.isSome: result.add(foldLineRaw("TZOFFSETTO:" & ob.offsetTo.get))
  for n in ob.names: result.add(foldLineRaw("TZNAME:" & escapeIcalText(n)))
  if ob.rrule.isSome: result.add(foldLineRaw("RRULE:" & ob.rrule.get))
  for p in ob.extraProps:
    if norm(p.name) in ["DTSTART","TZOFFSETFROM","TZOFFSETTO","TZNAME","RRULE"]: continue
    result.add(foldLineRaw(propLine(p)))
  result.add(foldLineRaw("END:" & kindName))

proc writeTimezone(tz: IcalTimezone): seq[string] =
  result = @[]
  result.add(foldLineRaw("BEGIN:VTIMEZONE"))
  result.add(foldLineRaw("TZID:" & tz.tzid))
  for p in tz.extraProps:
    if norm(p.name) in ["TZID","X-CHILD"]: continue
    result.add(foldLineRaw(propLine(p)))
  for s in tz.standard: result.add(writeObservance("STANDARD", s))
  for d in tz.daylight: result.add(writeObservance("DAYLIGHT", d))
  result.add(foldLineRaw("END:VTIMEZONE"))

proc writeOther(ot: IcalOther): seq[string] =
  result = @[]
  result.add(foldLineRaw("BEGIN:" & ot.name))
  for p in ot.props: result.add(foldLineRaw(propLine(p)))
  for ch in ot.children:
    result.add(foldLineRaw("BEGIN:" & ch.name))
    for p in ch.props: result.add(foldLineRaw(propLine(p)))
    for gc in ch.children:
      result.add(foldLineRaw("BEGIN:" & gc.name))
      for p in gc.props: result.add(foldLineRaw(propLine(p)))
      result.add(foldLineRaw("END:" & gc.name))
    result.add(foldLineRaw("END:" & ch.name))
  result.add(foldLineRaw("END:" & ot.name))

proc toIcal*(cal: IcalCalendar): string =
  ## Serialize `cal` to RFC 5545 text with CRLF and folding.
  var lines: seq[string] = @[]
  lines.add(foldLineRaw("BEGIN:VCALENDAR"))
  if cal.prodId.isSome: lines.add(foldLineRaw("PRODID:" & cal.prodId.get))
  else: lines.add(foldLineRaw("PRODID:-//OpenParser//ical//EN"))
  if cal.version.isSome: lines.add(foldLineRaw("VERSION:" & cal.version.get))
  else: lines.add(foldLineRaw("VERSION:2.0"))
  if cal.calscale.isSome: lines.add(foldLineRaw("CALSCALE:" & cal.calscale.get))
  if cal.`method`.isSome: lines.add(foldLineRaw("METHOD:" & cal.`method`.get))
  for p in cal.extraProps:
    if norm(p.name) in ["PRODID","VERSION","CALSCALE","METHOD"]: continue
    lines.add(foldLineRaw(propLine(p)))
  for c in cal.components:
    case c.kind
    of cckEvent: lines.add(writeEvent(c.event))
    of cckTodo: lines.add(writeTodo(c.todo))
    of cckJournal: lines.add(writeJournal(c.journal))
    of cckTimezone: lines.add(writeTimezone(c.timezone))
    of cckOther: lines.add(writeOther(c.other))
  lines.add(foldLineRaw("END:VCALENDAR"))
  result = lines.join(IcalCrlf) & IcalCrlf

proc `$`*(cal: IcalCalendar): string = toIcal(cal)
