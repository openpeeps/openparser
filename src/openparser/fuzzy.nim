# A collection of tiny parsers and dumpers
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/openparser

## SIMD-accelerated fuzzy (subsequence) search with fzf-style scoring.
##
## Every query character must appear in the candidate in order, but not
## necessarily contiguously. Matches are ranked by consecutive runs,
## word-boundary hits and gap penalties, and scored against the width of
## the match rather than the length of the candidate.
##
## The alignment is the best one available, not the first: a candidate is
## scored by a dynamic program over query byte by candidate byte, because
## a leftmost walk commits to the earliest byte a character can match and
## then highlights noise when the query also appears verbatim further along.
## Cells that cannot hold an alignment are skipped rather than visited, and
## the bytes that can are located with the same character search as before —
## SSE2 (x86 baseline), AVX2 (opt-in via `-d:avx2`), NEON (arm64, always
## available) or scalar lanes, selected per target at compile time with a
## runtime AVX2 guard.
##
## Scoring allocates its working set once per search rather than once per
## candidate, so ranking thousands of candidates allocates once. `fuzzyScore`
## on its own allocates, being a single call by definition.
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
    score*: float32     ## higher ranks first; normalized by match span
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

const
  FuzzyUnreachable* = low(float32) / 2'f32
    ## Sentinel for "no alignment ends here". Far enough below any real score
    ## that adding a bonus to it can never look like a match.

type
  ScoreScratch = object
    ## Per-thread working set for the alignment below.
    ##
    ## Two score rows and two index grids, kept between calls because scoring a
    ## few thousand candidates is the whole point of the SIMD kernels and
    ## reallocating four buffers per candidate would undo that. Grown on demand,
    ## never shrunk: a candidate set has a longest row and every candidate pays
    ## for it once.

    prev: seq[float32]  ## scores for query[0 .. j-1]
    cur: seq[float32]   ## scores for query[0 .. j]
    parent: seq[int16]  ## where query[j-1] sat, for the chosen alignment
    first: seq[int16]   ## where query[0] sat, so the span is known before the walk

proc reserve(scratch: var ScoreScratch, rows, width: int) =
  ## Grown on demand and never shrunk, so a search pays for its widest candidate
  ## once and reuses the buffers for every row after it.
  if scratch.prev.len < width:
    scratch.prev = newSeq[float32](width)
    scratch.cur = newSeq[float32](width)
  if scratch.parent.len < rows * width:
    scratch.parent = newSeq[int16](rows * width)
    scratch.first = newSeq[int16](rows * width)

proc charOf(query: string, i: int, caseSensitive: bool): tuple[a, b: char, alt: bool] =
  ## The two bytes a query byte can match, and whether they differ. They differ
  ## for ASCII letters only, which is what makes `alt` the flag for searching
  ## both: a non-letter has one byte and one candidate position.
  let q = query[i]
  let a = if caseSensitive: q else: lowerByte(q)
  let b = if caseSensitive: q else: upperByte(q)
  (a: a, b: b, alt: a != b)

proc fuzzyScoreImpl(query, candidate: string, caseSensitive: bool,
                    scratch: var ScoreScratch): tuple[matched: bool,
                    score: float32, positions: seq[int]] =
  ## Best alignment of `query` in `candidate`, not the first one.
  ##
  ## This used to walk the query left to right taking the earliest byte each
  ## character could match, which is the cheapest possible alignment and the
  ## wrong one often enough to be visible: `the heart` in `Reddit - The heart of
  ## the internet` locked its `t` onto the `t` in `Reddit` and highlighted nine
  ## scattered bytes, when the query sits there verbatim nine bytes along. A
  ## greedy walk cannot recover from that, because the first `t` it took is
  ## never reconsidered.
  ##
  ## So the alignment is chosen instead of stumbled into. For each query byte and
  ## each candidate byte, the best score of any alignment that ends there, built
  ## from two cases: the previous query byte sat immediately left, which earns
  ## `FuzzyBonusConsecutive`, or it sat somewhere earlier, which costs
  ## `FuzzyPenaltyGap` per byte skipped. The second case is what needs care —
  ## `prev[k] - Gap * (i - 1 - k)` is not a running maximum in `k` because every
  ## term is weighted by its own distance. Factoring the distance out gives
  ## `(prev[k] + Gap * k) - Gap * (i - 1)`, and the bracketed part does not depend
  ## on `i`, so one running maximum over `k` answers it in constant time.
  ##
  ## Rows are swept in increasing `i` and only bytes that can match the query
  ## byte are visited, found with the same SIMD kernels as before, so the cells
  ## that could never hold an alignment are never touched.
  if query.len == 0 or candidate.len == 0 or query.len > candidate.len:
    return (false, 0.0'f32, @[])
  let rows = query.len
  let width = candidate.len
  reserve(scratch, rows, width)

  # Row 0: a single byte standing alone, so only the leading penalty applies.
  for i in 0 ..< width:
    scratch.prev[i] = FuzzyUnreachable
  var ch = charOf(query, 0, caseSensitive)
  var i = findCharNext(candidate, 0, ch.a, ch.b, ch.alt)
  if i < 0:
    return (false, 0.0'f32, @[])
  while i >= 0:
    scratch.prev[i] =
      (if candidate[i] == query[0]: FuzzyScoreExact else: FuzzyScoreFold) +
      (if isWordStart(candidate, i): FuzzyBonusWordStart else: 0.0'f32) -
      FuzzyPenaltyLeading * float32(i)
    scratch.parent[i] = -1
    scratch.first[i] = int16(i)
    i = findCharNext(candidate, i + 1, ch.a, ch.b, ch.alt)

  for j in 1 ..< rows:
    for k in 0 ..< width:
      scratch.cur[k] = FuzzyUnreachable
    let here = charOf(query, j, caseSensitive)
    let prevCh = charOf(query, j - 1, caseSensitive)
    # Running maximum of `prev[k] + Gap * k` over every k at or before `i - 2`,
    # which is the set of predecessors separated from `i` by at least one byte.
    var runBest = FuzzyUnreachable
    var runAt = -1
    var k = findCharNext(candidate, 0, prevCh.a, prevCh.b, prevCh.alt)
    i = findCharNext(candidate, 0, here.a, here.b, here.alt)
    while i >= 0:
      while k >= 0 and k <= i - 2:
        let carried = scratch.prev[k] + FuzzyPenaltyGap * float32(k)
        if carried > runBest:
          runBest = carried
          runAt = k
        k = findCharNext(candidate, k + 1, prevCh.a, prevCh.b, prevCh.alt)
      var best = FuzzyUnreachable
      var arg = -1
      if i > 0 and scratch.prev[i - 1] > FuzzyUnreachable:
        best = scratch.prev[i - 1] + FuzzyBonusConsecutive
        arg = i - 1
      if runAt >= 0:
        let carried = runBest - FuzzyPenaltyGap * float32(i - 1)
        if carried > best:
          best = carried
          arg = runAt
      if arg >= 0:
        scratch.cur[i] =
          (if candidate[i] == query[j]: FuzzyScoreExact else: FuzzyScoreFold) +
          (if isWordStart(candidate, i): FuzzyBonusWordStart else: 0.0'f32) + best
        scratch.parent[j * width + i] = int16(arg)
        scratch.first[j * width + i] = scratch.first[(j - 1) * width + arg]
      i = findCharNext(candidate, i + 1, here.a, here.b, here.alt)
    swap(scratch.prev, scratch.cur)

  # The last row holds every way the query can end. Which one wins is decided on
  # the reported score rather than the raw one, because the divisor is the span
  # and the span is a property of the path: a run four bytes wide scores higher
  # than a better-formed match ten bytes wide, and picking the raw maximum first
  # would miss that.
  var bestScore = FuzzyUnreachable
  var endAt = -1
  var span = 0
  let lastRow = (rows - 1) * width
  for k in 0 ..< width:
    if scratch.prev[k] <= FuzzyUnreachable:
      continue
    let reach = k - int(scratch.first[lastRow + k]) + 1
    let normalized = scratch.prev[k] / float32(reach)
    if normalized > bestScore:
      bestScore = normalized
      endAt = k
      span = reach
  if endAt < 0:
    return (false, 0.0'f32, @[])

  var positions = newSeqOfCap[int](rows)
  var walk = endAt
  for j in countdown(rows - 1, 0):
    positions.add(walk)
    if j > 0:
      walk = int(scratch.parent[j * width + walk])
  # The walk runs backwards from the last query byte, so what it collected is
  # descending. Callers index `positions` as though it were ascending, and the
  # span at either end is the same either way, which is exactly why this is easy
  # to miss: the score was already right before this line.
  positions.reverse()
  (true, bestScore, positions)

proc fuzzyScore*(query, candidate: string,
                 opts: FuzzyOptions = FuzzyOptions()
                ): tuple[matched: bool, score: float32,
                         positions: seq[int]] =
  ## Score one candidate. `matched` reports the subsequence hit;
  ## `score` is normalized by the width of the match (higher ranks
  ## first) and may be negative for very gappy matches — filter with
  ## `minScore` in `fuzzySearch`.
  var scratch: ScoreScratch
  fuzzyScoreImpl(query, candidate, opts.caseSensitive, scratch)

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
  var scratch: ScoreScratch
  if opts.limit > 0:
    var heap = initHeapQueue[HeapItem]()
    for c in candidates:
      let r = fuzzyScoreImpl(query, c, opts.caseSensitive, scratch)
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
      let r = fuzzyScoreImpl(query, c, opts.caseSensitive, scratch)
      if r.matched and r.score >= opts.minScore:
        result.add(FuzzyMatch(text: c, score: r.score, positions: r.positions))
    result.sort(cmpMatch)
