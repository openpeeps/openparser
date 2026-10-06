# A collection of tiny parsers and dumpers
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/openparser

## Myers' O(ND) edit script. Myers, patience and histogram differ only in
## which lines they choose as anchors; this is the engine they all share and
## the only part that has to be fast.
##
## Why this rather than a plain LCS table. The dynamic-programming LCS needs
## O(N*M) time *and* memory, which stops being usable past a few thousand
## lines: two 20k-line files would need 1.6 GB. Myers costs O((N+M)*D), where
## D is the edit distance rather than the file size, and D stays small
## whenever text changes the way text usually changes. Replacing one line in a
## 50k-line file is D == 2 no matter how big the file is.
##
## The trade-off this form makes, stated plainly: recording enough state to
## walk the path back costs O(D^2) integers, because each step snapshots a
## frontier that grows with the step. With `maxEditDistance` defaulting to
## 1000 that is roughly 8 MB of transient trace in the worst case. That is a
## deliberate choice: it buys exactness up to 1000 edits and, past that,
## `Diff.truncated` reports a coarser script rather than the search grinding.
## The linear-space divide-and-conquer variant removes the O(D^2) entirely at
## the cost of a substantially harder search loop; it is the next step if
## benchmarks show the trace matters, and it is not needed for correctness.
## See `plans/diff-module.md`.
##
## Prefix and suffix trimming runs before every search. That is not only an
## optimisation: a one-line edit inside two large files trims down to almost
## nothing, so the search itself is handed a tiny problem.

import ./types
import ./lines
import ./script

proc myersWalk*(a, b: LineIndex, aLo, aHi, bLo, bHi, maxD: int,
                ops: var seq[LineOp]): bool {.raises: [].} =
  ## Emit the edit script for one range of each side, no trimming applied.
  ##
  ## Returns false when the edit distance exceeded `maxD`, leaving `ops`
  ## untouched so the caller can decide how to coarsen. Callers must trim
  ## first, since the trace below is exactly the cost trimming exists to
  ## avoid paying.
  let n = aHi - aLo + 1
  let m = bHi - bLo + 1
  if n <= 0 or m <= 0: return true

  let max = n + m
  let delta = n - m
  # Only diagonals in `-dCap .. dCap` can be reached, and `maxD` is a ceiling
  # on d, so this bound keeps the frontier small even for huge inputs.
  let dCap = min(max, max(1, maxD))
  let offset = dCap + 1
  let width = 2 * dCap + 3

  var v = newSeq[int](width)
  v[offset + 1] = 0
  var trace = newSeqOfCap[seq[int]](dCap + 1)

  var found = false
  var finalD = 0
  var d = 0
  while d <= dCap:
    # Snapshot before advancing, so `trace[d]` is the frontier as of the start
    # of step d, which is what the backward walk below indexes.
    trace.add v
    var k = -d
    while k <= d:
      var x: int
      if k == -d or (k != d and v[offset + k - 1] < v[offset + k + 1]):
        # Reached this diagonal by inserting a line from B.
        x = v[offset + k + 1]
      else:
        # Reached it by deleting a line from A.
        x = v[offset + k - 1] + 1
      var y = x - k
      # Consume equal lines greedily. A snake is free: it advances both
      # sides at once and contributes nothing to D.
      while x < n and y < m and linesEqual(a, aLo + x, b, bLo + y):
        inc x
        inc y
      v[offset + k] = x
      if k == delta and x >= n and y >= m:
        found = true
        finalD = d
        break
      k += 2
    if found: break
    inc d

  if not found:
    return false

  # Walk the script backwards from the far corner. Each step is a run of equal
  # lines followed by the single insert or delete that arrived there, so the
  # walk emits the run first and then the step itself.
  var rev = newSeqOfCap[LineOp](n + m)
  var x = n
  var y = m
  var step = finalD
  while step > 0:
    let frontier = trace[step]
    let k = x - y
    var prevK: int
    if k == -step or (k != step and
        frontier[offset + k - 1] < frontier[offset + k + 1]):
      prevK = k + 1
    else:
      prevK = k - 1
    let prevX = frontier[offset + prevK]
    let prevY = prevX - prevK
    while x > prevX and y > prevY:
      dec x
      dec y
      rev.add equalOp(aLo + x, bLo + y)
    if x == prevX:
      dec y
      rev.add insertOp(bLo + y)
    else:
      dec x
      rev.add deleteOp(aLo + x)
    dec step
  # Step zero: the run of equal lines at the origin.
  while x > 0 and y > 0:
    dec x
    dec y
    rev.add equalOp(aLo + x, bLo + y)

  for i in countdown(rev.high, rev.low):
    ops.add rev[i]
  true

proc myersRange*(a, b: LineIndex, a0, a1, b0, b1, maxD: int,
                 ops: var seq[LineOp], truncated: var bool) =
  ## Emit the edit script for one range of each side.
  ##
  ## The range bounds are locals rather than parameters because trimming walks
  ## them inwards, and a caller's copy must survive the recursion intact.
  var aLo = a0
  var aHi = a1
  var bLo = b0
  var bHi = b1

  if aLo > aHi and bLo > bHi: return

  if aLo > aHi:
    for j in bLo .. bHi: ops.add insertOp(j)
    return
  if bLo > bHi:
    for i in aLo .. aHi: ops.add deleteOp(i)
    return

  # The common prefix is final: nothing later can reorder lines ahead of it.
  while aLo <= aHi and bLo <= bHi and linesEqual(a, aLo, b, bLo):
    ops.add equalOp(aLo, bLo)
    inc aLo
    inc bLo

  # The common suffix is discovered right-to-left but belongs at the end, so
  # it is held aside and appended once the middle is done.
  var pending = newSeqOfCap[LineOp](min(aHi - aLo, bHi - bLo) + 1)
  while aLo <= aHi and bLo <= bHi and linesEqual(a, aHi, b, bHi):
    pending.add equalOp(aHi, bHi)
    dec aHi
    dec bHi

  # Trimming can exhaust one side while the other still has lines, so the
  # one-sided cases are re-tested here rather than trusting the checks above.
  # Missing this is what silently dropped the trailing lines of an
  # insert-after-identical-prefix.
  if aLo > aHi:
    for j in bLo .. bHi: ops.add insertOp(j)
  elif bLo > bHi:
    for i in aLo .. aHi: ops.add deleteOp(i)
  elif aLo == aHi and bLo == bHi:
    # One line against one different line. Cheaper and clearer than running a
    # search for an answer already in hand.
    ops.add deleteOp(aLo)
    ops.add insertOp(bLo)
  elif not myersWalk(a, b, aLo, aHi, bLo, bHi, maxD, ops):
    # D exceeded the ceiling. Coarsen to a whole-range replacement rather
    # than emitting a partial or wrong script, and tell the caller.
    truncated = true
    for i in aLo .. aHi: ops.add deleteOp(i)
    for j in bLo .. bHi: ops.add insertOp(j)

  for i in countdown(pending.high, pending.low):
    ops.add pending[i]

proc myersDiff*(a, b: LineIndex, opts: DiffOptions): (seq[LineOp], bool) =
  ## Edit script for two whole line indexes.
  ##
  ## Returns the script and whether the edit-distance ceiling was reached.
  ## Callers must check that flag: a truncated script is a valid if coarser
  ## description of the change, never a wrong one.
  var ops = newSeqOfCap[LineOp](a.lines.len + b.lines.len)
  var truncated = false
  myersRange(a, b, 0, a.lines.len - 1, 0, b.lines.len - 1,
             max(1, opts.maxEditDistance), ops, truncated)
  (ops, truncated)