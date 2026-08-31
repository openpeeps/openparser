# A collection of tiny parsers and dumpers
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/openparser
import std/math

const
  # D65 reference white
  Xn* = 95.047
  Yn* = 100.0
  Zn* = 108.883

  # sRGB -> XYZ matrix
  SRgbToXyz* = [
    [0.4124564, 0.3575761, 0.1804375],
    [0.2126729, 0.7151522, 0.0721750],
    [0.0193339, 0.1191920, 0.9503041]
  ]
  XyzToSrgb* = [
    [ 3.2404542, -1.5371385, -0.4985314],
    [-0.9692660,  1.8760108,  0.0415560],
    [ 0.0556434, -0.2040259,  1.0572252]
  ]

  # Oklab matrices (Bjorn Ottosson)
  # M1: linear sRGB -> LMS
  OklabM1* = [
    [0.4122214708, 0.5363325363, 0.0514459929],
    [0.2119034982, 0.6806995451, 0.1073969566],
    [0.0883024619, 0.2817188376, 0.6299787005]
  ]
  # M2: cbrt LMS -> Oklab
  OklabM2* = [
    [0.2104542553,  0.7936177850, -0.0040720468],
    [1.9779984951, -2.4285922050,  0.4505937099],
    [0.0259040371,  0.7827717662, -0.8086757660]
  ]
  OklabM2Inv* = [
    [1.0,  0.3963377774,  0.2158037573],
    [1.0, -0.1055613458, -0.0638541728],
    [1.0, -0.0894841775, -1.2914855480]
  ]
  OklabM1Inv* = [
    [ 4.0767416621, -3.3077115913,  0.2309699292],
    [-1.2684380046,  2.6097574011, -0.3413193965],
    [-0.0041960863, -0.7034186147,  1.7076147010]
  ]

proc clamp*(v, lo, hi: float): float =
  if v < lo: lo elif v > hi: hi else: v

proc clamp01*(v: float): float = clamp(v, 0.0, 1.0)

proc degToRad*(d: float): float = d * PI / 180.0
proc radToDeg*(r: float): float = r * 180.0 / PI

proc hueMod*(h: float): float =
  var x = h
  x = x - floor(x / 360.0) * 360.0
  if x < 0: x += 360.0
  x
