import std/[strutils, sequtils, random, tables, unittest, math]
import ../src/openparser/qr/model2

proc roundTrip(text: string, ver: int, ecl: QrEcLevel, mask: int): bool =
  var o = defaultQrEncodeOptions()
  o.minVersion = ver
  o.maxVersion = ver
  o.ecLevel = ecl
  o.mask = mask
  let m = encodeQr(text, o)
  let r = decodeQrMatrix(m)
  if not r.ok:
    return false
  result = r.text == text

proc renderToImage(m: QrMatrix, scale: int, quiet: int,
                   rotateDeg: float = 0.0, noise: float = 0.0): GrayImage =
  ## Renders a matrix to grayscale with an optional rotation and noise,
  ## mimicking a photographed symbol.
  let rad = rotateDeg * PI / 180.0
  let cosR = cos(rad)
  let sinR = sin(rad)
  # rotated bounding box around the quiet-zoned centre
  let side = (m.width + 2 * quiet) * scale
  let half = side.float / 2.0
  let bound = int(ceil(side.float * (abs(cosR) + abs(sinR)))) + 2
  let bhalf = bound.float / 2.0
  result = initGrayImage(bound, bound)
  for y in 0 ..< bound:
    for x in 0 ..< bound:
      # inverse rotate image coords into symbol space
      let dx = x.float - bhalf
      let dy = y.float - bhalf
      let sx = dx * cosR + dy * sinR + half - quiet.float * scale.float
      let sy = -dx * sinR + dy * cosR + half - quiet.float * scale.float
      let mx = int(floor(sx / scale.float))
      let my = int(floor(sy / scale.float))
      var v: uint8 = 255'u8
      if mx >= 0 and my >= 0 and mx < m.width and my < m.height and m[mx, my]:
        v = 0'u8
      if noise > 0.0:
        let n = int(noise * float(rand(255) - 127))
        v = uint8(clamp(v.int + n, 0, 255))
      result.pixels[y * bound + x] = v

suite "clean-matrix decode":
  test "ISO example numeric round trip":
    check roundTrip("01234567", 1, ecMedium, 5)

  test "all error correction levels at fixed version/mask":
    for lvl in [ecLow, ecMedium, ecQuartile, ecHigh]:
      check roundTrip("MODEST MOUSE 42", 4, lvl, 6)

  test "all eight masks":
    for mask in 0 .. 7:
      check roundTrip("mask probe", 3, ecQuartile, mask)

  test "byte mode with unicode":
    check roundTrip("Héllo wörld ünïcode ✓", 5, ecMedium, 3)

  test "kanji mode round trip":
    check roundTrip("日本語テキスト", 1, ecLow, 0)

  test "mixed kanji and byte segments":
    check roundTrip("日本語テキストabc", 2, ecMedium, 1)

  test "numeric capacity edge at v40-L":
    var s = ""
    for i in 0 ..< 1650: s.add '7'
    check roundTrip(s, 40, ecLow, 7)

  test "alphanumeric long haul v20-H":
    var s = ""
    const cs = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:"
    for i in 0 ..< 200: s.add cs[i mod cs.len]
    check roundTrip(s, 20, ecHigh, 0)

suite "error tolerance":
  test "survives corruption within the RS budget":
    randomize(4242)
    var o = defaultQrEncodeOptions()
    o.minVersion = 5
    o.maxVersion = 5
    o.ecLevel = ecMedium
    o.mask = 3
    let m0 = encodeQrBytes("corruption resistance probe".toOpenArrayByte(
      0, "corruption resistance probe".len - 1), o)
    let isFunc = reservedMap(5)
    for trial in 0 ..< 10:
      var m = m0
      # v5-M corrects ~12 errors per block over two blocks; flip well below
      for e in 0 ..< 6:
        var x = rand(m.width - 1)
        var y = rand(m.height - 1)
        while isFunc[y * m.width + x]:
          x = rand(m.width - 1)
          y = rand(m.height - 1)
        m[x, y] = not m[x, y]
      let r = decodeQrMatrix(m)
      check r.ok and r.text == "corruption resistance probe"

  test "rejects garbage gracefully":
    let junk = initSquareQrMatrix(25)
    var m = junk
    for i in 0 ..< 100:
      m[rand(24), rand(24)] = true
    discard decodeQrMatrix(m)  # must not crash; ok may be false

suite "image decoding":
  test "flat render decodes":
    let m = encodeQr("https://openparser.dev/qr")
    let img = renderToImage(m, scale = 8, quiet = 4)
    let r = decodeQrImage(img)
    check r.ok
    check r.text == "https://openparser.dev/qr"
    check r.version >= 1

  test "small module size":
    let m = encodeQr("tiny")
    let img = renderToImage(m, scale = 3, quiet = 2)
    let r = decodeQrImage(img)
    check r.ok and r.text == "tiny"

  test "rotated 15 degrees":
    let m = encodeQr("rotation probe")
    let img = renderToImage(m, scale = 6, quiet = 4, rotateDeg = 15.0)
    let r = decodeQrImage(img)
    check r.ok and r.text == "rotation probe"

  test "rotated minus 30 degrees":
    let m = encodeQr("skewed scan")
    let img = renderToImage(m, scale = 6, quiet = 4, rotateDeg = -30.0)
    let r = decodeQrImage(img)
    check r.ok and r.text == "skewed scan"

  test "noisy photo simulation":
    var o = defaultQrEncodeOptions()
    o.ecLevel = ecQuartile
    let m = encodeQr("grainy label", o)
    let img = renderToImage(m, scale = 6, quiet = 4, noise = 0.15)
    let r = decodeQrImage(img)
    check r.ok and r.text == "grainy label"
