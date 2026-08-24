# A collection of tiny parsers and dumpers
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/openparser

## Experimental AQR style symbols: an ordinary Model 2 core surrounded by
## a square ring of marks which carries a second, independent payload.
##
## The ring layout below is a documented openparser profile inspired by
## Zappar's Active/Ambiguous QR codes; their exact format is proprietary
## so treat this as an interoperable best effort rather than a clone.
##
## Ring encoding: a two module wide band runs two modules outside the
## core symbol. Its centre line is divided into single module slots,
## read clockwise starting just right of the band's top left corner. The
## first eight slots hold the frame length in bytes (big endian, payload
## plus CRC), followed by the payload bytes MSB first and a CRC-8 over
## the payload for validation; unused slots stay light. Decoding tries
## every plausible core size until the CRC validates.
##
## Unstable API. Prefer importing `openparser/qr` instead of this module.

import ./common, ./model2

const aqrGap = 2
  ## Distance from the core edge to the ring centre line.

proc crc8(data: openArray[byte]): uint8 =
  ## CRC-8/ATM used to validate recovered ring payloads.
  const poly = 0x07'u8
  for b in data:
    result = result xor uint8(b)
    for _ in 0 ..< 8:
      if (result and 0x80'u8) != 0:
        result = (result shl 1) xor poly
      else:
        result = result shl 1

proc aqrOuterSize*(coreSize: int): int {.inline.} =
  ## Total side length of an AQR symbol whose core has `coreSize` modules.
  coreSize + 2 * (aqrGap + 1)

func coreOffset(outer, coreSize: int): int {.inline.} =
  outer div 2 - coreSize div 2

iterator ringSlots(coreSize: int): tuple[x, y: int] =
  ## Clockwise walk over the ring centre line. Coordinates are relative
  ## to the core origin and may be negative or reach past the core.
  let lo = -aqrGap
  let hi = coreSize + aqrGap - 1
  # top edge left to right, right edge downwards, bottom right to left,
  # left edge upwards
  for x in lo .. hi: yield (x, lo)
  for y in lo + 1 .. hi: yield (hi, y)
  var x = hi - 1
  while x >= lo:
    yield (x, hi)
    dec x
  var y = hi - 1
  while y >= lo:
    yield (lo, y)
    dec y

proc ringSlotCount(coreSize: int): int =
  for _ in ringSlots(coreSize):
    inc result

proc encodeAqr*(mainPayload: string, ringPayload: string,
                ec = ecMedium, version = 0): QrMatrix {.
    raises: [QrError, ValueError].} =
  ## Encodes `mainPayload` as the Model 2 core and `ringPayload` into the
  ## surrounding ring.
  var opts = defaultQrEncodeOptions()
  opts.ecLevel = ec
  if version > 0:
    opts.minVersion = version
    opts.maxVersion = version
  let core = encodeQr(mainPayload, opts)
  let n = core.width
  let outer = aqrOuterSize(n)
  let off = coreOffset(outer, n)

  var payloadBytes: seq[byte] = @[]
  if ringPayload.len > 0:
    payloadBytes = @(ringPayload.toOpenArrayByte(0, ringPayload.len - 1))
  let frameLen = payloadBytes.len + 1
  let capacity = ringSlotCount(n)
  if 8 * frameLen > capacity:
    raise newException(QrError,
      "AQR ring payload exceeds " & $((capacity div 8) - 2) & " bytes")

  result = initSquareQrMatrix(outer)
  for y in 0 ..< n:
    for x in 0 ..< n:
      if core.modules[y * n + x]:
        result.modules[(y + off) * outer + (x + off)] = true

  var bits: seq[bool] = @[]
  template push(value: int, count: int) =
    for k in countdown(count - 1, 0):
      bits.add ((value shr k) and 1) == 1
  push frameLen, 8
  for b in payloadBytes:
    push b.int, 8
  push crc8(payloadBytes).int, 8

  var idx = 0
  for p in ringSlots(n):
    let ax = p.x + off
    let ay = p.y + off
    if idx < bits.len and bits[idx]:
      result.modules[ay * outer + ax] = true
    inc idx

proc tryReadRing(m: QrMatrix, coreSize: int): string =
  ## Attempts ring recovery assuming the given core size; returns ""
  ## unless the CRC validates.
  let outer = m.width
  let off = coreOffset(outer, coreSize)
  var raw: seq[bool] = @[]
  for p in ringSlots(coreSize):
    let ax = p.x + off
    let ay = p.y + off
    if ax < 0 or ay < 0 or ax >= outer or ay >= outer:
      return ""
    raw.add m.modules[ay * outer + ax]
  if raw.len < 24:
    return ""
  func takeByte(start: int): int =
    for k in 0 ..< 8:
      result = (result shl 1) or (if raw[start + k]: 1 else: 0)
  let frameLen = takeByte(0)
  if frameLen < 1 or 8 * frameLen > raw.len - 8:
    return ""
  var payload: seq[byte] = @[]
  var pos = 8
  for _ in 0 ..< frameLen - 1:
    var b: uint8 = 0
    for k in 0 ..< 8:
      b = (b shl 1) or (if raw[pos + k]: 1'u8 else: 0'u8)
    inc pos, 8
    payload.add b
  var expectedCrc: uint8 = 0
  for k in 0 ..< 8:
    expectedCrc = (expectedCrc shl 1) or (if raw[pos + k]: 1'u8 else: 0'u8)
  if crc8(payload) == expectedCrc:
    result = newString(payload.len)
    for i, b in payload: result[i] = char(b)

proc readAqrRing*(m: QrMatrix): string {.raises: [QrError].} =
  ## Recovers the ring payload of an AQR symbol produced by this module.
  ## Returns "" when no consistent ring is found.
  var coreSize = 21
  while coreSize + 2 * (aqrGap + 1) <= m.width:
    let r = tryReadRing(m, coreSize)
    if r.len > 0:
      return r
    inc coreSize, 4

proc aqrCore*(m: QrMatrix): QrMatrix {.raises: [QrError].} =
  ## Crops the Model 2 core out of an AQR symbol so it can be passed to
  ## `decodeQrMatrix`.
  if m.width < 27 or (m.width - 6 - 17) mod 4 != 0:
    raise newException(QrError, "not an openparser AQR symbol")
  let coreSize = m.width - 6
  let off = coreOffset(m.width, coreSize)
  result = initSquareQrMatrix(coreSize)
  for y in 0 ..< coreSize:
    for x in 0 ..< coreSize:
      result.modules[y * coreSize + x] =
        m.modules[(y + off) * m.width + (x + off)]

proc decodeAqrCore*(m: QrMatrix): QrDecodeResult {.raises: [QrError].} =
  ## Decodes the Model 2 core of an AQR symbol.
  result = decodeQrMatrix(aqrCore(m))