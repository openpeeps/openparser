import std/[strutils, sequtils, random, tables, unittest]
import ../src/openparser/qr/model2

# Golden matrices validated against segno 1.6.6 and zxing-cpp decoders.
const goldenNum1 = """
111111100110101111111
100000101011101000001
101110101000001011101
101110101010001011101
101110100011101011101
100000100100101000001
111111101010101111111
000000001101100000000
100000101100111001110
001011010100101011101
001000110101010011111
000110000000000011100
011100100010001001011
000000001111111101100
111111100110101100000
100000100101110110100
101110100000100101100
101110100000100000000
101110100000001001111
100000100100000010110
111111101111010010100""".splitLines()

proc matrixFromRows(rows: seq[string]): QrMatrix =
  result = initSquareQrMatrix(rows.len)
  for y, row in rows:
    for x in 0 ..< row.len:
      result[x, y] = row[x] == '1'

func parseEc(s: string): QrEcLevel =
  case s
  of "l": ecLow
  of "m": ecMedium
  of "q": ecQuartile
  else: ecHigh

proc pinned(text: string, ver: int, ecl: QrEcLevel, mask: int): QrMatrix =
  var o = defaultQrEncodeOptions()
  o.minVersion = ver
  o.maxVersion = ver
  o.ecLevel = ecl
  o.mask = mask
  encodeQr(text, o)

suite "GF(256) arithmetic":
  test "known products over the QR primitive polynomial":
    check gfMul(0x53'u8, 0xCA'u8) == 0x8F'u8
    check gfMul(0x57'u8, 0x83'u8) == 0x31'u8
    check gfMul(2'u8, 8'u8) == gfPow(2, 4)

  test "inverse round trip":
    for i in 1 ..< 256:
      let a = uint8(i)
      check gfMul(a, gfInv(a)) == 1'u8

suite "Reed-Solomon codec":
  test "ISO 18004 worked example parity":
    let data: seq[uint8] = @[0x10'u8, 0x20, 0x0C, 0x56, 0x61, 0x80, 0xEC,
      0x11, 0xEC, 0x11, 0xEC, 0x11, 0xEC, 0x11, 0xEC, 0x11]
    let expected: seq[uint8] = @[0xA5'u8, 0x24, 0xD4, 0xC1, 0xED, 0x36,
      0xC7, 0x87, 0x2C, 0x55]
    check rsEncodeParity(data, 10) == expected

  test "corrects up to t errors":
    randomize(2026)
    for trial in 0 ..< 60:
      let nsym = 10 + rand(20)
      let dataLen = 5 + rand(50)
      var msg = newSeq[uint8](dataLen)
      for i in 0 ..< dataLen:
        msg[i] = uint8(rand(255))
      let orig = msg & rsEncodeParity(msg, nsym)
      var cw = orig
      let nerr = rand(nsym div 2)
      var used: seq[int] = @[]
      for e in 0 ..< nerr:
        var p = rand(cw.len - 1)
        while p in used: p = rand(cw.len - 1)
        used.add p
        cw[p] = cw[p] xor uint8(1 + rand(255))
      rsDecode(cw, nsym)
      check cw == orig

  test "erasures plus errors":
    randomize(77)
    for trial in 0 ..< 40:
      let nsym = 14 + rand(12)
      let dataLen = 6 + rand(30)
      var msg = newSeq[uint8](dataLen)
      for i in 0 ..< dataLen:
        msg[i] = uint8(rand(255))
      let orig = msg & rsEncodeParity(msg, nsym)
      var cw = orig
      var erasePos: seq[int] = @[]
      for e in 0 ..< rand(nsym div 3):
        var p = rand(cw.len - 1)
        while p in erasePos: p = rand(cw.len - 1)
        erasePos.add p
        cw[p] = cw[p] xor uint8(1 + rand(255))
      let budget = (nsym - erasePos.len) div 2
      var errPos: seq[int] = @[]
      for e in 0 ..< rand(budget):
        var p = rand(cw.len - 1)
        while p in erasePos or p in errPos: p = rand(cw.len - 1)
        errPos.add p
        cw[p] = cw[p] xor uint8(1 + rand(255))
      rsDecode(cw, nsym, erasePos)
      check cw == orig

suite "symbol geometry":
  test "data codeword capacities match ISO table":
    check numDataCodewords(1, ecLow) == 19
    check numDataCodewords(1, ecMedium) == 16
    check numDataCodewords(1, ecQuartile) == 13
    check numDataCodewords(1, ecHigh) == 9
    check numDataCodewords(10, ecLow) == 274
    check numDataCodewords(20, ecHigh) == 385
    check numDataCodewords(40, ecLow) == 2956

  test "alignment pattern positions":
    check alignmentPositions(1).len == 0
    check alignmentPositions(2) == @[6, 18]
    check alignmentPositions(7) == @[6, 22, 38]
    check alignmentPositions(20) == @[6, 34, 62, 90]
    check alignmentPositions(40)[^1] == 170

suite "segment encoders":
  test "numeric packing":
    var s = makeNumeric("01234567")
    check s.bits.bitLen == 10 + 10 + 7
    check s.nchars == 8

  test "alphanumeric packing":
    let s = makeAlphanumeric("HELLO WORLD")
    check s.bits.bitLen == 5 * 11 + 6
    check s.bits.toSeq[0 ..< 7] == @[0x61'u8, 0x6F, 0x1A, 0x2E, 0x5B, 0x89, 0xA8]

  test "kanji packing uses C0 base-256 column encoding":
    let s = makeKanji(@[0x93'u8, 0xFA])  # 日 U+65E5
    check s.nchars == 1
    check s.bits.bitLen == 13
    # delta = 0x93FA - 0x8140 = 0x12BA; value = 0x12 * 0xC0 + 0xBA = 0xE3A
    # 13-bit field 0111000111010 -> bytes 0x71 0xD0 (zero padded)
    let bytes = s.bits.toSeq
    check bytes == @[0x71'u8, 0xD0]

  test "sjisBytes maps code points through JIS X 0208":
    check sjisBytes("日") == @[0x93'u8, 0xFA]
    check sjisBytes("テ") == @[0x83'u8, 0x65]
    expect QrError:
      discard sjisBytes("é")

suite "Model 2 encoder goldens":
  test "v1-M mask 5 numeric golden matrix":
    let m = pinned("01234567", 1, ecMedium, 5)
    let want = matrixFromRows(goldenNum1)
    check m.width == 21
    var same = true
    for y in 0 ..< 21:
      for x in 0 ..< 21:
        if m[x, y] != want[x, y]: same = false
    check same

  test "v1-Q mask 5 alphanumeric golden prefix":
    let m = pinned("HELLO WORLD", 1, ecQuartile, 5)
    # finder row and timing row are fully determined by the spec
    let finderRow = "111111101001001111111"
    var row0 = ""
    for x in 0 ..< 21:
      row0.add(if m[x, 0]: '1' else: '0')
    check row0 == finderRow

  test "format info carries requested level and valid BCH":
    const levels: array[4, tuple[name: string, lvl: QrEcLevel]] = [
      ("l", ecLow), ("m", ecMedium), ("q", ecQuartile), ("h", ecHigh)]
    for entry in levels:
      let m = pinned("abc123", 3, entry.lvl, 2)
      # first format copy, LSB-first cell order:
      # col 8 rows 0..5 then rows 7,8; row 8 col 7; row 8 cols 5..0
      var cells: seq[bool] = @[]
      for r in [0, 1, 2, 3, 4, 5]: cells.add m[8, r]
      cells.add m[8, 7]
      cells.add m[8, 8]
      cells.add m[7, 8]
      for x in countdown(5, 0): cells.add m[x, 8]
      var word = 0
      for i, c in cells:
        if c: word = word or (1 shl i)
      let raw = word xor 0x5412
      let data = raw shr 10
      var rem = data
      for _ in 0 ..< 10:
        rem = (rem shl 1) xor ((rem shr 9) * 0x537)
      check ((data shl 10) or rem) == raw
      const fmtBits: array[4, int] = [1, 0, 3, 2]
      check ((data shr 3) and 3) == fmtBits[ord(entry.lvl)]
      check (data and 7) == 2

suite "automatic segmentation":
  test "pure digit input stays one numeric segment":
    let segs = toSegments("123456789")
    check segs.len == 1
    check segs[0].mode == modeNumeric

  test "lowercase url stays one byte segment":
    let segs = toSegments("https://example.com/path?query=12345")
    check segs.len == 1
    check segs[0].mode == modeByte

  test "kanji runs split from byte runs":
    # all six characters are JIS X 0208 encodable, so they stay together
    check toSegments("日本語です。").len == 1
    let segs = toSegments("日本語テキストabc")
    check segs.len == 2
    check segs[0].mode == modeKanji
    check segs[1].mode == modeByte

suite "encoder error handling":
  test "capacity overflow raises":
    expect QrError:
      var o = defaultQrEncodeOptions()
      o.minVersion = 1
      o.maxVersion = 1
      o.ecLevel = ecHigh
      discard encodeQrBytes(repeat(byte('x'), 20), o)

  test "invalid alphanumeric characters raise":
    expect QrError:
      discard makeAlphanumeric("hello")

  test "odd kanji byte count raises":
    expect QrError:
      discard makeKanji(@[0x93'u8])

  test "out of range shift-jis raises":
    expect QrError:
      discard makeKanji(@[0x00'u8, 0x41])
