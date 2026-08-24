# A collection of tiny parsers and dumpers
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/openparser

## GF(2^8) arithmetic over the QR primitive polynomial x^8 + x^4 + x^3 + x^2 + 1
## and a systematic Reed-Solomon codec (Berlekamp-Massey, Chien search,
## Forney algorithm) supporting both random errors and declared erasures.
##
## Unstable API. Prefer importing `openparser/qr` instead of this module.

import std/[sequtils, algorithm]
import ./common

export common

const GfPoly* = 0x11D'u32
  ## QR field primitive polynomial.

func buildExpTable(): array[512, uint8] =
  var x = 1'u32
  for i in 0 ..< 255:
    result[i] = uint8(x)
    x = x * 2
    if x >= 0x100:
      x = x xor GfPoly
  for i in 255 ..< 512:
    result[i] = result[i - 255]

const gfExpTable = buildExpTable()

const gfLogTable = block:
  var t: array[256, uint8]
  for i in 0 ..< 255:
    t[gfExpTable[i]] = uint8(i)
  t

func gfMul*(a, b: uint8): uint8 {.inline.} =
  ## Multiplication in GF(256).
  if a == 0 or b == 0: 0'u8 else: gfExpTable[gfLogTable[a].int + gfLogTable[b].int]

func gfDiv*(a, b: uint8): uint8 {.inline.} =
  ## Division in GF(256). Raises QrError on division by zero.
  if b == 0:
    raise newException(QrError, "GF(256): division by zero")
  if a == 0: return 0'u8
  gfExpTable[(gfLogTable[a].int - gfLogTable[b].int + 255) mod 255]

func gfInv*(a: uint8): uint8 {.inline.} =
  ## Multiplicative inverse.
  gfExpTable[(255 - gfLogTable[a].int) mod 255]

func gfPow*(a: uint8, n: int): uint8 {.inline.} =
  ## Alpha power. Exponents wrap modulo 255, negatives included.
  if a == 0:
    if n < 0:
      raise newException(QrError, "GF(256): zero to a negative power")
    return (if n == 0: 1'u8 else: 0'u8)
  gfExpTable[((gfLogTable[a].int * n) mod 255 + 255) mod 255]

# Polynomial helpers (index 0 = highest degree coefficient)

func polyMul*(p, q: openArray[uint8]): seq[uint8] =
  result = newSeq[uint8](p.len + q.len - 1)
  for i, pi in p:
    for j, qj in q:
      result[i + j] = result[i + j] xor gfMul(pi, qj)

func polyEval*(p: openArray[uint8], x: uint8): uint8 =
  ## Evaluates the polynomial at `x` using Horner's method.
  var acc = 0'u8
  for c in p:
    acc = gfMul(acc, x) xor c
  acc

func polyAddLowAligned(p, q: openArray[uint8]): seq[uint8] =
  ## Addition with both polynomials aligned at the constant term,
  ## matching the classic Berlekamp-Massey formulation.
  let n = max(p.len, q.len)
  result = newSeq[uint8](n)
  for i, v in p: result[i + n - p.len] = v
  for i, v in q: result[i + n - q.len] = result[i + n - q.len] xor v

# Reed-Solomon encoding ------------------------------------------------------

func rsGeneratorPoly*(nsym: int): seq[uint8] =
  ## Generator polynomial prod_{i=0}^{nsym-1}(x - alpha^i), highest degree first.
  assert nsym > 0
  result = @[1'u8]
  for i in 0 ..< nsym:
    result = polyMul(result, [1'u8, gfPow(2, i)])

proc rsEncodeParity*(data: openArray[uint8], nsym: int): seq[uint8] =
  ## Systematic Reed-Solomon parity (`nsym` bytes) for `data`.
  ## Append the parity to `data` to obtain full codewords.
  let gen = rsGeneratorPoly(nsym)
  result = newSeq[uint8](nsym)
  for b in data:
    let factor = b xor result[0]
    for j in 1 ..< nsym:
      result[j - 1] = result[j]
    result[^1] = 0
    for i in 0 ..< nsym:
      result[i] = result[i] xor gfMul(gen[i + 1], factor)

# Reed-Solomon decoding ------------------------------------------------------
# Syndrome layout follows the classic formulation: entry 0 is an unused
# placeholder, the true syndromes S_0 .. S_{nsym-1} follow.

func rsCalcSyndromes(cw: openArray[uint8], nsym: int): seq[uint8] =
  result = newSeq[uint8](nsym + 1)
  for i in 0 ..< nsym:
    result[i + 1] = polyEval(cw, gfPow(2, i))

func errataLocator(coefPos: openArray[int]): seq[uint8] =
  ## Product of (1 + alpha^pos * x) over the given from-start positions.
  result = @[1'u8]
  for pos in coefPos:
    result = polyMul(result, polyAddLowAligned([1'u8], [gfPow(2, pos), 0'u8]))

func errorEvaluator(syndReversed, errLoc: openArray[uint8]): seq[uint8] =
  ## Remainder of syndReversed * errLoc modulo x^(deg+1).
  let prod = polyMul(syndReversed, errLoc)
  let remLen = errLoc.len
  if prod.len <= remLen:
    return @(prod)
  prod[prod.len - remLen ..< prod.len]

func forneySyndromes(synd: openArray[uint8], cwLen: int,
                     erasePosStart: openArray[int]): seq[uint8] =
  ## Erasure-transformed syndromes (placeholder dropped).
  ## `erasePosStart` holds byte indices counted from the start.
  result = newSeq[uint8](synd.len - 1)
  for i in 1 ..< synd.len:
    result[i - 1] = synd[i]
  for p in erasePosStart:
    let x = gfPow(2, cwLen - 1 - p)
    for j in 0 ..< result.len - 1:
      result[j] = gfMul(result[j], x) xor result[j + 1]

func berlekampMassey(fsynd: openArray[uint8],
                     nsym, eraseCount: int): seq[uint8] =
  ## Error locator polynomial, highest degree first.
  var errLoc: seq[uint8] = @[1'u8]
  var oldLoc: seq[uint8] = @[1'u8]
  let iters = min(nsym - eraseCount, fsynd.len)
  for i in 0 ..< iters:
    var delta = fsynd[i]
    for j in 1 ..< errLoc.len:
      if i - j >= 0:
        delta = delta xor gfMul(errLoc[errLoc.len - 1 - j], fsynd[i - j])
    oldLoc.add 0'u8
    if delta != 0:
      if oldLoc.len > errLoc.len:
        let newLoc = oldLoc.mapIt(gfMul(it, delta))
        oldLoc = errLoc.mapIt(gfMul(it, gfInv(delta)))
        errLoc = newLoc
      let scaledOld = oldLoc.mapIt(gfMul(it, delta))
      errLoc = polyAddLowAligned(errLoc, scaledOld)
  while errLoc.len > 1 and errLoc[0] == 0:
    errLoc.delete(0)
  let errs = errLoc.len - 1
  if (errs - eraseCount) * 2 + eraseCount > nsym:
    raise newException(QrError, "RS: too many errors for the parity budget")
  errLoc

func chienSearch(locatorReversed: openArray[uint8], n: int): seq[int] =
  ## Error positions as byte indices counted from the start of the codeword.
  let errs = locatorReversed.len - 1
  for i in 0 ..< n:
    if polyEval(locatorReversed, gfPow(2, i)) == 0:
      result.add n - 1 - i
  if result.len != errs:
    raise newException(QrError, "RS: locator degree mismatch during Chien search")

proc correctErrata(cw: var seq[uint8], synd: openArray[uint8],
                   allPosStart: openArray[int]) =
  ## Applies Forney magnitudes at every erasure/error position.
  ## Positions are byte indices counted from the start.
  let coefPos = allPosStart.mapIt(cw.len - 1 - it)
  let eLoc = errataLocator(coefPos)
  let eEval = errorEvaluator(reversed(synd.toSeq), eLoc).reversed
  var xs = newSeq[uint8](coefPos.len)
  for i, p in coefPos:
    xs[i] = gfPow(2, p - 255)
  var magnitudes = newSeq[uint8](cw.len)
  for i, xi in xs:
    let xiInv = gfInv(xi)
    var prime = 1'u8
    for j in 0 ..< xs.len:
      if j != i:
        prime = gfMul(prime, 1'u8 xor gfMul(xiInv, xs[j]))
    if prime == 0:
      raise newException(QrError, "RS: singular formal derivative")
    let y = gfMul(gfPow(xi, 1), polyEval(eEval.reversed, xiInv))
    magnitudes[allPosStart[i]] = gfDiv(y, prime)
  for i, m in magnitudes:
    cw[i] = cw[i] xor m

func rsIsValid*(codewords: openArray[uint8], nsym: int): bool =
  ## True when the codewords carry no detectable errors.
  let synd = rsCalcSyndromes(codewords, nsym)
  for i in 1 ..< synd.len:
    if synd[i] != 0: return false
  true

proc rsDecode*(codewords: var seq[uint8], nsym: int,
               erasures: openArray[int] = []) {.raises: [QrError].} =
  ## Corrects declared erasures plus random errors in place, within the
  ## budget 2*errors + erasures <= nsym. Positions are byte indices from
  ## the start of `codewords`. Raises QrError when uncorrectable.
  if codewords.len < nsym:
    raise newException(QrError, "RS: codeword shorter than parity length")
  for p in erasures:
    if p < 0 or p >= codewords.len:
      raise newException(QrError, "RS: erasure index out of range")
    codewords[p] = 0

  let synd = rsCalcSyndromes(codewords, nsym)
  if synd[1 ..< synd.len].allIt(it == 0):
    return

  let fsynd = forneySyndromes(synd, codewords.len, erasures.toSeq)
  var errPos: seq[int] = @[]
  block findRandomErrors:
    if fsynd.allIt(it == 0):
      break findRandomErrors
    let loc = berlekampMassey(fsynd, nsym, erasures.len)
    if loc.len > 1:
      errPos = chienSearch(loc.reversed, codewords.len)

  let allPos = erasures.toSeq & errPos
  if allPos.len > 0:
    correctErrata(codewords, synd, allPos)
    if not rsIsValid(codewords, nsym):
      raise newException(QrError, "RS: correction failed verification")
