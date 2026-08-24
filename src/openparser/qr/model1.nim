# A collection of tiny parsers and dumpers
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/openparser

## QR Code Model 1 (ISO/IEC 18004:2000 annex M) encoder and decoder.
##
## The original 1994 symbology: versions 1-14, all four error correction
## levels, codewords placed as 2x4 module blocks, solid timing bars along
## the right and bottom edge midsections and no alignment patterns.
## Model 1 is a closed-system legacy format; Model 2 supersedes it.
##
## Unstable API. Prefer importing `openparser/qr` instead of this module.

import ./common, ./galois, ./model2

const formatInfoMaskModel1 = 0x2825
  ## BCH XOR constant distinguishing Model 1 format words.

const model1Ec: array[14, array[4, tuple[ecCw, blocks, dataCw: int]]] = [
  [(7, 1, 19), (10, 1, 16), (13, 1, 13), (17, 1, 9)],
  [(10, 1, 36), (16, 1, 30), (22, 1, 24), (30, 1, 16)],
  [(15, 1, 57), (28, 1, 44), (36, 1, 36), (48, 1, 24)],
  [(20, 1, 80), (40, 1, 60), (50, 1, 50), (66, 1, 34)],
  [(26, 1, 108), (52, 1, 82), (66, 1, 68), (44, 2, 23)],
  [(34, 1, 136), (32, 2, 53), (42, 2, 43), (56, 2, 29)],
  [(42, 1, 170), (40, 2, 66), (52, 2, 54), (46, 3, 24)],
  [(24, 2, 104), (48, 2, 80), (64, 2, 64), (56, 3, 29)],
  [(30, 2, 123), (60, 2, 93), (50, 3, 52), (68, 3, 34)],
  [(34, 2, 145), (68, 2, 111), (58, 3, 61), (58, 4, 31)],
  [(40, 2, 168), (40, 4, 64), (52, 4, 52), (54, 5, 29)],
  [(46, 2, 192), (46, 4, 73), (58, 4, 61), (62, 5, 33)],
  [(36, 3, 144), (52, 4, 83), (66, 4, 69), (58, 6, 32)],
  [(40, 3, 163), (60, 4, 92), (60, 5, 62), (66, 6, 35)]]

proc model1Size*(ver: int): int {.inline.} = ver * 4 + 17

proc model1TotalCw*(ver: int): int =
  ## Total codeword capacity; identical across levels for one version.
  let lvl = model1Ec[ver - 1][0]
  result = (lvl.dataCw + lvl.ecCw) * lvl.blocks

proc model1DataCw*(ver: int, ec: QrEcLevel): int =
  let lvl = model1Ec[ver - 1][ord(ec)]
  result = lvl.dataCw * lvl.blocks

proc model1EcCw*(ver: int, ec: QrEcLevel): int {.inline.} =
  model1Ec[ver - 1][ord(ec)].ecCw

proc model1Blocks(ver: int, ec: QrEcLevel): int {.inline.} =
  model1Ec[ver - 1][ord(ec)].blocks

proc model1LayoutOk*(ver: int, ec: QrEcLevel): bool =
  ## True when the published block layout is consistent with the physical
  ## codeword capacity of the grid. A handful of high version and level
  ## combinations in the surviving references are not, and are refused.
  let dt = model1DataCw(ver, ec)
  result = dt + model1Blocks(ver, ec) * model1EcCw(ver, ec) ==
    model1TotalCw(ver)

func cciBits(mode: QrMode, ver: int): int =
  case mode
  of modeNumeric: (if ver < 10: 10 elif ver < 27: 12 else: 14)
  of modeAlphanumeric: (if ver < 10: 9 elif ver < 27: 11 else: 13)
  of modeByte: (if ver < 10: 8 else: 16)
  of modeKanji: (if ver < 10: 8 elif ver < 27: 10 else: 12)
  else: 0

func model1MaskBit(mask, x, y: int): bool {.inline.} =
  ## The eight data mask formulas shared with Model 2.
  let p = x * y
  case mask
  of 0: (x + y) mod 2 == 0
  of 1: y mod 2 == 0
  of 2: x mod 3 == 0
  of 3: (x + y) mod 3 == 0
  of 4: ((y div 2) + (x div 3)) mod 2 == 0
  of 5: p mod 6 == 0
  of 6: (p mod 6) < 3
  else: ((x + y) mod 2 + p mod 3) mod 2 == 0

proc bchFormatWord(data: int, maskConst: int): int =
  ## Five data bits encoded with the format BCH generator and XOR mask.
  var value = data shl 10
  for i in countdown(14, 10):
    if (value shr i and 1) != 0:
      value = value xor (0x537 shl (i - 10))
  result = ((data shl 10) or (value and 0x3FF)) xor maskConst

iterator codewordBlocks(dim: int): tuple[x, y: int, horizontal: bool] =
  ## Origin of every codeword block in reference decode order: two
  ## vertical strips on the right, the horizontal middle field, then the
  ## vertical strips on the left.
  let columns = dim div 4 + 1 + 2
  for j in 0 ..< columns:
    if j <= 1:
      let rows = (dim - 8) div 4
      for i in 0 ..< rows:
        if j == 0 and i mod 2 == 0 and i > 0 and i < rows - 1:
          continue
        yield (dim - 1 - j * 2, dim - 1 - i * 4, false)
    elif columns - j <= 4:
      let rows = (dim - 16) div 4
      for i in 0 ..< rows:
        let x = (columns - j - 1) * 2 + 1 + (if columns - j == 4: 1 else: 0)
        yield (x, dim - 1 - 8 - i * 4, false)
    else:
      let rows = dim div 2
      for i in 0 ..< rows:
        if j == 2 and i >= rows - 4:
          continue
        if i == 0 and j mod 2 == 1 and j + 1 != columns - 4:
          continue
        let x = dim - 1 - 4 - (j - 2) * 4
        let y = dim - 1 - i * 2 - (if i >= rows - 3: 1 else: 0)
        yield (x, y, true)

proc countCodewordBlocks*(ver: int): int =
  for _ in codewordBlocks(model1Size(ver)):
    inc result

proc drawModel1FunctionPatterns(g: var QrMatrix, reserved: var seq[bool]) =
  ## Finders with separators, cross timing, format reservations, dark
  ## module and the solid edge bars unique to Model 1.
  let n = g.width
  template mark(x, y: int) = reserved[y * n + x] = true
  template setCell(x, y: int, dark: bool) =
    g.modules[y * n + x] = dark
    mark(x, y)
  # finders top left, top right, bottom left plus separators
  const finderRows = [0b1111111'u8, 0b1000001, 0b1011101, 0b1011101,
                      0b1011101, 0b1000001, 0b1111111]
  for cx in [0, n - 7]:
    for dy in 0 ..< 7:
      for dx in 0 ..< 7:
        setCell(dx + cx, dy,
          ((finderRows[dy] shr (6 - dx)) and 1) == 1)
  for dy in 0 ..< 7:
    for dx in 0 ..< 7:
      setCell(dx, dy + n - 7,
        ((finderRows[dy] shr (6 - dx)) and 1) == 1)
  for i in 0 ..< 8:
    mark(i, 7); mark(7, i)
    mark(n - 8, i); mark(n - 1 - i, 7)
    mark(i, n - 8); mark(7, n - 1 - i)
  # cross timing
  for i in 8 ..< n - 8:
    setCell(i, 6, i mod 2 == 0)
    setCell(6, i, i mod 2 == 0)
  # format reservations and dark module
  for i in 0 ..< 9:
    mark(8, i); mark(i, 8)
    mark(8, n - 1 - i); mark(n - 1 - i, 8)
  setCell(8, n - 8, true)
  # Model 1 only: extension marks along the right and bottom edge
  # midsections - the outer half of each skipped block is solid dark,
  # the inner half solid light
  let rowsRight = (n - 8) div 4
  var ri = 2
  while ri < rowsRight - 1:
    let y = n - 1 - ri * 4
    for dy in 0 ..< 4:
      setCell(n - 1, y - dy, true)
      setCell(n - 2, y - dy, false)
    inc ri, 2
  let columns = n div 4 + 1 + 2
  var hj = 3
  while hj <= columns - 5:
    if hj mod 2 == 1 and hj + 1 != columns - 4:
      let x = n - 1 - 4 - (hj - 2) * 4
      for dx in 0 ..< 4:
        setCell(x - dx, n - 1, true)
        setCell(x - dx, n - 2, false)
    inc hj
  # fixed dark module in the extreme bottom right corner
  setCell(n - 1, n - 1, true)

proc writeModel1FormatInfo(g: var QrMatrix, word: int) =
  ## Two copies around the top left and opposing edges; geometry matches
  ## Model 2 including the skips over the timing patterns.
  let n = g.width
  template bit(i: int): bool = ((word shr i) and 1) == 1
  # first copy: down column 8 then across row 8
  for i in 0 .. 5:
    g.modules[i * n + 8] = bit(i)
  g.modules[7 * n + 8] = bit(6)
  g.modules[8 * n + 8] = bit(7)
  g.modules[8 * n + 7] = bit(8)
  for i in 9 ..< 15:
    g.modules[8 * n + (14 - i)] = bit(i)
  # second copy: across row 8 from the right edge then up column 8
  for i in 0 .. 7:
    g.modules[8 * n + (n - 1 - i)] = bit(i)
  for i in 8 ..< 15:
    g.modules[(n - 15 + i) * n + 8] = bit(i)

# Encoding --------------------------------------------------------------------

proc encodeModel1Matrix*(segments: seq[QrSegment], ver: int, ec: QrEcLevel,
                         mask = -1): QrMatrix {.raises: [QrError].} =
  ## Renders a Model 1 symbol from explicit segments.
  if ver < 1 or ver > 12:
    raise newException(QrError, "Model 1 version out of range (1 .. 12)")
  if not model1LayoutOk(ver, ec):
    raise newException(QrError,
      "no consistent codeword layout for Model 1 version " & $ver)
  let capBits = model1DataCw(ver, ec) * 8 - 4
  var bb = initBitBuffer(capBits div 8 + 8)
  var needed = 0
  for s in segments:
    inc needed, 4 + cciBits(s.mode, ver) + s.bits.bitLen
  if needed > capBits:
    raise newException(QrError,
      "data does not fit into Model 1 version " & $ver)
  for s in segments:
    bb.appendBits(ord(s.mode), 4)
    bb.appendBits(s.nchars, cciBits(s.mode, ver))
    bb.append(s.bits)
  var length = bb.bitLen
  let term = min(capBits - length, 4)
  bb.appendBits(0, term)
  inc length, term
  # pad towards the codeword slot grid, which sits four bits into the
  # stream because the corner slot only carries a nibble, then fill the
  # remaining whole slots with the alternating pad bytes
  while (length - 4) mod 8 != 0 and length < capBits:
    bb.appendBits(0, 1)
    inc length
  while capBits - length >= 8:
    bb.appendBytes([byte 0xEC])
    inc length, 8
    if capBits - length >= 8:
      bb.appendBytes([byte 0x11])
      inc length, 8

  # split payload over RS blocks back to back; the very first byte only
  # carries four payload bits because its upper half sits under the
  # corner timing bar
  let numBlocks = model1Blocks(ver, ec)
  let dataTotal = model1DataCw(ver, ec)
  let ecLen = model1EcCw(ver, ec)
  let shortLen = dataTotal div numBlocks
  let numLong = dataTotal mod numBlocks
  var dataBlocks = newSeq[seq[uint8]](numBlocks)
  var pos = 0
  for b in 0 ..< numBlocks:
    let len = shortLen + (if b >= numBlocks - numLong: 1 else: 0)
    var blk = newSeq[uint8](len)
    for i in 0 ..< len:
      var v = 0
      if b == 0 and i == 0:
        for _ in 0 ..< 4:
          v = (v shl 1) or (if pos < length and bb.bitAt(pos): 1 else: 0)
          if pos < length: inc pos
        blk[i] = uint8(v)
      else:
        for _ in 0 ..< 8:
          if pos < length:
            v = (v shl 1) or (if bb.bitAt(pos): 1 else: 0)
            inc pos
          else:
            v = v shl 1
        blk[i] = uint8(v)
    dataBlocks[b] = blk

  var fullCw: seq[uint8] = @[]
  var parities = newSeq[seq[uint8]](numBlocks)
  for b in 0 ..< numBlocks:
    parities[b] = rsEncodeParity(dataBlocks[b], ecLen)
  for b in 0 ..< numBlocks:
    fullCw.add dataBlocks[b]
  for b in 0 ..< numBlocks:
    fullCw.add parities[b]

  let dim = model1Size(ver)
  result = initSquareQrMatrix(dim)
  var reserved = newSeq[bool](dim * dim)
  drawModel1FunctionPatterns(result, reserved)

  # pick the mask with the lowest penalty unless one is pinned
  var chosen = mask
  if chosen < 0 or chosen > 7:
    var bestScore = high(int)
    var trial = initSquareQrMatrix(dim)
    for cand in 0 ..< 8:
      trial.modules = result.modules
      var idx = 0
      var first = true
      for bp in codewordBlocks(dim):
        let byteVal = fullCw[idx]
        if first:
          for b in 4 ..< 8:
            let bx = bp.x - (b mod 2)
            let by = bp.y - (b div 2)
            trial.modules[by * dim + bx] =
              (((byteVal shr (7 - b)) and 1) == 1) xor model1MaskBit(cand, bx, by)
          first = false
        else:
          for b in 0 ..< 8:
            let bx = (if bp.horizontal: bp.x - b mod 4 else: bp.x - b mod 2)
            let by = (if bp.horizontal: bp.y - b div 4 else: bp.y - b div 2)
            trial.modules[by * dim + bx] =
              (((byteVal shr (7 - b)) and 1) == 1) xor model1MaskBit(cand, bx, by)
        inc idx
      let score = penaltyScore(trial)
      if score < bestScore:
        bestScore = score
        chosen = cand

  var idx = 0
  var first = true
  for bp in codewordBlocks(dim):
    let byteVal = fullCw[idx]
    if first:
      for b in 4 ..< 8:
        let bx = bp.x - (b mod 2)
        let by = bp.y - (b div 2)
        result.modules[by * dim + bx] =
          (((byteVal shr (7 - b)) and 1) == 1) xor model1MaskBit(chosen, bx, by)
      first = false
    else:
      for b in 0 ..< 8:
        let bx = (if bp.horizontal: bp.x - b mod 4 else: bp.x - b mod 2)
        let by = (if bp.horizontal: bp.y - b div 4 else: bp.y - b div 2)
        result.modules[by * dim + bx] =
          (((byteVal shr (7 - b)) and 1) == 1) xor model1MaskBit(chosen, bx, by)
    inc idx
  doAssert idx == model1TotalCw(ver)

  let fmtData = case ec
    of ecLow: 0b001
    of ecMedium: 0b000
    of ecQuartile: 0b011
    of ecHigh: 0b010
  writeModel1FormatInfo(result,
    bchFormatWord((fmtData shl 3) or chosen, formatInfoMaskModel1))

proc encodeModel1*(text: string, ec = ecMedium, version = 0,
                   mask = -1): QrMatrix {.raises: [QrError, ValueError].} =
  ## Encodes `text` as a Model 1 symbol; version 0 picks the smallest
  ## fitting size.
  let segs = toSegments(text)
  proc neededBits(ver: int): int =
    for s in segs:
      inc result, 4 + cciBits(s.mode, ver) + s.bits.bitLen
  var ver = version
  if ver != 0 and (ver < 1 or ver > 12):
    raise newException(QrError, "Model 1 version out of range (1 .. 12)")
  if ver == 0:
    for candidate in 1 .. 12:
      if model1LayoutOk(candidate, ec) and
          neededBits(candidate) <= model1DataCw(candidate, ec) * 8 - 4:
        ver = candidate
        break
    if ver == 0:
      raise newException(QrError, "payload too large for any Model 1 version")
  elif neededBits(ver) > model1DataCw(ver, ec) * 8 - 4:
    raise newException(QrError,
      "payload does not fit into Model 1 version " & $ver)
  result = encodeModel1Matrix(segs, ver, ec, mask)

# Decoding --------------------------------------------------------------------

proc readModel1Format(m: QrMatrix): tuple[ec: QrEcLevel, mask: int,
                                          valid: bool] =
  ## Reads both format copies and matches against the valid Model 1
  ## words, tolerating a few flipped modules.
  let n = m.width
  var cBits = 0
  var rBits = 0
  # first copy: column 8 down then row 8 leftwards
  for i in 0 .. 5:
    if m.modules[i * n + 8]: cBits = cBits or (1 shl i)
  if m.modules[7 * n + 8]: cBits = cBits or (1 shl 6)
  if m.modules[8 * n + 8]: cBits = cBits or (1 shl 7)
  if m.modules[8 * n + 7]: cBits = cBits or (1 shl 8)
  for i in 9 ..< 15:
    if m.modules[8 * n + (14 - i)]: cBits = cBits or (1 shl i)
  # second copy: row 8 from the right edge then column 8 upwards
  for i in 0 .. 7:
    if m.modules[8 * n + (n - 1 - i)]: rBits = rBits or (1 shl i)
  for i in 8 ..< 15:
    if m.modules[(n - 15 + i) * n + 8]: rBits = rBits or (1 shl i)
  func popcount(v: int): int =
    var x = v
    while x != 0:
      x = x and (x - 1)
      inc result
  var best = 15
  var bestData = -1
  for candidate in [cBits, rBits]:
    for data in 0 ..< 32:
      let dist = popcount(candidate xor bchFormatWord(data,
                                                      formatInfoMaskModel1))
      if dist < best:
        best = dist
        bestData = data
  if bestData < 0 or best > 3:
    result.valid = false
    return
  case (bestData shr 3) and 3
  of 0: result.ec = ecMedium
  of 1: result.ec = ecLow
  of 2: result.ec = ecHigh
  else: result.ec = ecQuartile
  result.mask = bestData and 7
  result.valid = true

proc extractModel1Codewords*(m: QrMatrix, mask: int): seq[uint8] =
  ## Walks every codeword block applying the inverse mask. The corner
  ## block's upper four modules carry only the first byte's low nibble;
  ## the lower half belongs to the edge bar and reads as zero.
  let dim = m.width
  result = @[]
  var first = true
  for bp in codewordBlocks(dim):
    var currentByte: uint8 = 0
    let lo = if first: 4 else: 0
    for b in lo ..< 8:
      let bx = (if bp.horizontal: bp.x - b mod 4 else: bp.x - b mod 2)
      let by = (if bp.horizontal: bp.y - b div 4 else: bp.y - b div 2)
      let raw = m.modules[by * dim + bx]
      let bit = (if model1MaskBit(mask, bx, by): not raw else: raw)
      currentByte = (currentByte shl 1) or (if bit: 1'u8 else: 0'u8)
    if first:
      currentByte = currentByte and 0x0F
      first = false
    result.add currentByte

proc decodeModel1Matrix*(m: QrMatrix): QrDecodeResult =
  ## Decodes a Model 1 symbol grid of side 21 to 73 (step 4).
  result.eci = -1
  result.matrix = m
  result.family = famModel1
  let dim = m.width
  if m.width != m.height or dim < 21 or dim > 73 or (dim - 17) mod 4 != 0:
    result.ok = false
    return
  let ver = (dim - 17) div 4
  let fmt = readModel1Format(m)
  if not fmt.valid:
    result.ok = false
    return
  result.version = ver
  result.ecLevel = fmt.ec
  result.mask = fmt.mask
  try:
    let cw = extractModel1Codewords(m, fmt.mask)
    if cw.len != model1TotalCw(ver):
      result.ok = false
      return
    let numBlocks = model1Blocks(ver, fmt.ec)
    let dataTotal = model1DataCw(ver, fmt.ec)
    let ecLen = model1EcCw(ver, fmt.ec)
    let shortLen = dataTotal div numBlocks
    let numLong = dataTotal mod numBlocks
    var dataLens = newSeq[int](numBlocks)
    for b in 0 ..< numBlocks:
      dataLens[b] = shortLen + (if b >= numBlocks - numLong: 1 else: 0)
    # undo the back-to-back concatenation and RS-correct each block
    let ecBase = dataTotal
    var corrected = newSeq[uint8](dataTotal)
    var pos = 0
    for b in 0 ..< numBlocks:
      var blk = newSeq[uint8](dataLens[b] + ecLen)
      for i in 0 ..< dataLens[b]:
        blk[i] = cw[pos + i]
      for e in 0 ..< ecLen:
        blk[dataLens[b] + e] = cw[ecBase + b * ecLen + e]
      rsDecode(blk, ecLen)
      for i in 0 ..< dataLens[b]:
        corrected[pos + i] = blk[i]
      inc pos, dataLens[b]
    # the first codeword contributes only its low nibble to the logical
    # bit stream, so shift the whole data section left by four bits
    var data = newSeq[uint8](dataTotal)
    var acc = 0
    var accLen = 0
    var outIdx = 0
    for i in 0 ..< dataTotal:
      if i == 0:
        acc = (acc shl 4) or (corrected[0].int and 0x0F)
        inc accLen, 4
      else:
        acc = (acc shl 8) or corrected[i].int
        inc accLen, 8
      while accLen >= 8 and outIdx < dataTotal:
        dec accLen, 8
        data[outIdx] = uint8((acc shr accLen) and 0xFF)
        inc outIdx
    parseSegments(data, ver, result)
    result.ok = true
  except QrError, ValueError:
    result.ok = false
