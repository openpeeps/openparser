# A collection of tiny parsers and dumpers
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/openparser

## End to end tour of the openparser diff module: read the structured result
## the way a UI would, render unified text, then benchmark to find out where the
## time actually goes.
##
## The benchmark block is the interesting half. It measures each pipeline stage
## separately rather than timing `diff` as a black box, because the obvious
## optimisation targets are guesses until they are numbers. Run it with:
##
##     clue build examples/diff_example.nim --release && ./diff_example

import std/[monotimes, strutils, times, sequtils]
import ../src/openparser/diff

# Internal stages, imported directly so the benchmark can time them separately.
# The facade deliberately does not re-export them: a caller needs `diff`, not
# the pipeline. This example is in-tree and profiling is its whole job.
import ../src/openparser/diff/[lines, myers, anchor, ops]

proc withLines(count: int, prefix: string): string =
  ## `count` unique, terminated lines. Unique so Myers and patience have
  ## nothing to disagree about and the numbers reflect the search, not anchoring.
  result = newStringOfCap(count * (prefix.len + 8))
  for i in 1 .. count:
    result.add prefix & " " & $i & "\n"

proc heading(h: DiffHunk): string =
  ## The hunk's `@@` trailing text, or a marker when there is none.
  if h.heading.len > 0: " " & h.heading else: " (no preceding line)"

proc pad(n: int, width: int): string =
  ## Right-aligned in `width` columns, so the trace above lines up.
  ## -1 means "absent on this side" and is shown explicitly, since that is
  ## exactly the field a consumer has to branch on.
  if n < 0: alignLeft("-", width) else: align($n, width)

proc withEdits(src: string, every: int, text: string): string =
  ## Replace every `every`-th line, giving a controlled edit distance.
  var ls = src.splitLines()
  discard ls.pop()
  var i = 0
  while i < ls.len:
    ls[i] = text
    i += every
  ls.join("\n") & "\n"

block demo:
  let before = withLines(30, "line")
  let after = withEdits(before, 10, "CHANGED")

  echo "=== summary ==="
  let d = diff(before, after)
  echo "  ", renderSummary(d)
  echo "  bytes: ", d.a.byteLen, " -> ", d.b.byteLen
  echo "  hunks: ", d.stats.hunkCount

  echo "=== per line, the way a UI consumes it ==="
  for hunk in d.hunks:
    echo "  @@ -", hunk.aStart, ",", hunk.aCount,
         " +", hunk.bStart, ",", hunk.bCount, " @@", heading(hunk)
    for line in hunk.lines:
      # A side-by-side-ish trace: where the line lives on each side, and which
      # byte range inside it moved. `spans` is what lets a highlighter underline
      # the word that changed rather than the whole line.
      var row = "    " & alignLeft($line.kind, 7)
      row.add " A=" & pad(line.aLine, 3) & " B=" & pad(line.bLine, 3)
      row.add " bytes=" & pad(line.aByte, 4) & "/" & pad(line.bByte, 4)
      for sp in line.spans:
        row.add " [" & $sp.start & ":" & $sp.stop & "]"
      echo row

  echo "=== unified text ==="
  echo renderUnified(d)

  echo "=== algorithms on a file full of repeated lines ==="
  ## Histogram has anchors where patience has none, which is the case the two
  ## differ on: every line is identical, so nothing is unique.
  var repA = ""
  var repB = ""
  for _ in 1 .. 40: repA.add "generated\n"
  for _ in 1 .. 40: repB.add "generated\n"
  repB.add "tail\n"
  for alg in [daMyers, daPatience, daHistogram]:
    let r = diff(repA, repB, DiffOptions(algorithm: alg))
    echo "  ", $alg, ": ", $r.stats

  echo "=== borrowing rules ==="
  ## `diff` returns offsets into the inputs, not copies, so the inputs must
  ## outlive the result. Here they do; uncommenting the reassignment below
  ## would leave `d.hunks` pointing at freed memory.
  var mutableInput = "keep\n"
  let held = diff(mutableInput, "changed\n")
  echo "  spans still valid: ", held.hunks.len > 0
  # mutableInput = "different\n"   # unsafe: invalidates the diff above

block bench:
  # A realistic shape: unique-ish source lines with a scattered edit, which is
  # what a code review actually looks like.
  let bigA = withLines(20_000, "proc doThing")
  let bigB = withEdits(bigA, 200, "proc renamed")
  const iters = 20

  proc mbPerSec(bytes: int, ns: int64): float =
    ## Throughput, so a stage can be compared against another directly.
    if ns <= 0: return 0.0
    float(bytes) / (float(ns) * 1e-9) / (1024 * 1024)

  template timed(label: string, bytes: int, body: untyped) =
    ## Wall clock over `iters` runs, reported as ns and MB/s.
    ##
    ## `body` must not be optimised away: every stage here is used by the result
    ## or written somewhere, so the compiler cannot drop it.
    var sink = 0
    let t0 = getMonoTime()
    for _ in 0 ..< iters:
      sink += body
    let ns = (getMonoTime() - t0).inNanoseconds div iters
    echo "  ", label, ": ", ns, " ns  ", mbPerSec(bytes, ns).formatFloat(ffDecimal, 1),
         " MB/s"
    doAssert sink >= 0

  echo "=== pipeline stages (", bigA.len div 1024, " KiB per side) ==="

  timed "indexLines", bigA.len:
    indexLines(view(bigA)).lines.len

  let indexedA = indexLines(view(bigA))
  let indexedB = indexLines(view(bigB))
  let opts = DiffOptions()

  timed "myersDiff ", bigA.len:
    myersDiff(indexedA, indexedB, opts)[0].len

  let script = myersDiff(indexedA, indexedB, opts)[0]
  timed "buildHunks", bigA.len:
    buildHunks(indexedA, indexedB, script, opts).len

  let hunks = buildHunks(indexedA, indexedB, script, opts)
  let diffed = diff(bigA, bigB, opts)
  timed "renderUnified", bigA.len:
    renderUnified(diffed).len

  timed "diff (whole)", bigA.len:
    diff(bigA, bigB, opts).hunks.len

  echo "=== algorithms, same input ==="
  for alg in [daMyers, daPatience, daHistogram]:
    timed $alg, bigA.len:
      diff(bigA, bigB, DiffOptions(algorithm: alg)).hunks.len

  echo "=== intra-line cost ==="
  ## The only stage whose cost scales with bytes rather than lines, so it is
  ## worth knowing what turning it off actually saves.
  let pair = diff("let value = 12345\n", "let value = 67890\n")
  discard pair
  timed "one paired line, spans on", 18:
    diff("let value = 12345\n", "let value = 67890\n",
         DiffOptions(intraLine: diOn)).hunks.len
  timed "one paired line, spans off", 18:
    diff("let value = 12345\n", "let value = 67890\n",
         DiffOptions(intraLine: diOff)).hunks.len

  echo "=== worst case: nothing in common ==="
  ## The truncation path. Two files with no shared lines have D ~= N+M, which is
  ## the only input where the search can genuinely blow up, so it is the one to
  ## time.
  let alienA = withLines(20_000, "alpha")
  let alienB = withLines(20_000, "omega")
  timed "disjoint 20k lines, capped D=1000", alienA.len:
    diff(alienA, alienB, DiffOptions(maxEditDistance: 1000)).hunks.len
