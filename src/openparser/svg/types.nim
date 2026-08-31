# A collection of tiny parsers and dumpers
#
# (c) 2026 George Lemon | MIT License

import std/[strutils, options, math]

type
  SvgLengthUnit* = enum
    luNumber      # no unit -> px
    luPx = "px"
    luPercent = "%"
    luEm = "em"
    luEx = "ex"
    luPt = "pt"
    luPc = "pc"
    luCm = "cm"
    luMm = "mm"
    luIn = "in"

  SvgLength* = object
    value*: float
    unit*: SvgLengthUnit
    raw*: string

  SvgViewBox* = object
    minX*, minY*, width*, height*: float

  SvgPreserveAspect* = object
    align*: string  # e.g. xMidYMid
    meetOrSlice*: string # meet | slice | none

  SvgTransformKind* = enum
    trMatrix
    trTranslate
    trScale
    trRotate
    trSkewX
    trSkewY

  SvgTransform* = object
    kind*: SvgTransformKind
    values*: seq[float]  # matrix(6) translate(1-2) scale(1-2) rotate(1-3) skew(1)

proc defaultSvgLength*(v: float = 0): SvgLength =
  SvgLength(value: v, unit: luNumber, raw: $v)

proc svgLengthToString*(l: SvgLength): string =
  if l.raw.len > 0:
    return l.raw
  let isInt = abs(l.value - round(l.value)) < 1e-9
  let num = if isInt: $int(round(l.value)) else: formatFloat(l.value, ffDecimal, 6).strip(chars={'0'}, trailing=true).strip(chars={'.'}, trailing=true)
  case l.unit
  of luNumber: num
  of luPercent: num & "%"
  else: num & $l.unit

proc parseSvgLength*(s: string): SvgLength =
  let t = s.strip()
  if t.len == 0:
    return SvgLength(value: 0, unit: luNumber, raw: t)
  # parse number with proper exponent handling
  var numEnd = 0
  var i = 0
  if i < t.len and t[i] in {'-', '+'}: inc i
  var hasDigits = false
  while i < t.len and t[i] in {'0'..'9'}:
    hasDigits = true; inc i
  if i < t.len and t[i] == '.':
    inc i
    while i < t.len and t[i] in {'0'..'9'}:
      hasDigits = true; inc i
  if hasDigits and i < t.len and t[i] in {'e','E'}:
    var expPos = i
    inc i
    if i < t.len and t[i] in {'-', '+'}: inc i
    var expDigits = 0
    while i < t.len and t[i] in {'0'..'9'}:
      inc expDigits; inc i
    if expDigits == 0:
      i = expPos # not an exponent, roll back
  numEnd = i
  if numEnd == 0:
    return SvgLength(value: 0, unit: luNumber, raw: t)
  let numStr = t[0..<numEnd]
  let unitStr = t[numEnd..^1].strip().toLowerAscii()
  let v = try: parseFloat(numStr) except: 0.0
  let unit = case unitStr
    of "px": luPx
    of "%": luPercent
    of "em": luEm
    of "ex": luEx
    of "pt": luPt
    of "pc": luPc
    of "cm": luCm
    of "mm": luMm
    of "in": luIn
    of "": luNumber
    else: luNumber
  SvgLength(value: v, unit: unit, raw: t)

proc parseSvgViewBox*(s: string): SvgViewBox =
  let parts = s.strip().splitWhitespace()
  # also split by comma
  var nums: seq[float] = @[]
  for p in parts:
    for c in p.split(','):
      let cc = c.strip()
      if cc.len > 0:
        nums.add(parseFloat(cc))
  if nums.len != 4:
    raise newException(ValueError, "viewBox requires 4 numbers: " & s)
  SvgViewBox(minX: nums[0], minY: nums[1], width: nums[2], height: nums[3])

proc formatNum(v: float): string =
  let isInt = abs(v - round(v)) < 1e-9
  if isInt: $int(round(v)) else: formatFloat(v, ffDecimal, 6).strip(chars={'0'}, trailing=true).strip(chars={'.'}, trailing=true)

proc viewBoxToString*(vb: SvgViewBox): string =
  formatNum(vb.minX) & " " & formatNum(vb.minY) & " " & formatNum(vb.width) & " " & formatNum(vb.height)

proc parsePreserveAspectRatio*(s: string): SvgPreserveAspect =
  let t = s.strip()
  let parts = t.splitWhitespace()
  if parts.len == 0:
    return SvgPreserveAspect(align: "xMidYMid", meetOrSlice: "meet")
  if parts[0] == "none":
    return SvgPreserveAspect(align: "none", meetOrSlice: "meet")
  let align = parts[0]
  let ms = if parts.len > 1: parts[1] else: "meet"
  SvgPreserveAspect(align: align, meetOrSlice: ms)

proc preserveAspectToString*(p: SvgPreserveAspect): string =
  if p.align == "none": "none"
  elif p.meetOrSlice == "meet" and p.align == "xMidYMid": p.align
  else: p.align & " " & p.meetOrSlice

proc parseSvgTransform*(s: string): seq[SvgTransform] =
  result = @[]
  var i = 0
  let str = s.strip()
  while i < str.len:
    while i < str.len and str[i] in {' ', '\t', '\n', '\r', ','}: inc i
    if i >= str.len: break
    var nameStart = i
    while i < str.len and str[i] in {'a'..'z', 'A'..'Z'}: inc i
    if i == nameStart:
      inc i
      continue
    let name = str[nameStart..<i].toLowerAscii()
    while i < str.len and str[i] in {' ', '\t', '\n', '\r'}: inc i
    if i >= str.len or str[i] != '(':
      continue
    inc i # '('
    var args: seq[float] = @[]
    var cur = ""
    var depth = 1
    while i < str.len and depth > 0:
      let ch = str[i]
      if ch == '(':
        inc depth
        cur.add(ch)
      elif ch == ')':
        dec depth
        if depth == 0:
          if cur.strip().len > 0:
            for a in cur.strip().split({' ', '\t', '\n', '\r', ','}):
              if a.strip().len > 0:
                try: args.add(parseFloat(a.strip())) except: discard
          cur = ""
          inc i
          break
        else:
          cur.add(ch)
      else:
        cur.add(ch)
      inc i
    var kind: SvgTransformKind
    case name
    of "matrix": kind = trMatrix
    of "translate": kind = trTranslate
    of "scale": kind = trScale
    of "rotate": kind = trRotate
    of "skewx": kind = trSkewX
    of "skewy": kind = trSkewY
    else: continue
    result.add(SvgTransform(kind: kind, values: args))

proc transformToString*(t: SvgTransform): string =
  let name = case t.kind
    of trMatrix: "matrix"
    of trTranslate: "translate"
    of trScale: "scale"
    of trRotate: "rotate"
    of trSkewX: "skewX"
    of trSkewY: "skewY"
  var args: seq[string] = @[]
  for v in t.values:
    let isInt = abs(v - round(v)) < 1e-9
    args.add(if isInt: $int(round(v)) else: formatFloat(v, ffDecimal, 6).strip(chars={'0'}, trailing=true).strip(chars={'.'}, trailing=true))
  name & "(" & args.join(" ") & ")"

proc transformsToString*(ts: seq[SvgTransform]): string =
  var parts: seq[string] = @[]
  for t in ts:
    parts.add(transformToString(t))
  parts.join(" ")
