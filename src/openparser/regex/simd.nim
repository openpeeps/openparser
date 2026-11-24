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
  const hasNeon* = false
elif defined(arm64):
  import nimsimd/neon
  const hasSse2* = false
  const hasAvx2* = false
  const hasNeon* = true
else:
  const hasSse2* = false
  const hasAvx2* = false
  const hasNeon* = false

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

proc scanAnyOfNScalar*(s: string, start, stop: int,
                       needles: openArray[char]): int {.inline.} =
  ## First position holding any of `needles`.
  for i in start ..< stop:
    for b in needles:
      if s[i] == b: return i
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

  proc scanAnyOfNSse2*(s: string, start, stop: int,
                       needles: openArray[char]): int =
    ## First position holding any of `needles` (cap 8: the prefilter
    ## never builds larger sets). One broadcast per needle up front,
    ## then an OR-tree of compares per 16-byte chunk.
    let n = min(needles.len, 8)
    if n == 0: return -1
    var vecs: array[8, M128i]
    for k in 0 ..< n:
      vecs[k] = mm_set1_epi8(cast[int8](needles[k]))
    var i = start
    while i + 16 <= stop:
      let chunk = mm_loadu_si128(cast[ptr M128i](unsafeAddr s[i]))
      var acc = mm_cmpeq_epi8(chunk, vecs[0])
      for k in 1 ..< n:
        acc = mm_or_si128(acc, mm_cmpeq_epi8(chunk, vecs[k]))
      let mask = mm_movemask_epi8(acc)
      if mask != 0: return i + countTrailingZeroBits(cast[uint32](mask))
      i += 16
    while i < stop:
      for b in needles:
        if s[i] == b: return i
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
# NEON paths (16 bytes / cycle) — compiled only on AArch64
# ---------------------------------------------------------------------------

when hasNeon:
  # Lane-bit table for movemaskNeon: loaded once per scan call.
  let neonBitMask = [1'u8, 2, 4, 8, 16, 32, 64, 128,
                     1'u8, 2, 4, 8, 16, 32, 64, 128]

  proc movemaskNeon(v: uint8x16): uint32 {.inline.} =
    ## Collapse a 0xFF/0x00 lane mask to a 16-bit bitmask (lane i → bit i).
    ## vand keeps each lane's distinct bit, then two vpadds fold the
    ## disjoint bits down (addition == OR: no two set bits overlap).
    let bits = vandq_u8(v, vld1q_u8(cast[pointer](unsafeAddr neonBitMask[0])))
    let pairs = vpadd_u8(vget_low_u8(bits), vget_high_u8(bits))
    let quads = vpadd_u8(pairs, pairs)
    let w = vget_lane_u32(vreinterpret_u32_u8(quads), 0)
    let lo = (w and 0xFF'u32) + ((w shr 8) and 0xFF'u32)
    let hi = ((w shr 16) and 0xFF'u32) + ((w shr 24) and 0xFF'u32)
    lo or (hi shl 8)

  proc rangeMaskNeon(chunk: uint8x16, lo: char, span: int): uint8x16 =
    let loV = vmovq_n_u8(uint8(ord(lo)))
    let spV = vmovq_n_u8(uint8(span))
    let d   = vsubq_u8(chunk, loV)          ## wrapping, not saturating
    vmvnq_u8(vcltq_u8(spV, d))              ## NOT(span < d) ⟺ d <= span

  proc scanByteNeon*(s: string, start, stop: int, b: char): int =
    let bVec = vmovq_n_u8(uint8(ord(b)))
    var i = start
    while i + 16 <= stop:
      let chunk = vld1q_u8(cast[pointer](unsafeAddr s[i]))
      let m = vceqq_u8(chunk, bVec)
      if vmaxvq_u8(m) != 0:
        let mask = movemaskNeon(m)
        return i + countTrailingZeroBits(mask)
      i += 16
    while i < stop:
      if s[i] == b: return i
      inc i
    -1

  proc scanByteRangeNeon*(s: string, start, stop: int, lo, hi: char): int =
    var i = start
    while i + 16 <= stop:
      let chunk = vld1q_u8(cast[pointer](unsafeAddr s[i]))
      let m = rangeMaskNeon(chunk, lo, ord(hi) - ord(lo))
      if vmaxvq_u8(m) != 0:
        let mask = movemaskNeon(m)
        return i + countTrailingZeroBits(mask)
      i += 16
    while i < stop:
      if s[i] >= lo and s[i] <= hi: return i
      inc i
    -1

  proc scanAnyOfNeon*(s: string, start, stop: int, a, b: char): int =
    let va = vmovq_n_u8(uint8(ord(a)))
    let vb = vmovq_n_u8(uint8(ord(b)))
    var i = start
    while i + 16 <= stop:
      let chunk = vld1q_u8(cast[pointer](unsafeAddr s[i]))
      let m = vorrq_u8(vceqq_u8(chunk, va), vceqq_u8(chunk, vb))
      if vmaxvq_u8(m) != 0:
        let mask = movemaskNeon(m)
        return i + countTrailingZeroBits(mask)
      i += 16
    while i < stop:
      if s[i] == a or s[i] == b: return i
      inc i
    -1

  proc scanAnyOfNNeon*(s: string, start, stop: int,
                       needles: openArray[char]): int =
    let n = min(needles.len, 8)
    if n == 0: return -1
    var vecs: array[8, uint8x16]
    for k in 0 ..< n:
      vecs[k] = vmovq_n_u8(uint8(ord(needles[k])))
    var i = start
    while i + 16 <= stop:
      let chunk = vld1q_u8(cast[pointer](unsafeAddr s[i]))
      var acc = vceqq_u8(chunk, vecs[0])
      for k in 1 ..< n:
        acc = vorrq_u8(acc, vceqq_u8(chunk, vecs[k]))
      if vmaxvq_u8(acc) != 0:
        let mask = movemaskNeon(acc)
        return i + countTrailingZeroBits(mask)
      i += 16
    while i < stop:
      for b in needles:
        if s[i] == b: return i
      inc i
    -1

  proc wordCharMaskNeon(chunk: uint8x16): uint8x16 {.inline.} =
    ## Returns a mask where bytes that ARE \w are 0xFF.
    let mLo = rangeMaskNeon(chunk, 'a', 25)
    let mUp = rangeMaskNeon(chunk, 'A', 25)
    let mDi = rangeMaskNeon(chunk, '0', 9)
    let mUs = vceqq_u8(chunk, vmovq_n_u8(uint8(ord('_'))))
    vorrq_u8(vorrq_u8(mLo, mUp), vorrq_u8(mDi, mUs))

  proc alphaUnderMaskNeon(chunk: uint8x16): uint8x16 {.inline.} =
    ## Returns mask where bytes that ARE [a-zA-Z_] are 0xFF.
    let mLo = rangeMaskNeon(chunk, 'a', 25)
    let mUp = rangeMaskNeon(chunk, 'A', 25)
    let mUs = vceqq_u8(chunk, vmovq_n_u8(uint8(ord('_'))))
    vorrq_u8(vorrq_u8(mLo, mUp), mUs)

  proc upperDigitUnderMaskNeon(chunk: uint8x16): uint8x16 {.inline.} =
    let mUp = rangeMaskNeon(chunk, 'A', 25)
    let mDi = rangeMaskNeon(chunk, '0', 9)
    let mUs = vceqq_u8(chunk, vmovq_n_u8(uint8(ord('_'))))
    vorrq_u8(vorrq_u8(mUp, mDi), mUs)

  proc scanAlphaUnderscoreNeon*(s: string, start, stop: int): int =
    var i = start
    while i + 16 <= stop:
      let chunk = vld1q_u8(cast[pointer](unsafeAddr s[i]))
      let m = alphaUnderMaskNeon(chunk)
      if vmaxvq_u8(m) != 0:
        let mask = movemaskNeon(m)
        return i + countTrailingZeroBits(mask)
      i += 16
    while i < stop:
      if s[i] in {'a'..'z','A'..'Z','_'}: return i
      inc i
    -1

  proc scanWordCharNeon*(s: string, start, stop: int): int =
    var i = start
    while i + 16 <= stop:
      let chunk = vld1q_u8(cast[pointer](unsafeAddr s[i]))
      let m = wordCharMaskNeon(chunk)
      if vmaxvq_u8(m) != 0:
        let mask = movemaskNeon(m)
        return i + countTrailingZeroBits(mask)
      i += 16
    while i < stop:
      if s[i] in {'a'..'z','A'..'Z','0'..'9','_'}: return i
      inc i
    -1

  proc scanNonWordCharNeon*(s: string, start, stop: int): int =
    ## Find first byte NOT in \w — marks end of an identifier run.
    var i = start
    while i + 16 <= stop:
      let chunk = vld1q_u8(cast[pointer](unsafeAddr s[i]))
      let m = vmvnq_u8(wordCharMaskNeon(chunk))
      if vmaxvq_u8(m) != 0:
        let mask = movemaskNeon(m)
        return i + countTrailingZeroBits(mask)
      i += 16
    while i < stop:
      if s[i] notin {'a'..'z','A'..'Z','0'..'9','_'}: return i
      inc i
    -1

  proc scanNonDigitNeon*(s: string, start, stop: int): int =
    ## Find first byte NOT in \d — end-of-digit-run scan.
    var i = start
    while i + 16 <= stop:
      let chunk = vld1q_u8(cast[pointer](unsafeAddr s[i]))
      let m = vmvnq_u8(rangeMaskNeon(chunk, '0', 9))
      if vmaxvq_u8(m) != 0:
        let mask = movemaskNeon(m)
        return i + countTrailingZeroBits(mask)
      i += 16
    while i < stop:
      if s[i] notin {'0'..'9'}: return i
      inc i
    -1

  proc scanNonSpaceNeon*(s: string, start, stop: int): int =
    ## Find first byte NOT in \s — end-of-whitespace run scan.
    let vSp = vmovq_n_u8(uint8(ord(' ')))
    let vTb = vmovq_n_u8(uint8(ord('\t')))
    let vNl = vmovq_n_u8(uint8(ord('\n')))
    let vCr = vmovq_n_u8(uint8(ord('\r')))
    let vFf = vmovq_n_u8(uint8(ord('\f')))
    let vVt = vmovq_n_u8(uint8(ord('\v')))
    var i = start
    while i + 16 <= stop:
      let chunk = vld1q_u8(cast[pointer](unsafeAddr s[i]))
      let mSp = vceqq_u8(chunk, vSp)
      let mTb = vceqq_u8(chunk, vTb)
      let mNl = vceqq_u8(chunk, vNl)
      let mCr = vceqq_u8(chunk, vCr)
      let mFf = vceqq_u8(chunk, vFf)
      let mVt = vceqq_u8(chunk, vVt)
      let wsMask = vorrq_u8(vorrq_u8(mSp, mTb), vorrq_u8(mNl, mCr))
      let wsAll  = vorrq_u8(wsMask, vorrq_u8(mFf, mVt))
      let m = vmvnq_u8(wsAll)
      if vmaxvq_u8(m) != 0:
        let mask = movemaskNeon(m)
        return i + countTrailingZeroBits(mask)
      i += 16
    while i < stop:
      if s[i] notin {' ','\t','\n','\r','\f','\v'}: return i
      inc i
    -1

  proc scanNonAlphaUnderNeon*(s: string, start, stop: int): int =
    var i = start
    while i + 16 <= stop:
      let chunk = vld1q_u8(cast[pointer](unsafeAddr s[i]))
      let m = vmvnq_u8(alphaUnderMaskNeon(chunk))
      if vmaxvq_u8(m) != 0:
        let mask = movemaskNeon(m)
        return i + countTrailingZeroBits(mask)
      i += 16
    while i < stop:
      if s[i] notin {'a'..'z','A'..'Z','_'}: return i
      inc i
    -1

  proc scanUpperDigitUnderNeon*(s: string, start, stop: int): int =
    var i = start
    while i + 16 <= stop:
      let chunk = vld1q_u8(cast[pointer](unsafeAddr s[i]))
      let m = upperDigitUnderMaskNeon(chunk)
      if vmaxvq_u8(m) != 0:
        let mask = movemaskNeon(m)
        return i + countTrailingZeroBits(mask)
      i += 16
    while i < stop:
      if s[i] in {'A'..'Z','0'..'9','_'}: return i
      inc i
    -1

  proc scanNonUpperDigitUnderNeon*(s: string, start, stop: int): int =
    var i = start
    while i + 16 <= stop:
      let chunk = vld1q_u8(cast[pointer](unsafeAddr s[i]))
      let m = vmvnq_u8(upperDigitUnderMaskNeon(chunk))
      if vmaxvq_u8(m) != 0:
        let mask = movemaskNeon(m)
        return i + countTrailingZeroBits(mask)
      i += 16
    while i < stop:
      if s[i] notin {'A'..'Z','0'..'9','_'}: return i
      inc i
    -1

# ---------------------------------------------------------------------------
# Unified dispatch
# ---------------------------------------------------------------------------

proc scanByte*(s: string, start, stop: int, b: char): int {.inline.} =
  when hasSse2: scanByteSse2(s, start, stop, b)
  elif hasNeon: scanByteNeon(s, start, stop, b)
  else:         scanByteScalar(s, start, stop, b)

proc scanByteRange*(s: string, start, stop: int, lo, hi: char): int {.inline.} =
  when hasSse2: scanByteRangeSse2(s, start, stop, lo, hi)
  elif hasNeon: scanByteRangeNeon(s, start, stop, lo, hi)
  else:         scanByteSetScalar(s, start, stop, lo, hi)

proc scanAnyOf*(s: string, start, stop: int, a, b: char): int {.inline.} =
  when hasSse2: scanAnyOfSse2(s, start, stop, a, b)
  elif hasNeon: scanAnyOfNeon(s, start, stop, a, b)
  else:         scanAnyOfScalar(s, start, stop, a, b)

proc scanAnyOfN*(s: string, start, stop: int,
                 needles: openArray[char]): int {.inline.} =
  when hasSse2: scanAnyOfNSse2(s, start, stop, needles)
  elif hasNeon: scanAnyOfNNeon(s, start, stop, needles)
  else:         scanAnyOfNScalar(s, start, stop, needles)

proc scanAlphaUnderscore*(s: string, start, stop: int): int {.inline.} =
  when hasAvx2: scanAlphaUnderscoreAvx2(s, start, stop)
  elif hasSse2: scanAlphaUnderscoreSse2(s, start, stop)
  elif hasNeon: scanAlphaUnderscoreNeon(s, start, stop)
  else:         scanAlphaUnderscoreScalar(s, start, stop)

proc scanWordChar*(s: string, start, stop: int): int {.inline.} =
  when hasAvx2: scanWordCharAvx2(s, start, stop)
  elif hasSse2: scanWordCharSse2(s, start, stop)
  elif hasNeon: scanWordCharNeon(s, start, stop)
  else:         scanWordCharScalar(s, start, stop)

proc scanNonWordChar*(s: string, start, stop: int): int {.inline.} =
  when hasAvx2: scanNonWordCharAvx2(s, start, stop)
  elif hasSse2: scanNonWordCharSse2(s, start, stop)
  elif hasNeon: scanNonWordCharNeon(s, start, stop)
  else:         scanNonWordCharScalar(s, start, stop)

proc scanNonAlphaUnder*(s: string, start, stop: int): int {.inline.} =
  when hasAvx2: scanNonAlphaUnderAvx2(s, start, stop)
  elif hasSse2: scanNonAlphaUnderSse2(s, start, stop)
  elif hasNeon: scanNonAlphaUnderNeon(s, start, stop)
  else:         scanNonAlphaUnderScalar(s, start, stop)

proc scanUpperDigitUnder*(s: string, start, stop: int): int {.inline.} =
  when hasAvx2: scanUpperDigitUnderAvx2(s, start, stop)
  elif hasSse2: scanUpperDigitUnderSse2(s, start, stop)
  elif hasNeon: scanUpperDigitUnderNeon(s, start, stop)
  else:         scanUpperDigitUnderScalar(s, start, stop)

proc scanNonUpperDigitUnder*(s: string, start, stop: int): int {.inline.} =
  when hasAvx2: scanNonUpperDigitUnderAvx2(s, start, stop)
  elif hasSse2: scanNonUpperDigitUnderSse2(s, start, stop)
  elif hasNeon: scanNonUpperDigitUnderNeon(s, start, stop)
  else:         scanNonUpperDigitUnderScalar(s, start, stop)

proc scanNonDigit*(s: string, start, stop: int): int {.inline.} =
  when hasAvx2: scanNonDigitAvx2(s, start, stop)
  elif hasSse2: scanNonDigitSse2(s, start, stop)
  elif hasNeon: scanNonDigitNeon(s, start, stop)
  else:         scanNonDigitScalar(s, start, stop)

proc scanNonSpace*(s: string, start, stop: int): int {.inline.} =
  when hasAvx2: scanNonSpaceAvx2(s, start, stop)
  elif hasSse2: scanNonSpaceSse2(s, start, stop)
  elif hasNeon: scanNonSpaceNeon(s, start, stop)
  else:         scanNonSpaceScalar(s, start, stop)