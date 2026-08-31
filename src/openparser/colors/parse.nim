# A collection of tiny parsers and dumpers
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/openparser

import std/[strutils, tables]
import ./types
import ./constants
import ./convert
import ./names

proc error(msg: string) =
  raise newException(ParserColorError, msg)

proc isHexDigit(c: char): bool = c in {'0'..'9', 'a'..'f', 'A'..'F'}

proc hexVal(c: char): int =
  case c
  of '0'..'9': ord(c)-ord('0')
  of 'a'..'f': ord(c)-ord('a')+10
  of 'A'..'F': ord(c)-ord('A')+10
  else: 0

proc parseHexColor*(s: string): Color =
  var hex = s.strip()
  if hex.len == 0: error("empty color")
  if hex[0] == '#':
    hex = hex[1..^1]
  # allow only hex digits
  for ch in hex:
    if not isHexDigit(ch):
      error("invalid hex color: " & s)
  case hex.len
  of 3:
    let r = hexVal(hex[0])*16 + hexVal(hex[0])
    let g = hexVal(hex[1])*16 + hexVal(hex[1])
    let b = hexVal(hex[2])*16 + hexVal(hex[2])
    result = Color(r: float(r)/255.0, g: float(g)/255.0, b: float(b)/255.0, a: 1.0, format: cfHex, valid: true)
  of 4:
    let r = hexVal(hex[0])*16 + hexVal(hex[0])
    let g = hexVal(hex[1])*16 + hexVal(hex[1])
    let b = hexVal(hex[2])*16 + hexVal(hex[2])
    let a = hexVal(hex[3])*16 + hexVal(hex[3])
    result = Color(r: float(r)/255.0, g: float(g)/255.0, b: float(b)/255.0, a: float(a)/255.0, format: cfHex, valid: true)
  of 6:
    let r = hexVal(hex[0])*16 + hexVal(hex[1])
    let g = hexVal(hex[2])*16 + hexVal(hex[3])
    let b = hexVal(hex[4])*16 + hexVal(hex[5])
    result = Color(r: float(r)/255.0, g: float(g)/255.0, b: float(b)/255.0, a: 1.0, format: cfHex, valid: true)
  of 8:
    let r = hexVal(hex[0])*16 + hexVal(hex[1])
    let g = hexVal(hex[2])*16 + hexVal(hex[3])
    let b = hexVal(hex[4])*16 + hexVal(hex[5])
    let a = hexVal(hex[6])*16 + hexVal(hex[7])
    result = Color(r: float(r)/255.0, g: float(g)/255.0, b: float(b)/255.0, a: float(a)/255.0, format: cfHex, valid: true)
  else:
    error("invalid hex length: " & s)

proc looksLikeHex(s: string): bool =
  var h = s.strip()
  if h.len == 0: return false
  if h[0] == '#': h = h[1..^1]
  if h.len notin [3,4,6,8]: return false
  for ch in h:
    if not isHexDigit(ch): return false
  true

proc extractFuncName(s: string): string =
  let idx = s.find('(')
  if idx < 0: return ""
  s[0..<idx].strip().toLowerAscii()

proc extractInside(s: string): string =
  let a = s.find('(')
  let b = s.rfind(')')
  if a < 0 or b < 0 or b <= a: return ""
  s[a+1..<b]

proc splitValues(s: string): seq[string] =
  # split by comma, space, slash; keep slash as separate token
  var cur = ""
  for i, ch in s:
    if ch == ',' :
      if cur.strip().len > 0: result.add(cur.strip())
      cur = ""
    elif ch == '/':
      if cur.strip().len > 0: result.add(cur.strip())
      result.add("/")
      cur = ""
    elif ch in {' ', '\t', '\n', '\r'}:
      if cur.strip().len > 0:
        result.add(cur.strip())
        cur = ""
    else:
      cur.add(ch)
  if cur.strip().len > 0: result.add(cur.strip())

proc parseComponent(s: string, isAlpha=false): float =
  var t = s.strip()
  if t.len == 0: error("empty component")
  var isPct = false
  if t.endsWith("%"):
    isPct = true
    t = t[0..^2]
  let v = parseFloat(t)
  if isPct:
    if isAlpha: return clamp01(v/100.0)
    else: return v/100.0 # caller will scale if needed
  else:
    if isAlpha:
      # alpha may be 0..1 or 0..100%? already handled pct, so 0..1
      return clamp01(v)
    else:
      return v

proc parseRgbString(s: string): Color =
  let inside = extractInside(s)
  var parts = splitValues(inside)
  # handle slash alpha
  var alpha = 1.0
  var slashIdx = parts.find("/")
  if slashIdx >= 0:
    if slashIdx+1 < parts.len:
      alpha = parseComponent(parts[slashIdx+1], true)
    parts = parts[0..<slashIdx]
  if parts.len < 3: error("rgb requires 3 components")
  # each of first 3 may be % or 0..255
  var comps: array[3, float]
  for i in 0..<3:
    let p = parts[i]
    if p.endsWith("%"):
      comps[i] = parseFloat(p[0..^2])/100.0
    else:
      comps[i] = clamp01(parseFloat(p)/255.0)
  if parts.len >= 4 and slashIdx < 0:
    # legacy rgba comma with 4th arg
    alpha = parseComponent(parts[3], true)
  Color(r: clamp01(comps[0]), g: clamp01(comps[1]), b: clamp01(comps[2]), a: clamp01(alpha), format: cfRgb, valid: true)

proc parseHslString(s: string): Color =
  let inside = extractInside(s)
  var parts = splitValues(inside)
  var alpha = 1.0
  var slashIdx = parts.find("/")
  if slashIdx >= 0:
    if slashIdx+1 < parts.len:
      alpha = parseComponent(parts[slashIdx+1], true)
    parts = parts[0..<slashIdx]
  if parts.len < 3: error("hsl requires 3 components")
  let h = parseFloat(parts[0].replace("deg","").replace("rad","").replace("grad","").replace("turn",""))
  # if contains rad etc would need conversion but assume deg for now
  var sVal = 0.0; var lVal = 0.0
  if parts[1].endsWith("%"):
    sVal = parseFloat(parts[1][0..^2])/100.0
  else: sVal = parseFloat(parts[1])
  if parts[2].endsWith("%"):
    lVal = parseFloat(parts[2][0..^2])/100.0
  else: lVal = parseFloat(parts[2])
  if parts.len >= 4 and slashIdx < 0:
    alpha = parseComponent(parts[3], true)
  fromHsl(Hsl(h: hueMod(h), s: clamp01(sVal), l: clamp01(lVal), a: clamp01(alpha)))

proc parseHsvString(s: string): Color =
  let inside = extractInside(s)
  var parts = splitValues(inside)
  var alpha = 1.0
  var slashIdx = parts.find("/")
  if slashIdx >= 0:
    if slashIdx+1 < parts.len:
      alpha = parseComponent(parts[slashIdx+1], true)
    parts = parts[0..<slashIdx]
  if parts.len < 3: error("hsv requires 3 components")
  let h = parseFloat(parts[0])
  var sVal = 0.0; var vVal = 0.0
  if parts[1].endsWith("%"): sVal = parseFloat(parts[1][0..^2])/100.0 else: sVal = parseFloat(parts[1])
  if parts[2].endsWith("%"): vVal = parseFloat(parts[2][0..^2])/100.0 else: vVal = parseFloat(parts[2])
  if parts.len >= 4 and slashIdx < 0:
    alpha = parseComponent(parts[3], true)
  fromHsv(Hsv(h: hueMod(h), s: clamp01(sVal), v: clamp01(vVal), a: clamp01(alpha)))

proc parseCmykString(s: string): Color =
  let inside = extractInside(s)
  var parts = splitValues(inside)
  if parts.len < 4: error("cmyk requires 4 components")
  var vals: array[4, float]
  for i in 0..<4:
    let p = parts[i]
    if p.endsWith("%"): vals[i] = parseFloat(p[0..^2])/100.0 else: vals[i] = parseFloat(p)
    vals[i] = clamp01(vals[i])
  var alpha = 1.0
  if parts.len >= 5:
    alpha = parseComponent(parts[4], true)
  fromCmyk(Cmyk(c: vals[0], m: vals[1], y: vals[2], k: vals[3], a: clamp01(alpha)))

proc parseLabString(s: string): Color =
  let inside = extractInside(s)
  var parts = splitValues(inside)
  # lab(50% 40 30) or lab(50 40 30)
  if parts.len < 3: error("lab requires 3 components")
  var l = 0.0
  if parts[0].endsWith("%"): l = parseFloat(parts[0][0..^2]) # 0..100 keep
  else: l = parseFloat(parts[0])
  let a = parseFloat(parts[1])
  let b = parseFloat(parts[2])
  var alpha = 1.0
  var slashIdx = parts.find("/")
  if slashIdx >= 0 and slashIdx+1 < parts.len:
    alpha = parseComponent(parts[slashIdx+1], true)
  elif parts.len >= 4:
    # maybe no slash but 4th is alpha? not standard but allow
    if slashIdx < 0 and parts.len == 4:
      # ambiguous, treat as alpha only if contains slash earlier? skip
      discard
  fromLab(Lab(l: l, a: a, b: b, alpha: clamp01(alpha)))

proc parseLchString(s: string): Color =
  let inside = extractInside(s)
  var parts = splitValues(inside)
  if parts.len < 3: error("lch requires 3 components")
  var l = 0.0
  if parts[0].endsWith("%"): l = parseFloat(parts[0][0..^2]) else: l = parseFloat(parts[0])
  var c = 0.0
  if parts[1].endsWith("%"): c = parseFloat(parts[1][0..^2]) else: c = parseFloat(parts[1])
  let h = parseFloat(parts[2])
  var alpha = 1.0
  var slashIdx = parts.find("/")
  if slashIdx >= 0 and slashIdx+1 < parts.len:
    alpha = parseComponent(parts[slashIdx+1], true)
  fromLch(Lch(l: l, c: c, h: hueMod(h), alpha: clamp01(alpha)))

proc parseOklabString(s: string): Color =
  let inside = extractInside(s)
  var parts = splitValues(inside)
  if parts.len < 3: error("oklab requires 3 components")
  var l = 0.0
  if parts[0].endsWith("%"): l = parseFloat(parts[0][0..^2])/100.0 else: l = parseFloat(parts[0])
  let a = parseFloat(parts[1])
  let b = parseFloat(parts[2])
  var alpha = 1.0
  var slashIdx = parts.find("/")
  if slashIdx >= 0 and slashIdx+1 < parts.len:
    alpha = parseComponent(parts[slashIdx+1], true)
  fromOklab(Oklab(l: l, a: a, b: b, alpha: clamp01(alpha)))

proc parseOklchString(s: string): Color =
  let inside = extractInside(s)
  var parts = splitValues(inside)
  if parts.len < 3: error("oklch requires 3 components")
  var l = 0.0
  if parts[0].endsWith("%"): l = parseFloat(parts[0][0..^2])/100.0 else: l = parseFloat(parts[0])
  var c = 0.0
  if parts[1].endsWith("%"): c = parseFloat(parts[1][0..^2]) else: c = parseFloat(parts[1])
  let h = parseFloat(parts[2])
  var alpha = 1.0
  var slashIdx = parts.find("/")
  if slashIdx >= 0 and slashIdx+1 < parts.len:
    alpha = parseComponent(parts[slashIdx+1], true)
  fromOklchToColor(Oklch(l: l, c: c, h: hueMod(h), alpha: clamp01(alpha)))

proc parseColor*(s: string): Color =
  let input = s.strip()
  if input.len == 0: error("empty color string")
  let lower = input.toLowerAscii()
  if lower == "transparent":
    return Color(r: 0, g: 0, b: 0, a: 0, format: cfRgb, valid: true)
  # named?
  initNamedTable()
  if namedTable.hasKey(lower):
    let rgb = namedTable[lower]
    return Color(r: float(rgb.r)/255.0, g: float(rgb.g)/255.0, b: float(rgb.b)/255.0, a: 1.0, format: cfNamed, valid: true)
  # hex?
  if looksLikeHex(input):
    return parseHexColor(input)
  # function?
  if lower.contains("(") and lower.contains(")"):
    let fname = extractFuncName(lower)
    case fname
    of "rgb", "rgba":
      return parseRgbString(input)
    of "hsl", "hsla":
      return parseHslString(input)
    of "hsv", "hsva", "hsb", "hsba":
      return parseHsvString(input)
    of "hwb":
      # hwb not fully impl, fallback via hsv? parse as hsv? Better parse simple
      # hwb(h w% b%)
      let inside = extractInside(input)
      var parts = splitValues(inside)
      var alpha = 1.0
      var slashIdx = parts.find("/")
      if slashIdx >= 0 and slashIdx+1 < parts.len:
        alpha = parseComponent(parts[slashIdx+1], true)
        parts = parts[0..<slashIdx]
      if parts.len < 3: error("hwb requires 3 components")
      let h = parseFloat(parts[0])
      var w = 0.0; var bv = 0.0
      if parts[1].endsWith("%"): w = parseFloat(parts[1][0..^2])/100.0 else: w = parseFloat(parts[1])
      if parts[2].endsWith("%"): bv = parseFloat(parts[2][0..^2])/100.0 else: bv = parseFloat(parts[2])
      return fromHwb(Hwb(h: hueMod(h), w: clamp01(w), b: clamp01(bv), a: clamp01(alpha)))
    of "cmyk", "device-cmyk":
      return parseCmykString(input)
    of "lab":
      return parseLabString(input)
    of "lch":
      return parseLchString(input)
    of "oklab":
      return parseOklabString(input)
    of "oklch":
      return parseOklchString(input)
    of "color":
      # color(srgb 1 0 0) simplified: assume srgb
      let inside = extractInside(input).strip().toLowerAscii()
      # remove colorspace prefix
      var tokens = splitValues(inside)
      var startIdx = 0
      if tokens.len > 0 and tokens[0] in ["srgb", "srgb-linear", "display-p3", "a98-rgb", "prophoto-rgb", "rec2020", "xyz", "xyz-d50", "xyz-d65"]:
        startIdx = 1
      var vals: seq[float] = @[]
      for i in startIdx..<tokens.len:
        if tokens[i] == "/": continue
        vals.add(parseFloat(tokens[i]))
      if vals.len >= 3:
        var a = 1.0
        if tokens.find("/") >= 0:
          let si = tokens.find("/")
          if si+1 < tokens.len:
            a = parseComponent(tokens[si+1], true)
        return Color(r: clamp01(vals[0]), g: clamp01(vals[1]), b: clamp01(vals[2]), a: clamp01(a), format: cfRgb, valid: true)
      error("invalid color()")
    else:
      error("unsupported color function: " & fname)
  # fallback: try hex without hash already covered, maybe bare hex with invalid length?
  # if not matched, error
  error("unable to parse color: " & s)

proc isValidColor*(s: string): bool =
  try:
    discard parseColor(s)
    true
  except ParserColorError:
    false
  except:
    false
