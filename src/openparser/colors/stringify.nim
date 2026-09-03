# A collection of tiny parsers and dumpers
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/openparser

import std/[strutils, math]
import ./types
import ./constants
import ./convert

proc toHex*(c: Color, allow3Char = false): string =
  let rgb = c.toRgb()
  if allow3Char and (rgb.r shr 4) == (rgb.r and 0xF) and (rgb.g shr 4) == (rgb.g and 0xF) and (rgb.b shr 4) == (rgb.b and 0xF):
    result = "#"
    result.add(toHex(rgb.r and 0xF, 1).toLowerAscii())
    result.add(toHex(rgb.g and 0xF, 1).toLowerAscii())
    result.add(toHex(rgb.b and 0xF, 1).toLowerAscii())
  else:
    result = "#"
    result.add(toHex(rgb.r, 2).toLowerAscii())
    result.add(toHex(rgb.g, 2).toLowerAscii())
    result.add(toHex(rgb.b, 2).toLowerAscii())

proc toHex8*(c: Color, allow4Char = false): string =
  let rgb = c.toRgb()
  let a = int(round(clamp01(c.a)*255.0))
  if allow4Char and (rgb.r shr 4) == (rgb.r and 0xF) and (rgb.g shr 4) == (rgb.g and 0xF) and (rgb.b shr 4) == (rgb.b and 0xF) and (a shr 4) == (a and 0xF):
    result = "#"
    result.add(toHex(rgb.r and 0xF, 1).toLowerAscii())
    result.add(toHex(rgb.g and 0xF, 1).toLowerAscii())
    result.add(toHex(rgb.b and 0xF, 1).toLowerAscii())
    result.add(toHex(a and 0xF, 1).toLowerAscii())
  else:
    result = "#"
    result.add(toHex(rgb.r, 2).toLowerAscii())
    result.add(toHex(rgb.g, 2).toLowerAscii())
    result.add(toHex(rgb.b, 2).toLowerAscii())
    result.add(toHex(a, 2).toLowerAscii())

proc formatAlpha(a: float): string =
  var s = formatFloat(clamp01(a), ffDecimal, 3)
  # strip trailing zeros
  while s.len > 0 and s[^1] == '0': s.setLen(s.len-1)
  if s.len > 0 and s[^1] == '.': s.setLen(s.len-1)
  if s.len == 0: s = "0"
  s

proc toRgbString*(c: Color): string =
  let rgb = c.toRgb()
  if c.a >= 1.0 - 1e-9:
    "rgb(" & $rgb.r & ", " & $rgb.g & ", " & $rgb.b & ")"
  else:
    "rgba(" & $rgb.r & ", " & $rgb.g & ", " & $rgb.b & ", " & formatAlpha(c.a) & ")"

proc toHslString*(c: Color): string =
  let hsl = c.toHsl()
  let h = int(round(hsl.h))
  let s = int(round(hsl.s*100))
  let l = int(round(hsl.l*100))
  if c.a >= 1.0 - 1e-9:
    "hsl(" & $h & ", " & $s & "%, " & $l & "%)"
  else:
    "hsla(" & $h & ", " & $s & "%, " & $l & "%, " & formatAlpha(c.a) & ")"

proc toHsvString*(c: Color): string =
  let hsv = c.toHsv()
  let h = int(round(hsv.h))
  let s = int(round(hsv.s*100))
  let v = int(round(hsv.v*100))
  if c.a >= 1.0 - 1e-9:
    "hsv(" & $h & ", " & $s & "%, " & $v & "%)"
  else:
    "hsva(" & $h & ", " & $s & "%, " & $v & "%, " & formatAlpha(c.a) & ")"

proc toCmykString*(c: Color): string =
  let cmyk = c.toCmyk()
  "cmyk(" & formatFloat(cmyk.c*100, ffDecimal, 1) & "%, " & formatFloat(cmyk.m*100, ffDecimal, 1) & "%, " & formatFloat(cmyk.y*100, ffDecimal, 1) & "%, " & formatFloat(cmyk.k*100, ffDecimal, 1) & "%)"

proc toLabString*(c: Color): string =
  let lab = c.toLab()
  "lab(" & formatFloat(lab.l, ffDecimal, 2) & " " & formatFloat(lab.a, ffDecimal, 2) & " " & formatFloat(lab.b, ffDecimal, 2) & ")"

proc toLchString*(c: Color): string =
  let lch = c.toLch()
  "lch(" & formatFloat(lch.l, ffDecimal, 2) & " " & formatFloat(lch.c, ffDecimal, 2) & " " & formatFloat(lch.h, ffDecimal, 2) & ")"

proc toOklabString*(c: Color): string =
  let o = c.toOklab()
  "oklab(" & formatFloat(o.l, ffDecimal, 3) & " " & formatFloat(o.a, ffDecimal, 3) & " " & formatFloat(o.b, ffDecimal, 3) & ")"

proc toOklchString*(c: Color): string =
  let o = c.toOklch()
  "oklch(" & formatFloat(o.l, ffDecimal, 3) & " " & formatFloat(o.c, ffDecimal, 3) & " " & formatFloat(o.h, ffDecimal, 2) & ")"

proc toString*(c: Color): string =
  case c.format
  of cfHex: c.toHex()
  of cfRgb: c.toRgbString()
  of cfHsl: c.toHslString()
  of cfHsv, cfHsb: c.toHsvString()
  of cfCmyk: c.toCmykString()
  of cfLab: c.toLabString()
  of cfLch: c.toLchString()
  of cfOklab: c.toOklabString()
  of cfOklch: c.toOklchString()
  else: c.toRgbString()

# --- chroma compatibility aliases ---
proc toHexAlpha*(c: Color): string =
  ## Alias for chroma `toHexAlpha` (no '#', uppercase). Returns with '#'
  ## for openparser consistency via toHex8; exposed for drop-in compat.
  c.toHex8()

proc toHtmlHex*(c: Color): string =
  ## Alias for chroma `toHtmlHex` ("#RRGGBB").
  c.toHex()

proc toHtmlHexTiny*(c: Color): string =
  ## Alias for chroma `toHtmlHexTiny` ("#RGB").
  c.toHex(allow3Char = true)

proc toHtmlRgb*(c: Color): string = c.toRgbString()
proc toHtmlRgba*(c: Color): string = c.toRgbString()
