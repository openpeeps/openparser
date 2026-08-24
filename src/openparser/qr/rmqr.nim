# A collection of tiny parsers and dumpers
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/openparser

## Rectangular Micro QR Code (rMQR, ISO/IEC 23941) encoder and decoder.
##
## All 32 sizes from R7x43 to R17x139 at error correction levels M and H,
## Numeric, Alphanumeric, Byte and Kanji segments. The fixed data mask of
## section 7.8.2 is applied automatically; rMQR defines no mask selection.
##
## Unstable API. Prefer importing `openparser/qr` instead of this module.

import std/[unicode, strutils]
import ./common, ./galois, ./model2

const formatInfoMaskRmqr = 0x1FAB2'u32
  ## XOR mask applied to the finder side copy (ISO/IEC 23941 annex C).

include rmqr_tables

type
  RmqrSpec* = tuple[ver: int, ec: QrEcLevel]

proc rmqrEcIndex(ec: QrEcLevel): int {.inline.} =
  ## Internal table index; M = 0, H = 1.
  if ec == ecHigh: 1 else: 0

func rmqrSizeName*(ver: int): string =
  ## Canonical designation such as "R11x139".
  "R" & $rmqrHeight[ver] & "x" & $rmqrWidth[ver]

proc parseRmqrVersion(name: string): int {.raises: [QrError, ValueError].} =
  ## Resolves a designation like "R11x139" to the version index.
  if not name.startsWith("R") and not name.startsWith("r"):
    raise newException(QrError, "invalid rMQR version \"" & name & "\"")
  let parts = name[1 .. ^1].split('x')
  if parts.len != 2:
    raise newException(QrError, "invalid rMQR version \"" & name & "\"")
  try:
    let h = parseInt(parts[0])
    let w = parseInt(parts[1])
    for v in 0 ..< 32:
      if rmqrHeight[v] == h and rmqrWidth[v] == w:
        return v
    raise newException(QrError, "unknown rMQR size \"R" & $h & "x" & $w & "\"")
  except ValueError:
    raise newException(QrError, "invalid rMQR version \"" & name & "\"")

func rmqrCciWidth(mode: QrMode, ver: int): int {.inline.} =
  case mode
  of modeNumeric: rmqrCciBits[0][ver]
  of modeAlphanumeric: rmqrCciBits[1][ver]
  of modeByte: rmqrCciBits[2][ver]
  of modeKanji: rmqrCciBits[3][ver]
  else: -1

# Encoding --------------------------------------------------------------------

proc buildRmqrStream(segments: seq[QrSegment], ver: int,
                     targetCw: int): seq[bool] {.raises: [QrError].} =
  ## Segment headers with three bit mode indicators, payload, terminator
  ## and pad codewords down to `targetCw` bytes.
  var bb = initBitBuffer(targetCw + 8)
  var needed = 0
  for s in segments:
    let cci = rmqrCciWidth(s.mode, ver)
    if cci < 0:
      raise newException(QrError, $s.mode & " is not available in rMQR")
    inc needed, 3 + cci + s.bits.bitLen
  if needed > targetCw * 8:
    raise newException(QrError,
      "data does not fit into " & rmqrSizeName(ver))
  for s in segments:
    # mode indicator values follow Model 2 numbering minus one
    let code = case s.mode
      of modeNumeric: 1
      of modeAlphanumeric: 2
      of modeByte: 3
      of modeKanji: 4
      else: -1
    bb.appendBits(code, 3)
    bb.appendBits(s.nchars, rmqrCciWidth(s.mode, ver))
    bb.append(s.bits)
  var length = bb.bitLen
  # terminator: fill towards the byte boundary but never more than three
  # bits unless the stream already ends on a codeword edge
  var termbits = 8 - length mod 8
  if termbits == 8:
    termbits = 0
  let currentBytes = (length + termbits) div 8
  if termbits != 0 or currentBytes < targetCw:
    let maxTerm = 3
    termbits = if termbits < maxTerm and currentBytes == targetCw: termbits
               else: maxTerm
    bb.appendBits(0, termbits)
    inc length, termbits
  var padbits = 8 - length mod 8
  if padbits == 8:
    padbits = 0
  bb.appendBits(0, padbits)
  inc length, padbits
  let cwCount = length div 8
  result = newSeq[bool](cwCount * 8)
  for i in 0 ..< length:
    result[i] = bb.bitAt(i)
  # pad codewords alternate 0xEC / 0x11
  var toggle = true
  var pos = length
  while pos < targetCw * 8:
    let pad: uint8 = if toggle: 0xEC else: 0x11
    for k in countdown(7, 0):
      result.add ((pad.int shr k) and 1) == 1
    inc pos, 8
    toggle = not toggle

proc drawRmqrFunctionPatterns(g: var QrMatrix, reserved: var seq[bool]) =
  ## Edge timings, corner finders, alignment bars and format reservations.
  let h = g.height
  let w = g.width
  template mark(x, y: int) = reserved[y * w + x] = true
  template setDark(x, y: int, dark: bool) =
    g.modules[y * w + x] = dark
    mark(x, y)

  # timing along all four edges, starting dark in every corner
  for x in 0 ..< w:
    setDark(x, 0, (x mod 2) == 0)
    setDark(x, h - 1, (x mod 2) == 0)
  for y in 0 ..< h:
    setDark(0, y, (y mod 2) == 0)
    setDark(w - 1, y, (y mod 2) == 0)

  # finder pattern top left (7x7 ring with centre block)
  const finder = [0x7F, 0x41, 0x5D, 0x5D, 0x5D, 0x41, 0x7F]
  for dy in 0 ..< 7:
    for dx in 0 ..< 7:
      setDark(dx, dy, ((finder[dy] shr (6 - dx)) and 1) == 1)

  # finder sub-pattern bottom right (alignment style 5x5)
  const alignment = [0x1F, 0x11, 0x15, 0x11, 0x1F]
  for dy in 0 ..< 5:
    for dx in 0 ..< 5:
      setDark(w - 5 + dx, h - 5 + dy,
        ((alignment[dy] shr (4 - dx)) and 1) == 1)

  # corner finders bottom left and top right
  setDark(0, h - 2, true)
  setDark(1, h - 2, false)
  setDark(1, h - 1, true)
  setDark(w - 2, 0, true)
  setDark(w - 2, 1, false)
  setDark(w - 1, 1, true)

  # separator around the finder, drawn after the corners so it wins over
  # a corner finder when the symbol is only nine modules tall
  template setLight(x, y: int) =
    g.modules[y * w + x] = false
    mark(x, y)
  for y in 0 ..< 7:
    setLight(7, y)
  if h > 7:
    for x in 0 ..< 8:
      setLight(x, 7)

  # alignment patterns: alternating vertical bar plus dark squares at
  # both ends, one per centre column when the width exceeds 27
  if w > 27:
    var widthClass = -1
    for i, wc in [(43, 0), (59, 1), (77, 2), (99, 3), (139, 4)]:
      if w == wc[0]:
        widthClass = wc[1]
    for i in 0 ..< 4:
      let fp = rmqrTableD1[widthClass][i]
      if fp != 0:
        for y in 0 ..< h:
          setDark(fp, y, (y mod 2) == 0)
        # top square rows 1..2, bottom square rows h-3..h-2
        for dy in [1, 2, h - 3, h - 2]:
          setDark(fp - 1, dy, true)
          setDark(fp + 1, dy, true)

  # format info reservations
  for i in 0 ..< 5:
    for j in 0 ..< 3:
      mark(8 + j, 1 + i)             # top left block
      mark(w - 8 + j, h - 6 + i)     # bottom right block
  for i in 1 ..< 4:
    mark(11, i)
  for j in 1 ..< 4:
    mark(w - 5 + j - 1, h - 6)

proc placeRmqrCodewords(g: var QrMatrix, reserved: seq[bool],
                        bits: seq[bool]): bool =
  ## Bit level zigzag: column pairs from the right, starting upwards at
  ## the bottom right, skipping reserved cells.
  let h = g.height
  let w = g.width
  let n = bits.len
  let xStart = w - 3
  var rowIdx = 0
  var dirUp = true
  var y = h - 1
  var i = 0
  while i < n:
    let x = xStart - rowIdx * 2
    if not reserved[y * w + x + 1]:
      g.modules[y * w + x + 1] = bits[i]
      inc i
    if i < n:
      if not reserved[y * w + x]:
        g.modules[y * w + x] = bits[i]
        inc i
    if dirUp:
      dec y
      if y == -1:
        inc rowIdx
        y = 0
        dirUp = false
    else:
      inc y
      if y == h:
        inc rowIdx
        y = h - 1
        dirUp = true
  result = i == n

func rmqrMaskBit(x, y: int): bool {.inline.} =
  ## The single fixed rMQR data mask.
  ((y div 2) + (x div 3)) mod 2 == 0

proc writeRmqrFormatInfo(g: var QrMatrix, ver: int, ec: QrEcLevel) =
  ## Two 18-bit copies around the finders, bit order per ISO annex C.
  let h = g.height
  let w = g.width
  let idx = ver + (if ec == ecHigh: 32 else: 0)
  let left = formatInfoRmqrLeft[idx]
  let right = formatInfoRmqrRight[idx]
  for i in 0 ..< 5:
    for j in 0 ..< 3:
      g.modules[(i + 1) * w + j + 8] = ((left shr (j * 5 + i)) and 1) == 1
      g.modules[(h - 6 + i) * w + (w - 8 + j)] =
        ((right shr (j * 5 + i)) and 1) == 1
  for b in 0 ..< 3:
    g.modules[(b + 1) * w + 11] = ((left shr (15 + b)) and 1) == 1
    g.modules[(h - 6) * w + (w - 5 + b)] = ((right shr (15 + b)) and 1) == 1

proc encodeRmqrMatrix*(segments: seq[QrSegment], ver: int, ec: QrEcLevel,
                       ): QrMatrix {.raises: [QrError].} =
  ## Renders an rMQR symbol from explicit segments at a fixed version.
  if ec == ecLow or ec == ecQuartile:
    raise newException(QrError, "rMQR supports error correction levels M and H only")
  if ver < 0 or ver > 31:
    raise newException(QrError, "rMQR version out of range")
  let dataCw = rmqrDataCw[rmqrEcIndex(ec)][ver]
  let numBlocks = rmqrBlocks[rmqrEcIndex(ec)][ver]

  let stream = buildRmqrStream(segments, ver, dataCw)
  var dataCws = newSeq[uint8](dataCw)
  for i in 0 ..< dataCw:
    var b: uint8 = 0
    for k in 0 ..< 8:
      b = (b shl 1) or (if stream[i * 8 + k]: 1'u8 else: 0'u8)
    dataCws[i] = b

  # RS blocks (longer blocks last), then column-wise interleave of data
  # and parity across blocks
  let totalCw = rmqrTotalCw[ver]
  let ecLen = (totalCw - dataCw) div numBlocks
  let shortLen = dataCw div numBlocks
  let numLong = dataCw mod numBlocks
  var fullCw: seq[uint8] = @[]
  var pos = 0
  var blockDatas = newSeq[seq[uint8]](numBlocks)
  var parities = newSeq[seq[uint8]](numBlocks)
  for b in 0 ..< numBlocks:
    let len = shortLen + (if b >= numBlocks - numLong: 1 else: 0)
    blockDatas[b] = dataCws[pos ..< pos + len]
    inc pos, len
    parities[b] = rsEncodeParity(blockDatas[b], ecLen)
  for col in 0 ..< shortLen + 1:
    for b in 0 ..< numBlocks:
      if col < blockDatas[b].len:
        fullCw.add blockDatas[b][col]
  for e in 0 ..< ecLen:
    for b in 0 ..< numBlocks:
      fullCw.add parities[b][e]

  let h = rmqrHeight[ver]
  let w = rmqrWidth[ver]
  result = initQrMatrix(w, h)
  var reserved = newSeq[bool](w * h)
  drawRmqrFunctionPatterns(result, reserved)
  var bits: seq[bool] = @[]
  for cw in fullCw:
    for k in countdown(7, 0):
      bits.add ((cw.int shr k) and 1) == 1
  if not placeRmqrCodewords(result, reserved, bits):
    raise newException(QrError, "codeword placement failed")
  for y in 0 ..< h:
    for x in 0 ..< w:
      let i = y * w + x
      if not reserved[i] and rmqrMaskBit(x, y):
        result.modules[i] = not result.modules[i]
  writeRmqrFormatInfo(result, ver, ec)

proc encodeRmqr*(text: string, ec = ecMedium, version = ""): QrMatrix
    {.raises: [QrError, ValueError].} =
  ## Encodes `text` as an rMQR symbol. `version` is a size designation
  ## such as "R11x139"; empty selects the smallest fitting footprint.
  if ec == ecLow or ec == ecQuartile:
    raise newException(QrError, "rMQR supports error correction levels M and H only")
  let segs = toSegments(text)
  var ver: int
  if version.len > 0:
    ver = parseRmqrVersion(version)
    let cap = rmqrDataCw[rmqrEcIndex(ec)][ver] * 8
    var needed = 0
    for s in segs:
      needed += 3 + rmqrCciWidth(s.mode, ver) + s.bits.bitLen
    if needed > cap:
      raise newException(QrError,
        "data does not fit into " & rmqrSizeName(ver) & "-" & $ec)
  else:
    # smallest footprint wins; ties keep the later (taller) version
    ver = -1
    var bestFootprint = high(int)
    var candidate = 31
    while candidate >= 0:
      var needed = 0
      for s in segs:
        needed += 3 + rmqrCciWidth(s.mode, candidate) + s.bits.bitLen
      if needed <= rmqrDataCw[rmqrEcIndex(ec)][candidate] * 8:
        let footprint = rmqrHeight[candidate] * rmqrWidth[candidate]
        if footprint < bestFootprint:
          bestFootprint = footprint
          ver = candidate
      dec candidate
    if ver < 0:
      raise newException(QrError, "payload too large for any rMQR version")
  result = encodeRmqrMatrix(segs, ver, ec)

# Decoding --------------------------------------------------------------------

proc readRmqrFormat*(m: QrMatrix): tuple[spec: RmqrSpec, valid: bool] =
  ## Recovers both 18-bit format words, unmasking and matching against
  ## the valid sequences; tolerates a few flipped modules per copy.
  let h = m.height
  let w = m.width
  template appendBit(word: var uint32, bit: bool) =
    word = (word shl 1) or (if bit: 1'u32 else: 0'u32)
  # left copy: column 11 rows 3..1, then columns 10..8 rows 5..1
  var wordLeft = 0'u32
  for y in countdown(3, 1):
    wordLeft.appendBit(m.modules[y * w + 11])
  for x in countdown(10, 8):
    for y in countdown(5, 1):
      wordLeft.appendBit(m.modules[y * w + x])
  # right copy: row height-6 then columns width-6..width-8
  var wordRight = 0'u32
  for x in 3 .. 5:
    wordRight.appendBit(m.modules[(h - 6) * w + (w - x)])
  for x in 6 .. 8:
    for y in 2 .. 6:
      wordRight.appendBit(m.modules[(h - y) * w + (w - x)])
  # both tables store already-masked sequences, so compare directly
  func popcount(v: uint32): int =
    var x = v
    while x != 0:
      x = x and (x - 1)
      inc result
  var bestDist = 19
  var bestIdx = -1
  for idx in 0 ..< 64:
    let dl = popcount(wordLeft xor uint32(formatInfoRmqrLeft[idx]))
    if dl < bestDist:
      bestDist = dl
      bestIdx = idx
    let dr = popcount(wordRight xor uint32(formatInfoRmqrRight[idx]))
    if dr < bestDist:
      bestDist = dr
      bestIdx = idx
  if bestIdx < 0 or bestDist > 3:
    result.valid = false
    return
  let ver = bestIdx mod 32
  let ec = if bestIdx >= 32: ecHigh else: ecMedium
  if rmqrHeight[ver] != h or rmqrWidth[ver] != w:
    result.valid = false
    return
  result = ((ver, ec), true)

proc extractRmqrCodewords*(m: QrMatrix, ver: int,
                           ): seq[uint8] {.raises: [QrError].} =
  ## Zigzag walk with on-the-fly unmasking returning the full codeword
  ## stream (interleaved data and parity).
  let h = m.height
  let w = m.width
  var reserved = newSeq[bool](w * h)
  var grid = initQrMatrix(w, h)
  drawRmqrFunctionPatterns(grid, reserved)
  var bits: seq[bool] = @[]
  let xStart = w - 3
  var rowIdx = 0
  var dirUp = true
  var y = h - 1
  let n = rmqrTotalCw[ver] * 8
  while bits.len < n:
    let x = xStart - rowIdx * 2
    if not reserved[y * w + x + 1]:
      var dark = m.modules[y * w + x + 1]
      if rmqrMaskBit(x + 1, y):
        dark = not dark
      bits.add dark
    if bits.len < n:
      if not reserved[y * w + x]:
        var dark = m.modules[y * w + x]
        if rmqrMaskBit(x, y):
          dark = not dark
        bits.add dark
    if dirUp:
      dec y
      if y == -1:
        inc rowIdx
        y = 0
        dirUp = false
    else:
      inc y
      if y == h:
        inc rowIdx
        y = h - 1
        dirUp = true
  result = newSeq[uint8](n div 8)
  for i in 0 ..< n div 8:
    var b: uint8 = 0
    for k in 0 ..< 8:
      b = (b shl 1) or (if bits[i * 8 + k]: 1'u8 else: 0'u8)
    result[i] = b

proc deinterleaveRmqr(cw: openArray[uint8], ver: int, ec: QrEcLevel,
                      ): seq[uint8] {.raises: [QrError].} =
  ## Undoes the shorter-first column-wise interleave and corrects each
  ## RS block.
  let numBlocks = rmqrBlocks[rmqrEcIndex(ec)][ver]
  let dataTotal = rmqrDataCw[rmqrEcIndex(ec)][ver]
  let ecLen = (rmqrTotalCw[ver] - dataTotal) div numBlocks
  let shortLen = dataTotal div numBlocks
  let numLong = dataTotal mod numBlocks
  var dataLens = newSeq[int](numBlocks)
  for b in 0 ..< numBlocks:
    dataLens[b] = shortLen + (if b >= numBlocks - numLong: 1 else: 0)
  var blocks = newSeq[seq[uint8]](numBlocks)
  for b in 0 ..< numBlocks:
    blocks[b] = newSeq[uint8](dataLens[b] + ecLen)
  var pos = 0
  for col in 0 ..< shortLen + 1:
    for b in 0 ..< numBlocks:
      if col < dataLens[b]:
        blocks[b][col] = cw[pos]
        inc pos
  for e in 0 ..< ecLen:
    for b in 0 ..< numBlocks:
      blocks[b][dataLens[b] + e] = cw[pos]
      inc pos
  result = newSeq[uint8](dataTotal)
  var outIdx = 0
  for b in 0 ..< numBlocks:
    rsDecode(blocks[b], ecLen)
    for i in 0 ..< dataLens[b]:
      result[outIdx] = blocks[b][i]
      inc outIdx

proc parseRmqrSegments*(data: openArray[uint8], ver: int,
                        res: var QrDecodeResult) {.raises: [QrError, ValueError].} =
  ## Parses segment headers and payloads using rMQR widths.
  var idx = 0
  let totalBits = data.len * 8
  template take(count: int): int =
    var v = 0
    for _ in 0 ..< count:
      if idx >= totalBits:
        raise newException(QrError, "segment stream truncated")
      v = (v shl 1) or ((data[idx div 8].int shr (7 - (idx mod 8))) and 1)
      inc idx
    v
  while idx + 3 <= totalBits:
    let code = take(3)
    case code
    of 0:
      break
    of 1, 2, 3, 4:
      let segMode = case code
        of 1: modeNumeric
        of 2: modeAlphanumeric
        of 3: modeByte
        else: modeKanji
      let cciTable = case code
        of 1: 0
        of 2: 1
        of 3: 2
        else: 3
      let n = take(rmqrCciBits[cciTable][ver])
      var pl = initBitBuffer(n * 2 + 16)
      case segMode
      of modeNumeric:
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
      of modeAlphanumeric:
        var consumed = 0
        while consumed + 2 <= n:
          let v = take(11)
          pl.appendByte byte(alnumCharset[v div 45])
          pl.appendByte byte(alnumCharset[v mod 45])
          inc consumed, 2
        if n - consumed == 1:
          pl.appendByte byte(alnumCharset[take(6)])
      of modeByte:
        for _ in 0 ..< n:
          pl.appendByte uint8(take(8))
      of modeKanji:
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
      res.segments.add QrDecodedSegment(mode: segMode, nchars: n,
        data: pl.toSeq)
    else:
      # FNC1 and ECI headers are skipped without payload interpretation
      if code == 7:
        let first = take(1)
        if first == 0:
          discard take(7)
        else:
          let second = take(1)
          if second == 0:
            discard take(14)
          else:
            discard take(21)
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

proc decodeRmqrMatrix*(m: QrMatrix): QrDecodeResult =
  ## Decodes an rMQR module grid of any of the 32 standard sizes.
  result.eci = -1
  result.matrix = m
  result.family = famRmqr
  var ver = -1
  for v in 0 ..< 32:
    if rmqrHeight[v] == m.height and rmqrWidth[v] == m.width:
      ver = v
      break
  if ver < 0 or m.width < 21:
    result.ok = false
    return
  let fmt = readRmqrFormat(m)
  if not fmt.valid:
    result.ok = false
    return
  result.version = fmt.spec.ver + 1
  result.ecLevel = fmt.spec.ec
  result.mask = 0
  try:
    let cw = extractRmqrCodewords(m, ver)
    let data = deinterleaveRmqr(cw, ver, fmt.spec.ec)
    parseRmqrSegments(data, ver, result)
    result.ok = true
  except QrError, ValueError:
    result.ok = false
