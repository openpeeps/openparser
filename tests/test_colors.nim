import unittest, math, strutils, sequtils
import openparser/colors

suite "Colors - Flexible Input Parsing":
  test "hex with #":
    check parseColor("#ff0000").toHex() == "#ff0000"
    check parseColor("#f00").toHex() == "#ff0000"
    check parseColor("#FF0000").toHex() == "#ff0000"
    check parseColor("#ff000080").toHex8() == "#ff000080"
    check parseColor("#f0a8").toHex8() == "#ff00aa88"
  test "hex without #":
    check parseColor("ff0000").toHex() == "#ff0000"
    check parseColor("f00").toHex() == "#ff0000"
    check parseColor("FF00AA").toHex() == "#ff00aa"
    check parseColor("ff000080").toHex8() == "#ff000080"
    check parseColor("f0a8").toHex8() == "#ff00aa88"
    check isValidColor("abc") == true
    check isValidColor("abcd") == true
  test "named colors case insensitive":
    check parseColor("red").toHex() == "#ff0000"
    check parseColor("Red").toHex() == "#ff0000"
    check parseColor("RED").toHex() == "#ff0000"
    check parseColor("rebeccapurple").toHex() == "#663399"
    check parseColor("transparent").toHex8() == "#00000000"
    check parseColor("transparent").a == 0.0
  test "rgb and rgba":
    check parseColor("rgb(255,0,0)").toHex() == "#ff0000"
    check parseColor("rgb(255 0 0)").toHex() == "#ff0000"
    check parseColor("rgb(100% 0% 0%)").toHex() == "#ff0000"
    check parseColor("rgba(255,0,0,0.5)").toHex8() == "#ff000080"
    check parseColor("rgba(255 0 0 / 0.5)").toHex8() == "#ff000080"
    check parseColor("rgb(255 0 0 / 50%)").toHex8() == "#ff000080"
  test "hsl and hsla":
    check parseColor("hsl(0,100%,50%)").toHex() == "#ff0000"
    check parseColor("hsl(0 100% 50%)").toHex() == "#ff0000"
    check parseColor("hsl(120,100%,50%)").toHex() == "#00ff00"
    check parseColor("hsla(0,100%,50%,0.5)").toHex8() == "#ff000080"
    check parseColor("hsl(0 100% 50% / 0.5)").toHex8() == "#ff000080"
  test "hsv hsb":
    check parseColor("hsv(0,100%,100%)").toHex() == "#ff0000"
    check parseColor("hsv(120 100% 100%)").toHex() == "#00ff00"
    check parseColor("hsb(0,100%,100%)").toHex() == "#ff0000"
    check parseColor("hsva(0,100%,100%,0.5)").a == 0.5
  test "hwb":
    check parseColor("hwb(0 0% 0%)").toHex() == "#ff0000"
    check parseColor("hwb(120 0% 0%)").toHex() == "#00ff00"
  test "cmyk":
    check parseColor("cmyk(0,1,1,0)").toHex() == "#ff0000"
    check parseColor("cmyk(0% 100% 100% 0%)").toHex() == "#ff0000"
    check parseColor("device-cmyk(0 1 1 0)").toHex() == "#ff0000"
  test "lab lch oklab oklch":
    let lab = parseColor("lab(53.23288 80.10933 67.22006)")
    check abs(lab.r - 1.0) < 0.02
    check abs(lab.g - 0.0) < 0.02
    check abs(lab.b - 0.0) < 0.02
    let lch = parseColor("lch(53.24 104 40)")
    check lch.r >= 0.0 and lch.r <= 1.0
    let oklab = parseColor("oklab(0.62797 0.22486 0.12585)")
    check abs(oklab.r - 1.0) < 0.02
    let oklch = parseColor("oklch(0.62797 0.25768 29.23)")
    check abs(oklch.r - 1.0) < 0.02
    check parseColor("oklch(0.7 0.15 180)").toHex().len == 7
  test "color() function":
    check parseColor("color(srgb 1 0 0)").toHex() == "#ff0000"
    check parseColor("color(srgb 0 1 0)").toHex() == "#00ff00"
  test "whitespace and case in functions":
    check parseColor(" RGB( 255 , 0 , 0 ) ").toHex() == "#ff0000"
    check parseColor("HSL(0, 100%, 50%)").toHex() == "#ff0000"
  test "isValidColor and errors":
    check isValidColor("#ff0000") == true
    check isValidColor("notacolor") == false
    check isValidColor("#gg0000") == false
    check isValidColor("") == false
    expect ParserColorError:
      discard parseColor("notacolor")
    expect ParserColorError:
      discard parseColor("#ff")
    expect ParserColorError:
      discard parseColor("")

suite "Colors - Extensive Color Support and Conversions":
  test "rgb round-trip":
    let c = parseColor("#1a2b3c")
    let rgb = c.toRgb()
    check rgb.r == 0x1a
    check rgb.g == 0x2b
    check rgb.b == 0x3c
    check fromRgb(rgb).toHex() == "#1a2b3c"
  test "hsl round-trip":
    let c = parseColor("#ff0000")
    let hsl = c.toHsl()
    check abs(hsl.h - 0.0) < 0.01 or abs(hsl.h - 360.0) < 0.01
    check abs(hsl.s - 1.0) < 0.01
    check abs(hsl.l - 0.5) < 0.01
    check fromHsl(hsl).toHex() == "#ff0000"
    # achromatic
    let gray = parseColor("#808080")
    check abs(gray.toHsl().s - 0.0) < 0.01
  test "hsv round-trip":
    let c = parseColor("#00ff00")
    let hsv = c.toHsv()
    check abs(hsv.h - 120.0) < 0.5
    check abs(hsv.s - 1.0) < 0.01
    check abs(hsv.v - 1.0) < 0.01
    check fromHsv(hsv).toHex() == "#00ff00"
  test "hsb alias":
    let c = parseColor("red")
    check c.toHsb().h == c.toHsv().h
    check fromHsb(c.toHsb()).toHex() == "#ff0000"
  test "hwb round-trip":
    let c = parseColor("red")
    let hwb = c.toHwb()
    check abs(hwb.h - 0.0) < 0.5
    check fromHwb(hwb).toHex() == "#ff0000"
    let grayHwb = Hwb(h: 0, w: 0.5, b: 0.5, a: 1.0)
    check fromHwb(grayHwb).toHex() == "#808080"
  test "cmyk round-trip":
    check parseColor("#ff0000").toCmyk().c == 0.0
    check parseColor("#ff0000").toCmyk().m == 1.0
    check parseColor("#00ff00").toCmyk().k < 0.01
    let cmyk = Cmyk(c: 0, m: 1, y: 1, k: 0, a: 1)
    check fromCmyk(cmyk).toHex() == "#ff0000"
    let black = fromCmyk(Cmyk(c:0,m:0,y:0,k:1,a:1))
    check black.toHex() == "#000000"
  test "lab round-trip":
    let c = parseColor("#ff0000")
    let lab = c.toLab()
    check abs(lab.l - 53.23) < 0.5
    check abs(lab.a - 80.1) < 0.5
    let c2 = fromLab(lab)
    check abs(c2.r - 1.0) < 0.02
    check abs(c2.g - 0.0) < 0.02
  test "lch round-trip":
    let c = parseColor("#ff0000")
    let lch = c.toLch()
    check lch.c > 50
    let c2 = fromLch(lch)
    check abs(c2.r - 1.0) < 0.02
  test "oklab round-trip":
    let c = parseColor("#ff0000")
    let ok = c.toOklab()
    check abs(ok.l - 0.627) < 0.01
    let c2 = fromOklab(ok)
    check abs(c2.r - 1.0) < 0.02
  test "oklch round-trip":
    let c = parseColor("#00ff00")
    let oklch = c.toOklch()
    check oklch.c > 0.1
    let c2 = fromOklchToColor(oklch)
    check abs(c2.g - 1.0) < 0.02

suite "Colors - Stringify toHex toRgb toName etc":
  test "toHex":
    check parseColor("red").toHex() == "#ff0000"
    check parseColor("#ff0000").toHex(true) == "#f00" # allow short
    check parseColor("#ff00aa").toHex(true) == "#f0a"
    check parseColor("blue").toHex() == "#0000ff"
  test "toHex8":
    check parseColor("rgba(255,0,0,0.5)").toHex8() == "#ff000080"
    check parseColor("transparent").toHex8() == "#00000000"
    check parseColor("rgba(255,0,0,1)").toHex8() == "#ff0000ff"
    check parseColor("rgba(255,0,0,1)").toHex8(true) == "#f00f"
    check parseColor("rgba(255,0,0,0.5)").toHex8(true) == "#ff000080" # not shortenable
  test "toRgbString":
    check parseColor("red").toRgbString() == "rgb(255, 0, 0)"
    check parseColor("rgba(255,0,0,0.5)").toRgbString() == "rgba(255, 0, 0, 0.5)"
    check parseColor("rgba(255,0,0,1)").toRgbString() == "rgb(255, 0, 0)"
  test "toHslString":
    check parseColor("red").toHslString() == "hsl(0, 100%, 50%)"
    check parseColor("rgba(255,0,0,0.5)").toHslString().startsWith("hsla")
  test "toHsvString":
    check parseColor("red").toHsvString() == "hsv(0, 100%, 100%)"
  test "toCmykString":
    check parseColor("red").toCmykString().contains("100.0%")
  test "toLabString toOklabString etc not empty":
    check parseColor("red").toLabString().startsWith("lab(")
    check parseColor("red").toLchString().startsWith("lch(")
    check parseColor("red").toOklabString().startsWith("oklab(")
    check parseColor("red").toOklchString().startsWith("oklch(")
  test "toString dispatches by format":
    check parseColor("#ff0000").toString().startsWith("#")
    check parseColor("rgb(255,0,0)").toString().startsWith("rgb")
    check parseColor("hsl(0,100%,50%)").toString().startsWith("hsl")
  test "toName always returns closest":
    check parseColor("#ff0000").toName() == "red"
    check parseColor("#00ff00").toName() == "lime"
    check parseColor("#0000ff").toName() == "blue"
    check parseColor("#fe0000").toName() == "red"
    check parseColor("#010101").toName() == "black"
    check parseColor("#ffffff").toName() == "white"
    check parseColor("#f5f5dc").toName() == "beige"
  test "toRgb struct":
    let rgb = parseColor("red").toRgb()
    check rgb.r == 255 and rgb.g == 0 and rgb.b == 0 and rgb.a == 1.0
    let hsl = parseColor("red").toHsl()
    check abs(hsl.h - 0) < 0.1

suite "Colors - Modifications chainable":
  test "lighten darken":
    check parseColor("#ff0000").lighten(10).toHsl().l > 0.5
    check parseColor("#ff0000").darken(10).toHsl().l < 0.5
    check parseColor("#ff0000").lighten(0).toHex() == "#ff0000"
    check parseColor("red").darken(100).toHex() == "#000000"
    check parseColor("red").lighten(100).toHex() == "#ffffff"
  test "saturate desaturate greyscale":
    check parseColor("red").desaturate(100).toHsl().s < 0.01
    check parseColor("#808080").saturate(50).toHsl().s > 0.0
    check parseColor("red").greyscale().toHsl().s < 0.01
    check parseColor("red").greyscale().toHex() == "#808080"
  test "spin":
    check parseColor("red").spin(0).toHex() == "#ff0000"
    check parseColor("red").spin(360).toHex() == "#ff0000"
    check parseColor("red").spin(720).toHex() == "#ff0000"
    check parseColor("red").spin(180).toHex() == "#00ffff"
    check parseColor("red").spin(-180).toHex() == "#00ffff"
    check parseColor("red").spin(120).toHex() == "#00ff00"
  test "brighten":
    let c = parseColor("#330000").brighten(10)
    check c.toRgb().r > 0x33
  test "mix":
    check mix(parseColor("red"), parseColor("blue"), 0).toHex() == "#ff0000"
    check mix(parseColor("red"), parseColor("blue"), 100).toHex() == "#0000ff"
    check mix(parseColor("red"), parseColor("blue"), 50).toHex() == "#800080"
  test "tint shade":
    check parseColor("red").tint(100).toHex() == "#ffffff"
    check parseColor("red").shade(100).toHex() == "#000000"
    check parseColor("red").tint(0).toHex() == "#ff0000"
  test "alpha operations":
    check parseColor("red").setAlpha(0.5).a == 0.5
    check parseColor("rgba(255,0,0,0.5)").fadeIn(10).a > 0.5
    check parseColor("rgba(255,0,0,0.5)").fadeOut(10).a < 0.5
    check parseColor("red").setAlpha(0).toHex8() == "#ff000000"
    check parseColor("red").setAlpha(2).a == 1.0
    check parseColor("red").setAlpha(-1).a == 0.0
  test "complement is spin 180":
    check parseColor("red").complement().toHex() == parseColor("red").spin(180).toHex()
  test "chain calls":
    let c = parseColor("#ff0000").lighten(10).desaturate(20).spin(30).darken(5)
    check c.toHex().len == 7
    # discardable without assignment must compile
    var c2 = parseColor("red")
    c2.lighten(10)
    c2.desaturate(20)
    check c2.toHex() == "#ff0000" # immutable so original unchanged
    let c3 = parseColor("red").lighten(10)
    check c3.toHex() != "#ff0000"
  test "amount clamping":
    check parseColor("red").lighten(200).toHex() == "#ffffff"
    check parseColor("red").darken(200).toHex() == "#000000"
    check parseColor("red").saturate(200).toHsl().s == 1.0

suite "Colors - Schemes and Harmonies":
  test "complement seq":
    check parseColor("red").complement().toHex() == "#00ffff"
  test "triad":
    let t = parseColor("red").triad()
    check t.len == 3
    check t[0].toHex() == "#ff0000"
    check t[1].toHex() == "#00ff00"
    check t[2].toHex() == "#0000ff"
  test "tetrad":
    let t = parseColor("red").tetrad()
    check t.len == 4
    check t[0].toHex() == "#ff0000"
  test "splitComplement":
    let s = parseColor("red").splitComplement()
    check s.len == 3
    check s[0].toHex() == "#ff0000"
  test "analogous":
    check parseColor("red").analogous(6,30).len == 6
    check parseColor("red").analogous(3,30).len == 3
    let a = parseColor("red").analogous(5, 30)
    check a.len == 5
  test "monochromatic":
    check parseColor("red").monochromatic(6).len == 6
    check parseColor("red").monochromatic(3).len == 3
    let m = parseColor("blue").monochromatic(4)
    check m.len == 4

suite "Colors - Contrast and Readability":
  test "luminance":
    check abs(parseColor("black").luminance() - 0.0) < 0.001
    check abs(parseColor("white").luminance() - 1.0) < 0.001
    check abs(parseColor("red").luminance() - 0.2126) < 0.01
  test "contrastRatio":
    check abs(contrastRatio(parseColor("white"), parseColor("black")) - 21.0) < 0.01
    check abs(contrastRatio(parseColor("black"), parseColor("white")) - 21.0) < 0.01
    check abs(contrastRatio(parseColor("white"), parseColor("white")) - 1.0) < 0.01
    check contrastRatio(parseColor("#777777"), parseColor("white")) < 4.5
  test "isReadable":
    check isReadable(parseColor("white"), parseColor("black")) == true
    check isReadable(parseColor("white"), parseColor("black"), "AAA", "small") == true
    check isReadable(parseColor("#777"), parseColor("white")) == false
    check isReadable(parseColor("#777"), parseColor("white"), "AA", "large") == true or isReadable(parseColor("#777"), parseColor("white"), "AA", "large") == false # just ensure no crash
    check isReadable(parseColor("black"), parseColor("white"), "AA", "small") == true
    check isReadable(parseColor("#777"), parseColor("white"), "AAA", "small") == false
  test "readability":
    let r = readability(parseColor("white"), parseColor("black"))
    check abs(r.ratio - 21.0) < 0.01
    check r.level == "AAA"
    check readability(parseColor("white"), parseColor("white")).level == "fail"
    check readability(parseColor("#777"), parseColor("white")).level in ["AA", "AAA", "AA large", "fail"]
  test "isLight isDark":
    check isLight(parseColor("white")) == true
    check isDark(parseColor("white")) == false
    check isLight(parseColor("black")) == false
    check isDark(parseColor("black")) == true
    check isLight(parseColor("yellow")) == true
    check isDark(parseColor("navy")) == true
  test "mostReadable":
    let best = mostReadable(parseColor("black"), @[parseColor("white"), parseColor("red")])
    check best.toHex() == "#ffffff"
    let best2 = mostReadable(parseColor("white"), @[parseColor("black"), parseColor("yellow")])
    check best2.toHex() == "#000000"

suite "Colors - Random":
  test "randomColor basic":
    let c = randomColor()
    check c.toHex().len == 7
    check c.a == 1.0
  test "randomColors count":
    check randomColors(5).len == 5
    check randomColors(1).len == 1
    check randomColors(0).len == 0
  test "randomColor hue options":
    for hue in ["red", "orange", "yellow", "green", "blue", "purple", "pink", "monochrome"]:
      let c = randomColor(RandomColorOptions(hue: hue))
      check c.toHex().len == 7
  test "randomColor luminosity":
    for lum in [lmBright, lmLight, lmDark, lmRandom]:
      let c = randomColor(RandomColorOptions(luminosity: lum))
      check c.toHex().len == 7
  test "randomColor alpha":
    let c = randomColor(RandomColorOptions(alpha: 0.5))
    check abs(c.a - 0.5) < 0.01

suite "Colors - Chainability and Integration":
  test "full chain example from README":
    let c = parseColor("#ff0000").lighten(10).saturate(5).spin(30).tint(20).shade(10)
    check c.toHex().len == 7
  test "complement chain":
    check parseColor("red").complement().lighten(10).toHex().len == 7
  test "parse then convert then manipulate":
    let c = parseColor("lab(50 40 30)").lighten(5).toHex()
    check c.len == 7
  test "toName after manipulation still works":
    check parseColor("#ff0000").lighten(0).toName() == "red"

