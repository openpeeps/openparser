import std/[unittest, strutils, sequtils, random, os]
import ../src/openparser/diff

# Internal stages, for the losslessness checks that need the edit script itself
# rather than the hunks built from it, and for the kernel parity checks.
import ../src/openparser/diff/[lines, script, kernel, myers, anchor]


proc mkLines(rnd: var Rand, n: int, pool: openArray[string]): string =
  ## Random text drawn from a small pool, so lines repeat often and the
  ## anchoring strategies actually have something to disagree about.
  result = ""
  for _ in 1 .. n:
    result.add pool[rnd.rand(pool.high)] & "\n"

proc raggedLines(rnd: var Rand, n: int, pool: openArray[string],
                  eol: string): string =
  ## Like `mkLines`, but with a caller-chosen terminator and a chance of
  ## dropping the final one, so the generator covers mixed and missing
  ## terminators rather than only the easy case.
  result = ""
  for _ in 1 .. n:
    result.add pool[rnd.rand(pool.high)] & eol
  if result.len > 0 and rnd.rand(3) == 0:
    result.setLen(result.len - eol.len)

proc numbered(count: int): string =
  ## `count` terminated lines, no trailing blank line.
  ##
  ## Built by joining rather than via `splitLines`, which keeps a trailing empty
  ## element and would silently add a phantom line to every test that rebuilds a
  ## file through it.
  result = (1 .. count).mapIt("l" & $it).join("\n") & "\n"

proc scriptOf(a, b: string, opts: DiffOptions): seq[LineOp] =
  ## The full edit script for two inputs, for the algorithm `opts` selects.
  ##
  ## The facade deliberately does not re-export this, but a test that wants to
  ## prove the *script* is lossless needs the script rather than the hunks,
  ## which drop unchanged lines outside the context window.
  let ai = indexLines(view(a))
  let bi = indexLines(view(b))
  case opts.algorithm
  of daMyers: myersDiff(ai, bi, opts)[0]
  of daPatience: patienceDiff(ai, bi, opts)[0]
  of daHistogram: histogramDiff(ai, bi, opts)[0]

proc replay(a, b: string, script: seq[LineOp], ra, rb: var string) =
  ## Rebuild both inputs by following an edit script.
  ##
  ## Only `\n` is appended after a line: `contentLen` already counts the `\r` of
  ## a CRLF terminator, because the scanner treats it as content. Adding `\r\n`
  ## here would double it, which is exactly the bug this shape of replay is
  ## checking for.
  let ai = indexLines(view(a))
  let bi = indexLines(view(b))
  for op in script:
    if op.kind in [opEqual, opDelete]:
      let s = ai.lines[op.aIdx]
      ra.add a[s.byteStart ..< s.byteStart + s.contentLen]
      if s.eol != eolNone: ra.add "\n"
    if op.kind in [opEqual, opInsert]:
      let t = bi.lines[op.bIdx]
      rb.add b[t.byteStart ..< t.byteStart + t.contentLen]
      if t.eol != eolNone: rb.add "\n"

proc renumbered(src: string, changes: openArray[int], text: string): string =
  ## `src` with the given 0-based lines replaced by `text`.
  var ls = src.splitLines()
  # splitLines yields a trailing "" for a terminated file; drop it so the count
  # matches the line numbering the rest of the module reports.
  discard ls.pop()
  for i in changes: ls[i] = text
  ls.join("\n") & "\n"

# ---------------------------------------------------------------------------
# Empty and degenerate inputs
# ---------------------------------------------------------------------------

suite "Diff: empty and degenerate":
  test "two empty files produce no hunks":
    let d = diff("", "")
    check d.hunks.len == 0
    check d.isIdentical
    check d.stats.added == 0
    check d.stats.removed == 0
    check renderUnified(d) == ""

  test "empty against non-empty is all additions":
    let d = diff("", "x\ny\n")
    check d.hunks.len == 1
    check d.hunks[0].aCount == 0
    check d.hunks[0].bCount == 2
    check d.stats.added == 2
    check d.stats.removed == 0
    check d.a.lineCount == 0
    check d.b.lineCount == 2

  test "non-empty against empty is all removals":
    let d = diff("x\ny\n", "")
    check d.hunks[0].aCount == 2
    check d.hunks[0].bCount == 0
    check d.stats.removed == 2

  test "single line added to empty file":
    let d = diff("", "only\n")
    check d.stats.added == 1
    check d.hunks[0].aStart == 0

  test "identical inputs are reported identical":
    let d = diff("a\nb\nc\n", "a\nb\nc\n")
    check d.isIdentical
    check d.stats.hunkCount == 0

# ---------------------------------------------------------------------------
# Trailing newlines
# ---------------------------------------------------------------------------

suite "Diff: trailing newlines":
  ## `git` treats a missing final newline as a real difference, and so does
  ## this module: a file that only gained its trailing newline is a change.
  test "gaining a trailing newline is a change":
    let d = diff("a\nb\nc", "a\nb\nc\n")
    check not d.isIdentical
    check d.stats.removed == 1
    check d.stats.added == 1

  test "losing a trailing newline is a change":
    let d = diff("a\nb\nc\n", "a\nb\nc")
    check not d.isIdentical

  test "unterminated line renders the git marker":
    let got = renderUnified(diff("a\nb", "a\nb\n"))
    check got.contains("\\ No newline at end of file")

  test "both sides unterminated is identical":
    check diff("a\nb", "a\nb").isIdentical

  test "only the unterminated side reports eolNone":
    ## Side A ends its last line with \n and side B does not, so the delete
    ## carries eolLf and only the insert carries eolNone. That is what lets the
    ## renderer put the marker on the correct line of the pair.
    let d = diff("a\nb\n", "a\nb")
    let del = d.hunks[0].lines.filterIt(it.kind == dlDelete)[0]
    let ins = d.hunks[0].lines.filterIt(it.kind == dlInsert)[0]
    check del.eol == eolLf
    check ins.eol == eolNone

# ---------------------------------------------------------------------------
# CRLF
# ---------------------------------------------------------------------------

suite "Diff: CRLF":
  test "CRLF file diffed against itself is identical":
    check diff("a\r\nb\r\n", "a\r\nb\r\n").isIdentical

  test "crlf is recorded on the side that has it":
    let d = diff("a\r\nb\r\n", "a\r\nb\r\n")
    check d.a.crlf
    check d.b.crlf

  test "converting CRLF to LF changes every line":
    ## Byte-exact by design: the \r is content, so every line really did change.
    ## A caller who wants to forgive this should normalise before diffing.
    let d = diff("a\r\nb\r\nc\r\n", "a\nb\nc\n")
    check not d.isIdentical
    check d.stats.removed == 3
    check d.stats.added == 3

  test "a CRLF line's content includes the carriage return":
    let d = diff("a\r\n", "b\r\n")
    let del = d.hunks[0].lines.filterIt(it.kind == dlDelete)[0]
    let ins = d.hunks[0].lines.filterIt(it.kind == dlInsert)[0]
    check del.aLen == 2 # "a\r"
    check ins.bLen == 2 # "b\r"

  test "crlf content survives rendering byte for byte":
    let got = renderUnified(diff("a\r\n", "b\r\n"))
    check "-a\r\n" in got
    check "+b\r\n" in got

# ---------------------------------------------------------------------------
# Long lines and binary detection
# ---------------------------------------------------------------------------

suite "Diff: long lines and binary":
  test "a very long line with no newline round-trips":
    let long = "x".repeat(1 shl 20) # 1 MiB, unterminated
    let d = diff(long, long)
    check d.isIdentical

  test "a one-byte change inside a 1 MiB line is found":
    var a = "y".repeat(1 shl 20) & "\n"
    var b = a
    b[500_000] = 'Z'
    let d = diff(a, b)
    check not d.isIdentical
    check d.stats.changed == 1

  test "NUL byte marks content binary":
    let d = diff("a\0b\n", "a\0c\n")
    check d.binary

  test "text content is not binary":
    check not diff("a\nb\n", "a\nc\n").binary

  test "binary diff renders one differ line and no hunks":
    let d = diff("a\0b\n", "a\0c\n")
    let got = renderUnified(d)
    check got.contains("Binary files")
    check got.contains("differ")
    check d.hunks.len == 0

  test "binary can be overridden to produce hunks":
    let d = diff("a\0b\n", "a\0c\n", DiffOptions(ignoreBinary: true))
    check d.hunks.len == 1
    check d.comparedBinary
    # "a\0b" is one line: the NUL is content, not a terminator.
    check renderUnified(d).contains("-a\0b")
    check renderUnified(d).contains("+a\0c")

  test "identical binary files are not reported identical":
    ## The hunks are empty because the diff was skipped, not because the bytes
    ## matched. Reporting `true` here would hide a real difference.
    check not diff("a\0b\n", "a\0b\n").isIdentical

  test "a NUL past the sniff limit does not mark binary":
    ## git only inspects the first 8000 bytes, so a late NUL is invisible.
    var late = "a".repeat(9000) & "\0b\n"
    check not diff(late, late & "x\n").binary

# ---------------------------------------------------------------------------
# Intra-line spans
# ---------------------------------------------------------------------------

suite "Diff: intra-line spans":
  test "a one-word change brackets only the changed bytes":
    let d = diff("let x = 1\n", "let x = 2\n")
    let del = d.hunks[0].lines.filterIt(it.kind == dlDelete)[0]
    let ins = d.hunks[0].lines.filterIt(it.kind == dlInsert)[0]
    check del.spans.len == 1
    check del.spans[0].start == 8 # index of '1' in "let x = 1"
    check del.spans[0].stop == 9
    check ins.spans.len == 1
    # The highlight must cover the differing byte and nothing else.
    check "let x = 1"[del.spans[0].start ..< del.spans[0].stop] == "1"

  test "spans mark the differing middle, not the whole line":
    let d = diff("abcdefghij", "abcdXXXXij")
    let del = d.hunks[0].lines[0]
    check del.spans[0].start == 4
    check del.spans[0].stop == 8

  test "spans are empty when intraLine is off":
    let d = diff("let x = 1\n", "let x = 2\n", DiffOptions(intraLine: diOff))
    let del = d.hunks[0].lines[0]
    check del.spans.len == 0

  test "a line past maxSpanBytes keeps whole-line semantics":
    ## Character-level output on a generated line is noise, so the cap is
    ## about readability as much as speed.
    var a = "z".repeat(600)
    var b = "z".repeat(600)
    b[300] = 'q'
    let d = diff(a & "\n", b & "\n", DiffOptions(maxSpanBytes: 100))
    check d.hunks[0].lines[0].spans.len == 0

  test "a replacement of unequal length still reports both sides":
    let d = diff("value = short\n", "value = muchLonger\n")
    let lines = d.hunks[0].lines
    check lines[0].spans.len == 1
    check lines[1].spans.len == 1

  test "span content can be sliced out of the line":
    let s = DiffSpan(start: 2, stop: 5)
    check s.slice("abcdef") == "cde"
    check s.spanLen == 3
    check s.contains(2)
    check s.contains(5) == false # half-open

# ---------------------------------------------------------------------------
# Hunk grouping and context
# ---------------------------------------------------------------------------

suite "Diff: kernel parity (libc vs scalar)":
  ## The byte searches delegate to libc `memchr`, which takes an unsigned count
  ## and returns a raw pointer. Both are places to get it subtly wrong: a
  ## negative length becomes an enormous unsigned one, and a pointer-to-index
  ## conversion can be off if the offset is not taken relative to the search's
  ## own base pointer. Both would corrupt every downstream offset, so the
  ## vectorised path is checked against the scalar reference at every edge.
  test "findNewline agrees with findNewlineScalar":
    let cases = [
      "",                       # empty
      "\n",                     # match at 0
      "a",                      # no match, unterminated
      "abc",                    # no match, several bytes
      "abc\n",                  # match at the end
      "\nabc",                  # match at the start
      "a\r\nb",                 # CRLF, match past the CR
      "\r\n",                   # match at index 1
      "no newline here at all", # long enough to need more than one vector step
      "\n\n\n\n\n"              # consecutive matches
    ]
    for s in cases:
      let v = view(s)
      check findNewline(v, 0, v.len) == findNewlineScalar(v, 0, v.len)
    # A deliberately long tail, past any single 16/32-byte vector step, so a
    # lane that mishandled its tail would disagree here.
    let long = "z".repeat(1000) & "\n" & "y".repeat(1000)
    for start in [0, 1, 15, 16, 17, 31, 32, 33, 999, 1000]:
      let v = view(long)
      check findNewline(v, start, v.len) == findNewlineScalar(v, start, v.len)

  test "findNewline handles every sub-range, not just whole buffers":
    ## The scan is called once per line with a moving start, so an off-by-one in
    ## the offset or the length would show up as a wrong line split on some
    ## window rather than on the whole buffer.
    let v = view("one\ntwo\nthree\nfour\n")
    for start in 0 .. v.len:
      for stop in start .. v.len:
        check findNewline(v, start, stop) == findNewlineScalar(v, start, stop)

  test "findNewline treats an inverted or empty range as no match":
    ## `memchr` takes an unsigned count; these ranges would become enormous if
    ## the bounds were passed through unchecked.
    let v = view("abc\ndef\n")
    check findNewline(v, 5, 5) == -1
    check findNewline(v, 5, 2) == -1
    check findNewline(v, 0, 0) == -1
    check findNewlineScalar(v, 5, 5) == -1
    check findNewlineScalar(v, 5, 2) == -1
    check findNewlineScalar(v, 0, 0) == -1

  test "findNewline on an empty view is safe":
    ## `view("")` has a nil pointer, and dereferencing it would be a crash
    ## rather than a wrong answer.
    let v = view("")
    check findNewline(v, 0, 0) == -1
    check findByte(v, 0, 0, nlByte) == -1
    check findNewlineScalar(v, 0, 0) == -1

  test "findByte agrees with findByteScalar":
    let cases = ["", "\0", "abc\0def", "\0\0\0", "no nul", "nul\0"]
    for s in cases:
      let v = view(s)
      check findByte(v, 0, v.len, 0'u8) == findByteScalar(v, 0, v.len, 0'u8)
    let long = "z".repeat(500) & "\0" & "y".repeat(500)
    for start in [0, 1, 16, 32, 500, 501]:
      let v = view(long)
      check findByte(v, start, v.len, 0'u8) ==
        findByteScalar(v, start, v.len, 0'u8)

  test "the binary sniff window is honoured exactly":
    ## git inspects the first 8000 bytes, and the sniff is one bounded scan over
    ## that window. A NUL inside it must be found and one past it must not be,
    ## otherwise a large file's binary status silently changes.
    let inside = "a".repeat(DiffBinarySniff - 1) & "\0rest\n"
    check indexLines(view(inside)).binary
    let outside = "a".repeat(DiffBinarySniff + 100) & "\0rest\n"
    check not indexLines(view(outside)).binary
    # A zero or negative window sniffs nothing rather than reading backwards.
    check not indexLines(view(inside), 0).binary
    check not indexLines(view(inside), -1).binary

  test "the sniff still finds a NUL in a file with no newlines":
    ## The sniff is no longer interleaved with the line loop, so this is the case
    ## that would expose it having been dropped.
    check indexLines(view("\0\0\0")).binary
    check indexLines(view("\0")).binary

suite "Diff: hunk grouping":
  test "nearby changes share one hunk":
    let a = numbered(20)
    let b = renumbered(a, [4, 9], "CHANGED")
    check diff(a, b).hunks.len == 1

  test "distant changes split into separate hunks":
    let a = numbered(60)
    let b = renumbered(a, [4, 54], "CHANGED")
    check diff(a, b).hunks.len == 2

  test "changes 2 * context equal lines apart are coalesced":
    ## Git's boundary, measured against real `git diff`: two changes share a
    ## hunk while at most `2 * context` (here 6) equal lines separate them.
    ## Lines 10 and 17 have exactly 6 between them, so this is the boundary
    ## case and must still coalesce.
    let a = numbered(40)
    let b = renumbered(a, [9, 16], "CHANGED")
    check diff(a, b).hunks.len == 1

  test "changes more than 2 * context apart split":
    ## One equal line further out and git separates them, so the boundary is
    ## not off by one in the other direction either.
    let a = numbered(40)
    let b = renumbered(a, [9, 17], "CHANGED")
    check diff(a, b).hunks.len == 2

  test "no context emits only the changed lines":
    ## `DiffNoContext` rather than 0, since 0 means "unset" and would silently
    ## become the default of 3.
    let a = numbered(20)
    let b = renumbered(a, [9], "CHANGED")
    let d = diff(a, b, DiffOptions(context: DiffNoContext))
    let eq = d.hunks[0].lines.filterIt(it.kind == dlEqual)
    check eq.len == 0
    check d.hunks.len == 1

  test "context widens the hunk":
    let a = numbered(40)
    let b = renumbered(a, [20], "CHANGED")
    let narrow = diff(a, b, DiffOptions(context: 1))
    let wide = diff(a, b, DiffOptions(context: 8))
    check wide.hunks[0].lines.len > narrow.hunks[0].lines.len

  test "a hunk that opens the file has no heading":
    let d = diff("l1\nl2\nl3\n", "CHANGED\nl2\nl3\n")
    check d.hunks[0].heading == ""

  test "a hunk mid-file carries the preceding line as heading":
    ## This is what git prints after `@@` for plain text.
    let a = numbered(20)
    let b = renumbered(a, [9], "CHANGED")
    let d = diff(a, b)
    # The heading is the line immediately before the hunk, not a function name.
    check d.hunks[0].aStart == 6
    check d.hunks[0].heading == "l6"

# ---------------------------------------------------------------------------
# Offsets and anchoring on both sides
# ---------------------------------------------------------------------------

suite "Diff: offsets":
  test "byte offsets point at the real line starts":
    let a = "one\ntwo\nthree\n"
    let b = "one\nTWO\nthree\n"
    let d = diff(a, b)
    let del = d.hunks[0].lines.filterIt(it.kind == dlDelete)[0]
    check del.aByte == 4 # "two" begins at byte 4
    check del.aLen == 3
    check a[del.aByte ..< del.aByte + del.aLen] == "two"

  test "an absent side is recorded as -1":
    let d = diff("one\ntwo\n", "one\ntwo\nthree\n")
    let ins = d.hunks[0].lines.filterIt(it.kind == dlInsert)[0]
    check ins.aLine == -1
    check ins.aByte == -1
    check ins.aLen == -1
    check ins.bLine == 2

  test "line numbers advance in order":
    let a = numbered(30)
    let b = renumbered(a, [4, 9, 24], "CHANGED")
    let d = diff(a, b)
    var seenA = -1
    for h in d.hunks:
      for l in h.lines:
        if l.aLine >= 0:
          check l.aLine > seenA
          seenA = l.aLine

# ---------------------------------------------------------------------------
# Algorithms
# ---------------------------------------------------------------------------

suite "Diff: algorithms":
  test "all three algorithms agree on totals for a modest edit":
    let a = numbered(80)
    let b = renumbered(a, [10, 40, 70], "CHANGED")
    let m = diff(a, b, DiffOptions(algorithm: daMyers)).stats
    let p = diff(a, b, DiffOptions(algorithm: daPatience)).stats
    let h = diff(a, b, DiffOptions(algorithm: daHistogram)).stats
    check m.added == p.added and p.added == h.added
    check m.removed == p.removed and p.removed == h.removed
    check m.hunkCount == p.hunkCount and p.hunkCount == h.hunkCount

  test "the chosen algorithm is reported on the result":
    check diff("a\n", "b\n", DiffOptions(algorithm: daPatience)).algorithm ==
      daPatience
    check diff("a\n", "b\n", DiffOptions(algorithm: daHistogram)).algorithm ==
      daHistogram
    check diff("a\n", "b\n").algorithm == daMyers

  test "myers and patience agree when every line is unique":
    ## With no repeated lines there is nothing to anchor on differently, so
    ## both strategies reduce to the same minimal script.
    let a = numbered(50)
    let b = renumbered(a, [25], "CHANGED")
    check renderUnified(diff(a, b, DiffOptions(algorithm: daMyers))) ==
      renderUnified(diff(a, b, DiffOptions(algorithm: daPatience)))

  test "histogram still works where patience finds no anchors":
    ## Every line identical, so patience has nothing unique to anchor on and
    ## falls back to Myers. Histogram ranks by frequency instead.
    var a = ""
    var b = ""
    for _ in 1 .. 40: a.add "dup\n"
    for _ in 1 .. 40: b.add "dup\n"
    b.add "new\n"
    let d = diff(a, b, DiffOptions(algorithm: daHistogram))
    check d.stats.added == 1
    check not d.isIdentical

  test "all algorithms handle a wholly replaced file":
    let a = (1 .. 10).mapIt("old " & $it).join("\n") & "\n"
    let b = (1 .. 10).mapIt("new " & $it).join("\n") & "\n"
    for alg in [daMyers, daPatience, daHistogram]:
      let d = diff(a, b, DiffOptions(algorithm: alg))
      check d.stats.removed == 10
      check d.stats.added == 10

# ---------------------------------------------------------------------------
# Truncation
# ---------------------------------------------------------------------------

suite "Diff: edit distance ceiling":
  test "exceeding maxEditDistance coarsens and flags the result":
    ## Two large files with nothing in common: D is roughly N+M, so a low
    ## ceiling has to give up. Reporting it beats grinding or lying.
    var la, lb = newSeqOfCap[string](2000)
    for i in 0 ..< 2000: la.add "alpha " & $i
    for i in 0 ..< 2000: lb.add "omega " & $i
    let d = diff(la.join("\n") & "\n", lb.join("\n") & "\n",
                 DiffOptions(maxEditDistance: 50))
    check d.truncated
    check d.hunks.len == 1
    # Coarsened to a whole-range replacement, which is still an honest answer.
    check d.stats.removed == 2000
    check d.stats.added == 2000

  test "a truncated result is never reported as identical":
    ## `resolved` treats 0 as "unset" and substitutes the default, so this asks
    ## for the smallest ceiling the module will accept rather than none.
    check not diff("a\n", "b\n", DiffOptions(maxEditDistance: 1)).isIdentical

  test "an untruncated small diff sets truncated false":
    check not diff("a\nb\n", "a\nc\n").truncated

  test "a large edit distance still succeeds when under the ceiling":
    ## 100 replacements cost 200 edits, so a ceiling of 500 leaves room and the
    ## search must finish normally rather than coarsen.
    let a = numbered(500)
    let b = renumbered(a, toSeq(0 ..< 100), "CHANGED")
    let d = diff(a, b, DiffOptions(maxEditDistance: 500))
    check not d.truncated
    check d.stats.removed == 100
    check d.stats.added == 100
    # 100 consecutive edits is one contiguous run, and a run of N deletes
    # followed by N inserts pairs up one-to-one, so every line is a change.
    check d.stats.changed == 100

  test "scattered replacements still pair up":
    ## The edits are far apart, so the intra-line pass never sees a delete
    ## immediately followed by an insert and nothing counts as a paired
    ## replacement. Totals are what must hold.
    let a = numbered(500)
    var changed = newSeqOfCap[int](20)
    var i = 0
    while i < 500:
      changed.add i
      i += 25
    let b = renumbered(a, changed, "CHANGED")
    let d = diff(a, b, DiffOptions(maxEditDistance: 500))
    check not d.truncated
    check d.stats.removed == 20
    check d.stats.added == 20
    # Each isolated edit is still a delete immediately followed by an insert,
    # so it counts as a paired replacement: "changed" tracks paired edits, not
    # adjacency in the rendered output.
    check d.stats.changed == 20

# ---------------------------------------------------------------------------
# Statistics
# ---------------------------------------------------------------------------

suite "Diff: stats":
  test "a paired replacement counts as one change":
    let d = diff("let x = 1\n", "let x = 2\n")
    check d.stats.changed == 1
    check d.stats.added == 1
    check d.stats.removed == 1

  test "byte counts exclude terminators":
    let d = diff("abc\n", "abcd\n")
    check d.stats.bytesRemoved == 3
    check d.stats.bytesAdded == 4

  test "unchanged lines contribute nothing":
    let a = numbered(50)
    let b = renumbered(a, [25], "CHANGED")
    let d = diff(a, b)
    check d.stats.added == 1
    check d.stats.removed == 1
    check d.stats.bytesAdded == "CHANGED".len
    check d.stats.hunkCount == 1

  test "stats stringify compactly":
    check $diff("a\n", "b\n").stats == "+1 -1 ~1, 1 hunks"

# ---------------------------------------------------------------------------
# Determinism and views
# ---------------------------------------------------------------------------

suite "Diff: determinism and inputs":
  test "the same input twice gives identical output":
    let a = numbered(100)
    let b = renumbered(a, [3, 17, 42, 88], "CHANGED")
    for alg in [daMyers, daPatience, daHistogram]:
      let one = renderUnified(diff(a, b, DiffOptions(algorithm: alg)))
      let two = renderUnified(diff(a, b, DiffOptions(algorithm: alg)))
      check one == two

  test "seq[byte] input diffs like string input":
    let a = "one\ntwo\n"
    let b = "one\nTWO\n"
    var ba = newSeq[byte](a.len)
    for i, c in a: ba[i] = c.byte
    var bb = newSeq[byte](b.len)
    for i, c in b: bb[i] = c.byte
    let seqResult: Diff = diff(ba, bb)
    let strResult: Diff = diff(a, b)
    check renderUnified(seqResult) == renderUnified(strResult)
    check seqResult.stats == strResult.stats

  test "sameText is true only for byte-identical input":
    check sameText("a\nb\n", "a\nb\n")
    check not sameText("a\nb\n", "a\nb")
    check sameText("", "")

  test "diffFile matches diff on the same bytes":
    let dir = getTempDir() / "openparser_diff_test"
    createDir(dir)
    defer: removeDir(dir)
    let pa = dir / "a.txt"
    let pb = dir / "b.txt"
    let a = "one\ntwo\nthree\n"
    let b = "one\nTWO\nthree\n"
    writeFile(pa, a)
    writeFile(pb, b)
    let fromFile = diffFile(pa, pb)
    check fromFile.stats.added == diff(a, b).stats.added
    check fromFile.stats.removed == diff(a, b).stats.removed
    check fromFile.a.name == pa
    check fromFile.b.name == pb

  test "resolved fills in defaults without losing explicit values":
    let o = resolved(DiffOptions())
    check o.context == DiffContext
    check o.maxEditDistance == DiffMaxEditDistance
    check o.maxSpanBytes == DiffMaxSpanBytes
    check o.intraLine == diOn
    let explicit = resolved(DiffOptions(context: 0 + 7, intraLine: diOff))
    check explicit.context == 7
    check explicit.intraLine == diOff

# ---------------------------------------------------------------------------
# Randomized replay
# ---------------------------------------------------------------------------

suite "Diff: edit script losslessness (randomized)":
  ## The strongest property available without writing a second diff: replaying
  ## the edit script must reconstruct both inputs byte for byte. Any off-by-one
  ## in the search, the anchoring or the trimming shows up here, across
  ## thousands of inputs rather than the handful a hand-written case covers.
  ##
  ## The script is replayed rather than the hunks, and the two are not
  ## interchangeable: hunks deliberately omit unchanged lines outside the
  ## context window, so only the script is a complete description.
  test "the script reconstructs both inputs, across options":
    var rnd = initRand(20261005)
    # Pools chosen to stress the anchoring strategies: a pool of one distinct
    # line leaves patience with nothing unique, and one with empty strings
    # produces zero-length lines.
    var many: seq[string] = @[]
    for i in 0 .. 20: many.add "line " & $i
    let pools = [@["a", "b", "c"], @["x"],
                 @["", "q", "q", "r", "s", "s", "s"], many]

    for trial in 0 ..< 400:
      let pool = pools[rnd.rand(pools.high)]
      # Both terminators, since CRLF puts a \r inside the content and the two
      # must not be conflated.
      let eol = if rnd.rand(2) == 0: "\n" else: "\r\n"
      let a = raggedLines(rnd, rnd.rand(60), pool, eol)
      let b = raggedLines(rnd, rnd.rand(60), pool, eol)
      for alg in [daMyers, daPatience, daHistogram]:
        let opts = DiffOptions(algorithm: alg,
                               maxEditDistance: 200)
        let script = scriptOf(a, b, opts)
        var ra = newStringOfCap(a.len)
        var rb = newStringOfCap(b.len)
        replay(a, b, script, ra, rb)
        if ra != a or rb != b:
          check ra == a
          check rb == b

  test "replaying through hunks reproduces the whole input with wide context":
    var rnd = initRand(4242)
    let pool1 = ["alpha", "beta", "gamma", "delta", "eps", "zeta"]
    let pool2 = ["alpha", "beta", "omega", "delta", "eta", "theta", "phi"]
    for trial in 0 ..< 60:
      let a = mkLines(rnd, rnd.rand(80), pool1)
      let b = mkLines(rnd, rnd.rand(80), pool2)
      for alg in [daMyers, daPatience, daHistogram]:
        # Context wide enough to keep every unchanged line, which makes the
        # hunks a complete description and lets them be replayed too.
        let d = diff(a, b, DiffOptions(algorithm: alg, context: 1000))
        var ra = newStringOfCap(a.len)
        var rb = newStringOfCap(b.len)
        for h in d.hunks:
          for l in h.lines:
            if l.kind in [dlEqual, dlDelete]:
              ra.add a[l.aByte ..< l.aByte + l.aLen]
              if l.eol != eolNone: ra.add "\n"
            if l.kind in [dlEqual, dlInsert]:
              rb.add b[l.bByte ..< l.bByte + l.bLen]
              if l.eol != eolNone: rb.add "\n"
        check ra == a
        check rb == b

  test "line indices are strictly increasing on both sides":
    var rnd = initRand(77)
    let pool = ["p", "q", "r", "s"]
    for _ in 0 ..< 60:
      let a = mkLines(rnd, rnd.rand(40), pool)
      let b = mkLines(rnd, rnd.rand(40), pool)
      for alg in [daMyers, daPatience, daHistogram]:
        let d = diff(a, b, DiffOptions(algorithm: alg, context: 1000))
        var lastA = -1
        for h in d.hunks:
          for l in h.lines:
            if l.aLine >= 0:
              check l.aLine > lastA
              lastA = l.aLine

  test "intra-line spans stay inside their own line":
    ## A span pointing past the line end would make a UI read adjacent memory or
    ## throw, so the bound is asserted rather than assumed.
    var rnd = initRand(31337)
    let pool = ["alpha", "beta", "gamma", "delta", "eps"]
    for _ in 0 ..< 200:
      let a = mkLines(rnd, rnd.rand(30), pool)
      let b = mkLines(rnd, rnd.rand(30), pool)
      let d = diff(a, b, DiffOptions(context: 1000))
      for h in d.hunks:
        for l in h.lines:
          let n = if l.kind == dlInsert: l.bLen else: l.aLen
          for sp in l.spans:
            check sp.start >= 0
            check sp.start <= sp.stop
            check sp.stop <= n

  test "the result is identical across repeated runs":
    ## Determinism is a real requirement, not a nicety: a UI that renders the
    ## same diff twice must show the same thing twice.
    var rnd = initRand(999)
    let pool = ["a", "b", "c", "d", "e"]
    for _ in 0 ..< 80:
      let a = mkLines(rnd, rnd.rand(50), pool)
      let b = mkLines(rnd, rnd.rand(50), pool)
      for alg in [daMyers, daPatience, daHistogram]:
        let opts = DiffOptions(algorithm: alg, context: 2)
        let one = diff(a, b, opts)
        let two = diff(a, b, opts)
        check one.stats == two.stats
        check one.hunks.len == two.hunks.len

# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

suite "Diff: rendering":
  test "headers name the files and use git's ordering":
    let got = renderUnified(diff("a\n", "b\n"))
    check got.startsWith("diff --git /dev/null /dev/null\n")
    check "--- /dev/null\n" in got
    check "+++ /dev/null\n" in got

  test "an empty side renders as /dev/null":
    let d = diff("", "x\n")
    check renderUnified(d).contains("--- /dev/null")

  test "hunk counts omit the ,N suffix for a single line":
    ## Git's own quirk: `@@ -1 +1,2 @@`, not `@@ -1,1 +1,2 @@`.
    let got = renderUnified(diff("", "x\n"))
    check "@@ -0,0 +1 @@" in got

  test "an empty side uses the -0,0 form":
    check "@@ -0,0 +1 @@" in renderUnified(diff("", "x\n"))

  test "the full header for a mid-file change":
    ## Verified against `git diff --no-index --no-prefix` on the same input.
    let a = numbered(10)
    let b = renumbered(a, [4], "CHANGED")
    let got = renderUnified(diff(a, b))
    check got.contains("@@ -2,7 +2,7 @@ l1")

  test "changed lines are prefixed correctly":
    let got = renderUnified(diff("keep\nold\n", "keep\nnew\n"))
    check "-old\n" in got
    check "+new\n" in got
    check " keep\n" in got

  test "renderSummary describes the change":
    check renderSummary(diff("a\n", "a\n")) == "no changes"
    check renderSummary(diff("a\n", "b\n")).contains("+1 lines")
    check renderSummary(diff("a\0b\n", "a\0c\n")) == "binary files differ"

  test "renderSummary notes truncation":
    var la, lb = newSeqOfCap[string](1000)
    for i in 0 ..< 1000: la.add "a " & $i
    for i in 0 ..< 1000: lb.add "b " & $i
    let d = diff(la.join("\n") & "\n", lb.join("\n") & "\n",
                 DiffOptions(maxEditDistance: 10))
    check renderSummary(d).contains("truncated")

  test "contentText reads a line back out of the view":
    let d = diff("one\ntwo\n", "one\nTWO\n")
    let del = d.hunks[0].lines.filterIt(it.kind == dlDelete)[0]
    check contentText(d.a.view, del, true) == "two"
    let ins = d.hunks[0].lines.filterIt(it.kind == dlInsert)[0]
    check contentText(d.b.view, ins, false) == "TWO"

  test "an unterminated line still gets a newline in the output":
    ## Otherwise the marker line would be glued to the content it annotates.
    let got = renderUnified(diff("a", "b"))
    check "-a\n\\ No newline at end of file\n" in got