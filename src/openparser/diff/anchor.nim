# A collection of tiny parsers and dumpers
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/openparser

## Patience and histogram: the two anchoring strategies, both of which recurse
## into Myers. Myers alone produces a *minimal* script, but not necessarily a
## *readable* one, and on files full of repeated structure it will happily
## attribute a change to the wrong copy of a block.
##
## Patience anchors on lines that occur exactly once on each side. Those are
## lines the author did not duplicate, so an anchor between them is almost
## always what a human meant, and Myers only has to work inside the gaps.
##
## Histogram generalises that: instead of demanding uniqueness it ranks by
## occurrence count and anchors on the rarest lines, which keeps anchors
## working when a file has *no* unique lines at all. Patience with no unique
## lines degrades to plain Myers; histogram does not.
##
## Neither changes the worst-case complexity. Anchoring is a linear scan plus
## a sort, and each gap goes to Myers, so the bound stays O((N+M)*D) time
## with the same O(D^2) trace per gap. What changes is output quality, not
## cost, which is why these are pass-throughs around the Myers engine rather
## than independent algorithms.
##
## Both need line content as a hash key, which means one `string` per line.
## That is the allocation this module otherwise avoids, and it is confined to
## this file. A caller diffing many small files should prefer `daMyers`,
## which never allocates a key; a caller chasing readable output on large
## files should accept the keys, since they are what makes the anchors
## possible.

import std/[algorithm, tables]
import ./types
import ./lines
import ./script
import ./myers

type
  Anchor* = object
    ## A line paired across both sides, safe to treat as a fixed point.
    aIdx*: int
    bIdx*: int

  SidedLine = object
    ## How often a line occurs, and where. `idx` is only meaningful when
    ## `count == 1`, which is the only case either algorithm anchors on
    ## directly.
    count: int
    idx: int

proc indexSide(ix: LineIndex, lo, hi: int): Table[string, SidedLine] =
  ## Occurrence count and first position for every line in a range.
  for i in lo .. hi:
    let key = keyOf(ix, i)
    let seen = result.getOrDefault(key)
    if seen.count == 0:
      result[key] = SidedLine(count: 1, idx: i)
    else:
      result[key].count = seen.count + 1

proc monotonic*(anchors: var seq[Anchor]) =
  ## Drop anchors that would cross an earlier one.
  ##
  ## The recursion in `anchoredDiff` walks both sides forwards, so the anchors
  ## have to increase on both sides or a gap would be walked backwards. Cheap
  ## enough to apply unconditionally.
  var lastA = -1
  var lastB = -1
  var kept = newSeqOfCap[Anchor](anchors.len)
  for anc in anchors:
    if anc.aIdx > lastA and anc.bIdx > lastB:
      kept.add anc
      lastA = anc.aIdx
      lastB = anc.bIdx
  anchors = kept

proc uniqueAnchors*(a, b: LineIndex, aLo, aHi, bLo, bHi: int): seq[Anchor] =
  ## Lines occurring exactly once in each range, in ascending index order.
  var countsA = indexSide(a, aLo, aHi)
  var countsB = indexSide(b, bLo, bHi)

  for i in aLo .. aHi:
    let key = keyOf(a, i)
    let seenA = countsA.getOrDefault(key)
    let seenB = countsB.getOrDefault(key)
    # Both sides must hold exactly one copy: an anchor is only meaningful if
    # it pins a single position on each side.
    if seenA.count != 1 or seenB.count != 1: continue
    result.add Anchor(aIdx: seenA.idx, bIdx: seenB.idx)
  monotonic(result)

proc histogramAnchors*(a, b: LineIndex, aLo, aHi, bLo, bHi: int): seq[Anchor] =
  ## The rarest lines present on both sides, matched greedily.
  ##
  ## Candidates are ranked by combined occurrence count on both sides, so a
  ## line appearing once anchors ahead of one appearing fifty times. Each
  ## position is consumed at most once, which is what stops a repeated line
  ## from anchoring the same place twice.
  var countsA = indexSide(a, aLo, aHi)
  var countsB = indexSide(b, bLo, bHi)

  type Candidate = tuple[cost: int, aIdx, bIdx: int]
  var cands: seq[Candidate] = @[]
  for i in aLo .. aHi:
    let key = keyOf(a, i)
    let seenA = countsA.getOrDefault(key)
    let seenB = countsB.getOrDefault(key)
    if seenB.count == 0: continue
    cands.add (cost: seenA.count + seenB.count, aIdx: i, bIdx: seenB.idx)
  if cands.len == 0: return

  # Ascending rarity, then position. The position tiebreaker is what makes the
  # output deterministic: diffing the same input twice must give the same
  # answer, and a UI showing a diff twice has to show the same thing twice.
  cands.sort(proc (x, y: Candidate): int =
    if x.cost != y.cost: return cmp(x.cost, y.cost)
    cmp(x.aIdx, y.aIdx)
  )

  var usedA = initTable[int, bool]()
  var usedB = initTable[int, bool]()
  for c in cands:
    if usedA.hasKey(c.aIdx) or usedB.hasKey(c.bIdx): continue
    usedA[c.aIdx] = true
    usedB[c.bIdx] = true
    result.add Anchor(aIdx: c.aIdx, bIdx: c.bIdx)
  monotonic(result)

proc anchoredDiff*(a, b: LineIndex, aLo, aHi, bLo, bHi, maxD: int,
                   anchors: seq[Anchor], ops: var seq[LineOp],
                   truncated: var bool) =
  ## Myers across each gap between anchors, emitting the anchors themselves.
  ## Shared by both strategies, which differ only in how `anchors` was chosen.
  var prevA = aLo
  var prevB = bLo
  for anc in anchors:
    if anc.aIdx < prevA or anc.bIdx < prevB: continue
    myersRange(a, b, prevA, anc.aIdx - 1, prevB, anc.bIdx - 1, maxD,
               ops, truncated)
    ops.add equalOp(anc.aIdx, anc.bIdx)
    prevA = anc.aIdx + 1
    prevB = anc.bIdx + 1
  myersRange(a, b, prevA, aHi, prevB, bHi, maxD, ops, truncated)

proc anchoredWhole*(a, b: LineIndex, opts: DiffOptions,
                    anchors: seq[Anchor]): (seq[LineOp], bool) =
  ## `anchoredDiff` over both whole files, with the no-anchors fallback that
  ## keeps a strategy honest: with nothing to anchor on, it *is* Myers.
  var ops = newSeqOfCap[LineOp](a.lines.len + b.lines.len)
  var truncated = false
  let maxD = max(1, opts.maxEditDistance)
  if anchors.len == 0:
    myersRange(a, b, 0, a.lines.len - 1, 0, b.lines.len - 1, maxD,
               ops, truncated)
  else:
    anchoredDiff(a, b, 0, a.lines.len - 1, 0, b.lines.len - 1, maxD,
                 anchors, ops, truncated)
  (ops, truncated)

proc patienceDiff*(a, b: LineIndex, opts: DiffOptions): (seq[LineOp], bool) =
  ## Unique-line anchoring, then Myers inside each gap.
  anchoredWhole(a, b, opts, uniqueAnchors(a, b, 0, a.lines.len - 1,
                                          0, b.lines.len - 1))

proc histogramDiff*(a, b: LineIndex, opts: DiffOptions): (seq[LineOp], bool) =
  ## Rarest-line anchoring, then Myers inside each gap.
  ##
  ## Worth preferring over patience for generated or templated files, where
  ## every line repeats and patience therefore finds nothing to anchor on.
  anchoredWhole(a, b, opts, histogramAnchors(a, b, 0, a.lines.len - 1,
                                              0, b.lines.len - 1))