# A collection of tiny parsers and dumpers
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/openparser

## Colors end to end tour: parse any CSS color, convert, manipulate, harmonize and check contrast.

import ../src/openparser/colors
import std/[strformat, sequtils]

block parse_any_css_color:
  echo "--- parse any CSS color ---"
  for s in ["#ff0000", "#f00", "rebeccapurple", "rgb(255 0 0 / 0.5)",
            "hsl(0 100% 50%)", "hwb(120 0% 0%)", "lab(53.2 80.1 67.2)",
            "oklch(0.7 0.15 180)", "color(srgb 1 0 0)", "transparent"]:
    let c = parseColor(s)
    echo &"{s:25} -> {c.toHex():7} {c.toRgbString():22} valid={c.valid}"

block conversions:
  echo "\n--- conversions ---"
  let c = parseColor("#ff0000")
  echo "hex  ", c.toHex(), " -> rgb ", c.toRgb()
  echo "hsl  ", c.toHsl(), " -> back ", fromHsl(c.toHsl()).toHex()
  echo "hsv  ", c.toHsv(), " -> back ", fromHsv(c.toHsv()).toHex()
  echo "hwb  ", c.toHwb(), " -> back ", fromHwb(c.toHwb()).toHex()
  echo "cmyk ", c.toCmyk(), " -> back ", fromCmyk(c.toCmyk()).toHex()
  echo "lab  ", c.toLab(), " -> back ", fromLab(c.toLab()).toHex()
  echo "lch  ", c.toLch(), " -> back ", fromLch(c.toLch()).toHex()
  echo "oklab", c.toOklab(), " -> back ", fromOklab(c.toOklab()).toHex()
  echo "oklch", c.toOklch(), " -> back ", fromOklchToColor(c.toOklch()).toHex()

block stringify:
  echo "\n--- stringify ---"
  let r = parseColor("red")
  echo r.toHex()           # #ff0000
  echo r.toHex(true)       # #f00
  echo r.toHex8()          # #ff0000ff
  echo r.toRgbString()     # rgb(255, 0, 0)
  echo r.toHslString()     # hsl(0, 100%, 50%)
  echo r.toHsvString()     # hsv(0, 100%, 100%)
  echo r.toCmykString()    # cmyk(...)
  echo r.toOklchString()   # oklch(...)
  echo parseColor("rgba(255,0,0,0.5)").toHex8()  # #ff000080
  echo parseColor("#ff0000").toName()            # red

block manipulation_chainable:
  echo "\n--- manipulation (chainable, immutable) ---"
  let base = parseColor("#ff0000")
  echo "base        ", base.toHex()
  echo "lighten 20  ", base.lighten(20).toHex()
  echo "darken 20   ", base.darken(20).toHex()
  echo "saturate    ", parseColor("#808080").saturate(50).toHex()
  echo "spin 180    ", base.spin(180).toHex(), " = complement ", base.complement().toHex()
  echo "mix 50% blue", base.mix(parseColor("blue"), 50).toHex()
  echo "tint 30%    ", base.tint(30).toHex()
  echo "shade 30%   ", base.shade(30).toHex()
  echo "chain       ", base.lighten(10).desaturate(20).spin(30).tint(10).toHex()
  doAssert base.toHex() == "#ff0000" # immutable

block harmonies:
  echo "\n--- harmonies ---"
  let c = parseColor("red")
  echo "triad        ", c.triad().mapIt(it.toHex())
  echo "tetrad       ", c.tetrad().mapIt(it.toHex())
  echo "splitComplement", c.splitComplement().mapIt(it.toHex())
  echo "analogous(5) ", c.analogous(5).mapIt(it.toHex())
  echo "monochromatic(4)", c.monochromatic(4).mapIt(it.toHex())

block contrast:
  echo "\n--- contrast / WCAG ---"
  let white = parseColor("white")
  let black = parseColor("black")
  let gray = parseColor("#777777")
  echo "luminance white ", white.luminance()
  echo "luminance black ", black.luminance()
  echo "contrast w/b ", contrastRatio(white, black)
  echo "readable w/b ", isReadable(white, black)
  echo "readable #777/white ", isReadable(gray, white), " -> ", readability(gray, white)
  echo "mostReadable on black ", mostReadable(black, @[white, parseColor("red")]).toHex()
  echo "isLight yellow? ", isLight(parseColor("yellow")), " isDark navy? ", isDark(parseColor("navy"))

block random:
  echo "\n--- random ---"
  echo "random ", randomColor().toHex()
  echo "random red hue ", randomColor(RandomColorOptions(hue: "red")).toHex()
  echo "random bright ", randomColor(RandomColorOptions(luminosity: lmBright)).toHex()
  echo "5 random ", randomColors(5).mapIt(it.toHex())

block validation:
  echo "\n--- validation ---"
  echo "isValid #ff0000 ", isValidColor("#ff0000")
  echo "isValid notacolor ", isValidColor("notacolor")
  try:
    discard parseColor("notacolor")
  except ParserColorError as e:
    echo "error: ", e.msg
