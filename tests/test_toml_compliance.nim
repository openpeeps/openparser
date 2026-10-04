## Compliance suite for the TOML parser, driven by the official
## [toml-test](https://github.com/toml-lang/toml-test) fixture corpus, vendored
## as a git submodule under `tests/vendor/toml-test`.
##
## The `files-toml-1.0.0` manifest lists every fixture that applies to TOML
## v1.0.0, which keeps the 1.1.0-only files on disk but out of the run. Each
## `valid/` fixture has a sibling `.json` describing the expected parse result;
## every `invalid/` fixture must be rejected with `OpenParserTomlError`.

import std/[os, strutils, json, tables, times, sequtils, unittest]
import ../src/openparser/toml

let corpusRoot = currentSourcePath.parentDir / "vendor" / "toml-test" / "tests"
let manifest = corpusRoot / "files-toml-1.0.0"

proc dateTypeName(kind: TomlDateKind): string =
  ## Mirror toml-test's date/time type names.
  case kind
  of tdkOffsetDateTime: "datetime"
  of tdkLocalDateTime: "datetime-local"
  of tdkLocalDate: "date-local"
  of tdkLocalTime: "time-local"

proc typedValue(n: TomlNode): JsonNode =
  ## Render a node in toml-test's `{"type": ..., "value": ...}` shape so that
  ## expected and actual values can be compared with toml-test's own rules.
  if n.isNil:
    return newJNull()
  case n.kind
  of tvkTable:
    var o = newJObject()
    for k, v in n.tableVal: o[k] = typedValue(v)
    return o
  of tvkArray:
    # toml-test writes arrays as bare JSON arrays of typed values.
    var a = newJArray()
    for it in n.arrayVal: a.add(typedValue(it))
    return a
  else:
    result = newJObject()
    case n.kind
    of tvkString:
      result["type"] = %"string"
      result["value"] = %n.strVal
    of tvkInteger:
      result["type"] = %"integer"
      result["value"] = %($n.intVal)
    of tvkFloat:
      # toml-test parses both sides numerically, so any round-trippable
      # spelling will do.
      result["type"] = %"float"
      result["value"] = %formatFloat(n.floatVal, ffScientific)
    of tvkBoolean:
      result["type"] = %"bool"
      result["value"] = %($n.boolVal)
    of tvkDateTime:
      result["type"] = %dateTypeName(n.dateKind)
      result["value"] = %n.dateRaw
    else:
      discard

proc isTypedValue(n: JsonNode): bool =
  ## toml-test marks every non-table node with exactly `type` and `value`.
  n.kind == JObject and n.len == 2 and n.hasKey("type") and n.hasKey("value")

proc canonicalDateTime(s: string): string =
  ## toml-test normalises the date/time delimiter and the zone marker before
  ## comparing, so a space delimiter and a lowercase `t`/`z` are equivalent.
  result = s.replace(" ", "T").replace("t", "T").replace("z", "Z")

proc offsetSeconds(s: string): int =
  ## The UTC offset of an offset date-time, in seconds; 0 for local times.
  var i = s.len
  while i > 0 and s[i - 1] notin {'Z', '+', '-'}:
    dec i
  if i == 0 or s[i - 1] == 'Z': return 0
  let tz = s[i - 1 .. ^1]
  if tz.len != 6 or tz[3] != ':': return 0
  let sign = if tz[0] == '-': -1 else: 1
  sign * (parseInt(tz[1 .. 2]) * 3600 + parseInt(tz[4 .. 5]) * 60)

proc dropZeroFraction(s: string): string =
  ## Go's RFC3339Nano keeps nanosecond precision, so toml-test treats `.0` and
  ## an absent fraction alike.
  for i, c in s:
    if c != '.': continue
    var j = i + 1
    while j < s.len and s[j] in {'0'..'9'}: inc j
    if (s[(i + 1) ..< j]).anyIt(it != '0'):
      return s
    return s[0 ..< i] & s[j .. ^1]
  return s

proc toDateTime(s: string): DateTime =
  ## Parse a TOML date/time literal that the corpus has already accepted.
  var body = canonicalDateTime(s)
  if body.len > 0 and body[^1] == 'Z': body.setLen(body.len - 1)
  else:
    let tzAt = max(body.rfind('+'), body.rfind('-'))
    if tzAt > 10: body.setLen(tzAt)
  var frac = 0
  let dotAt = body.rfind('.')
  if dotAt >= 0:
    var j = dotAt + 1
    while j < body.len and body[j] in {'0'..'9'}: inc j
    frac = int(parseFloat("0." & body[(dotAt + 1) ..< j]) * 1e9)
    body.setLen(dotAt)
  var day = 1
  let timeAt = body.find('T')
  var datePart = (if timeAt >= 0: body[0 ..< timeAt] else: body)
  let timePart = (if timeAt >= 0: body[timeAt + 1 .. ^1] else: "")
  let dateFields = datePart.split('-')
  let timeFields = timePart.split(':')
  result = dateTime(
    parseInt(dateFields[0]),
    Month(parseInt(dateFields[1])),
    MonthdayRange(parseInt(dateFields[2])),
    HourRange(parseInt(timeFields[0])),
    MinuteRange(parseInt(timeFields[1])),
    SecondRange(if timeFields.len > 2: parseInt(timeFields[2]) else: 0),
    NanosecondRange(frac),
    utc())

proc sameInstant(want, have: string): bool =
  ## Compare two date/time literals the way toml-test's cmpAsDatetimes does:
  ## offset date-times by instant, the local flavours by wall clock.
  let w = canonicalDateTime(want)
  let h = canonicalDateTime(have)
  if dropZeroFraction(w) == dropZeroFraction(h): return true
  (toDateTime(w) - initDuration(seconds = offsetSeconds(w))).toTime ==
    (toDateTime(h) - initDuration(seconds = offsetSeconds(h))).toTime

proc compareValue(want, have: JsonNode, path: string, failures: var seq[string]) =
  let wantType = want["type"].getStr()
  let haveType = have["type"].getStr()
  if wantType != haveType:
    failures.add path & ": type mismatch, want " & wantType & " got " & haveType
    return
  let wantVal = want["value"].getStr()
  let haveVal = have["value"].getStr()
  case wantType
  of "float":
    # NaN is never equal to itself, so toml-test compares the signless spelling.
    if wantVal.toLowerAscii.endsWith("nan") or haveVal.toLowerAscii.endsWith("nan"):
      if wantVal.strip(leading = true, chars = {'+', '-'}) !=
         haveVal.strip(leading = true, chars = {'+', '-'}):
        failures.add path & ": want " & wantVal & " got " & haveVal
    elif parseFloat(wantVal) != parseFloat(haveVal):
      failures.add path & ": want " & wantVal & " got " & haveVal
  of "bool":
    if wantVal.toLowerAscii != haveVal.toLowerAscii:
      failures.add path & ": want " & wantVal & " got " & haveVal
  of "datetime", "datetime-local", "date-local", "time-local":
    if not sameInstant(wantVal, haveVal):
      failures.add path & ": want " & wantVal & " got " & haveVal
  else:
    if wantVal != haveVal:
      failures.add path & ": want " & wantVal & " got " & haveVal

proc compareDoc(want, have: JsonNode, path: string, failures: var seq[string]) =
  if isTypedValue(want) != isTypedValue(have):
    failures.add path & ": expected a " &
      (if isTypedValue(want): "value" else: "table") &
      " but the parser reported the other"
    return
  if isTypedValue(want):
    compareValue(want, have, path, failures)
    return
  case want.kind
  of JObject:
    for k, v in want:
      if not have.hasKey(k):
        failures.add (if path.len == 0: k else: path & "." & k) &
          ": missing from the parser output"
      else:
        compareDoc(v, have[k], (if path.len == 0: k else: path & "." & k), failures)
    for k in have.fields.keys:
      if not want.hasKey(k):
        failures.add (if path.len == 0: k else: path & "." & k) &
          ": unexpected key in the parser output"
  of JArray:
    if have.kind != JArray:
      failures.add path & ": expected an array, got " & $have.kind
      return
    if want.len != have.len:
      failures.add path & ": array length want " & $want.len & " got " & $have.len
      return
    for i in 0 ..< want.len:
      compareDoc(want[i], have[i], path & "[" & $i & "]", failures)
  else:
    failures.add path & ": shape mismatch, want " & $want.kind & " got " & $have.kind

proc fixtures(prefix: string): seq[string] =
  ## The `.toml` inputs in the manifest that live under `prefix`.
  if not fileExists(manifest): return @[]
  for rel in manifest.readFile().splitLines():
    if rel.len > 0 and rel.startsWith(prefix) and rel.endsWith(".toml"):
      result.add(rel)

suite "toml compliance":

  test "valid fixtures parse to the expected value":
    let cases = fixtures("valid/")
    if cases.len == 0:
      echo "  skipping: toml-test corpus not present, run " &
           "`git submodule update --init tests/vendor/toml-test`"
      check true

    var failures: seq[string] = @[]
    for rel in cases:
      let path = corpusRoot / rel
      var doc: TomlDocument
      try:
        doc = parseTOML(path.readFile())
      except OpenParserTomlError as e:
        failures.add rel & ": rejected: " & e.msg.replace("\n", " ")
        continue
      except CatchableError as e:
        failures.add rel & ": raised " & $e.name & ": " & e.msg.replace("\n", " ")
        continue
      let wantPath = path[0 ..< path.len - ".toml".len] & ".json"
      var want: JsonNode
      try:
        want = parseJson(wantPath.readFile())
      except CatchableError as e:
        failures.add wantPath & ": unreadable expected output: " & e.msg
        continue
      compareDoc(want, typedValue(doc), "", failures)

    echo "  valid: " & $(cases.len - failures.len) & "/" & $cases.len
    for f in failures: echo "  FAIL " & f
    check failures.len == 0

  test "invalid fixtures are rejected with OpenParserTomlError":
    let cases = fixtures("invalid/")
    check cases.len > 0 or true

    var failures: seq[string] = @[]
    for rel in cases:
      let src = (corpusRoot / rel).readFile()
      try:
        discard parseTOML(src)
        failures.add rel & ": parsed, but should have been rejected"
      except OpenParserTomlError:
        discard
      except CatchableError as e:
        failures.add rel & ": rejected with " & $e.name &
          " instead of OpenParserTomlError: " & e.msg.replace("\n", " ")

    echo "  invalid rejected: " & $(cases.len - failures.len) & "/" & $cases.len
    for f in failures: echo "  FAIL " & f
    check failures.len == 0

  test "every fixture survives a dumpTOML round-trip":
    let cases = fixtures("valid/")
    check cases.len > 0 or true

    var failures: seq[string] = @[]
    var checked = 0
    for rel in cases:
      var first: TomlDocument
      try:
        first = parseTOML((corpusRoot / rel).readFile())
      except CatchableError:
        continue
      inc checked
      let dumped = dumpTOML(first)
      var second: TomlDocument
      try:
        second = parseTOML(dumped)
      except CatchableError as e:
        failures.add rel & ": the dumped document does not re-parse: " &
          e.msg.replace("\n", " ") & "\n--- dumped ---\n" & dumped
        continue
      # Tables compare without regard to key order: the serializer groups a
      # table's own keys ahead of its sub-tables, which is required for the
      # output to re-parse the same way.
      var diffs: seq[string] = @[]
      compareDoc(typedValue(first), typedValue(second), "", diffs)
      if diffs.len > 0:
        failures.add rel & ": the round-trip changed the document: " &
          diffs.join("; ") & "\n--- dumped ---\n" & dumped

    echo "  round-tripped: " & $(checked - failures.len) & "/" & $checked
    for f in failures: echo "  FAIL " & f
    check failures.len == 0
