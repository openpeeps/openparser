# A collection of tiny parsers and dumpers
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/openparser
import ./types
import ./manipulate
import ./convert
import ./constants

proc triad*(c: Color): seq[Color] =
  result = @[c, c.spin(120.0), c.spin(240.0)]

proc tetrad*(c: Color): seq[Color] =
  result = @[c, c.spin(90.0), c.spin(180.0), c.spin(270.0)]

proc splitComplement*(c: Color): seq[Color] =
  result = @[c, c.spin(150.0), c.spin(210.0)]

proc analogous*(c: Color, results: int = 6, slices: int = 30): seq[Color] =
  let slice = float(slices)
  result = @[]
  # center at c, produce results evenly around
  let half = results div 2
  for i in 0..<results:
    let offset = float(i - half) * slice
    result.add(c.spin(offset))
  # if results even, we have one extra on negative side; fine. Ensure c included
  # adjust to exactly include c when results odd already does
  if results mod 2 == 0:
    # shift so c is at index results/2 -1? keep as is
    discard

proc monochromatic*(c: Color, results: int = 6): seq[Color] =
  var hsl = c.toHsl()
  result = @[]
  # vary l and s? simple: vary value via lighten/darken steps
  let step = 20.0 # lightness step
  # generate by modifying l
  # start from dark to light
  var baseL = hsl.l
  # produce results around baseL
  for i in 0..<results:
    let t = float(i) / float(results - 1) # 0..1
    # map t 0..1 to l 0..1 but keep hue/s
    var nhsl = hsl
    nhsl.l = clamp01(t)
    # also vary s slightly? keep s
    var col = fromHsl(nhsl)
    col.a = c.a
    result.add(col)

proc complementSeq*(c: Color): seq[Color] =
  @[c, c.complement()]
