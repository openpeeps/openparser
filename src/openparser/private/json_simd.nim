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

proc scanStringEndScalar*(p: ptr char, start, stop: int): int {.inline.} =
  let s = cast[cstring](p)
  for i in start ..< stop:
    let c = s[i]
    if c == '"' or c == '\\':
      return i
  -1

proc scanWhitespaceRunScalar*(p: ptr char, start, stop: int): (int, int, int) {.inline.} =
  let s = cast[cstring](p)
  var i = start
  var nlCount = 0
  var lastNL = -1
  while i < stop:
    let c = s[i]
    if c notin {' ', '\t', '\n', '\r'}:
      break
    if c == '\n':
      nlCount += 1
      lastNL = i
    i += 1
  (i, nlCount, lastNL)

# ---------------------------------------------------------------------------
# SSE2 paths
# ---------------------------------------------------------------------------

when hasSse2:
  proc scanStringEndSse2*(p: ptr char, start, stop: int): int =
    let dq = mm_set1_epi8(cast[int8]('"'))
    let bs = mm_set1_epi8(cast[int8]('\\'))
    let buf = cast[ptr UncheckedArray[char]](p)
    var i = start
    while i + 16 <= stop:
      let chunk = mm_loadu_si128(cast[ptr M128i](addr buf[i]))
      let mask = mm_movemask_epi8(
        mm_or_si128(mm_cmpeq_epi8(chunk, dq),
                    mm_cmpeq_epi8(chunk, bs)))
      if mask != 0:
        return i + countTrailingZeroBits(cast[uint32](mask))
      i += 16
    for j in i ..< stop:
      if buf[j] == '"' or buf[j] == '\\':
        return j
    -1

  proc scanWhitespaceRunSse2*(p: ptr char, start, stop: int): (int, int, int) =
    let buf = cast[ptr UncheckedArray[char]](p)
    var i = start
    var nlCount = 0
    var lastNL = -1
    while i + 16 <= stop:
      let chunk = mm_loadu_si128(cast[ptr M128i](addr buf[i]))
      let sp = mm_set1_epi8(cast[int8](' '))
      let tb = mm_set1_epi8(cast[int8]('\t'))
      let nl = mm_set1_epi8(cast[int8]('\n'))
      let cr = mm_set1_epi8(cast[int8]('\r'))
      let notWs = mm_andnot_si128(
        mm_or_si128(mm_or_si128(mm_cmpeq_epi8(chunk, sp),
                                mm_cmpeq_epi8(chunk, tb)),
                    mm_or_si128(mm_cmpeq_epi8(chunk, nl),
                                mm_cmpeq_epi8(chunk, cr))),
        mm_set1_epi8(cast[int8](-1)))
      let bitset = mm_movemask_epi8(notWs)
      if bitset != 0:
        let tz = countTrailingZeroBits(cast[uint32](bitset))
        if tz > 0:
          let nlBits = mm_movemask_epi8(mm_cmpeq_epi8(chunk, nl)) and ((1 shl tz) - 1).int32
          let chunkNL = countSetBits(cast[uint32](nlBits))
          nlCount += chunkNL
          if chunkNL > 0:
            lastNL = i + 31 - countLeadingZeroBits(cast[uint32](nlBits))
        i += tz
        return (i, nlCount, lastNL)
      else:
        let nlBits = mm_movemask_epi8(mm_cmpeq_epi8(chunk, nl))
        let chunkNL = countSetBits(cast[uint32](nlBits))
        nlCount += chunkNL
        if chunkNL > 0:
          lastNL = i + 31 - countLeadingZeroBits(cast[uint32](nlBits))
        i += 16
    for j in i ..< stop:
      let c = buf[j]
      if c notin {' ', '\t', '\n', '\r'}:
        break
      if c == '\n':
        nlCount += 1
        lastNL = j
      i += 1
    (i, nlCount, lastNL)

# ---------------------------------------------------------------------------
# AVX2 paths
# ---------------------------------------------------------------------------

when hasAvx2:
  proc scanStringEndAvx2*(p: ptr char, start, stop: int): int =
    let dq = mm256_set1_epi8(cast[int8]('"'))
    let bs = mm256_set1_epi8(cast[int8]('\\'))
    let buf = cast[ptr UncheckedArray[char]](p)
    var i = start
    while i + 32 <= stop:
      let chunk = mm256_loadu_si256(cast[ptr M256i](addr buf[i]))
      let mask = cast[uint32](mm256_movemask_epi8(
        mm256_or_si256(mm256_cmpeq_epi8(chunk, dq),
                       mm256_cmpeq_epi8(chunk, bs))))
      if mask != 0:
        return i + countTrailingZeroBits(mask)
      i += 32
    while i + 16 <= stop:
      let chunk = mm_loadu_si128(cast[ptr M128i](addr buf[i]))
      let mask = mm_movemask_epi8(
        mm_or_si128(mm_cmpeq_epi8(chunk, mm_set1_epi8(cast[int8]('"'))),
                    mm_cmpeq_epi8(chunk, mm_set1_epi8(cast[int8]('\\')))))
      if mask != 0:
        return i + countTrailingZeroBits(cast[uint32](mask))
      i += 16
    for j in i ..< stop:
      if buf[j] == '"' or buf[j] == '\\':
        return j
    -1

  proc scanWhitespaceRunAvx2*(p: ptr char, start, stop: int): (int, int, int) =
    let buf = cast[ptr UncheckedArray[char]](p)
    var i = start
    var nlCount = 0
    var lastNL = -1
    while i + 32 <= stop:
      let chunk = mm256_loadu_si256(cast[ptr M256i](addr buf[i]))
      let sp = mm256_set1_epi8(cast[int8](' '))
      let tb = mm256_set1_epi8(cast[int8]('\t'))
      let nl = mm256_set1_epi8(cast[int8]('\n'))
      let cr = mm256_set1_epi8(cast[int8]('\r'))
      let notWs = mm256_andnot_si256(
        mm256_or_si256(mm256_or_si256(mm256_cmpeq_epi8(chunk, sp),
                                      mm256_cmpeq_epi8(chunk, tb)),
                       mm256_or_si256(mm256_cmpeq_epi8(chunk, nl),
                                      mm256_cmpeq_epi8(chunk, cr))),
        mm256_set1_epi8(cast[int8](-1)))
      let bitset = cast[uint32](mm256_movemask_epi8(notWs))
      if bitset != 0:
        let tz = countTrailingZeroBits(bitset)
        if tz > 0:
          let nlBits = cast[uint32](mm256_movemask_epi8(mm256_cmpeq_epi8(chunk, nl))) and ((1'u32 shl tz) - 1)
          let chunkNL = countSetBits(nlBits)
          nlCount += chunkNL
          if chunkNL > 0:
            lastNL = i + 31 - countLeadingZeroBits(nlBits)
        i += tz
        return (i, nlCount, lastNL)
      else:
        let nlBits = cast[uint32](mm256_movemask_epi8(mm256_cmpeq_epi8(chunk, nl)))
        let chunkNL = countSetBits(nlBits)
        nlCount += chunkNL
        if chunkNL > 0:
          lastNL = i + 31 - countLeadingZeroBits(nlBits)
        i += 32
    while i + 16 <= stop:
      let chunk = mm_loadu_si128(cast[ptr M128i](addr buf[i]))
      let sp = mm_set1_epi8(cast[int8](' '))
      let tb = mm_set1_epi8(cast[int8]('\t'))
      let nl = mm_set1_epi8(cast[int8]('\n'))
      let cr = mm_set1_epi8(cast[int8]('\r'))
      let notWs = mm_andnot_si128(
        mm_or_si128(mm_or_si128(mm_cmpeq_epi8(chunk, sp),
                                mm_cmpeq_epi8(chunk, tb)),
                    mm_or_si128(mm_cmpeq_epi8(chunk, nl),
                                mm_cmpeq_epi8(chunk, cr))),
        mm_set1_epi8(cast[int8](-1)))
      let bitset = mm_movemask_epi8(notWs)
      if bitset != 0:
        let tz = countTrailingZeroBits(cast[uint32](bitset))
        if tz > 0:
          let nlBits = mm_movemask_epi8(mm_cmpeq_epi8(chunk, nl)) and ((1 shl tz) - 1).int32
          let chunkNL = countSetBits(cast[uint32](nlBits))
          nlCount += chunkNL
          if chunkNL > 0:
            lastNL = i + 31 - countLeadingZeroBits(cast[uint32](nlBits))
        i += tz
        return (i, nlCount, lastNL)
      else:
        let nlBits = mm_movemask_epi8(mm_cmpeq_epi8(chunk, nl))
        let chunkNL = countSetBits(cast[uint32](nlBits))
        nlCount += chunkNL
        if chunkNL > 0:
          lastNL = i + 31 - countLeadingZeroBits(cast[uint32](nlBits))
        i += 16
    for j in i ..< stop:
      let c = buf[j]
      if c notin {' ', '\t', '\n', '\r'}:
        break
      if c == '\n':
        nlCount += 1
        lastNL = j
      i += 1
    (i, nlCount, lastNL)

# ---------------------------------------------------------------------------
# Unified dispatch
# ---------------------------------------------------------------------------

proc scanStringEnd*(p: ptr char, start, stop: int): int {.inline.} =
  when hasAvx2: scanStringEndAvx2(p, start, stop)
  elif hasSse2: scanStringEndSse2(p, start, stop)
  else:         scanStringEndScalar(p, start, stop)

proc scanWhitespaceRun*(p: ptr char, start, stop: int): (int, int, int) {.inline.} =
  when hasAvx2: scanWhitespaceRunAvx2(p, start, stop)
  elif hasSse2: scanWhitespaceRunSse2(p, start, stop)
  else:         scanWhitespaceRunScalar(p, start, stop)
