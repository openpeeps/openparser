# A collection of tiny parsers and dumpers
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/openparser
import ./types
import ./constants
import ./convert

proc lighten*(c: Color, amount: float = 10.0): Color {.discardable.} =
  var hsl = c.toHsl()
  hsl.l = clamp01(hsl.l + amount/100.0)
  result = fromHsl(hsl)
  result.a = c.a
  result.format = c.format

proc darken*(c: Color, amount: float = 10.0): Color {.discardable.} =
  var hsl = c.toHsl()
  hsl.l = clamp01(hsl.l - amount/100.0)
  result = fromHsl(hsl)
  result.a = c.a
  result.format = c.format

proc saturate*(c: Color, amount: float = 10.0): Color {.discardable.} =
  var hsl = c.toHsl()
  hsl.s = clamp01(hsl.s + amount/100.0)
  result = fromHsl(hsl)
  result.a = c.a
  result.format = c.format

proc desaturate*(c: Color, amount: float = 10.0): Color {.discardable.} =
  var hsl = c.toHsl()
  hsl.s = clamp01(hsl.s - amount/100.0)
  result = fromHsl(hsl)
  result.a = c.a
  result.format = c.format

proc greyscale*(c: Color): Color {.discardable.} =
  c.desaturate(100.0)

proc spin*(c: Color, amount: float): Color {.discardable.} =
  var hsl = c.toHsl()
  hsl.h = hueMod(hsl.h + amount)
  result = fromHsl(hsl)
  result.a = c.a
  result.format = c.format

proc brighten*(c: Color, amount: float = 10.0): Color {.discardable.} =
  # increase RGB by amount%
  let amt = amount/100.0
  Color(r: clamp01(c.r + amt), g: clamp01(c.g + amt), b: clamp01(c.b + amt), a: c.a, format: c.format, valid: true)

proc mix*(a, b: Color, weight: float = 50.0): Color {.discardable.} =
  let w = clamp(weight/100.0, 0.0, 1.0)
  let w1 = 1.0 - w
  Color(r: clamp01(a.r*w1 + b.r*w), g: clamp01(a.g*w1 + b.g*w), b: clamp01(a.b*w1 + b.b*w), a: clamp01(a.a*w1 + b.a*w), format: a.format, valid: true)

proc tint*(c: Color, amount: float = 10.0): Color {.discardable.} =
  let white = Color(r: 1, g: 1, b: 1, a: 1, format: cfRgb, valid: true)
  mix(c, white, amount)

proc shade*(c: Color, amount: float = 10.0): Color {.discardable.} =
  let black = Color(r: 0, g: 0, b: 0, a: 1, format: cfRgb, valid: true)
  mix(c, black, amount)

proc setAlpha*(c: Color, a: float): Color {.discardable.} =
  Color(r: c.r, g: c.g, b: c.b, a: clamp01(a), format: c.format, valid: true)

proc fadeIn*(c: Color, amount: float = 10.0): Color {.discardable.} =
  Color(r: c.r, g: c.g, b: c.b, a: clamp01(c.a + amount/100.0), format: c.format, valid: true)

proc fadeOut*(c: Color, amount: float = 10.0): Color {.discardable.} =
  Color(r: c.r, g: c.g, b: c.b, a: clamp01(c.a - amount/100.0), format: c.format, valid: true)

proc complement*(c: Color): Color {.discardable.} =
  c.spin(180.0)

proc mixCMYK*(a, b: Color, weight: float = 50.0): Color {.discardable.} =
  ## Mix two colors via CMYK interpolation (chroma compat).
  ## When weight == 50, simple average; otherwise lerp in CMYK space.
  let w = clamp(weight/100.0, 0.0, 1.0)
  let ca = a.toCmyk()
  let cb = b.toCmyk()
  var c: Cmyk
  c.c = clamp01(ca.c*(1.0 - w) + cb.c*w)
  c.m = clamp01(ca.m*(1.0 - w) + cb.m*w)
  c.y = clamp01(ca.y*(1.0 - w) + cb.y*w)
  c.k = clamp01(ca.k*(1.0 - w) + cb.k*w)
  c.a = clamp01(a.a*(1.0 - w) + b.a*w)
  result = fromCmyk(c)
  result.format = a.format

proc almostEqual*(a, b: Color, eps: float = 0.01): bool =
  ## Chroma compat: true if r,g,b within eps (ignores alpha, like chroma).
  abs(a.r - b.r) <= eps and abs(a.g - b.g) <= eps and abs(a.b - b.b) <= eps
