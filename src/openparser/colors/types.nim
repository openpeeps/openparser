# A collection of tiny parsers and dumpers
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/openparser
type
  ParserColorError* = object of CatchableError

  ColorFormat* = enum
    cfHex
    cfRgb
    cfHsl
    cfHsv
    cfHsb  ## alias of hsv
    cfCmyk
    cfLab
    cfLch
    cfOklab
    cfOklch
    cfNamed
    cfHwb

  Color* = object
    r*, g*, b*, a*: float ## sRGB 0..1, alpha 0..1
    format*: ColorFormat
    valid*: bool

  Rgb* = object
    r*, g*, b*: int ## 0..255
    a*: float       ## 0..1

  Hsl* = object
    h*: float ## 0..360
    s*, l*, a*: float ## 0..1, alpha 0..1

  Hsv* = object
    h*: float ## 0..360
    s*, v*, a*: float

  Hsb* = Hsv

  Hwb* = object
    h*: float
    w*, b*, a*: float ## w,b 0..1

  Cmyk* = object
    c*, m*, y*, k*, a*: float ## 0..1

  Lab* = object
    l*, a*, b*: float
    alpha*: float

  Lch* = object
    l*, c*, h*, alpha*: float

  Oklab* = object
    l*, a*, b*: float
    alpha*: float

  Oklch* = object
    l*, c*, h*, alpha*: float

proc initColor*(r, g, b: float, a: float = 1.0, format = cfRgb): Color =
  Color(r: r, g: g, b: b, a: a, format: format, valid: true)

proc isValid*(c: Color): bool = c.valid
