# A collection of tiny parsers and dumpers
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/openparser

## SIMD-accelerated scanning utilities for datregex.
## Falls back to scalar on non-x86 targets.
import std/bitops

when defined(amd64) or defined(i386):
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
# Scalar fallbacks
# ---------------------------------------------------------------------------

proc scanByteScalar*(s: string, start, stop: int, b: char): int {.inline.} =
  for i in start ..< stop:
    if s[i] == b: return i
  -1

proc scanByteSetScalar*(s: string, start, stop: int, lo, hi: char): int {.inline.} =
  for i in start ..< stop:
    if s[i] >= lo and s[i] <= hi: return i
  -1

proc scanAnyOfScalar*(s: string, start, stop: int, a, b: char): int {.inline.} =
  for i in start ..< stop:
    if s[i] == a or s[i] == b: return i
  -1

proc scanAlphaUnderscoreScalar*(s: string, start, stop: int): int {.inline.} =
  for i in start ..< stop:
    let c = s[i]
    if c in {'a'..'z', 'A'..'Z', '_'}: return i
  -1

proc scanWordCharScalar*(s: string, start, stop: int): int {.inline.} =
  for i in start ..< stop:
    let c = s[i]
    if c in {'a'..'z', 'A'..'Z', '0'..'9', '_'}: return i
  -1

proc scanNonWordCharScalar*(s: string, start, stop: int): int {.inline.} =
  ## Find first byte that is NOT \w — marks end of an identifier run.
  for i in start ..< stop:
    let c = s[i]
    if c notin {'a'..'z','A'..'Z','0'..'9','_'}: return i
  -1

proc scanNonDigitScalar*(s: string, start, stop: int): int {.inline.} =
  ## Find first byte that is NOT \d — marks end of a digit run.
  for i in start ..< stop:
    if s[i] notin {'0'..'9'}: return i
  -1

proc scanNonSpaceScalar*(s: string, start, stop: int): int {.inline.} =
  ## Find first byte that is NOT \s — marks end of a whitespace run.
  for i in start ..< stop:
    if s[i] notin {' ','\t','\n','\r','\f','\v'}: return i
  -1

proc scanNonAlphaUnderScalar*(s: string, start, stop: int): int {.inline.} =
  ## Find first byte that is NOT [a-zA-Z_].
  for i in start ..< stop:
    let c = s[i]
    if c notin {'a'..'z', 'A'..'Z', '_'}: return i
  -1

proc scanUpperDigitUnderScalar*(s: string, start, stop: int): int {.inline.} =
  ## Find first [A-Z0-9_] — for [A-Z_][A-Z0-9_]* prefilter.
  for i in start ..< stop:
    let c = s[i]
    if c in {'A'..'Z', '0'..'9', '_'}: return i
  -1

proc scanNonUpperDigitUnderScalar*(s: string, start, stop: int): int {.inline.} =
  for i in start ..< stop:
    let c = s[i]
    if c notin {'A'..'Z', '0'..'9', '_'}: return i
  -1

# ---------------------------------------------------------------------------
# SSE2 paths (16 bytes / cycle)
# ---------------------------------------------------------------------------

when hasSse2:
  template rangeMask16(chunk: M128i, lo: char, span: int): M128i =
    let loV = mm_set1_epi8(cast[int8](lo))
    let spV = mm_set1_epi8(cast[int8](span))
    let d   = mm_sub_epi8(chunk, loV)          ## wrapping, not saturating
    mm_cmpeq_epi8(mm_min_epu8(d, spV), d)

  proc scanByteSse2*(s: string, start, stop: int, b: char): int =
    let bVec = mm_set1_epi8(cast[int8](b))
    var i = start
    while i + 16 <= stop:
      let chunk = mm_loadu_si128(cast[ptr M128i](unsafeAddr s[i]))
      let mask  = mm_movemask_epi8(mm_cmpeq_epi8(chunk, bVec))
      if mask != 0: return i + countTrailingZeroBits(cast[uint32](mask))
      i += 16
    while i < stop:
      if s[i] == b: return i
      inc i
    -1

  proc scanByteRangeSse2*(s: string, start, stop: int, lo, hi: char): int =
    var i = start
    while i + 16 <= stop:
      let chunk = mm_loadu_si128(cast[ptr M128i](unsafeAddr s[i]))
      let mask  = mm_movemask_epi8(rangeMask16(chunk, lo, ord(hi) - ord(lo)))
      if mask != 0: return i + countTrailingZeroBits(cast[uint32](mask))
      i += 16
    while i < stop:
      if s[i] >= lo and s[i] <= hi: return i
      inc i
    -1

  proc scanAnyOfSse2*(s: string, start, stop: int, a, b: char): int =
    let va = mm_set1_epi8(cast[int8](a))
    let vb = mm_set1_epi8(cast[int8](b))
    var i = start
    while i + 16 <= stop:
      let chunk = mm_loadu_si128(cast[ptr M128i](unsafeAddr s[i]))
      let mask  = mm_movemask_epi8(
                    mm_or_si128(mm_cmpeq_epi8(chunk, va),
                                mm_cmpeq_epi8(chunk, vb)))
      if mask != 0: return i + countTrailingZeroBits(cast[uint32](mask))
      i += 16
    while i < stop:
      if s[i] == a or s[i] == b: return i
      inc i
    -1

  proc wordCharMask16(chunk: M128i): M128i {.inline.} =
    ## Returns a mask where bytes that ARE \w are 0xFF.
    let mLo = rangeMask16(chunk, 'a', 25)
    let mUp = rangeMask16(chunk, 'A', 25)
    let mDi = rangeMask16(chunk, '0', 9)
    let mUs = mm_cmpeq_epi8(chunk, mm_set1_epi8(cast[int8]('_')))
    mm_or_si128(mm_or_si128(mLo, mUp), mm_or_si128(mDi, mUs))

  proc alphaUnderMask16(chunk: M128i): M128i {.inline.} =
    ## Returns mask where bytes that ARE [a-zA-Z_] are 0xFF.
    let mLo = rangeMask16(chunk, 'a', 25)
    let mUp = rangeMask16(chunk, 'A', 25)
    let mUs = mm_cmpeq_epi8(chunk, mm_set1_epi8(cast[int8]('_')))
    mm_or_si128(mm_or_si128(mLo, mUp), mUs)

  proc upperDigitUnderMask16(chunk: M128i): M128i {.inline.} =
    let mUp = rangeMask16(chunk, 'A', 25)
    let mDi = rangeMask16(chunk, '0', 9)
    let mUs = mm_cmpeq_epi8(chunk, mm_set1_epi8(cast[int8]('_')))
    mm_or_si128(mm_or_si128(mUp, mDi), mUs)

  proc scanAlphaUnderscoreSse2*(s: string, start, stop: int): int =
    var i = start
    while i + 16 <= stop:
      let chunk = mm_loadu_si128(cast[ptr M128i](unsafeAddr s[i]))
      let mask  = mm_movemask_epi8(alphaUnderMask16(chunk))
      if mask != 0: return i + countTrailingZeroBits(cast[uint32](mask))
      i += 16
    while i < stop:
      if s[i] in {'a'..'z','A'..'Z','_'}: return i
      inc i
    -1

  proc scanWordCharSse2*(s: string, start, stop: int): int =
    var i = start
    while i + 16 <= stop:
      let chunk = mm_loadu_si128(cast[ptr M128i](unsafeAddr s[i]))
      let mask  = mm_movemask_epi8(wordCharMask16(chunk))
      if mask != 0: return i + countTrailingZeroBits(cast[uint32](mask))
      i += 16
    while i < stop:
      if s[i] in {'a'..'z','A'..'Z','0'..'9','_'}: return i
      inc i
    -1

  proc scanNonWordCharSse2*(s: string, start, stop: int): int =
    ## Find first byte NOT in \w — end-of-identifier scan.
    var i = start
    while i + 16 <= stop:
      let chunk = mm_loadu_si128(cast[ptr M128i](unsafeAddr s[i]))
      ## invert: non-word bytes become 0xFF
      let inv  = mm_andnot_si128(wordCharMask16(chunk),
                                 mm_set1_epi8(cast[int8](-1)))
      let mask = mm_movemask_epi8(inv)
      if mask != 0: return i + countTrailingZeroBits(cast[uint32](mask))
      i += 16
    while i < stop:
      if s[i] notin {'a'..'z','A'..'Z','0'..'9','_'}: return i
      inc i
    -1

  proc scanNonDigitSse2*(s: string, start, stop: int): int =
    ## Find first byte NOT in \d — end-of-digit-run scan.
    var i = start
    while i + 16 <= stop:
      let chunk = mm_loadu_si128(cast[ptr M128i](unsafeAddr s[i]))
      let mDi = rangeMask16(chunk, '0', 9)
      let inv = mm_andnot_si128(mDi, mm_set1_epi8(cast[int8](-1)))
      let mask = mm_movemask_epi8(inv)
      if mask != 0: return i + countTrailingZeroBits(cast[uint32](mask))
      i += 16
    while i < stop:
      if s[i] notin {'0'..'9'}: return i
      inc i
    -1

  proc scanNonSpaceSse2*(s: string, start, stop: int): int =
    ## Find first byte NOT in \s — end-of-whitespace run scan.
    var i = start
    while i + 16 <= stop:
      let chunk = mm_loadu_si128(cast[ptr M128i](unsafeAddr s[i]))
      # Match space, tab, newline, carriage return, form feed, vertical tab
      let mSp = mm_cmpeq_epi8(chunk, mm_set1_epi8(cast[int8](' ')))
      let mTb = mm_cmpeq_epi8(chunk, mm_set1_epi8(cast[int8]('\t')))
      let mNl = mm_cmpeq_epi8(chunk, mm_set1_epi8(cast[int8]('\n')))
      let mCr = mm_cmpeq_epi8(chunk, mm_set1_epi8(cast[int8]('\r')))
      let mFf = mm_cmpeq_epi8(chunk, mm_set1_epi8(cast[int8]('\f')))
      let mVt = mm_cmpeq_epi8(chunk, mm_set1_epi8(cast[int8]('\v')))
      let wsMask = mm_or_si128(mm_or_si128(mSp, mTb), mm_or_si128(mNl, mCr))
      let wsAll  = mm_or_si128(wsMask, mm_or_si128(mFf, mVt))
      let inv = mm_andnot_si128(wsAll, mm_set1_epi8(cast[int8](-1)))
      let mask = mm_movemask_epi8(inv)
      if mask != 0: return i + countTrailingZeroBits(cast[uint32](mask))
      i += 16
    while i < stop:
      if s[i] notin {' ','\t','\n','\r','\f','\v'}: return i
      inc i
    -1

  proc scanNonAlphaUnderSse2*(s: string, start, stop: int): int =
    var i = start
    while i + 16 <= stop:
      let chunk = mm_loadu_si128(cast[ptr M128i](unsafeAddr s[i]))
      let inv  = mm_andnot_si128(alphaUnderMask16(chunk),
                                 mm_set1_epi8(cast[int8](-1)))
      let mask = mm_movemask_epi8(inv)
      if mask != 0: return i + countTrailingZeroBits(cast[uint32](mask))
      i += 16
    while i < stop:
      if s[i] notin {'a'..'z','A'..'Z','_'}: return i
      inc i
    -1

  proc scanUpperDigitUnderSse2*(s: string, start, stop: int): int =
    var i = start
    while i + 16 <= stop:
      let chunk = mm_loadu_si128(cast[ptr M128i](unsafeAddr s[i]))
      let mask  = mm_movemask_epi8(upperDigitUnderMask16(chunk))
      if mask != 0: return i + countTrailingZeroBits(cast[uint32](mask))
      i += 16
    while i < stop:
      if s[i] in {'A'..'Z','0'..'9','_'}: return i
      inc i
    -1

  proc scanNonUpperDigitUnderSse2*(s: string, start, stop: int): int =
    var i = start
    while i + 16 <= stop:
      let chunk = mm_loadu_si128(cast[ptr M128i](unsafeAddr s[i]))
      let inv  = mm_andnot_si128(upperDigitUnderMask16(chunk),
                                 mm_set1_epi8(cast[int8](-1)))
      let mask = mm_movemask_epi8(inv)
      if mask != 0: return i + countTrailingZeroBits(cast[uint32](mask))
      i += 16
    while i < stop:
      if s[i] notin {'A'..'Z','0'..'9','_'}: return i
      inc i
    -1

# ---------------------------------------------------------------------------
# AVX2 paths (32 bytes / cycle) — compiled only with -d:avx2
# ---------------------------------------------------------------------------

when hasAvx2:
  template rangeMask32(chunk: M256i, lo: char, span: int): M256i =
    let loV = mm256_set1_epi8(cast[int8](lo))
    let spV = mm256_set1_epi8(cast[int8](span))
    let d   = mm256_sub_epi8(chunk, loV)       ## wrapping, not saturating
    mm256_cmpeq_epi8(mm256_min_epu8(d, spV), d)

  proc wordCharMask32(chunk: M256i): M256i {.inline.} =
    let mLo = rangeMask32(chunk, 'a', 25)
    let mUp = rangeMask32(chunk, 'A', 25)
    let mDi = rangeMask32(chunk, '0', 9)
    let mUs = mm256_cmpeq_epi8(chunk, mm256_set1_epi8(cast[int8]('_')))
    mm256_or_si256(mm256_or_si256(mLo, mUp), mm256_or_si256(mDi, mUs))

  proc alphaUnderMask32(chunk: M256i): M256i {.inline.} =
    let mLo = rangeMask32(chunk, 'a', 25)
    let mUp = rangeMask32(chunk, 'A', 25)
    let mUs = mm256_cmpeq_epi8(chunk, mm256_set1_epi8(cast[int8]('_')))
    mm256_or_si256(mm256_or_si256(mLo, mUp), mUs)

  proc upperDigitUnderMask32(chunk: M256i): M256i {.inline.} =
    let mUp = rangeMask32(chunk, 'A', 25)
    let mDi = rangeMask32(chunk, '0', 9)
    let mUs = mm256_cmpeq_epi8(chunk, mm256_set1_epi8(cast[int8]('_')))
    mm256_or_si256(mm256_or_si256(mUp, mDi), mUs)

  proc scanNonWordCharAvx2*(s: string, start, stop: int): int =
    var i = start
    while i + 32 <= stop:
      let chunk = mm256_loadu_si256(cast[ptr M256i](unsafeAddr s[i]))
      let inv   = mm256_andnot_si256(wordCharMask32(chunk),
                                     mm256_set1_epi8(cast[int8](-1)))
      let mask  = cast[uint32](mm256_movemask_epi8(inv))
      if mask != 0: return i + countTrailingZeroBits(mask)
      i += 32
    # SSE2 tail
    while i + 16 <= stop:
      let chunk = mm_loadu_si128(cast[ptr M128i](unsafeAddr s[i]))
      let inv   = mm_andnot_si128(wordCharMask16(chunk),
                                  mm_set1_epi8(cast[int8](-1)))
      let mask  = cast[uint32](mm_movemask_epi8(inv))
      if mask != 0: return i + countTrailingZeroBits(mask)
      i += 16
    while i < stop:
      if s[i] notin {'a'..'z','A'..'Z','0'..'9','_'}: return i
      inc i
    -1

  proc scanAlphaUnderscoreAvx2*(s: string, start, stop: int): int =
    var i = start
    while i + 32 <= stop:
      let chunk = mm256_loadu_si256(cast[ptr M256i](unsafeAddr s[i]))
      let mask  = cast[uint32](mm256_movemask_epi8(alphaUnderMask32(chunk)))
      if mask != 0: return i + countTrailingZeroBits(mask)
      i += 32
    while i + 16 <= stop:
      let chunk = mm_loadu_si128(cast[ptr M128i](unsafeAddr s[i]))
      let mask  = cast[uint32](mm_movemask_epi8(alphaUnderMask16(chunk)))
      if mask != 0: return i + countTrailingZeroBits(mask)
      i += 16
    while i < stop:
      if s[i] in {'a'..'z','A'..'Z','_'}: return i
      inc i
    -1

  proc scanWordCharAvx2*(s: string, start, stop: int): int =
    var i = start
    while i + 32 <= stop:
      let chunk = mm256_loadu_si256(cast[ptr M256i](unsafeAddr s[i]))
      let mask  = cast[uint32](mm256_movemask_epi8(wordCharMask32(chunk)))
      if mask != 0: return i + countTrailingZeroBits(mask)
      i += 32
    while i + 16 <= stop:
      let chunk = mm_loadu_si128(cast[ptr M128i](unsafeAddr s[i]))
      let mask  = cast[uint32](mm_movemask_epi8(wordCharMask16(chunk)))
      if mask != 0: return i + countTrailingZeroBits(mask)
      i += 16
    while i < stop:
      if s[i] in {'a'..'z','A'..'Z','0'..'9','_'}: return i
      inc i
    -1

  proc scanNonAlphaUnderAvx2*(s: string, start, stop: int): int =
    var i = start
    while i + 32 <= stop:
      let chunk = mm256_loadu_si256(cast[ptr M256i](unsafeAddr s[i]))
      let inv   = mm256_andnot_si256(alphaUnderMask32(chunk),
                                     mm256_set1_epi8(cast[int8](-1)))
      let mask  = cast[uint32](mm256_movemask_epi8(inv))
      if mask != 0: return i + countTrailingZeroBits(mask)
      i += 32
    while i + 16 <= stop:
      let chunk = mm_loadu_si128(cast[ptr M128i](unsafeAddr s[i]))
      let inv   = mm_andnot_si128(alphaUnderMask16(chunk),
                                  mm_set1_epi8(cast[int8](-1)))
      let mask  = cast[uint32](mm_movemask_epi8(inv))
      if mask != 0: return i + countTrailingZeroBits(mask)
      i += 16
    while i < stop:
      if s[i] notin {'a'..'z','A'..'Z','_'}: return i
      inc i
    -1

  proc scanUpperDigitUnderAvx2*(s: string, start, stop: int): int =
    var i = start
    while i + 32 <= stop:
      let chunk = mm256_loadu_si256(cast[ptr M256i](unsafeAddr s[i]))
      let mask  = cast[uint32](mm256_movemask_epi8(upperDigitUnderMask32(chunk)))
      if mask != 0: return i + countTrailingZeroBits(mask)
      i += 32
    while i + 16 <= stop:
      let chunk = mm_loadu_si128(cast[ptr M128i](unsafeAddr s[i]))
      let mask  = cast[uint32](mm_movemask_epi8(upperDigitUnderMask16(chunk)))
      if mask != 0: return i + countTrailingZeroBits(mask)
      i += 16
    while i < stop:
      if s[i] in {'A'..'Z','0'..'9','_'}: return i
      inc i
    -1

  proc scanNonUpperDigitUnderAvx2*(s: string, start, stop: int): int =
    var i = start
    while i + 32 <= stop:
      let chunk = mm256_loadu_si256(cast[ptr M256i](unsafeAddr s[i]))
      let inv   = mm256_andnot_si256(upperDigitUnderMask32(chunk),
                                     mm256_set1_epi8(cast[int8](-1)))
      let mask  = cast[uint32](mm256_movemask_epi8(inv))
      if mask != 0: return i + countTrailingZeroBits(mask)
      i += 32
    while i + 16 <= stop:
      let chunk = mm_loadu_si128(cast[ptr M128i](unsafeAddr s[i]))
      let inv   = mm_andnot_si128(upperDigitUnderMask16(chunk),
                                  mm_set1_epi8(cast[int8](-1)))
      let mask  = cast[uint32](mm_movemask_epi8(inv))
      if mask != 0: return i + countTrailingZeroBits(mask)
      i += 16
    while i < stop:
      if s[i] notin {'A'..'Z','0'..'9','_'}: return i
      inc i
    -1

  proc scanNonDigitAvx2*(s: string, start, stop: int): int =
    ## Find first byte NOT in \d — end-of-digit-run scan.
    var i = start
    while i + 32 <= stop:
      let chunk = mm256_loadu_si256(cast[ptr M256i](unsafeAddr s[i]))
      let mDi = rangeMask32(chunk, '0', 9)
      let inv = mm256_andnot_si256(mDi, mm256_set1_epi8(cast[int8](-1)))
      let mask = cast[uint32](mm256_movemask_epi8(inv))
      if mask != 0: return i + countTrailingZeroBits(mask)
      i += 32
    while i + 16 <= stop:
      let chunk = mm_loadu_si128(cast[ptr M128i](unsafeAddr s[i]))
      let mDi = rangeMask16(chunk, '0', 9)
      let inv = mm_andnot_si128(mDi, mm_set1_epi8(cast[int8](-1)))
      let mask = cast[uint32](mm_movemask_epi8(inv))
      if mask != 0: return i + countTrailingZeroBits(mask)
      i += 16
    while i < stop:
      if s[i] notin {'0'..'9'}: return i
      inc i
    -1

  proc scanNonSpaceAvx2*(s: string, start, stop: int): int =
    ## Find first byte NOT in \s — end-of-whitespace run scan.
    var i = start
    while i + 32 <= stop:
      let chunk = mm256_loadu_si256(cast[ptr M256i](unsafeAddr s[i]))
      let mSp = mm256_cmpeq_epi8(chunk, mm256_set1_epi8(cast[int8](' ')))
      let mTb = mm256_cmpeq_epi8(chunk, mm256_set1_epi8(cast[int8]('\t')))
      let mNl = mm256_cmpeq_epi8(chunk, mm256_set1_epi8(cast[int8]('\n')))
      let mCr = mm256_cmpeq_epi8(chunk, mm256_set1_epi8(cast[int8]('\r')))
      let mFf = mm256_cmpeq_epi8(chunk, mm256_set1_epi8(cast[int8]('\f')))
      let mVt = mm256_cmpeq_epi8(chunk, mm256_set1_epi8(cast[int8]('\v')))
      let wsMask = mm256_or_si256(mm256_or_si256(mSp, mTb), mm256_or_si256(mNl, mCr))
      let wsAll  = mm256_or_si256(wsMask, mm256_or_si256(mFf, mVt))
      let inv = mm256_andnot_si256(wsAll, mm256_set1_epi8(cast[int8](-1)))
      let mask = cast[uint32](mm256_movemask_epi8(inv))
      if mask != 0: return i + countTrailingZeroBits(mask)
      i += 32
    while i + 16 <= stop:
      let chunk = mm_loadu_si128(cast[ptr M128i](unsafeAddr s[i]))
      let mSp = mm_cmpeq_epi8(chunk, mm_set1_epi8(cast[int8](' ')))
      let mTb = mm_cmpeq_epi8(chunk, mm_set1_epi8(cast[int8]('\t')))
      let mNl = mm_cmpeq_epi8(chunk, mm_set1_epi8(cast[int8]('\n')))
      let mCr = mm_cmpeq_epi8(chunk, mm_set1_epi8(cast[int8]('\r')))
      let mFf = mm_cmpeq_epi8(chunk, mm_set1_epi8(cast[int8]('\f')))
      let mVt = mm_cmpeq_epi8(chunk, mm_set1_epi8(cast[int8]('\v')))
      let wsMask = mm_or_si128(mm_or_si128(mSp, mTb), mm_or_si128(mNl, mCr))
      let wsAll  = mm_or_si128(wsMask, mm_or_si128(mFf, mVt))
      let inv = mm_andnot_si128(wsAll, mm_set1_epi8(cast[int8](-1)))
      let mask = cast[uint32](mm_movemask_epi8(inv))
      if mask != 0: return i + countTrailingZeroBits(mask)
      i += 16
    while i < stop:
      if s[i] notin {' ','\t','\n','\r','\f','\v'}: return i
      inc i
    -1

# ---------------------------------------------------------------------------
# Unified dispatch
# ---------------------------------------------------------------------------

proc scanByte*(s: string, start, stop: int, b: char): int {.inline.} =
  when hasSse2: scanByteSse2(s, start, stop, b)
  else:         scanByteScalar(s, start, stop, b)

proc scanByteRange*(s: string, start, stop: int, lo, hi: char): int {.inline.} =
  when hasSse2: scanByteRangeSse2(s, start, stop, lo, hi)
  else:         scanByteSetScalar(s, start, stop, lo, hi)

proc scanAnyOf*(s: string, start, stop: int, a, b: char): int {.inline.} =
  when hasSse2: scanAnyOfSse2(s, start, stop, a, b)
  else:         scanAnyOfScalar(s, start, stop, a, b)

proc scanAlphaUnderscore*(s: string, start, stop: int): int {.inline.} =
  when hasAvx2: scanAlphaUnderscoreAvx2(s, start, stop)
  elif hasSse2: scanAlphaUnderscoreSse2(s, start, stop)
  else:         scanAlphaUnderscoreScalar(s, start, stop)

proc scanWordChar*(s: string, start, stop: int): int {.inline.} =
  when hasAvx2: scanWordCharAvx2(s, start, stop)
  elif hasSse2: scanWordCharSse2(s, start, stop)
  else:         scanWordCharScalar(s, start, stop)

proc scanNonWordChar*(s: string, start, stop: int): int {.inline.} =
  when hasAvx2: scanNonWordCharAvx2(s, start, stop)
  elif hasSse2: scanNonWordCharSse2(s, start, stop)
  else:         scanNonWordCharScalar(s, start, stop)

proc scanNonAlphaUnder*(s: string, start, stop: int): int {.inline.} =
  when hasAvx2: scanNonAlphaUnderAvx2(s, start, stop)
  elif hasSse2: scanNonAlphaUnderSse2(s, start, stop)
  else:         scanNonAlphaUnderScalar(s, start, stop)

proc scanUpperDigitUnder*(s: string, start, stop: int): int {.inline.} =
  when hasAvx2: scanUpperDigitUnderAvx2(s, start, stop)
  elif hasSse2: scanUpperDigitUnderSse2(s, start, stop)
  else:         scanUpperDigitUnderScalar(s, start, stop)

proc scanNonUpperDigitUnder*(s: string, start, stop: int): int {.inline.} =
  when hasAvx2: scanNonUpperDigitUnderAvx2(s, start, stop)
  elif hasSse2: scanNonUpperDigitUnderSse2(s, start, stop)
  else:         scanNonUpperDigitUnderScalar(s, start, stop)

proc scanNonDigit*(s: string, start, stop: int): int {.inline.} =
  when hasAvx2: scanNonDigitAvx2(s, start, stop)
  elif hasSse2: scanNonDigitSse2(s, start, stop)
  else:         scanNonDigitScalar(s, start, stop)

proc scanNonSpace*(s: string, start, stop: int): int {.inline.} =
  when hasAvx2: scanNonSpaceAvx2(s, start, stop)
  elif hasSse2: scanNonSpaceSse2(s, start, stop)
  else:         scanNonSpaceScalar(s, start, stop)