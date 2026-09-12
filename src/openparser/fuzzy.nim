# A collection of tiny parsers and dumpers
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/openparser

## SIMD-accelerated fuzzy (subsequence) search with fzf-style scoring.
##
## Every query character must appear in the candidate in order, but not
## necessarily contiguously. Matches are ranked by consecutive runs,
## word-boundary hits and gap penalties. The hot loop — forward character
## search — runs over SSE2 (x86 baseline), AVX2 (opt-in via `-d:avx2`),
## NEON (arm64, always available) or scalar lanes, selected per target at
## compile time with a runtime AVX2 guard. The matcher itself never
## allocates per candidate: case is folded on the fly and positions are
## collected only for reported matches.
##
## No unconditional C flags are set here on purpose: x86-only flags such
## as `-msse2` break clang on arm64 targets. AVX2 flags travel with
## `-d:avx2` from the caller's `.nims` file (see `tests/test_fuzzy.nims`).

import std/[algorithm, bitops, heapqueue]

when defined(amd64) or defined(i386):
  import nimsimd/sse2
  import nimsimd/runtimecheck
  when defined(avx2):
    import nimsimd/avx2
    const hasAvx2* = true
  else:
    const hasAvx2* = false
  const hasSse2* = true
  const hasNeon* = false
elif defined(arm64):
  import nimsimd/neon
  const hasNeon* = true
  const hasSse2* = false
  const hasAvx2* = false
else:
  const hasSse2* = false
  const hasAvx2* = false
  const hasNeon* = false

type
  FuzzyMatch* = object
    text*: string       ## candidate that matched
    score*: float32     ## higher ranks first; normalized by candidate length
    positions*: seq[int] ## byte offsets of the matched chars (highlighting)

  FuzzyOptions* = object
    caseSensitive*: bool  ## default false: ASCII case-insensitive
    limit*: int           ## keep only the top-N matches; <= 0 means no limit
    minScore*: float32    ## drop matches scoring below this (default 0.0)

  FuzzyError* = object of ValueError

const
  FuzzyScoreExact* = 16.0'f32        ## case-exact character hit
  FuzzyScoreFold* = 8.0'f32          ## case-folded character hit
  FuzzyBonusConsecutive* = 12.0'f32  ## per char continuing a run
  FuzzyBonusWordStart* = 10.0'f32    ## hit at pos 0, after a separator, camel hump
  FuzzyPenaltyGap* = 3.0'f32         ## per skipped byte between hits
  FuzzyPenaltyLeading* = 1.0'f32     ## per byte before the first hit

when defined(amd64):
  # Compiled with AVX2 but running on an older CPU must not execute
  # AVX2 lanes: gate once per process via CPUID.
  let cpuHasAvx2* = hasAvx2 and checkInstructionSets({AVX2})

# ---------------------------------------------------------------------------
# Byte helpers (ASCII only, branchless intent, match floof scope)
# ---------------------------------------------------------------------------

proc lowerByte(b: char): char {.inline.} =
  if b in 'A'..'Z': chr(ord(b) + 32) else: b

proc upperByte(b: char): char {.inline.} =
  if b in 'a'..'z': chr(ord(b) - 32) else: b

proc isWordStart(t: string, pos: int): bool {.inline.} =
  ## Word starts drive the boundary bonus: string start, after a
  ## separator, or a camelCase hump (`parseURL`).
  if pos == 0: return true
  let prev = t[pos - 1]
  if prev in {' ', '/', '-', '_', '.', ':', '\\', '\'', '"', '(', '[', '{'}:
    return true
  prev in 'a'..'z' and t[pos] in 'A'..'Z'

# ---------------------------------------------------------------------------
# Forward character search kernels: first index >= start holding `a`,
# or `b` when useAlt. One 16/32-byte vector per cycle, scalar tail.
# ---------------------------------------------------------------------------

proc findCharScalar*(text: string, start: int, a, b: char,
                     useAlt: bool): int =
  var pos = max(start, 0)
  while pos < text.len:
    let t = text[pos]
    if t == a or (useAlt and t == b): return pos
    inc pos
  -1

when hasSse2:
  proc findCharSse2*(text: string, start: int, a, b: char,
                     useAlt: bool): int =
    if start >= text.len: return -1
    let va = mm_set1_epi8(cast[int8](a))
    let vb = mm_set1_epi8(cast[int8](b))
    var pos = max(start, 0)
    while pos + 16 <= text.len:
      let chunk = mm_loadu_si128(cast[ptr M128i](unsafeAddr text[pos]))
      var m = mm_cmpeq_epi8(chunk, va)
      if useAlt:
        m = mm_or_si128(m, mm_cmpeq_epi8(chunk, vb))
      let mask = mm_movemask_epi8(m)
      if mask != 0:
        return pos + countTrailingZeroBits(cast[uint32](mask))
      pos += 16
    while pos < text.len:
      let t = text[pos]
      if t == a or (useAlt and t == b): return pos
      inc pos
    -1

when hasAvx2:
  proc findCharAvx2*(text: string, start: int, a, b: char,
                     useAlt: bool): int =
    if start >= text.len: return -1
    let va = mm256_set1_epi8(cast[int8](a))
    let vb = mm256_set1_epi8(cast[int8](b))
    var pos = max(start, 0)
    while pos + 32 <= text.len:
      let chunk = mm256_loadu_si256(cast[ptr M256i](unsafeAddr text[pos]))
      var m = mm256_cmpeq_epi8(chunk, va)
      if useAlt:
        m = mm256_or_si256(m, mm256_cmpeq_epi8(chunk, vb))
      let mask = mm256_movemask_epi8(m)
      if mask != 0:
        return pos + countTrailingZeroBits(cast[uint32](mask))
      pos += 32
    # SSE2 tail, then scalar tail
    let va16 = mm_set1_epi8(cast[int8](a))
    let vb16 = mm_set1_epi8(cast[int8](b))
    while pos + 16 <= text.len:
      let chunk = mm_loadu_si128(cast[ptr M128i](unsafeAddr text[pos]))
      var m = mm_cmpeq_epi8(chunk, va16)
      if useAlt:
        m = mm_or_si128(m, mm_cmpeq_epi8(chunk, vb16))
      let mask = mm_movemask_epi8(m)
      if mask != 0:
        return pos + countTrailingZeroBits(cast[uint32](mask))
      pos += 16
    while pos < text.len:
      let t = text[pos]
      if t == a or (useAlt and t == b): return pos
      inc pos
    -1

when hasNeon:
  proc findCharNeon*(text: string, start: int, a, b: char,
                     useAlt: bool): int =
    if start >= text.len: return -1
    let va = vmovq_n_u8(uint8(ord(a)))
    let vb = vmovq_n_u8(uint8(ord(b)))
    var pos = max(start, 0)
    var lanes: array[16, uint8]
    while pos + 16 <= text.len:
      var m = vceqq_u8(vld1q_u8(cast[pointer](unsafeAddr text[pos])), va)
      if useAlt:
        m = vorrq_u8(m, vceqq_u8(vld1q_u8(cast[pointer](unsafeAddr text[pos])), vb))
      vst1q_u8(addr lanes[0], m)
      for i in 0 .. 15:
        if lanes[i] != 0: return pos + i
      pos += 16
    while pos < text.len:
      let t = text[pos]
      if t == a or (useAlt and t == b): return pos
      inc pos
    -1

proc findCharNext(text: string, start: int, a, b: char,
                  useAlt: bool): int {.inline.} =
  ## Best available lane for this target; AVX2 additionally guarded
  ## at runtime so an AVX2 binary stays safe on older x86-64 CPUs.
  when defined(amd64):
    when hasAvx2:
      if cpuHasAvx2:
        return findCharAvx2(text, start, a, b, useAlt)
    when hasSse2:
      return findCharSse2(text, start, a, b, useAlt)
    else:
      return findCharScalar(text, start, a, b, useAlt)
  elif hasNeon:
    findCharNeon(text, start, a, b, useAlt)
  else:
    when hasSse2:
      findCharSse2(text, start, a, b, useAlt)
    else:
      findCharScalar(text, start, a, b, useAlt)

# ---------------------------------------------------------------------------
# Scoring core (shared by every lane)
# ---------------------------------------------------------------------------

proc fuzzyScoreImpl(query, candidate: string,
                    caseSensitive: bool): tuple[matched: bool, score: float32,
                    positions: seq[int]] =
  if query.len == 0 or candidate.len == 0 or query.len > candidate.len:
    return (false, 0.0'f32, @[])
  var positions = newSeqOfCap[int](query.len)
  var score = 0.0'f32
  var searchPos = 0
  var lastPos = -1
  for i in 0 ..< query.len:
    let q = query[i]
    let a = if caseSensitive: q else: lowerByte(q)
    let b = if caseSensitive: q else: upperByte(q)
    let p = findCharNext(candidate, searchPos, a, b, a != b)
    if p < 0:
      return (false, 0.0'f32, @[])
    positions.add(p)
    score += (if candidate[p] == q: FuzzyScoreExact else: FuzzyScoreFold)
    if lastPos < 0:
      score -= FuzzyPenaltyLeading * float32(p)
    else:
      let gap = p - lastPos - 1
      if gap == 0:
        score += FuzzyBonusConsecutive
      else:
        score -= FuzzyPenaltyGap * float32(gap)
    if isWordStart(candidate, p):
      score += FuzzyBonusWordStart
    lastPos = p
    searchPos = p + 1
  score /= float32(candidate.len)
  (true, score, positions)

proc fuzzyScore*(query, candidate: string,
                 opts: FuzzyOptions = FuzzyOptions()
                ): tuple[matched: bool, score: float32,
                         positions: seq[int]] =
  ## Score one candidate. `matched` reports the subsequence hit;
  ## `score` is length-normalized (higher ranks first) and may be
  ## negative for gappy matches — filter with `minScore` in `fuzzySearch`.
  fuzzyScoreImpl(query, candidate, opts.caseSensitive)

# ---------------------------------------------------------------------------
# Ranked search with bounded top-N
# ---------------------------------------------------------------------------

type HeapItem = object
  score: float32
  text: string
  positions: seq[int]

proc `<`(a, b: HeapItem): bool =
  ## Min-heap order: the worst item sorts first so `limit` evicts it.
  ## Ties evict the lexicographically larger text, keeping output stable.
  if a.score != b.score: a.score < b.score else: a.text > b.text

proc cmpMatch(a, b: FuzzyMatch): int =
  if a.score != b.score: cmp(b.score, a.score) else: cmp(a.text, b.text)

proc fuzzySearch*(query: string, candidates: openArray[string],
                  opts: FuzzyOptions = FuzzyOptions()): seq[FuzzyMatch] =
  ## Rank all candidates, best first. With `limit > 0` only the top-N
  ## are kept via a bounded heap instead of a full sort.
  if query.len == 0 or candidates.len == 0:
    return @[]
  if opts.limit > 0:
    var heap = initHeapQueue[HeapItem]()
    for c in candidates:
      let r = fuzzyScoreImpl(query, c, opts.caseSensitive)
      if r.matched and r.score >= opts.minScore:
        heap.push(HeapItem(score: r.score, text: c, positions: r.positions))
        if heap.len > opts.limit:
          discard heap.pop()
    result = newSeqOfCap[FuzzyMatch](heap.len)
    while heap.len > 0:
      let h = heap.pop()
      result.add(FuzzyMatch(text: h.text, score: h.score,
                            positions: h.positions))
    result.sort(cmpMatch)
  else:
    result = @[]
    for c in candidates:
      let r = fuzzyScoreImpl(query, c, opts.caseSensitive)
      if r.matched and r.score >= opts.minScore:
        result.add(FuzzyMatch(text: c, score: r.score, positions: r.positions))
    result.sort(cmpMatch)
