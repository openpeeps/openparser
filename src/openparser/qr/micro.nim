# A collection of tiny parsers and dumpers
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/openparser

## Micro QR Code (ISO/IEC 18004 annex) encoder and decoder.
##
## Sizes M1 (11x11) through M4 (17x17), error correction levels L/M/Q
## depending on the size class, Numeric, Alphanumeric, Byte and Kanji
## segments with per-size mode indicators and character counts.
##
## Unstable API. Prefer importing `openparser/qr` instead of this module.

import std/[unicode]
import ./common, ./galois, ./model2

const formatInfoMicro: array[32, int] = [
  17477, 16754, 20011, 19228, 21934, 20633, 24512, 23287,
  26515, 25252, 28157, 26826, 30328, 29519, 31766, 31009,
  1758, 1001, 3248, 2439, 5941, 4610, 7515, 6252,
  9480, 8255, 12134, 10833, 13539, 12756, 16013, 15290]

type
  MicroVersion* {.pure.} = enum
    ## Micro QR size class. `mvAuto` selects the smallest fitting symbol.
    mvAuto = 0
    mvM1 = 1
    mvM2 = 2
    mvM3 = 3
    mvM4 = 4

func microDesignator*(ver: int): string {.inline.} =
  ## Human readable size name such as "M4".
  "M" & $ver

const
  microSize: array[mvM1 .. mvM4, int] = [11, 13, 15, 17]
    ## Symbol side length in modules.
  microTermBits: array[mvM1 .. mvM4, int] = [3, 5, 7, 9]
    ## Terminator length per size class.
  microModeBits: array[mvM1 .. mvM4, int] = [0, 1, 2, 3]
    ## Mode indicator width; M1 carries no mode indicator.
  # Codeword counts indexed by [version][ecLevel]; -1 marks version and
  # level combinations that do not exist. Columns are L, M, Q, H.
  microDataCw: array[mvM1 .. mvM4, array[4, int]] = [
    [3, -1, -1, -1],
    [5, 4, -1, -1],
    [11, 9, -1, -1],
    [16, 14, 10, -1]]
  microEcCw: array[mvM1 .. mvM4, array[4, int]] = [
    [2, -1, -1, -1],
    [5, 6, -1, -1],
    [6, 8, -1, -1],
    [8, 10, 14, -1]]

proc microCountWidth*(mode: QrMode, ver: MicroVersion): int {.inline.} =
  ## Character count width; negative when the mode is unavailable.
  case mode
  of modeNumeric: [3, 4, 5, 6][ord(ver) - 1]
  of modeAlphanumeric: [-1, 3, 4, 5][ord(ver) - 1]
  of modeByte: [-1, -1, 4, 5][ord(ver) - 1]
  of modeKanji: [-1, -1, 3, 4][ord(ver) - 1]
  else: -1

proc microNibble(ver: MicroVersion, ec: QrEcLevel): int {.inline.} =
  ## Format info data nibble combining size class and EC level.
  case ver
  of mvM1: 0
  of mvM2: (if ec == ecLow: 1 else: 2)
  of mvM3: (if ec == ecLow: 3 else: 4)
  of mvM4:
    case ec
    of ecLow: 5
    of ecMedium: 6
    else: 7
  of mvAuto: 0

func microDataCapacity*(ver: MicroVersion, ec: QrEcLevel): int =
  ## Usable data bits; M1 and M3 end with a half codeword.
  let cw = microDataCw[ver][ord(ec)]
  result = cw * 8
  if ver == mvM1 or ver == mvM3:
    result -= 4

func microLastHalf*(ver: MicroVersion): bool {.inline.} =
  ## True when the final data codeword is four bits wide.
  ver == mvM1 or ver == mvM3

proc microMaskBit*(mask, x, y: int): bool {.inline.} =
  ## The four Micro QR data mask patterns.
  let p = x * y
  case mask
  of 0: (y and 1) == 0
  of 1: ((y div 2) + (x div 3)) mod 2 == 0
  of 2: (((p and 1) + (p mod 3)) and 1) == 0
  else: ((((x + y) and 1) + (p mod 3)) and 1) == 0

proc microModeCode(mode: QrMode): int {.inline.} =
  ## Micro QR renumbers the mode indicators compared to Model 2.
  case mode
  of modeNumeric: 0
  of modeAlphanumeric: 1
  of modeByte: 2
  of modeKanji: 3
  else: -1

# Encoding --------------------------------------------------------------------

proc buildMicroStream(segments: seq[QrSegment], ver: MicroVersion,
                      ec: QrEcLevel): seq[bool] {.raises: [QrError].} =
  ## Segment headers, payload, terminator and padding down to the exact
  ## data capacity of the symbol.
  let cap = microDataCapacity(ver, ec)
  var needed = 0
  for s in segments:
    let cw = microCountWidth(s.mode, ver)
    if cw < 0:
      raise newException(QrError,
        $s.mode & " is not available in " & $ver & "-" & $ec)
    inc needed, microModeBits[ver] + cw + s.bits.bitLen
  if needed > cap:
    raise newException(QrError, "data does not fit into " & $ver & "-" & $ec)
  var bb = initBitBuffer(cap div 8 + 8)
  for s in segments:
    if microModeBits[ver] > 0:
      bb.appendBits(microModeCode(s.mode), microModeBits[ver])
    bb.appendBits(s.nchars, microCountWidth(s.mode, ver))
    bb.append(s.bits)
  var length = bb.bitLen
  let term = min(cap - length, microTermBits[ver])
  bb.appendBits(0, term)
  inc length, term
  if not microLastHalf(ver):
    let pad = (8 - (length mod 8)) mod 8
    bb.appendBits(0, pad)
    inc length, pad
    while cap - length >= 16:
      bb.appendBytes([byte 0xEC, byte 0x11])
      inc length, 16
    if cap - length == 8:
      bb.appendBytes([byte 0xEC])
      inc length, 8
  else:
    while length < cap:
      let chunk = min(cap - length, 32)
      bb.appendBits(0, chunk)
      inc length, chunk
    doAssert length == cap
  doAssert length == cap
  result = newSeq[bool](cap)
  for i in 0 ..< cap:
    result[i] = bb.bitAt(i)

proc drawMicroFunctionPatterns(g: var QrMatrix, reserved: var seq[bool]) =
  ## Finder with separator, edge timing patterns and format reservations.
  let n = g.width
  template mark(x, y: int) = reserved[y * n + x] = true
  for y in 0 ..< 8:
    for x in 0 ..< 8:
      let dark = (x <= 6 and y <= 6) and
        (x == 0 or x == 6 or y == 0 or y == 6 or
         (x >= 2 and x <= 4 and y >= 2 and y <= 4))
      g.modules[y * n + x] = dark
      mark(x, y)
  for i in 8 ..< n:
    let dark = (i mod 2) == 0
    g.modules[i] = dark
    g.modules[i * n] = dark
    mark(i, 0)
    mark(0, i)
  for i in 0 ..< 9:
    mark(8, i)
    mark(i, 8)

proc writeMicroFormatInfo(g: var QrMatrix, fmt: int) =
  ## Single perpendicular format copy around the finder.
  for i in 0 ..< 8:
    g.modules[(i + 1) * g.width + 8] = ((fmt shr i) and 1) == 1
    g.modules[8 * g.width + (i + 1)] = ((fmt shr (14 - i)) and 1) == 1

proc placeMicroCodewords(m: var QrMatrix, reserved: seq[bool],
                         bits: seq[bool], dirOffset: int): bool =
  ## Two-column zigzag from the right edge; M1/M3 alternate direction
  ## offset by one pair compared to M2/M4.
  let n = m.width
  var idx = 0
  var right = n - 1
  while right >= 1:
    for vertical in 0 ..< n:
      for z in [0, 1]:
        let x = right - z
        let upwards = ((right + dirOffset) and 2) == 0
        let y = if upwards: n - 1 - vertical else: vertical
        if not reserved[y * n + x]:
          if idx >= bits.len:
            return false
          m.modules[y * n + x] = bits[idx]
          inc idx
    dec right, 2
  result = idx == bits.len

proc encodeMicroMatrix*(segments: seq[QrSegment], ver: MicroVersion,
                        ec: QrEcLevel, mask = -1): QrMatrix
    {.raises: [QrError].} =
  ## Renders a Micro QR symbol from explicit segments at a fixed size class.
  if ec == ecHigh:
    raise newException(QrError,
      "error correction level H is not available for Micro QR")
  if ver == mvAuto:
    raise newException(QrError, "explicit Micro QR version required")
  let dataCw = microDataCw[ver][ord(ec)]
  if dataCw < 0:
    raise newException(QrError, $ver & " does not support level " & $ec)

  let stream = buildMicroStream(segments, ver, ec)
  let lastHalf = microLastHalf(ver)
  let fullCw = if lastHalf: dataCw - 1 else: dataCw
  var dataCws = newSeq[uint8](dataCw)
  var pos = 0
  for i in 0 ..< fullCw:
    var b: uint8 = 0
    for _ in 0 ..< 8:
      b = (b shl 1) or (if stream[pos]: 1'u8 else: 0'u8)
      inc pos
    dataCws[i] = b
  if lastHalf:
    var b: uint8 = 0
    for _ in 0 ..< 4:
      b = (b shl 1) or (if stream[pos]: 1'u8 else: 0'u8)
      inc pos
    dataCws[dataCw - 1] = b shl 4
  let ecCws = rsEncodeParity(dataCws, microEcCw[ver][ord(ec)])

  var bits: seq[bool] = @[]
  for cw in dataCws[0 ..< fullCw]:
    for k in countdown(7, 0):
      bits.add ((cw.int shr k) and 1) == 1
  if lastHalf:
    for k in countdown(7, 4):
      bits.add ((dataCws[^1].int shr k) and 1) == 1
  for cw in ecCws:
    for k in countdown(7, 0):
      bits.add ((cw.int shr k) and 1) == 1

  let n = microSize[ver]
  result = initSquareQrMatrix(n)
  var reserved = newSeq[bool](n * n)
  drawMicroFunctionPatterns(result, reserved)
  if not placeMicroCodewords(result, reserved, bits,
                             if lastHalf: 2 else: 0):
    raise newException(QrError, "codeword placement failed")

  # masks are scored by the dark module balance along the bottom and right
  # edges; the highest score wins and ties keep the earliest mask
  var bestMask = 0
  var bestScore = -1
  for m in 0 ..< 4:
    var sumRight = 0
    var sumBottom = 0
    for i in 1 ..< n:
      if result.modules[i * n + n - 1] xor microMaskBit(m, n - 1, i):
        inc sumRight
      if result.modules[(n - 1) * n + i] xor microMaskBit(m, i, n - 1):
        inc sumBottom
    let score = if sumRight <= sumBottom: sumRight * 16 + sumBottom
                else: sumBottom * 16 + sumRight
    if score > bestScore:
      bestScore = score
      bestMask = m
  let chosen = if mask >= 0 and mask < 4: mask else: bestMask
  for y in 0 ..< n:
    for x in 0 ..< n:
      if not reserved[y * n + x] and microMaskBit(chosen, x, y):
        let i = y * n + x
        result.modules[i] = not result.modules[i]
  writeMicroFormatInfo(result, formatInfoMicro[microNibble(ver, ec) * 4 + chosen])

proc encodeMicro*(text: string, ec = ecLow, version = mvAuto,
                  mask = -1): QrMatrix {.raises: [QrError, ValueError].} =
  ## Encodes `text` as a Micro QR symbol, picking the smallest size class
  ## that holds the payload at the requested level when `version` is auto.
  if ec == ecHigh:
    raise newException(QrError,
      "error correction level H is not available for Micro QR")
  let segs = toSegments(text)
  var target = version
  if target == mvAuto:
    target = mvM4
    var found = false
    for v in mvM1 .. mvM4:
      if microDataCw[v][ord(ec)] < 0:
        continue
      try:
        discard buildMicroStream(segs, v, ec)
        target = v
        found = true
        break
      except QrError:
        discard
    if not found:
      raise newException(QrError,
        "payload too large for any Micro QR version at this level")
  result = encodeMicroMatrix(segs, target, ec, mask)

# Decoding --------------------------------------------------------------------

type MicroParsedFormat* = tuple[ver: MicroVersion, ec: QrEcLevel, mask: int]

proc microNibbleToSpec(nibble: int): MicroParsedFormat =
  case nibble
  of 0: (mvM1, ecLow, 0)
  of 1: (mvM2, ecLow, 0)
  of 2: (mvM2, ecMedium, 0)
  of 3: (mvM3, ecLow, 0)
  of 4: (mvM3, ecMedium, 0)
  of 5: (mvM4, ecLow, 0)
  of 6: (mvM4, ecMedium, 0)
  else: (mvM4, ecQuartile, 0)

proc readMicroFormat*(m: QrMatrix): tuple[spec: MicroParsedFormat, valid: bool] =
  ## Recovers the 15-bit format word; the vertical copy carries the low
  ## eight bits, the horizontal copy the high eight (bit 7 in both).
  var fmt = 0
  for i in 0 ..< 8:
    if m.modules[(i + 1) * m.width + 8]: fmt = fmt or (1 shl i)
    if m.modules[8 * m.width + (i + 1)]: fmt = fmt or (1 shl (14 - i))
  for idx in 0 ..< 32:
    if formatInfoMicro[idx] == fmt:
      var spec = microNibbleToSpec(idx div 4)
      if microSize[spec.ver] == m.width:
        spec.mask = idx mod 4
        return (spec, true)
  result.valid = false

func microIsFunctionCell(x, y: int): bool {.inline.} =
  (x < 8 and y < 8) or
  (y == 0 and x >= 8) or (x == 0 and y >= 8) or
  (x == 8 and y < 9) or (y == 8 and x < 9)

proc extractMicroCodewords*(m: QrMatrix, mask: int, dataCw, ecCwCount: int,
                            lastHalf: bool): tuple[data, parity: seq[uint8]] =
  ## Zigzag walk with on-the-fly unmasking, split into data and parity.
  let n = m.width
  let inc = if lastHalf: 2 else: 0
  let totalDataBits = dataCw * 8 - (if lastHalf: 4 else: 0)
  let fullCw = if lastHalf: dataCw - 1 else: dataCw
  var bits: seq[bool] = @[]
  var right = n - 1
  while right >= 1:
    for vertical in 0 ..< n:
      for z in [0, 1]:
        let x = right - z
        let upwards = ((right + inc) and 2) == 0
        let y = if upwards: n - 1 - vertical else: vertical
        if not microIsFunctionCell(x, y):
          var dark = m.modules[y * n + x]
          if microMaskBit(mask, x, y):
            dark = not dark
          bits.add dark
    dec right, 2
  var data = newSeq[uint8](dataCw)
  for i in 0 ..< fullCw:
    var b: uint8 = 0
    for k in 0 ..< 8:
      b = (b shl 1) or (if bits[i * 8 + k]: 1'u8 else: 0'u8)
    data[i] = b
  if lastHalf:
    var b: uint8 = 0
    for k in 0 ..< 4:
      b = (b shl 1) or (if bits[fullCw * 8 + k]: 1'u8 else: 0'u8)
    data[dataCw - 1] = b shl 4
  var parity = newSeq[uint8](ecCwCount)
  for i in 0 ..< ecCwCount:
    var b: uint8 = 0
    for k in 0 ..< 8:
      b = (b shl 1) or (if bits[totalDataBits + i * 8 + k]: 1'u8 else: 0'u8)
    parity[i] = b
  result = (data, parity)

proc parseMicroSegments*(data: openArray[uint8], ver: MicroVersion,
                         res: var QrDecodeResult) {.raises: [QrError, ValueError].} =
  ## Parses the corrected data region using per-size header widths.
  var idx = 0
  let totalBits = data.len * 8 - (if microLastHalf(ver): 4 else: 0)
  template take(count: int): int =
    var v = 0
    for _ in 0 ..< count:
      if idx >= totalBits:
        raise newException(QrError, "segment stream truncated")
      v = (v shl 1) or ((data[idx div 8].int shr (7 - (idx mod 8))) and 1)
      inc idx
    v
  template payloadSeg(segMode: QrMode, cnt: int, body: untyped) {.dirty.} =
    var pl = initBitBuffer(cnt * 2 + 16)
    body
    res.segments.add QrDecodedSegment(mode: segMode, nchars: cnt,
      data: pl.toSeq)
  let firstCode = if microModeBits[ver] > 0: take(microModeBits[ver]) else: 0
  case firstCode
  of 0:
    let n = take(microCountWidth(modeNumeric, ver))
    payloadSeg(modeNumeric, n):
      var consumed = 0
      while consumed + 3 <= n:
        let v = take(10)
        pl.appendByte uint8(ord('0') + v div 100)
        pl.appendByte uint8(ord('0') + (v div 10) mod 10)
        pl.appendByte uint8(ord('0') + v mod 10)
        inc consumed, 3
      if n - consumed == 2:
        let v = take(7)
        pl.appendByte uint8(ord('0') + v div 10)
        pl.appendByte uint8(ord('0') + v mod 10)
      elif n - consumed == 1:
        pl.appendByte uint8(ord('0') + take(4))
  of 1:
    let n = take(microCountWidth(modeAlphanumeric, ver))
    payloadSeg(modeAlphanumeric, n):
      var consumed = 0
      while consumed + 2 <= n:
        let v = take(11)
        pl.appendByte byte(alnumCharset[v div 45])
        pl.appendByte byte(alnumCharset[v mod 45])
        inc consumed, 2
      if n - consumed == 1:
        pl.appendByte byte(alnumCharset[take(6)])
  of 2:
    let n = take(microCountWidth(modeByte, ver))
    payloadSeg(modeByte, n):
      for _ in 0 ..< n:
        pl.appendByte uint8(take(8))
  of 3:
    let n = take(microCountWidth(modeKanji, ver))
    payloadSeg(modeKanji, n):
      var sj: seq[byte]
      for _ in 0 ..< n:
        let v = take(13)
        let sVal = ((v div 0xC0) shl 8) or (v mod 0xC0)
        if sVal + 0x8140 <= 0x9FFC:
          let sv = sVal + 0x8140
          sj.add byte(sv shr 8)
          sj.add byte(sv and 0xFF)
        elif sVal + 0xC140 <= 0xEBBF:
          let sv = sVal + 0xC140
          sj.add byte(sv shr 8)
          sj.add byte(sv and 0xFF)
      for b in sj:
        pl.appendByte b
  else:
    discard
  for s in res.segments:
    case s.mode
    of modeNumeric, modeAlphanumeric, modeByte:
      res.text.add cast[string](s.data)
    of modeKanji:
      var i = 0
      while i + 1 < s.data.len:
        let sj = s.data[i].int shl 8 or s.data[i + 1].int
        inc i, 2
        res.text.add toUTF8(runeFromSjis(sj))
    else:
      discard

proc decodeMicroMatrix*(m: QrMatrix): QrDecodeResult =
  ## Decodes a Micro QR module grid of side 11, 13, 15 or 17.
  result.eci = -1
  result.matrix = m
  result.family = famMicro
  if m.width != m.height or m.width notin {11, 13, 15, 17}:
    result.ok = false
    return
  let fmt = readMicroFormat(m)
  if not fmt.valid:
    result.ok = false
    return
  let spec = fmt.spec
  result.version = ord(spec.ver)
  result.ecLevel = spec.ec
  result.mask = spec.mask
  let dataCw = microDataCw[spec.ver][ord(spec.ec)]
  let ecCwCount = microEcCw[spec.ver][ord(spec.ec)]
  let extracted = extractMicroCodewords(m, spec.mask, dataCw, ecCwCount,
                                        microLastHalf(spec.ver))
  var blockCw = newSeq[uint8](dataCw + ecCwCount)
  for i in 0 ..< dataCw:
    blockCw[i] = extracted.data[i]
  for i in 0 ..< ecCwCount:
    blockCw[dataCw + i] = extracted.parity[i]
  try:
    rsDecode(blockCw, ecCwCount)
    parseMicroSegments(blockCw[0 ..< dataCw], spec.ver, result)
    result.ok = true
  except QrError:
    result.ok = false
