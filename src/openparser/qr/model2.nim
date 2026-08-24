# A collection of tiny parsers and dumpers
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/openparser

## QR Code Model 2 (ISO/IEC 18004) encoder: versions 1-40, error correction
## levels L/M/Q/H, Numeric, Alphanumeric, Byte (UTF-8), Kanji (Shift-JIS),
## ECI and Structured Append headers, automatic segmentation, mask selection
## by penalty scoring and Reed-Solomon block interleaving.
##
## Unstable API. Prefer importing `openparser/qr` instead of this module.

import std/[unicode, strutils, tables, sequtils, algorithm, math]
import ./common, ./galois, ./jis, ./read

export common, galois, read

const
  alnumCharset* = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:"
    ## Alphanumeric mode alphabet, index equals the encoded value.

  ecCwPerBlock: array[4, array[41, int]] = [
    # L
    [-1, 7, 10, 15, 20, 26, 18, 20, 24, 30, 18, 20, 24, 26, 30, 22, 24,
     28, 30, 28, 28, 28, 28, 30, 30, 26, 28, 30, 30, 30, 30, 30, 30, 30,
     30, 30, 30, 30, 30, 30, 30],
    # M
    [-1, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28,
     28, 26, 26, 26, 26, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28,
     28, 28, 28, 28, 28, 28, 28],
    # Q
    [-1, 13, 22, 18, 26, 18, 24, 18, 22, 20, 24, 28, 26, 24, 20, 30, 24,
     28, 28, 26, 30, 28, 30, 30, 30, 30, 28, 30, 30, 30, 30, 30, 30, 30,
     30, 30, 30, 30, 30, 30, 30],
    # H
    [-1, 17, 28, 22, 16, 22, 28, 26, 26, 24, 28, 24, 28, 22, 24, 24, 30,
     28, 28, 26, 28, 30, 24, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30,
     30, 30, 30, 30, 30, 30, 30]]

  ecNumBlocks: array[4, array[41, int]] = [
    # L
    [-1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 4, 4, 4, 4, 4, 6, 6, 6, 6, 7, 8, 8,
     9, 9, 10, 12, 12, 12, 13, 14, 15, 16, 17, 18, 19, 19, 20, 21, 22,
     24, 25],
    # M
    [-1, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14,
     16, 17, 17, 18, 20, 21, 23, 25, 26, 28, 29, 31, 33, 35, 37, 38, 40,
     43, 45, 47, 49],
    # Q
    [-1, 1, 1, 2, 2, 4, 4, 6, 6, 8, 8, 8, 10, 12, 16, 12, 17, 16, 18, 21,
     20, 23, 23, 25, 27, 29, 34, 34, 35, 38, 40, 43, 45, 48, 51, 53, 56,
     59, 62, 65, 68],
    # H
    [-1, 1, 1, 2, 4, 4, 4, 5, 6, 8, 8, 11, 11, 16, 16, 18, 16, 19, 21,
     25, 25, 25, 34, 30, 32, 35, 37, 40, 42, 45, 48, 51, 54, 57, 60, 63,
     66, 70, 74, 77, 81]]

type
  QrEncodeOptions* = object
    ## Tunables accepted by every Model 2 entry point.
    ecLevel*: QrEcLevel = ecMedium
      ## Error correction level requested by the caller.
    minVersion*: int = 1
      ## Smallest permitted symbol version.
    maxVersion*: int = 40
      ## Largest permitted symbol version.
    mask*: int = -1
      ## Fixed mask pattern 0-7, or -1 to pick the lowest-penalty mask.
    eci*: int = 0
      ## ECI assignment number emitted as a leading header, 0 disables it.
    structuredAppend*: tuple[enabled: bool, index, total: int, parity: uint8] =
      (false, 0, 0, 0'u8)
      ## When enabled a Structured Append header is prepended. `parity` may
      ## be supplied by the caller or derived with `structuredAppendParity`.

func defaultQrEncodeOptions*(): QrEncodeOptions = QrEncodeOptions()

# Version geometry -----------------------------------------------------------

proc numRawDataModules(ver: int): int {.inline.} =
  ## Total storable data modules for `ver`, function patterns excluded.
  assert ver >= 1 and ver <= 40
  result = (16 * ver + 128) * ver + 64
  if ver >= 2:
    let numAlign = ver div 7 + 2
    result -= (25 * numAlign - 10) * numAlign - 55
    if ver >= 7:
      result -= 36

proc numDataCodewords*(ver: int, ecl: QrEcLevel): int {.inline.} =
  ## Data codeword capacity of `ver` at error correction level `ecl`.
  numRawDataModules(ver) div 8 -
    ecCwPerBlock[ord(ecl)][ver] * ecNumBlocks[ord(ecl)][ver]

proc alignmentPositions*(ver: int): seq[int] =
  ## Center coordinates of alignment patterns for `ver`, ascending.
  if ver == 1: return @[]
  let numAlign = ver div 7 + 2
  let step = (if ver == 32: 26
              else: (ver * 4 + numAlign * 2 + 1) div (numAlign * 2 - 2) * 2)
  result = @[6]
  var pos = ver * 4 + 17 - 7
  while result.len < numAlign:
    result.insert(pos, 1)
    pos -= step

proc charCountBits(mode: QrMode, ver: int): int =
  case mode
  of modeNumeric: (if ver < 10: 10 elif ver < 27: 12 else: 14)
  of modeAlphanumeric: (if ver < 10: 9 elif ver < 27: 11 else: 13)
  of modeByte: (if ver < 10: 8 else: 16)
  of modeKanji: (if ver < 10: 8 elif ver < 27: 10 else: 12)
  else: raise newException(QrError, "mode has no character count field")

# Segment construction -------------------------------------------------------

type
  QrSegment* = object
    ## One encodation segment: mode tag, ISO character count and payload
    ## bits (header fields excluded, they are added during assembly).
    mode*: QrMode
    nchars*: int
    bits*: BitBuffer

func initSegment(mode: QrMode, nchars: int, capHint = 16): QrSegment =
  QrSegment(mode: mode, nchars: nchars, bits: initBitBuffer(capHint))

proc makeNumeric*(digits: string): QrSegment =
  ## Numeric segment; every character must be an ASCII digit.
  for c in digits:
    if c notin {'0' .. '9'}:
      raise newException(QrError, "numeric segment accepts digits only")
  result = initSegment(modeNumeric, digits.len, digits.len div 2 + 8)
  var i = 0
  while i < digits.len:
    let rem = digits.len - i
    if rem >= 3:
      result.bits.appendBits(parseInt(digits[i ..< i + 3]), 10)
      inc i, 3
    elif rem == 2:
      result.bits.appendBits(parseInt(digits[i ..< i + 2]), 7)
      inc i, 2
    else:
      result.bits.appendBits(parseInt(digits[i ..< i + 1]), 4)
      inc i

proc alnumValue(c: char): int {.inline.} =
  ## Index of `c` in the alphanumeric alphabet or -1.
  let p = find(alnumCharset, c)
  p

proc makeAlphanumeric*(text: string): QrSegment =
  ## Alphanumeric segment over `alnumCharset`.
  for c in text:
    if alnumValue(c) < 0:
      raise newException(QrError, "character not in alphanumeric set: '" & c & "'")
  result = initSegment(modeAlphanumeric, text.len, text.len)
  var i = 0
  while i < text.len:
    if i + 1 < text.len:
      result.bits.appendBits(alnumValue(text[i]) * 45 + alnumValue(text[i + 1]), 11)
      inc i, 2
    else:
      result.bits.appendBits(alnumValue(text[i]), 6)
      inc i

proc makeBytes*(data: openArray[byte]): QrSegment =
  ## Byte segment over raw bytes (UTF-8 text lands here unchanged).
  result = initSegment(modeByte, data.len, data.len + 4)
  result.bits.appendBytes(data)

proc makeBytes*(text: string): QrSegment {.inline.} =
  makeBytes(text.toOpenArrayByte(0, text.len - 1))

proc makeKanji*(sjis: openArray[byte]): QrSegment =
  ## Kanji segment over raw Shift-JIS double-byte characters.
  ## Values must fall in 0x8140-0x9FFC or 0xE040-0xEBBF.
  if sjis.len mod 2 != 0:
    raise newException(QrError, "kanji segment needs an even number of bytes")
  result = initSegment(modeKanji, sjis.len div 2, sjis.len)
  var i = 0
  while i < sjis.len:
    let v = sjis[i].int shl 8 or sjis[i + 1].int
    let d =
      if v >= 0x8140 and v <= 0x9FFC: v - 0x8140
      elif v >= 0xE040 and v <= 0xEBBF: v - 0xC140
      else: raise newException(QrError, "shift-jis value out of kanji range: 0x" &
        v.toHex(4))
    result.bits.appendBits((d shr 8) * 0xC0 + (d and 0xFF), 13)
    inc i, 2

proc makeEci*(assignmentNumber: int): QrSegment =
  ## ECI header segment carrying `assignmentNumber` (0x000000-0xFFFF).
  var s = initSegment(modeEci, 0, 4)
  if assignmentNumber < 1 shl 7:
    s.bits.appendBits(0'u32, 1)
    s.bits.appendBits(uint32(assignmentNumber), 7)
  elif assignmentNumber < 1 shl 14:
    s.bits.appendBits(2'u32, 2)
    s.bits.appendBits(uint32(assignmentNumber), 14)
  elif assignmentNumber < 1 shl 21:
    s.bits.appendBits(6'u32, 3)
    s.bits.appendBits(uint32(assignmentNumber), 21)
  else:
    raise newException(QrError, "ECI assignment number too large")
  s

proc makeTerminator*(): QrSegment {.inline.} =
  ## Empty terminator segment (mode 0000, zero bits of payload).
  initSegment(modeTerminator, 0)

# Automatic segmentation -----------------------------------------------------

func isDigitRune(r: Rune): bool {.inline.} = r.int >= 0x30 and r.int <= 0x39
func isAlnumRune(r: Rune): bool {.inline.} =
  r.int < 128 and alnumValue(char(r.int)) >= 0

proc jisLookup(cp: Rune): int =
  ## Shift-JIS value for code point `cp` or -1. Binary search over the
  ## generated table.
  var lo = 0
  var hi = jisTableHex.len div 8 - 1
  let key = cp.uint16
  while lo <= hi:
    let mid = (lo + hi) div 2
    let midCp = uint16(parseHexInt(jisTableHex[mid * 8 ..< mid * 8 + 4]))
    if midCp == key:
      return parseHexInt(jisTableHex[mid * 8 + 4 ..< mid * 8 + 8])
    elif midCp < key: lo = mid + 1
    else: hi = mid - 1
  -1

proc sjisBytes*(s: string): seq[byte] =
  ## Shift-JIS encoding of `s` restricted to JIS X 0208 characters.
  ## Raises QrError for characters outside the generated table.
  for r in s.runes:
    let v = jisLookup(r)
    if v < 0:
      raise newException(QrError,
        "code point U+" & r.int.toHex(4) & " has no Shift-JIS mapping")
    result.add byte(v shr 8)
    result.add byte(v and 0xFF)

proc toSegments*(s: string): seq[QrSegment] =
  ## Chooses a compact encodation for `s`: Numeric when the whole input
  ## is digits, Alphanumeric when the alphabet suffices, otherwise the
  ## text splits into Kanji runs (two or more characters) surrounded by
  ## Byte runs. This keeps header overhead low without a full cost model.
  var runes: seq[Rune] = @[]
  for r in s.runes: runes.add r
  result = @[]

  if runes.len == 0:
    return @[makeBytes("")]

  block chooseWholeString:
    var allDigits = true
    var allAlnum = true
    for r in runes:
      if not isDigitRune(r): allDigits = false
      if not isAlnumRune(r): allAlnum = false
    if allDigits:
      var buf = ""
      for r in runes: buf.add char(r.int)
      return @[makeNumeric(buf)]
    if allAlnum:
      var buf = ""
      for r in runes: buf.add char(r.int)
      return @[makeAlphanumeric(buf)]

  var i = 0
  while i < runes.len:
    if jisLookup(runes[i]) >= 0:
      var j = i
      while j < runes.len and jisLookup(runes[j]) >= 0: inc j
      if j - i >= 2:
        var buf: seq[byte]
        for k in i ..< j:
          let v = jisLookup(runes[k])
          buf.add byte(v shr 8)
          buf.add byte(v and 0xFF)
        result.add makeKanji(buf)
        i = j
        continue
    # otherwise accumulate into the current byte run
    var j = i + 1
    while j < runes.len and jisLookup(runes[j]) < 0: inc j
    var buf = ""
    for k in i ..< j:
      buf.add toUTF8(runes[k])
    result.add makeBytes(buf)
    i = j
  if result.len == 0:
    result.add makeBytes("")

# Codeword assembly ----------------------------------------------------------

proc interleave(cw: openArray[byte], ver: int, ecl: QrEcLevel): seq[byte] =
  ## Splits into RS blocks, computes parity and merges data-then-ECC order.
  let numBlocks = ecNumBlocks[ord(ecl)][ver]
  let total = numDataCodewords(ver, ecl) + ecCwPerBlock[ord(ecl)][ver] * numBlocks
  let ecLen = ecCwPerBlock[ord(ecl)][ver]
  let shortLen = numDataCodewords(ver, ecl) div numBlocks
  let numLong = numDataCodewords(ver, ecl) mod numBlocks
  var blockStarts = newSeq[int](numBlocks)
  var dataLens = newSeq[int](numBlocks)
  var offset = 0
  for b in 0 ..< numBlocks:
    blockStarts[b] = offset
    dataLens[b] = shortLen + (if b >= numBlocks - numLong: 1 else: 0)
    offset += dataLens[b]
  var parities = newSeq[seq[uint8]](numBlocks)
  for b in 0 ..< numBlocks:
    parities[b] = rsEncodeParity(
      cw.toOpenArray(blockStarts[b], blockStarts[b] + dataLens[b] - 1), ecLen)
  result = newSeq[byte](total)
  var outIdx = 0
  for col in 0 ..< shortLen + 1:
    for b in 0 ..< numBlocks:
      if col < dataLens[b]:
        result[outIdx] = cw[blockStarts[b] + col]
        inc outIdx
  for e in 0 ..< ecLen:
    for b in 0 ..< numBlocks:
      result[outIdx] = parities[b][e]
      inc outIdx

# Module placement -----------------------------------------------------------

type
  PlacedGrid = object
    matrix: QrMatrix
    isFunction: seq[bool]

proc setModule(g: var PlacedGrid, x, y: int, dark: bool) {.inline.} =
  g.matrix[x, y] = dark
  g.isFunction[y * g.matrix.width + x] = true

proc reserve(g: var PlacedGrid, x, y: int) {.inline.} =
  ## Marks a module as function/reserved without altering its colour.
  g.isFunction[y * g.matrix.width + x] = true

proc drawFinder(g: var PlacedGrid, cx, cy: int) =
  for dy in -4 .. 4:
    for dx in -4 .. 4:
      let x = cx + dx
      let y = cy + dy
      if x >= 0 and x < g.matrix.width and y >= 0 and y < g.matrix.height:
        let dist = max(abs(dx), abs(dy))
        g.setModule(x, y, dist != 2 and dist != 4)

proc drawFunctionPatterns(g: var PlacedGrid, ver: int, ecl: QrEcLevel) =
  let size = ver * 4 + 17
  g.drawFinder(3, 3)
  g.drawFinder(size - 4, 3)
  g.drawFinder(3, size - 4)
  # timing patterns
  for i in 8 ..< size - 8:
    g.setModule(i, 6, i mod 2 == 0)
    g.setModule(6, i, i mod 2 == 0)
  # alignment patterns
  let pos = alignmentPositions(ver)
  for py in pos:
    for px in pos:
      let overlapsFinder =
        (px == 6 and py == 6) or (px == 6 and py == pos[^1]) or
        (px == pos[^1] and py == 6)
      if not overlapsFinder:
        for dy in -2 .. 2:
          for dx in -2 .. 2:
            g.setModule(px + dx, py + dy,
              max(abs(dx), abs(dy)) != 1)
  # reserve format info areas and the permanent dark module
  for i in 0 ..< 9:
    g.reserve(i, 8)
    g.reserve(8, i)
  for i in 0 ..< 8:
    g.reserve(size - 1 - i, 8)
    g.reserve(8, size - 1 - i)
  g.setModule(8, size - 8, true)
  # version information blocks
  if ver >= 7:
    var rem = ver
    for _ in 0 ..< 12:
      rem = (rem shl 1) xor ((rem shr 11) * 0x1F25)
    let bits = (ver shl 12) or rem
    for i in 0 ..< 18:
      let bit = ((bits shr i) and 1) == 1
      let a = size - 11 + i mod 3
      let b = i div 3
      g.setModule(a, b, bit)
      g.setModule(b, a, bit)

proc drawFormatBits(m: var QrMatrix, ecl: QrEcLevel, mask: int) =
  ## Writes both copies of the format information onto the final matrix.
  let size = m.width
  const formatBits: array[4, int] = [1, 0, 3, 2]  # L M Q H
  let data = (formatBits[ord(ecl)] shl 3) or mask
  var rem = data
  for _ in 0 ..< 10:
    rem = (rem shl 1) xor ((rem shr 9) * 0x537)
  let bits = ((data shl 10) or rem) xor 0x5412
  template bit(i: int): bool = ((bits shr i) and 1) == 1
  for i in 0 .. 5: m[8, i] = bit(i)
  m[8, 7] = bit(6)
  m[8, 8] = bit(7)
  m[7, 8] = bit(8)
  for i in 9 ..< 15: m[14 - i, 8] = bit(i)
  for i in 0 .. 7: m[size - 1 - i, 8] = bit(i)
  for i in 8 ..< 15: m[8, size - 15 + i] = bit(i)
  m[8, size - 8] = true

proc drawCodewords(g: var PlacedGrid, cw: openArray[byte]) =
  ## Zigzag placement of every codeword bit into non-function modules,
  ## two-module wide column pairs from right to left, alternately
  ## upwards and downwards, skipping the timing column.
  let size = g.matrix.width
  let totalBits = cw.len * 8
  var idx = 0
  var right = size - 1
  while right >= 1:
    let pairRight = if right <= 6: right - 1 else: right
    for vertical in 0 ..< size:
      for z in [0, 1]:
        let x = pairRight - z
        var upwards = (pairRight and 2) == 0
        if x < 6:
          upwards = not upwards
        let y = if upwards: size - 1 - vertical else: vertical
        if not g.isFunction[y * size + x]:
          if idx < totalBits:
            g.matrix[x, y] =
              ((cw[idx shr 3] shr (7 - (idx and 7))) and 1) == 1
          else:
            g.matrix[x, y] = false
          inc idx
    dec right, 2

func maskBit(mask, x, y: int): bool =
  case mask
  of 0: (y + x) mod 2 == 0
  of 1: y mod 2 == 0
  of 2: x mod 3 == 0
  of 3: (x + y) mod 3 == 0
  of 4: (y div 2 + x div 3) mod 2 == 0
  of 5: (x * y) mod 2 + (x * y) mod 3 == 0
  of 6: ((x * y) mod 2 + (x * y) mod 3) mod 2 == 0
  of 7: ((x + y) mod 2 + (x * y) mod 3) mod 2 == 0
  else: raise newException(QrError, "invalid mask " & $mask)

proc applyMaskToCopy(dst: var QrMatrix, src: QrMatrix,
                     isFunction: openArray[bool], mask: int) =
  dst.modules = src.modules
  let size = src.width
  for y in 0 ..< size:
    for x in 0 ..< size:
      if not isFunction[y * size + x] and maskBit(mask, x, y):
        dst[x, y] = not dst[x, y]

# Penalty scoring ------------------------------------------------------------

proc penaltyScore*(m: QrMatrix): int =
  ## Mask penalty score (N1-N4); shared by the Model 1 encoder.
  let size = m.width
  # N1: runs of five or more same-coloured modules per row and column
  for axis in 0 ..< 2:
    for i in 0 ..< size:
      var runColor = false
      var runLen = 0
      for j in 0 ..< size:
        let cell = if axis == 0: m[j, i] else: m[i, j]
        if j > 0 and cell != runColor:
          if runLen >= 5: result += 3 + runLen - 5
          runColor = cell
          runLen = 1
        else:
          inc runLen
      if runLen >= 5: result += 3 + runLen - 5
  # N2: 2x2 blocks of identical colour
  for y in 0 ..< size - 1:
    for x in 0 ..< size - 1:
      let c = m[x, y]
      if c == m[x + 1, y] and c == m[x, y + 1] and c == m[x + 1, y + 1]:
        result += 3
  # N3: finder-like 1011101 runs padded by four light modules
  const pattern1: uint32 = 0b00001011101'u32
  const pattern2: uint32 = 0b10111010000'u32
  for axis in 0 ..< 2:
    for i in 0 ..< size:
      var hist: uint32 = 0
      for j in 0 ..< size:
        let cell = if axis == 0: m[j, i] else: m[i, j]
        hist = ((hist shl 1) or uint32(ord(cell))) and 0x7FF'u32
        if j >= 10:
          if hist == pattern1 or hist == pattern2:
            result += 40
  # N4: deviation from a 50% dark proportion
  var dark = 0
  for v in m.modules:
    if v: inc dark
  let total = m.width * m.height
  let k = (abs(dark * 20 - total * 10) + total - 1) div total - 1
  result += k * 10

proc structuredAppendParity*(codewords: openArray[byte]): uint8 =
  ## Structured Append parity byte: XOR over the data codewords of the
  ## complete logical message (all symbols of the set combined).
  var acc: uint8
  for c in codewords:
    acc = acc xor c
  acc

# Top-level encoding ---------------------------------------------------------

proc encodeQrSegments*(segsInput: openArray[QrSegment],
                       options: QrEncodeOptions = defaultQrEncodeOptions()): QrMatrix =
  ## Builds the smallest permitted Model 2 symbol carrying `segsInput`.
  ## ECI and Structured Append headers are prepended when requested.
  if segsInput.len == 0:
    raise newException(QrError, "no segments to encode")
  var segs = @segsInput
  if options.eci != 0:
    segs.insert(makeEci(options.eci), 0)
  let saHeaderLen = if options.structuredAppend.enabled: 20 else: 0

  var chosenVer = -1
  for ver in options.minVersion .. options.maxVersion:
    var need = saHeaderLen
    for s in segs:
      need += 4 + (if s.mode == modeEci: 0 else: charCountBits(s.mode, ver)) +
        s.bits.bitLen
    if need <= numDataCodewords(ver, options.ecLevel) * 8:
      chosenVer = ver
      break
  if chosenVer < 0:
    raise newException(QrError, "data exceeds maximum capacity at level " &
      $options.ecLevel)

  var bb = initBitBuffer(numDataCodewords(chosenVer, options.ecLevel))
  if options.structuredAppend.enabled:
    bb.appendBits(ord(modeStructuredAppend), 4)
    bb.appendBits(options.structuredAppend.index, 4)
    bb.appendBits(options.structuredAppend.total, 4)
    bb.appendBits(options.structuredAppend.parity, 8)
  for s in segs:
    bb.appendBits(ord(s.mode), 4)
    if s.mode != modeEci:
      bb.appendBits(s.nchars, charCountBits(s.mode, chosenVer))
    bb.append(s.bits)

  let capBits = numDataCodewords(chosenVer, options.ecLevel) * 8
  let termLen = min(4, capBits - bb.bitLen)
  bb.appendBits(0'u32, termLen)
  let remBits = bb.bitLen mod 8
  if remBits != 0:
    bb.appendBits(0'u32, 8 - remBits)
  let pads = [0xEC'u8, 0x11'u8]
  var pi = 0
  while bb.bitLen < capBits:
    bb.appendByte(pads[pi mod 2])
    inc pi
  let payloadCw = bb.toSeq

  let fullCw = interleave(payloadCw, chosenVer, options.ecLevel)

  var grid = PlacedGrid(matrix: initSquareQrMatrix(chosenVer * 4 + 17),
                        isFunction: newSeq[bool](
                          (chosenVer * 4 + 17) * (chosenVer * 4 + 17)))
  drawFunctionPatterns(grid, chosenVer, options.ecLevel)
  drawCodewords(grid, fullCw)


  var bestMatrix = grid.matrix
  var bestPenalty = high(int)
  let masks =
    if options.mask >= 0: @[options.mask]
    else: @[0, 1, 2, 3, 4, 5, 6, 7]
  for mask in masks:
    var candidate = grid.matrix
    applyMaskToCopy(candidate, grid.matrix, grid.isFunction, mask)
    drawFormatBits(candidate, options.ecLevel, mask)
    let p = penaltyScore(candidate)
    if p < bestPenalty:
      bestPenalty = p
      bestMatrix = candidate
  result = bestMatrix

proc encodeQr*(text: string,
               options: QrEncodeOptions = defaultQrEncodeOptions()): QrMatrix =
  ## Encodes `text` with automatic segmentation (Kanji where beneficial).
  encodeQrSegments(toSegments(text), options)

proc encodeQrBytes*(data: openArray[byte],
                    options: QrEncodeOptions = defaultQrEncodeOptions()): QrMatrix =
  ## Encodes raw bytes as a single Byte-mode segment.
  encodeQrSegments([makeBytes(data)], options)

# Decoding -------------------------------------------------------------------

type
  QrDecodedSegment* = object
    ## One parsed segment of a decoded symbol.
    mode*: QrMode
    nchars*: int
    data*: seq[byte]
      ## Numeric: ASCII digits. Alphanumeric: raw alphabet indices packed
      ## one byte per character. Byte/Kanji: the original bytes (Shift-JIS
      ## for Kanji).

  QrDecodeResult* = object
    ## Outcome of decoding a Model 2 symbol.
    ok*: bool
    family*: QrFamily
    version*: int
    ecLevel*: QrEcLevel
    mask*: int
    eci*: int
      ## ECI assignment number when an ECI header was present, else -1.
    structuredAppend*: tuple[enabled: bool, index, total: int, parity: uint8]
    segments*: seq[QrDecodedSegment]
    text*: string
      ## UTF-8 rendering of the payload; Byte data is passed through as-is,
      ## Kanji data is converted from Shift-JIS via the built-in table.
    matrix*: QrMatrix

func reservedMap*(ver: int): seq[bool] =
  ## Function/reserved module map for `ver` in row-major order. Shared by
  ## the encoder placement and the decoder extraction.
  let size = ver * 4 + 17
  result = newSeq[bool](size * size)
  template mark(x, y: int) =
    result[y * size + x] = true
  # finders plus separators
  let corners = [(3, 3), (3, size - 4), (size - 4, 3)]
  for corner in corners:
    let (cx, cy) = corner
    for dy in -4 .. 4:
      for dx in -4 .. 4:
        let x = cx + dx
        let y = cy + dy
        if x >= 0 and x < size and y >= 0 and y < size:
          mark(x, y)
  # timing patterns
  for i in 8 ..< size - 8:
    mark(i, 6)
    mark(6, i)
  # alignment patterns
  let pos = alignmentPositions(ver)
  for pyi, py in pos:
    for pxi, px in pos:
      let overlapsFinder =
        (px == 6 and py == 6) or
        (px == 6 and py == pos[^1]) or
        (px == pos[^1] and py == 6)
      if not overlapsFinder:
        for dy in -2 .. 2:
          for dx in -2 .. 2:
            mark(px + dx, py + dy)
  # format information areas
  for i in 0 ..< 9:
    mark(i, 8)
    mark(8, i)
  for i in 0 ..< 8:
    mark(size - 1 - i, 8)
    mark(8, size - 1 - i)
  # version information blocks
  if ver >= 7:
    for i in 0 ..< 18:
      let a = size - 11 + i mod 3
      let b = i div 3
      mark(a, b)
      mark(b, a)

proc readFormatBits(m: QrMatrix): tuple[ecl: QrEcLevel, mask: int, valid: bool] =
  ## Reads both format copies and accepts the first that passes the BCH
  ## check; falls back to a per-bit vote across the two copies.
  let size = m.width
  var cells: array[15, array[2, bool]]
  for i in 0 .. 5: cells[i][0] = m[8, i]
  cells[6][0] = m[8, 7]
  cells[7][0] = m[8, 8]
  cells[8][0] = m[7, 8]
  for i in 9 ..< 15: cells[i][0] = m[14 - i, 8]
  for i in 0 .. 7: cells[i][1] = m[size - 1 - i, 8]
  for i in 8 ..< 15: cells[i][1] = m[8, size - 15 + i]

  proc assemble(copy: int): int =
    for i in 0 ..< 15:
      if cells[i][copy]:
        result = result or (1 shl i)

  proc parse(word: int): tuple[ecl: QrEcLevel, mask: int, valid: bool] =
    let raw = word xor 0x5412
    let data = raw shr 10
    var rem = data
    for _ in 0 ..< 10:
      rem = (rem shl 1) xor ((rem shr 9) * 0x537)
    if ((data shl 10) or rem) != raw:
      return (ecLow, 0, false)
    const levelOf: array[4, QrEcLevel] = [ecMedium, ecLow, ecHigh, ecQuartile]
    return (levelOf[(data shr 3) and 3], data and 7, true)

  let r0 = parse(assemble(0))
  if r0.valid: return r0
  let r1 = parse(assemble(1))
  if r1.valid: return r1
  # voted fallback
  var word = 0
  for i in 0 ..< 15:
    if ord(cells[i][0]) + ord(cells[i][1]) >= 1:
      word = word or (1 shl i)
  result = parse(word)

proc readVersionInfo(m: QrMatrix): int =
  ## Recovers the version number from the two 3x6 blocks; -1 on failure.
  let size = m.width
  var word = 0
  for i in 0 ..< 18:
    let bitA = m[size - 11 + i mod 3, i div 3]
    let bitB = m[i div 3, size - 11 + i mod 3]
    if bitA and bitB:
      word = word or (1 shl i)
  let data = word shr 12
  var rem = data
  for _ in 0 ..< 12:
    rem = (rem shl 1) xor ((rem shr 11) * 0x1F25)
  if ((data shl 12) or rem) != word:
    return -1
  if data < 7 or data > 40:
    return -1
  data

proc extractCodewords*(m: QrMatrix, ver: int, mask: int): seq[uint8] =
  ## Walks the zigzag, unmasks on the fly and returns the interleaved
  ## codeword stream.
  let size = m.width
  let isFunc = reservedMap(ver)
  let totalModules = numRawDataModules(ver)
  var bb = initBitBuffer(totalModules div 8 + 1)
  var right = size - 1
  while right >= 1:
    let pairRight = if right <= 6: right - 1 else: right
    for vertical in 0 ..< size:
      for z in [0, 1]:
        let x = pairRight - z
        var upwards = (pairRight and 2) == 0
        if x < 6:
          upwards = not upwards
        let y = if upwards: size - 1 - vertical else: vertical
        if not isFunc[y * size + x]:
          var dark = m[x, y]
          if maskBit(mask, x, y):
            dark = not dark
          bb.appendBit(dark)
    dec right, 2
  result = bb.toSeq

proc deinterleave*(cw: openArray[uint8], ver: int,
                  ecl: QrEcLevel): seq[uint8] {.raises: [QrError].} =
  ## Undoes the column-wise interleaving of data and parity across RS
  ## blocks (shorter blocks first), corrects each block with Reed-Solomon
  ## and returns the concatenated data codewords.
  let numBlocks = ecNumBlocks[ord(ecl)][ver]
  let ecLen = ecCwPerBlock[ord(ecl)][ver]
  let dataTotal = numDataCodewords(ver, ecl)
  let shortLen = dataTotal div numBlocks
  let numLong = dataTotal mod numBlocks
  var dataLens = newSeq[int](numBlocks)
  for b in 0 ..< numBlocks:
    dataLens[b] = shortLen + (if b >= numBlocks - numLong: 1 else: 0)
  var blocks = newSeq[seq[uint8]](numBlocks)
  for b in 0 ..< numBlocks:
    blocks[b] = newSeq[uint8](dataLens[b] + ecLen)
  var pos = 0
  # undo data interleave
  for col in 0 ..< shortLen + 1:
    for b in 0 ..< numBlocks:
      if col < dataLens[b]:
        blocks[b][col] = cw[pos]
        inc pos
  # undo parity interleave
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

# Reverse Shift-JIS lookup ----------------------------------------------------

var sjisReverse: Table[int, Rune]

proc reverseSjisInit() =
  if sjisReverse.len > 0: return
  for i in 0 ..< jisTableHex.len div 8:
    let cp = parseHexInt(jisTableHex[i * 8 ..< i * 8 + 4])
    let sj = parseHexInt(jisTableHex[i * 8 + 4 ..< i * 8 + 8])
    sjisReverse[sj] = Rune(cp)

proc runeFromSjis*(sj: int): Rune =
  reverseSjisInit()
  if sjisReverse.hasKey(sj): sjisReverse[sj]
  else: Rune(0xFFFD)

# Segment parsing -------------------------------------------------------------

proc alnumChar(v: int): char {.inline.} = alnumCharset[v]

proc parseSegments*(data: openArray[uint8], ver: int,
                    res: var QrDecodeResult) {.raises: [QrError, ValueError].} =
  ## Walks the segment headers and payloads of the corrected data region.
  var bb = initBitBuffer(64)
  bb.appendBytes(data)
  var idx = 0
  template take(count: int): int =
    var v = 0
    for b in 0 ..< count:
      if idx >= bb.bitLen:
        raise newException(QrError, "segment stream truncated")
      v = (v shl 1) or (if bb.bitAt(idx): 1 else: 0)
      inc idx
    v
  while idx + 4 <= bb.bitLen:
    let modeInt = take(4)
    if modeInt == ord(modeTerminator):
      break
    let segMode: QrMode =
      case modeInt
      of ord(modeNumeric): modeNumeric
      of ord(modeAlphanumeric): modeAlphanumeric
      of ord(modeStructuredAppend): modeStructuredAppend
      of ord(modeByte): modeByte
      of ord(modeFnc1First): modeFnc1First
      of ord(modeEci): modeEci
      of ord(modeKanji): modeKanji
      else: modeFnc1Second
    case segMode
    of modeEci:
      let first = take(1)
      var eciVal = 0
      if first == 0:
        eciVal = take(7)
      else:
        let second = take(1)
        if second == 0:
          eciVal = take(14)
        else:
          eciVal = take(21)
      res.eci = eciVal
    of modeStructuredAppend:
      res.structuredAppend.index = take(4)
      res.structuredAppend.total = take(4)
      res.structuredAppend.parity = uint8(take(8))
      res.structuredAppend.enabled = true
    of modeFnc1First, modeFnc1Second:
      discard
    of modeNumeric, modeAlphanumeric, modeByte, modeKanji:
      let ccBits = charCountBits(segMode, ver)
      let n = take(ccBits)
      var payload = initBitBuffer(n * 2 + 16)
      case segMode
      of modeNumeric:
        var consumed = 0
        while consumed + 3 <= n:
          let v = take(10)
          payload.appendByte(uint8(ord('0') + v div 100))
          payload.appendByte(uint8(ord('0') + (v div 10) mod 10))
          payload.appendByte(uint8(ord('0') + v mod 10))
          inc consumed, 3
        if n - consumed == 2:
          let v = take(7)
          payload.appendByte(uint8(ord('0') + v div 10))
          payload.appendByte(uint8(ord('0') + v mod 10))
          inc consumed
        elif n - consumed == 1:
          let v = take(4)
          payload.appendByte(uint8(ord('0') + v))
          inc consumed
        res.segments.add QrDecodedSegment(mode: segMode, nchars: n,
          data: payload.toSeq)
      of modeAlphanumeric:
        var consumed = 0
        while consumed + 2 <= n:
          let v = take(11)
          payload.appendByte(byte(alnumChar(v div 45)))
          payload.appendByte(byte(alnumChar(v mod 45)))
          inc consumed, 2
        if n - consumed == 1:
          let v = take(6)
          payload.appendByte(byte(alnumChar(v)))
          inc consumed
        res.segments.add QrDecodedSegment(mode: segMode, nchars: n,
          data: payload.toSeq)
      of modeByte:
        for _ in 0 ..< n:
          payload.appendByte(uint8(take(8)))
        res.segments.add QrDecodedSegment(mode: segMode, nchars: n,
          data: payload.toSeq)
      of modeKanji:
        var sj: seq[byte]
        for _ in 0 ..< n:
          let v = take(13)
          let high = v div 0xC0
          let low = v mod 0xC0
          var sVal = (high shl 8) or low
          if sVal + 0x8140 <= 0x9FFC:
            inc sVal, 0x8140
          elif sVal + 0xC140 <= 0xEBBF:
            inc sVal, 0xC140
          else:
            continue
          sj.add byte(sVal shr 8)
          sj.add byte(sVal and 0xFF)
        res.segments.add QrDecodedSegment(mode: segMode, nchars: n,
          data: sj)
      else:
        discard
    else:
      raise newException(QrError, "unknown segment mode " & $modeInt)
  # assemble text from every payload segment
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

proc decodeQrMatrix*(m: QrMatrix): QrDecodeResult =
  ## Decodes a clean module grid produced by `encodeQr*`, `sampleSymbol`
  ## or any external binarizer.
  result.eci = -1
  result.matrix = m
  result.family = famModel2
  if m.width != m.height:
    result.ok = false
    return
  let verGuess = (m.width - 17) div 4
  if verGuess < 1 or verGuess > 40 or verGuess * 4 + 17 != m.width:
    result.ok = false
    return
  let fmt = readFormatBits(m)
  if not fmt.valid:
    return
  result.ecLevel = fmt.ecl
  result.mask = fmt.mask
  var ver = (m.width - 17) div 4
  if ver >= 7:
    let vInfo = readVersionInfo(m)
    if vInfo != ver:
      return
  result.version = ver
  let cw = extractCodewords(m, ver, fmt.mask)
  try:
    let data = deinterleave(cw, ver, fmt.ecl)
    parseSegments(data, ver, result)
    result.ok = true
  except QrError, ValueError:
    result.ok = false


proc locateGrid*(img: GrayImage): QrDecodeResult =
  ## Locates the three finder patterns inside a grayscale image, fits an
  ## affine map from the finder centres and samples the module grid.
  ## Candidate triangles are trialled against the decoder itself, so a
  ## spurious detection never wins over a symbol that actually decodes.
  result.eci = -1
  let bw = binarizeAdaptive(img)
  var cands = dedupe(horizontalCandidates(bw))
    .mapIt(verticalVerify(bw, it))
    .filterIt(it.moduleSize > 0.0)
  cands = dedupe(cands)
  if cands.len < 3:
    return

  # keep the largest pitch cluster: real finders share one module size
  cands.sort(proc(a, b: FinderCandidate): int =
    cmp(b.moduleSize, a.moduleSize))
  var bestCluster: seq[FinderCandidate] = @[]
  var i = 0
  while i < cands.len:
    var j = i
    while j + 1 < cands.len and
          cands[j + 1].moduleSize > cands[i].moduleSize * 0.72:
      inc j
    if j - i + 1 > bestCluster.len:
      bestCluster = cands[i .. j]
    i = j + 1
  cands = bestCluster
  if cands.len < 3:
    return

  # enumerate triples by descending area and keep the ones that decode
  type Triple = array[3, FinderCandidate]
  var triples: seq[tuple[area: float64, t: Triple]] = @[]
  for a in 0 ..< cands.len:
    for b in a + 1 ..< cands.len:
      for c in b + 1 ..< cands.len:
        let p1 = cands[a].center
        let p2 = cands[b].center
        let p3 = cands[c].center
        let area = abs((p2.x - p1.x) * (p3.y - p1.y) -
                       (p2.y - p1.y) * (p3.x - p1.x))
        triples.add (area, [cands[a], cands[b], cands[c]])
  triples.sort(proc(x, y: tuple[area: float64, t: Triple]): int =
    cmp(y.area, x.area))

  func dist2(p, q: Point2): float =
    (p.x - q.x) * (p.x - q.x) + (p.y - q.y) * (p.y - q.y)

  for entry in triples:
    let trio = entry.t
    # orient: the corner opposite the longest side is top-left
    let d01 = dist2(trio[0].center, trio[1].center)
    let d02 = dist2(trio[0].center, trio[2].center)
    let d12 = dist2(trio[1].center, trio[2].center)
    let dmax = max(d01, max(d02, d12))
    var tlIdx = 0
    if dmax == d01: tlIdx = 2
    elif dmax == d02: tlIdx = 1
    else: tlIdx = 0
    let others = [0, 1, 2].filterIt(it != tlIdx)
    let topLeft = trio[tlIdx].center
    let pA = trio[others[0]].center
    let pB = trio[others[1]].center
    let cross = (pA.x - topLeft.x) * (pB.y - topLeft.y) -
                (pA.y - topLeft.y) * (pB.x - topLeft.x)
    var topRight, bottomLeft: Point2
    if cross > 0:
      topRight = pA; bottomLeft = pB
    else:
      topRight = pB; bottomLeft = pA

    let ms = (trio[tlIdx].moduleSize + trio[others[0]].moduleSize +
              trio[others[1]].moduleSize) / 3.0
    if ms <= 0: continue
    let spanX = sqrt(dist2(topLeft, topRight)) / ms + 7.0
    let spanY = sqrt(dist2(topLeft, bottomLeft)) / ms + 7.0
    # pitch estimates wobble with binarization edge loss, so trial the
    # neighbouring integer dimensions and let the decoder adjudicate
    var sizes: seq[int] = @[]
    for cand in [round(spanX).int, round(spanX).int - 1,
                 round(spanX).int + 1]:
      if cand notin sizes and cand >= 21 and cand <= 177:
        sizes.add cand
    let affBase = (topLeft, topRight, bottomLeft)
    for size in sizes:
      let aff = affineFromFinders(affBase[0], affBase[1], affBase[2], size)
      let threshold = otsuThreshold(img).float + 10.0
      let sampled = sampleSymbol(img, aff, size, threshold)
      let attempt = decodeQrMatrix(sampled)
      if attempt.ok:
        return attempt

proc decodeQrImage*(img: GrayImage): QrDecodeResult =
  ## Locates and decodes a Model 2 symbol inside a grayscale image.
  ## Handles rotation and uniform scale through the affine finder fit;
  ## strong perspective distortion is not compensated.
  locateGrid(img)
