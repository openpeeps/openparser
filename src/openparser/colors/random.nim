# A collection of tiny parsers and dumpers
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/openparser

import std/[random, strutils]
import ./types
import ./constants
import ./convert

type Luminosity* = enum
  lmRandom
  lmBright
  lmLight
  lmDark

type RandomColorOptions* = object
  hue*: string ## "" random, or "red","orange","yellow","green","blue","purple","pink","monochrome"
  luminosity*: Luminosity
  alpha*: float ## -1 means opaque 1.0, else 0..1
  format*: ColorFormat

proc randomInRange(r: var Rand, lo, hi: float): float =
  lo + r.rand(1.0)*(hi - lo)

proc hueRange(name: string): tuple[lo,hi: float] =
  case name.toLowerAscii()
  of "red": (0.0, 20.0)
  of "orange": (20.0, 45.0)
  of "yellow": (45.0, 70.0)
  of "green": (70.0, 175.0)
  of "blue": (175.0, 260.0)
  of "purple": (260.0, 290.0)
  of "pink": (290.0, 350.0)
  else: (0.0, 360.0)

proc randomColor*(opts = RandomColorOptions(alpha: -1.0)): Color =
  var r = initRand(rand(int.high))
  var h: float
  if opts.hue == "" or opts.hue.toLowerAscii() == "random":
    h = r.rand(360.0)
  elif opts.hue.toLowerAscii() == "monochrome":
    h = 0.0
  else:
    let rg = hueRange(opts.hue)
    # handle wrap for red which crosses 360
    if rg.lo == 0.0 and rg.hi == 20.0:
      # 20% chance to pick near 360
      if r.rand(1.0) < 0.5:
        h = r.randomInRange(rg.lo, rg.hi)
      else:
        h = r.randomInRange(350.0, 360.0)
    else:
      h = r.randomInRange(rg.lo, rg.hi)
  var s, v: float
  let isMono = opts.hue.toLowerAscii() == "monochrome"
  if isMono:
    s = 0.0
    case opts.luminosity
    of lmBright, lmLight: v = r.randomInRange(0.6, 1.0)
    of lmDark: v = r.randomInRange(0.0, 0.5)
    else: v = r.rand(1.0)
  else:
    case opts.luminosity
    of lmBright:
      s = r.randomInRange(0.7, 1.0)
      v = r.randomInRange(0.7, 1.0)
    of lmLight:
      s = r.randomInRange(0.3, 0.7)
      v = r.randomInRange(0.7, 1.0)
    of lmDark:
      s = r.randomInRange(0.7, 1.0)
      v = r.randomInRange(0.3, 0.7)
    else:
      s = r.rand(1.0)
      v = r.rand(1.0)
      if s < 0.1: s = 0.1 + r.rand(0.9)
      if v < 0.2: v = 0.2 + r.rand(0.8)
  var alpha = 1.0
  if opts.alpha >= 0.0: alpha = clamp01(opts.alpha)
  let hsv = Hsv(h: hueMod(h), s: clamp01(s), v: clamp01(v), a: alpha)
  var col = fromHsv(hsv)
  col.format = opts.format
  col

proc randomColors*(count: int, opts = RandomColorOptions(alpha: -1.0)): seq[Color] =
  result = @[]
  for i in 0..<count:
    result.add(randomColor(opts))
