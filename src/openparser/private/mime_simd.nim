# A collection of tiny parsers and dumpers
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/openparser

## SIMD-accelerated byte scanners for the MIME parser.
## Scalar fallback on non-x86 targets; disable with `-d:openparserMimeNoSimd`.
import std/bitops

when defined(openparserMimeNoSimd):
  const hasSse2* = false
  const hasAvx2* = false
elif defined(amd64) or defined(i386):
  import nimsimd/sse2
  when defined(avx2):
    import nimsimd/avx2
    const hasAvx2* = true
  else:
    const hasAvx2* = false
  const hasSse2* = true
else:
  const hasSse2* = false
  const hasAvx2* = false

# ---------------------------------------------------------------------------
# Scalar fallbacks (also used for tails)
# ---------------------------------------------------------------------------

proc findEolScalar*(p: ptr char, start, stop: int): int {.inline.} =
  let s = cast[cstring](p)
  for i in start ..< stop:
    if s[i] == '\r' or s[i] == '\n': return i
  -1

proc findEqScalar*(p: ptr char, start, stop: int): int {.inline.} =
  let s = cast[cstring](p)
  for i in start ..< stop:
    if s[i] == '=': return i
  -1

proc hasNonAsciiScalar*(p: ptr char, start, stop: int): bool {.inline.} =
  let s = cast[cstring](p)
  for i in start ..< stop:
    if ord(s[i]) >= 0x80: return true
  false

proc hasBase64WsScalar*(p: ptr char, start, stop: int): bool {.inline.} =
  let s = cast[cstring](p)
  for i in start ..< stop:
    let c = s[i]
    if c == ' ' or c == '\t' or c == '\r' or c == '\n': return true
  false

proc findNonBase64Scalar*(p: ptr char, start, stop: int): int {.inline.} =
  ## First byte outside the base64 alphabet (A-Z a-z 0-9 + / =).
  let s = cast[cstring](p)
  for i in start ..< stop:
    let c = s[i]
    if c >= 'A' and c <= 'Z': continue
    if c >= 'a' and c <= 'z': continue
    if c >= '0' and c <= '9': continue
    if c == '+' or c == '/' or c == '=': continue
    return i
  -1

# ---------------------------------------------------------------------------
# SSE2 paths (16 bytes / cycle)
# ---------------------------------------------------------------------------

when hasSse2:
  proc findEolSse2*(p: ptr char, start, stop: int): int =
    let cr = mm_set1_epi8(cast[int8]('\r'))
    let lf = mm_set1_epi8(cast[int8]('\n'))
    let buf = cast[ptr UncheckedArray[char]](p)
    var i = start
    while i + 16 <= stop:
      let chunk = mm_loadu_si128(cast[ptr M128i](addr buf[i]))
      let mask = mm_movemask_epi8(mm_or_si128(
        mm_cmpeq_epi8(chunk, cr), mm_cmpeq_epi8(chunk, lf)))
      if mask != 0:
        return i + countTrailingZeroBits(cast[uint32](mask))
      i += 16
    for j in i ..< stop:
      if buf[j] == '\r' or buf[j] == '\n': return j
    -1

  proc findEqSse2*(p: ptr char, start, stop: int): int =
    let eq = mm_set1_epi8(cast[int8]('='))
    let buf = cast[ptr UncheckedArray[char]](p)
    var i = start
    while i + 16 <= stop:
      let chunk = mm_loadu_si128(cast[ptr M128i](addr buf[i]))
      let mask = mm_movemask_epi8(mm_cmpeq_epi8(chunk, eq))
      if mask != 0:
        return i + countTrailingZeroBits(cast[uint32](mask))
      i += 16
    for j in i ..< stop:
      if buf[j] == '=': return j
    -1

  proc hasNonAsciiSse2*(p: ptr char, start, stop: int): bool =
    ## High bit set anywhere -> movemask nonzero.
    let buf = cast[ptr UncheckedArray[char]](p)
    var i = start
    while i + 16 <= stop:
      let chunk = mm_loadu_si128(cast[ptr M128i](addr buf[i]))
      if mm_movemask_epi8(chunk) != 0: return true
      i += 16
    for j in i ..< stop:
      if ord(buf[j]) >= 0x80: return true
    false

  proc hasBase64WsSse2*(p: ptr char, start, stop: int): bool =
    let buf = cast[ptr UncheckedArray[char]](p)
    let sp = mm_set1_epi8(cast[int8](' '))
    let tb = mm_set1_epi8(cast[int8]('\t'))
    let cr = mm_set1_epi8(cast[int8]('\r'))
    let lf = mm_set1_epi8(cast[int8]('\n'))
    var i = start
    while i + 16 <= stop:
      let chunk = mm_loadu_si128(cast[ptr M128i](addr buf[i]))
      let ws = mm_or_si128(mm_or_si128(
        mm_cmpeq_epi8(chunk, sp), mm_cmpeq_epi8(chunk, tb)),
        mm_or_si128(mm_cmpeq_epi8(chunk, cr), mm_cmpeq_epi8(chunk, lf)))
      if mm_movemask_epi8(ws) != 0: return true
      i += 16
    for j in i ..< stop:
      if buf[j] == ' ' or buf[j] == '\t' or buf[j] == '\r' or buf[j] == '\n':
        return true
    false

  template rangeMask16(chunk: M128i, lo: char, span: int): M128i =
    let loV = mm_set1_epi8(cast[int8](lo))
    let spV = mm_set1_epi8(cast[int8](span))
    let d = mm_sub_epi8(chunk, loV)
    mm_cmpeq_epi8(mm_min_epu8(d, spV), d)

  proc findNonBase64Sse2*(p: ptr char, start, stop: int): int =
    let buf = cast[ptr UncheckedArray[char]](p)
    let plus = mm_set1_epi8(cast[int8]('+'))
    let slash = mm_set1_epi8(cast[int8]('/'))
    let eq = mm_set1_epi8(cast[int8]('='))
    let ones = mm_set1_epi8(cast[int8](-1))
    var i = start
    while i + 16 <= stop:
      let chunk = mm_loadu_si128(cast[ptr M128i](addr buf[i]))
      var ok = mm_or_si128(rangeMask16(chunk, 'A', 25),
                           rangeMask16(chunk, 'a', 25))
      ok = mm_or_si128(ok, rangeMask16(chunk, '0', 9))
      ok = mm_or_si128(ok, mm_or_si128(
        mm_cmpeq_epi8(chunk, plus),
        mm_or_si128(mm_cmpeq_epi8(chunk, slash), mm_cmpeq_epi8(chunk, eq))))
      let bad = mm_movemask_epi8(mm_andnot_si128(ok, ones))
      if bad != 0:
        return i + countTrailingZeroBits(cast[uint32](bad))
      i += 16
    for j in i ..< stop:
      let c = buf[j]
      if c >= 'A' and c <= 'Z': continue
      if c >= 'a' and c <= 'z': continue
      if c >= '0' and c <= '9': continue
      if c == '+' or c == '/' or c == '=': continue
      return j
    -1

# ---------------------------------------------------------------------------
# AVX2 paths (32 bytes / cycle)
# ---------------------------------------------------------------------------

when hasAvx2:
  proc findEolAvx2*(p: ptr char, start, stop: int): int =
    let cr = mm256_set1_epi8(cast[int8]('\r'))
    let lf = mm256_set1_epi8(cast[int8]('\n'))
    let buf = cast[ptr UncheckedArray[char]](p)
    var i = start
    while i + 32 <= stop:
      let chunk = mm256_loadu_si256(cast[ptr M256i](addr buf[i]))
      let mask = cast[uint32](mm256_movemask_epi8(mm256_or_si256(
        mm256_cmpeq_epi8(chunk, cr), mm256_cmpeq_epi8(chunk, lf))))
      if mask != 0:
        return i + countTrailingZeroBits(mask)
      i += 32
    while i + 16 <= stop:
      let chunk = mm_loadu_si128(cast[ptr M128i](addr buf[i]))
      let m = mm_movemask_epi8(mm_or_si128(
        mm_cmpeq_epi8(chunk, mm_set1_epi8(cast[int8]('\r'))),
        mm_cmpeq_epi8(chunk, mm_set1_epi8(cast[int8]('\n')))))
      if m != 0:
        return i + countTrailingZeroBits(cast[uint32](m))
      i += 16
    for j in i ..< stop:
      if buf[j] == '\r' or buf[j] == '\n': return j
    -1

  proc findEqAvx2*(p: ptr char, start, stop: int): int =
    let eq = mm256_set1_epi8(cast[int8]('='))
    let buf = cast[ptr UncheckedArray[char]](p)
    var i = start
    while i + 32 <= stop:
      let chunk = mm256_loadu_si256(cast[ptr M256i](addr buf[i]))
      let mask = cast[uint32](mm256_movemask_epi8(mm256_cmpeq_epi8(chunk, eq)))
      if mask != 0:
        return i + countTrailingZeroBits(mask)
      i += 32
    while i + 16 <= stop:
      let chunk = mm_loadu_si128(cast[ptr M128i](addr buf[i]))
      let m = mm_movemask_epi8(mm_cmpeq_epi8(chunk,
        mm_set1_epi8(cast[int8]('='))))
      if m != 0:
        return i + countTrailingZeroBits(cast[uint32](m))
      i += 16
    for j in i ..< stop:
      if buf[j] == '=': return j
    -1

  proc hasNonAsciiAvx2*(p: ptr char, start, stop: int): bool =
    let buf = cast[ptr UncheckedArray[char]](p)
    var i = start
    while i + 32 <= stop:
      let chunk = mm256_loadu_si256(cast[ptr M256i](addr buf[i]))
      if cast[uint32](mm256_movemask_epi8(chunk)) != 0: return true
      i += 32
    while i + 16 <= stop:
      let chunk = mm_loadu_si128(cast[ptr M128i](addr buf[i]))
      if mm_movemask_epi8(chunk) != 0: return true
      i += 16
    for j in i ..< stop:
      if ord(buf[j]) >= 0x80: return true
    false

  proc hasBase64WsAvx2*(p: ptr char, start, stop: int): bool =
    let buf = cast[ptr UncheckedArray[char]](p)
    let sp = mm256_set1_epi8(cast[int8](' '))
    let tb = mm256_set1_epi8(cast[int8]('\t'))
    let cr = mm256_set1_epi8(cast[int8]('\r'))
    let lf = mm256_set1_epi8(cast[int8]('\n'))
    var i = start
    while i + 32 <= stop:
      let chunk = mm256_loadu_si256(cast[ptr M256i](addr buf[i]))
      let ws = mm256_or_si256(mm256_or_si256(
        mm256_cmpeq_epi8(chunk, sp), mm256_cmpeq_epi8(chunk, tb)),
        mm256_or_si256(mm256_cmpeq_epi8(chunk, cr),
                       mm256_cmpeq_epi8(chunk, lf)))
      if cast[uint32](mm256_movemask_epi8(ws)) != 0: return true
      i += 32
    while i + 16 <= stop:
      let chunk = mm_loadu_si128(cast[ptr M128i](addr buf[i]))
      let ws = mm_or_si128(mm_or_si128(
        mm_cmpeq_epi8(chunk, mm_set1_epi8(cast[int8](' '))),
        mm_cmpeq_epi8(chunk, mm_set1_epi8(cast[int8]('\t')))),
        mm_or_si128(mm_cmpeq_epi8(chunk, mm_set1_epi8(cast[int8]('\r'))),
                    mm_cmpeq_epi8(chunk, mm_set1_epi8(cast[int8]('\n')))))
      if mm_movemask_epi8(ws) != 0: return true
      i += 16
    for j in i ..< stop:
      if buf[j] == ' ' or buf[j] == '\t' or buf[j] == '\r' or buf[j] == '\n':
        return true
    false

  template rangeMask32(chunk: M256i, lo: char, span: int): M256i =
    let loV = mm256_set1_epi8(cast[int8](lo))
    let spV = mm256_set1_epi8(cast[int8](span))
    let d = mm256_sub_epi8(chunk, loV)
    mm256_cmpeq_epi8(mm256_min_epu8(d, spV), d)

  proc findNonBase64Avx2*(p: ptr char, start, stop: int): int =
    let buf = cast[ptr UncheckedArray[char]](p)
    let plus = mm256_set1_epi8(cast[int8]('+'))
    let slash = mm256_set1_epi8(cast[int8]('/'))
    let eq = mm256_set1_epi8(cast[int8]('='))
    let ones = mm256_set1_epi8(cast[int8](-1))
    var i = start
    while i + 32 <= stop:
      let chunk = mm256_loadu_si256(cast[ptr M256i](addr buf[i]))
      var ok = mm256_or_si256(rangeMask32(chunk, 'A', 25),
                              rangeMask32(chunk, 'a', 25))
      ok = mm256_or_si256(ok, rangeMask32(chunk, '0', 9))
      ok = mm256_or_si256(ok, mm256_or_si256(
        mm256_cmpeq_epi8(chunk, plus),
        mm256_or_si256(mm256_cmpeq_epi8(chunk, slash),
                       mm256_cmpeq_epi8(chunk, eq))))
      let bad = cast[uint32](mm256_movemask_epi8(
        mm256_andnot_si256(ok, ones)))
      if bad != 0:
        return i + countTrailingZeroBits(bad)
      i += 32
    while i + 16 <= stop:
      let chunk = mm_loadu_si128(cast[ptr M128i](addr buf[i]))
      var ok = mm_or_si128(rangeMask16(chunk, 'A', 25),
                           rangeMask16(chunk, 'a', 25))
      ok = mm_or_si128(ok, rangeMask16(chunk, '0', 9))
      ok = mm_or_si128(ok, mm_or_si128(
        mm_cmpeq_epi8(chunk, mm_set1_epi8(cast[int8]('+'))),
        mm_or_si128(mm_cmpeq_epi8(chunk, mm_set1_epi8(cast[int8]('/'))),
                      mm_cmpeq_epi8(chunk, mm_set1_epi8(cast[int8]('='))))))
      let bad = mm_movemask_epi8(mm_andnot_si128(ok,
        mm_set1_epi8(cast[int8](-1))))
      if bad != 0:
        return i + countTrailingZeroBits(cast[uint32](bad))
      i += 16
    for j in i ..< stop:
      let c = buf[j]
      if c >= 'A' and c <= 'Z': continue
      if c >= 'a' and c <= 'z': continue
      if c >= '0' and c <= '9': continue
      if c == '+' or c == '/' or c == '=': continue
      return j
    -1

# ---------------------------------------------------------------------------
# Unified dispatch
# ---------------------------------------------------------------------------

proc findEol*(p: ptr char, start, stop: int): int {.inline.} =
  when hasAvx2: findEolAvx2(p, start, stop)
  elif hasSse2: findEolSse2(p, start, stop)
  else:         findEolScalar(p, start, stop)

proc findEq*(p: ptr char, start, stop: int): int {.inline.} =
  when hasAvx2: findEqAvx2(p, start, stop)
  elif hasSse2: findEqSse2(p, start, stop)
  else:         findEqScalar(p, start, stop)

proc hasNonAscii*(p: ptr char, start, stop: int): bool {.inline.} =
  when hasAvx2: hasNonAsciiAvx2(p, start, stop)
  elif hasSse2: hasNonAsciiSse2(p, start, stop)
  else:         hasNonAsciiScalar(p, start, stop)

proc hasBase64Ws*(p: ptr char, start, stop: int): bool {.inline.} =
  when hasAvx2: hasBase64WsAvx2(p, start, stop)
  elif hasSse2: hasBase64WsSse2(p, start, stop)
  else:         hasBase64WsScalar(p, start, stop)

proc findNonBase64*(p: ptr char, start, stop: int): int {.inline.} =
  when hasAvx2: findNonBase64Avx2(p, start, stop)
  elif hasSse2: findNonBase64Sse2(p, start, stop)
  else:         findNonBase64Scalar(p, start, stop)
