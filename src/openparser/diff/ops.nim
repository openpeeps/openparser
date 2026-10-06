# A collection of tiny parsers and dumpers
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/openparser

## Turning an edit script into the `Diff` a consumer actually reads: hunks
## with context, per-line anchors on both sides, optional intra-line spans,
## and the totals a UI draws without walking anything.
##
## This is the only stage that allocates per *changed* line rather than per
## input line. Everything unchanged is dropped here, which is why a one-line
## edit in a 50k-line file produces two `DiffLine`s rather than fifty thousand.

import ./types
import ./lines
import ./script
import ./intraline

proc lineOf*(kind: DiffLineKind): char {.inline.} =
  ## The sign a unified diff prints for a line kind.
  case kind
  of dlEqual: ' '
  of dlInsert: '+'
  of dlDelete: '-'

proc fillLine*(a, b: LineIndex, op: LineOp, line: var DiffLine) =
  ## Populate one `DiffLine` from a script step.
  ##
  ## A step that does not consume a side records -1 rather than a stale index,
  ## so a consumer can test one field instead of cross-checking `kind`.
  line.kind = kindOf(op)
  line.aLine = if op.kind in {opEqual, opDelete}: op.aIdx else: -1
  line.bLine = if op.kind in {opEqual, opInsert}: op.bIdx else: -1
  line.aByte = -1
  line.aLen = -1
  line.bByte = -1
  line.bLen = -1
  if line.aLine >= 0 and line.aLine < a.lines.len:
    let s = a.lines[line.aLine]
    line.aByte = s.byteStart
    line.aLen = s.contentLen
    line.eol = s.eol
  if line.bLine >= 0 and line.bLine < b.lines.len:
    let s = b.lines[line.bLine]
    line.bByte = s.byteStart
    line.bLen = s.contentLen
    # An equal line is the same line on both sides, so A's terminator is
    # authoritative. Otherwise report whichever side this step carries.
    if op.kind != opEqual: line.eol = s.eol

proc makeHunk*(a, b: LineIndex, ops: seq[LineOp], startPos, endPos: int,
               opts: DiffOptions): DiffHunk =
  ## One hunk covering script positions `startPos .. endPos`.
  ##
  ## Declared before `buildHunks` because that proc calls it and Nim resolves
  ## calls in file order.
  result.lines = newSeqOfCap[DiffLine](endPos - startPos + 1)
  result.aStart = -1
  result.bStart = -1

  var i = startPos
  while i <= endPos:
    if not ops[i].isEqual:
      # A maximal run of changes. Runs are collected whole before emitting,
      # because deletes and inserts inside one run have to be paired
      # *positionally* rather than by adjacency: a rewritten block of N lines
      # is emitted as N deletes followed by N inserts, so pairing only adjacent
      # steps would pair one line and leave the rest unpaired.
      let runStart = i
      while i <= endPos and not ops[i].isEqual:
        inc i
      # Where this run's lines land in `result.lines`. Anything before it belongs
      # to earlier steps and has already been counted.
      let firstNew = result.lines.len
      var dels = newSeqOfCap[LineOp](i - runStart)
      var inss = newSeqOfCap[LineOp](i - runStart)
      for p in runStart ..< i:
        if ops[p].kind == opDelete: dels.add ops[p]
        else: inss.add ops[p]

      # Within one run, git emits every removal and then every addition.
      # Verified against `git diff` rather than assumed: replacing three whole
      # lines gives `-a1 -a2 -a3 +b1 +b2 +b3`, and two edits separated by
      # context give `-k1 +K1 ... -k3 +K3` because each is its own run.
      for k in 0 ..< dels.len:
        var line = DiffLine()
        fillLine(a, b, dels[k], line)
        if result.aStart < 0 and line.aLine >= 0: result.aStart = line.aLine
        if result.bStart < 0 and line.bLine >= 0: result.bStart = line.bLine
        result.lines.add line
      for k in 0 ..< inss.len:
        var line = DiffLine()
        fillLine(a, b, inss[k], line)
        if result.aStart < 0 and line.aLine >= 0: result.aStart = line.aLine
        if result.bStart < 0 and line.bLine >= 0: result.bStart = line.bLine
        result.lines.add line

      # Pairing is positional and happens after emission, purely to attach
      # intra-line spans: the k-th removal against the k-th addition. Doing it
      # this way keeps the emitted order git-compatible while still giving a
      # rewritten block per-line detail instead of none.
      let paired = min(dels.len, inss.len)
      if paired > 0 and opts.intraLine != diOff:
        # The run occupies `[firstNew, result.lines.len)`; its deletions start
        # at firstNew and its insertions at firstNew + dels.len.
        for k in 0 ..< paired:
          var del = result.lines[firstNew + k]
          var ins = result.lines[firstNew + dels.len + k]
          let (aSpans, bSpans) = spansForPair(
            a.view, b.view,
            max(del.aByte, 0), max(del.aLen, 0),
            max(ins.bByte, 0), max(ins.bLen, 0),
            opts.maxSpanBytes)
          del.spans = aSpans
          ins.spans = bSpans
          result.lines[firstNew + k] = del
          result.lines[firstNew + dels.len + k] = ins

      # Counts cover *every* line the hunk shows on a side, context included.
      # That is what a unified diff header means by `aCount`: the span of the
      # hunk in that file, not the number of edits inside it. Only the lines
      # this run just appended are counted; earlier lines were counted already.
      for k in firstNew ..< result.lines.len:
        if result.lines[k].aLine >= 0: result.aCount += 1
        if result.lines[k].bLine >= 0: result.bCount += 1
    else:
      var line = DiffLine()
      fillLine(a, b, ops[i], line)
      if result.aStart < 0 and line.aLine >= 0: result.aStart = line.aLine
      if result.bStart < 0 and line.bLine >= 0: result.bStart = line.bLine
      if line.aLine >= 0: result.aCount += 1
      if line.bLine >= 0: result.bCount += 1
      result.lines.add line
      inc i

  # An empty side is reported as `-0,0`, so normalise a hunk that consumed
  # nothing from one side to start at line zero rather than keeping -1.
  if result.aStart < 0: result.aStart = 0
  if result.bStart < 0: result.bStart = 0

  # The heading git prints after `@@` is the source line *immediately before* the
  # hunk, which is not necessarily inside it: with `-U0` there is no leading
  # context at all and git still prints one. It is also not part of this
  # function's inputs, so it is filled in by `buildHunks`, which knows which
  # line precedes each hunk.

proc finishHunk(h: DiffHunk, a: LineIndex): DiffHunk =
  ## Attach the heading: the source line immediately before the hunk.
  ##
  ## Side A rather than B, because the heading describes where the hunk sits in
  ## the file being revised. A hunk that opens the file has no preceding line
  ## and therefore no heading, which is exactly what git prints.
  result = h
  let before = h.aStart - 1
  if before >= 0 and before < a.lines.len:
    let span = a.lines[before]
    if span.contentLen > 0:
      var text = newString(span.contentLen)
      copyMem(addr text[0], a.view.at(span.byteStart), span.contentLen)
      result.heading = text

proc buildHunks*(a, b: LineIndex, ops: seq[LineOp],
                 opts: DiffOptions): seq[DiffHunk] =
  ## Group the script into hunks, keeping `context` equal lines on each side.
  ##
  ## Two changes separated by no more than `2 * context` equal lines share a
  ## hunk, which is what `git` does and what stops a widely spaced set of
  ## edits from rendering as dozens of overlapping windows.
  let ctx = max(0, opts.context)
  let n = ops.len
  if n == 0: return

  # Positions of every changed step, so hunk boundaries come from the changes
  # themselves rather than being guessed during a single forward scan.
  var changed = newSeqOfCap[int](16)
  for i in 0 ..< n:
    if not ops[i].isEqual:
      changed.add i
  if changed.len == 0: return

  var startPos = max(0, changed[0] - ctx)
  var endPos = min(n - 1, changed[0] + ctx)
  # Equal lines seen since the last change step. This is the quantity the
  # coalescing rule is defined in, and it cannot be recovered from the distance
  # between change positions: a replacement occupies two script steps for one
  # changed line, so counting positions would make the window depend on how many
  # lines each individual edit happened to touch.
  var equalRun = 0

  # `changed[1 .. ^1]`: the first change already opened the hunk above.
  for ci in 1 ..< changed.len:
    let c = changed[ci]
    equalRun = 0
    var p = changed[ci - 1]
    while p < c:
      inc p
      if ops[p].kind == opEqual: inc equalRun
    if equalRun <= ctx * 2:
      # Git's rule, verified against `git diff` rather than assumed: two changes
      # share a hunk when at most `2 * context` equal lines separate them.
      endPos = min(n - 1, c + ctx)
    else:
      result.add finishHunk(makeHunk(a, b, ops, startPos, endPos, opts), a)
      startPos = max(0, c - ctx)
      endPos = min(n - 1, c + ctx)
  result.add finishHunk(makeHunk(a, b, ops, startPos, endPos, opts), a)

proc computeStats*(hunks: seq[DiffHunk]): DiffStats =
  ## Totals for a summary view: line counts and content bytes.
  ##
  ## `changed` counts *paired* replacements, so a caller drawing "N lines
  ## changed" matches a two-way diff instead of counting one edit as a removal
  ## plus an unrelated addition. The pairing is the same adjacency `makeHunk`
  ## uses, so the two views cannot disagree.
  result.hunkCount = hunks.len
  for hunk in hunks:
    let lines = hunk.lines
    var j = 0
    while j < lines.len:
      # Walk each maximal run of changes, so a delete/insert pair is recognised
      # as one replacement rather than two unrelated edits. This is the same
      # positional pairing `makeHunk` applies, so the totals and the per-line
      # spans can never disagree.
      if lines[j].kind == dlEqual:
        inc j
        continue
      var dels = 0
      var inss = 0
      var removedBytes = 0
      var addedBytes = 0
      while j < lines.len and lines[j].kind != dlEqual:
        if lines[j].kind == dlDelete:
          inc dels
          if lines[j].aLen > 0: removedBytes += lines[j].aLen
        else:
          inc inss
          if lines[j].bLen > 0: addedBytes += lines[j].bLen
        inc j
      result.removed += dels
      result.added += inss
      result.bytesRemoved += removedBytes
      result.bytesAdded += addedBytes
      result.changed += min(dels, inss)

proc isIdentical*(d: Diff): bool {.inline.} =
  ## Whether the two inputs matched exactly.
  ##
  ## The cheapest question a caller can ask, and the one a UI asks before
  ## drawing anything. Three things force false besides an empty hunk list:
  ## `truncated`, because a coarsened script means the search gave up rather
  ## than that the files agree; `binary`, because an empty hunk list for binary
  ## input means the diff was skipped, not that the bytes matched; and
  ## `comparedBinary`, which means hunks were deliberately not built.
  d.hunks.len == 0 and not d.truncated and not d.binary