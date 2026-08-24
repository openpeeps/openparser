# A collection of tiny parsers and dumpers
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/openparser

## Shared primitives for the QR symbology family: symbol matrices,
## grayscale images, bit buffers, error types and encoding enums.
##
## Unstable API. Prefer importing `openparser/qr` instead of this module.

type
  QrError* = object of ValueError
    ## Raised for malformed QR input, undecodable symbols and capacity overflow.

  QrEcLevel* = enum
    ## Error correction level. Recovery capability grows from L to H.
    ecLow = "L"
    ecMedium = "M"
    ecQuartile = "Q"
    ecHigh = "H"

  QrMode* = enum
    ## Segment encodation modes defined by ISO/IEC 18004.
    modeTerminator = 0b0000
    modeNumeric = 0b0001
    modeAlphanumeric = 0b0010
    modeStructuredAppend = 0b0011
    modeByte = 0b0100
    modeFnc1First = 0b0101
    modeEci = 0b0111
    modeKanji = 0b1000
    modeFnc1Second = 0b1001

  QrFamily* = enum
    ## QR symbology families supported by this package.
    famModel1
    famModel2
    famMicro
    famRmqr

  GrayImage* = object
    ## 8-bit grayscale pixel buffer, row-major, top-left origin.
    width*: int
    height*: int
    pixels*: seq[uint8]

  QrMatrix* = object
    ## Module grid of a decoded or generated symbol.
    ## `true` marks a dark module. Row-major storage.
    width*: int
    height*: int
    modules*: seq[bool]

  BitBuffer* = object
    ## MSB-first packed bit accumulator used by every QR encoder.
    buf: seq[byte]
    n: int

func initQrMatrix*(width, height: int): QrMatrix =
  QrMatrix(width: width, height: height, modules: newSeq[bool](width * height))

func initSquareQrMatrix*(size: int): QrMatrix =
  initQrMatrix(size, size)

func `[]`*(m: QrMatrix, x, y: int): bool {.inline.} =
  m.modules[y * m.width + x]

func `[]=`*(m: var QrMatrix, x, y: int, v: bool) {.inline.} =
  m.modules[y * m.width + x] = v

func `$`*(m: QrMatrix): string =
  ## ASCII preview of the matrix (`■` for dark modules, a space for
  ## light ones) suitable for terminals.
  result = newStringOfCap((m.width + 1) * m.height)
  for y in 0 ..< m.height:
    for x in 0 ..< m.width:
      result.add(if m[x, y]: "■" else: " ")
    if y < m.height - 1:
      result.add '\n'

func initGrayImage*(width, height: int): GrayImage =
  GrayImage(width: width, height: height, pixels: newSeq[uint8](width * height))

func grayAt*(img: GrayImage, x, y: int): uint8 {.inline.} =
  img.pixels[y * img.width + x]

# BitBuffer ------------------------------------------------------------------

func initBitBuffer*(capHint = 64): BitBuffer =
  BitBuffer(buf: newSeqOfCap[byte](capHint))

func bitLen*(b: BitBuffer): int {.inline.} =
  b.n

func bitAt*(b: BitBuffer, i: int): bool {.inline.} =
  ((b.buf[i shr 3] shr (7 - (i and 7))) and 1'u8) == 1'u8

func appendBit*(b: var BitBuffer, bit: bool) {.inline.} =
  if b.n mod 8 == 0:
    b.buf.add 0'u8
  if bit:
    b.buf[b.buf.len - 1] = b.buf[^1] or (1'u8 shl (7 - (b.n and 7)))
  inc b.n

func appendBits*(b: var BitBuffer, value: uint32, count: int) {.inline.} =
  ## Appends the low `count` bits of `value`, most significant bit first.
  assert count >= 0 and count <= 32
  for i in countdown(count - 1, 0):
    b.appendBit(((value shr i) and 1'u32) == 1'u32)

func appendBits*(b: var BitBuffer, value: int, count: int) {.inline.} =
  b.appendBits(uint32(value), count)

func appendByte*(b: var BitBuffer, value: uint8) {.inline.} =
  b.appendBits(value, 8)

func appendBytes*(b: var BitBuffer, values: openArray[byte]) =
  for v in values:
    b.appendByte(v)

func append*(b: var BitBuffer, other: BitBuffer) =
  ## Copies all valid bits of `other`, honouring its partial final byte.
  let full = other.n div 8
  for i in 0 ..< full:
    b.appendByte(other.buf[i])
  let rem = other.n mod 8
  if rem != 0:
    let tail = other.buf[full]
    for i in 0 ..< rem:
      b.appendBit(((tail shr (7 - i)) and 1'u8) == 1'u8)

func toSeq*(b: BitBuffer): seq[byte] =
  ## Copy of the underlying byte storage (last partial byte included).
  b.buf
