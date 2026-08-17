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

proc scanTextRunScalar*(p: ptr char, start, stop: int): int {.inline.} =
  let s = cast[cstring](p)
  for i in start ..< stop:
    let c = s[i]
    if c == '<' or c == '&':
      return i
  -1

proc scanAttrValueEndScalar*(p: ptr char, start, stop: int, quote: char): int {.inline.} =
  let s = cast[cstring](p)
  for i in start ..< stop:
    let c = s[i]
    if c == quote or c == '&':
      return i
  -1

proc scanNameEndScalar*(p: ptr char, start, stop: int): int {.inline.} =
  let s = cast[cstring](p)
  for i in start ..< stop:
    let c = s[i]
    if c notin {'a'..'z', 'A'..'Z', '0'..'9', '-', '_', '.', ':'}:
      return i
  -1

# ---------------------------------------------------------------------------
# SSE2 paths
# ---------------------------------------------------------------------------

when hasSse2:
  proc scanTextRunSse2*(p: ptr char, start, stop: int): int =
    let lt = mm_set1_epi8(cast[int8]('<'))
    let am = mm_set1_epi8(cast[int8]('&'))
    let buf = cast[ptr UncheckedArray[char]](p)
    var i = start
    while i + 16 <= stop:
      let chunk = mm_loadu_si128(cast[ptr M128i](addr buf[i]))
      let mask = mm_movemask_epi8(
        mm_or_si128(mm_cmpeq_epi8(chunk, lt),
                     mm_cmpeq_epi8(chunk, am)))
      if mask != 0:
        return i + countTrailingZeroBits(cast[uint32](mask))
      i += 16
    for j in i ..< stop:
      if buf[j] == '<' or buf[j] == '&':
        return j
    -1

  proc scanAttrValueEndSse2*(p: ptr char, start, stop: int, quote: char): int =
    let q = mm_set1_epi8(cast[int8](quote))
    let am = mm_set1_epi8(cast[int8]('&'))
    let buf = cast[ptr UncheckedArray[char]](p)
    var i = start
    while i + 16 <= stop:
      let chunk = mm_loadu_si128(cast[ptr M128i](addr buf[i]))
      let mask = mm_movemask_epi8(
        mm_or_si128(mm_cmpeq_epi8(chunk, q),
                     mm_cmpeq_epi8(chunk, am)))
      if mask != 0:
        return i + countTrailingZeroBits(cast[uint32](mask))
      i += 16
    for j in i ..< stop:
      if buf[j] == quote or buf[j] == '&':
        return j
    -1

  proc scanNameEndSse2*(p: ptr char, start, stop: int): int =
    # Name chars: a-z A-Z 0-9 - _ . : — build a SIMD mask
    let buf = cast[ptr UncheckedArray[char]](p)
    let lo  = mm_set1_epi8(cast[int8]('a'))
    let hi  = mm_set1_epi8(cast[int8]('z'))
    let Lo  = mm_set1_epi8(cast[int8]('A'))
    let Hi  = mm_set1_epi8(cast[int8]('Z'))
    let d0  = mm_set1_epi8(cast[int8]('0'))
    let d9  = mm_set1_epi8(cast[int8]('9'))
    let dash = mm_set1_epi8(cast[int8]('-'))
    let und = mm_set1_epi8(cast[int8]('_'))
    let dot = mm_set1_epi8(cast[int8]('.'))
    let col = mm_set1_epi8(cast[int8](':'))
    var i = start
    while i + 16 <= stop:
      let chunk = mm_loadu_si128(cast[ptr M128i](addr buf[i]))
      let isAlpha = mm_or_si128(
        mm_and_si128(mm_cmpgt_epi8(chunk, mm_sub_epi8(lo, mm_set1_epi8(1))),
                      mm_cmplt_epi8(chunk, mm_add_epi8(hi, mm_set1_epi8(1)))),
        mm_and_si128(mm_cmpgt_epi8(chunk, mm_sub_epi8(Lo, mm_set1_epi8(1))),
                      mm_cmplt_epi8(chunk, mm_add_epi8(Hi, mm_set1_epi8(1)))))
      let isDigit = mm_and_si128(
        mm_cmpgt_epi8(chunk, mm_sub_epi8(d0, mm_set1_epi8(1))),
        mm_cmplt_epi8(chunk, mm_add_epi8(d9, mm_set1_epi8(1))))
      let isName = mm_or_si128(
        mm_or_si128(isAlpha, isDigit),
        mm_or_si128(mm_or_si128(mm_cmpeq_epi8(chunk, dash), mm_cmpeq_epi8(chunk, und)),
                     mm_or_si128(mm_cmpeq_epi8(chunk, dot), mm_cmpeq_epi8(chunk, col))))
      let notName = mm_andnot_si128(isName, mm_set1_epi8(cast[int8](-1)))
      let bitset = mm_movemask_epi8(notName)
      if bitset != 0:
        return i + countTrailingZeroBits(cast[uint32](bitset))
      i += 16
    for j in i ..< stop:
      if buf[j] notin {'a'..'z', 'A'..'Z', '0'..'9', '-', '_', '.', ':'}:
        return j
    -1

# ---------------------------------------------------------------------------
# AVX2 paths
# ---------------------------------------------------------------------------

when hasAvx2:
  proc scanTextRunAvx2*(p: ptr char, start, stop: int): int =
    let lt = mm256_set1_epi8(cast[int8]('<'))
    let am = mm256_set1_epi8(cast[int8]('&'))
    let buf = cast[ptr UncheckedArray[char]](p)
    var i = start
    while i + 32 <= stop:
      let chunk = mm256_loadu_si256(cast[ptr M256i](addr buf[i]))
      let mask = cast[uint32](mm256_movemask_epi8(
        mm256_or_si256(mm256_cmpeq_epi8(chunk, lt),
                       mm256_cmpeq_epi8(chunk, am))))
      if mask != 0:
        return i + countTrailingZeroBits(mask)
      i += 32
    while i + 16 <= stop:
      let chunk = mm_loadu_si128(cast[ptr M128i](addr buf[i]))
      let mask = mm_movemask_epi8(
        mm_or_si128(mm_cmpeq_epi8(chunk, mm_set1_epi8(cast[int8]('<'))),
                     mm_cmpeq_epi8(chunk, mm_set1_epi8(cast[int8]('&')))))
      if mask != 0:
        return i + countTrailingZeroBits(cast[uint32](mask))
      i += 16
    for j in i ..< stop:
      if buf[j] == '<' or buf[j] == '&':
        return j
    -1

  proc scanAttrValueEndAvx2*(p: ptr char, start, stop: int, quote: char): int =
    let q = mm256_set1_epi8(cast[int8](quote))
    let am = mm256_set1_epi8(cast[int8]('&'))
    let buf = cast[ptr UncheckedArray[char]](p)
    var i = start
    while i + 32 <= stop:
      let chunk = mm256_loadu_si256(cast[ptr M256i](addr buf[i]))
      let mask = cast[uint32](mm256_movemask_epi8(
        mm256_or_si256(mm256_cmpeq_epi8(chunk, q),
                       mm256_cmpeq_epi8(chunk, am))))
      if mask != 0:
        return i + countTrailingZeroBits(mask)
      i += 32
    while i + 16 <= stop:
      let chunk = mm_loadu_si128(cast[ptr M128i](addr buf[i]))
      let mask = mm_movemask_epi8(
        mm_or_si128(mm_cmpeq_epi8(chunk, mm_set1_epi8(cast[int8](quote))),
                     mm_cmpeq_epi8(chunk, mm_set1_epi8(cast[int8]('&')))))
      if mask != 0:
        return i + countTrailingZeroBits(cast[uint32](mask))
      i += 16
    for j in i ..< stop:
      if buf[j] == quote or buf[j] == '&':
        return j
    -1

  proc scanNameEndAvx2*(p: ptr char, start, stop: int): int =
    let buf = cast[ptr UncheckedArray[char]](p)
    let lo  = mm256_set1_epi8(cast[int8]('a'))
    let hi  = mm256_set1_epi8(cast[int8]('z'))
    let Lo  = mm256_set1_epi8(cast[int8]('A'))
    let Hi  = mm256_set1_epi8(cast[int8]('Z'))
    let d0  = mm256_set1_epi8(cast[int8]('0'))
    let d9  = mm256_set1_epi8(cast[int8]('9'))
    let dash = mm256_set1_epi8(cast[int8]('-'))
    let und = mm256_set1_epi8(cast[int8]('_'))
    let dot = mm256_set1_epi8(cast[int8]('.'))
    let col = mm256_set1_epi8(cast[int8](':'))
    let one = mm256_set1_epi8(1)
    var i = start
    while i + 32 <= stop:
      let chunk = mm256_loadu_si256(cast[ptr M256i](addr buf[i]))
      let isAlpha = mm256_or_si256(
        mm256_and_si256(mm256_cmpgt_epi8(chunk, mm256_sub_epi8(lo, one)),
                         mm256_cmplt_epi8(chunk, mm256_add_epi8(hi, one))),
        mm256_and_si256(mm256_cmpgt_epi8(chunk, mm256_sub_epi8(Lo, one)),
                         mm256_cmplt_epi8(chunk, mm256_add_epi8(Hi, one))))
      let isDigit = mm256_and_si256(
        mm256_cmpgt_epi8(chunk, mm256_sub_epi8(d0, one)),
        mm256_cmplt_epi8(chunk, mm256_add_epi8(d9, one)))
      let isName = mm256_or_si256(
        mm256_or_si256(isAlpha, isDigit),
        mm256_or_si256(mm256_or_si256(mm256_cmpeq_epi8(chunk, dash), mm256_cmpeq_epi8(chunk, und)),
                       mm256_or_si256(mm256_cmpeq_epi8(chunk, dot), mm256_cmpeq_epi8(chunk, col))))
      let notName = mm256_andnot_si256(isName, mm256_set1_epi8(cast[int8](-1)))
      let bitset = cast[uint32](mm256_movemask_epi8(notName))
      if bitset != 0:
        return i + countTrailingZeroBits(bitset)
      i += 32
    # Tail with SSE2
    while i + 16 <= stop:
      let chunk = mm_loadu_si128(cast[ptr M128i](addr buf[i]))
      let lo128 = mm_set1_epi8(cast[int8]('a'))
      let hi128 = mm_set1_epi8(cast[int8]('z'))
      let Lo128 = mm_set1_epi8(cast[int8]('A'))
      let Hi128 = mm_set1_epi8(cast[int8]('Z'))
      let d0128 = mm_set1_epi8(cast[int8]('0'))
      let d9128 = mm_set1_epi8(cast[int8]('9'))
      let dash128 = mm_set1_epi8(cast[int8]('-'))
      let und128 = mm_set1_epi8(cast[int8]('_'))
      let dot128 = mm_set1_epi8(cast[int8]('.'))
      let col128 = mm_set1_epi8(cast[int8](':'))
      let one128 = mm_set1_epi8(1)
      let isAlpha = mm_or_si128(
        mm_and_si128(mm_cmpgt_epi8(chunk, mm_sub_epi8(lo128, one128)),
                      mm_cmplt_epi8(chunk, mm_add_epi8(hi128, one128))),
        mm_and_si128(mm_cmpgt_epi8(chunk, mm_sub_epi8(Lo128, one128)),
                      mm_cmplt_epi8(chunk, mm_add_epi8(Hi128, one128))))
      let isDigit = mm_and_si128(
        mm_cmpgt_epi8(chunk, mm_sub_epi8(d0128, one128)),
        mm_cmplt_epi8(chunk, mm_add_epi8(d9128, one128)))
      let isName = mm_or_si128(
        mm_or_si128(isAlpha, isDigit),
        mm_or_si128(mm_or_si128(mm_cmpeq_epi8(chunk, dash128), mm_cmpeq_epi8(chunk, und128)),
                     mm_or_si128(mm_cmpeq_epi8(chunk, dot128), mm_cmpeq_epi8(chunk, col128))))
      let notName = mm_andnot_si128(isName, mm_set1_epi8(cast[int8](-1)))
      let bitset = mm_movemask_epi8(notName)
      if bitset != 0:
        return i + countTrailingZeroBits(cast[uint32](bitset))
      i += 16
    for j in i ..< stop:
      if buf[j] notin {'a'..'z', 'A'..'Z', '0'..'9', '-', '_', '.', ':'}:
        return j
    -1

# ---------------------------------------------------------------------------
# Unified dispatch
# ---------------------------------------------------------------------------

proc scanTextRun*(p: ptr char, start, stop: int): int {.inline.} =
  when hasAvx2: scanTextRunAvx2(p, start, stop)
  elif hasSse2: scanTextRunSse2(p, start, stop)
  else:         scanTextRunScalar(p, start, stop)

proc scanAttrValueEnd*(p: ptr char, start, stop: int, quote: char): int {.inline.} =
  when hasAvx2: scanAttrValueEndAvx2(p, start, stop, quote)
  elif hasSse2: scanAttrValueEndSse2(p, start, stop, quote)
  else:         scanAttrValueEndScalar(p, start, stop, quote)

proc scanNameEnd*(p: ptr char, start, stop: int): int {.inline.} =
  when hasAvx2: scanNameEndAvx2(p, start, stop)
  elif hasSse2: scanNameEndSse2(p, start, stop)
  else:         scanNameEndScalar(p, start, stop)
