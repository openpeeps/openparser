# A collection of tiny parsers and dumpers
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/openparser

## Line-level diffing with a structured result and unified-diff rendering.
##
## Two strings in, a `Diff` out. The result describes *what* changed rather
## than *how to print it*: which lines were added, removed or replaced, where
## they sit on each side in both line numbers and byte offsets, and which byte
## range inside a changed line moved. That is the shape a code review UI, a
## merge tool or a language server needs, and `renderUnified` is one formatter
## over it rather than the point of the module.
##
## Known hotspots, measured on 20k unique lines (360 KiB per side) with a
## scattered edit. Numbers from `examples/diff_example.nim`:
##
## Where the time actually goes, measured on 20k lines (360 KiB per side) with
## 100 scattered single-line edits, `examples/diff_example.nim`:
##
## ```
##   myersDiff    1.51 ms   78%   <-- the cost centre
##   indexLines   0.48 ms   25%   both sides
##   buildHunks   0.07 ms    3%   100 hunks, 797 DiffLines
##   renderUnified 0.05 ms   2%
##   computeStats  0.01 ms   0.5%
##   whole diff   1.92 ms         366 MB/s
## ```
##
## Three things worth knowing before optimising anything here.
##
## First, **Myers is the hot spot, not the hunk builder.** An earlier version of
## this comment claimed the opposite, on the strength of a benchmark that was
## wrong: it passed a raw `DiffOptions()` to the search, whose `maxEditDistance`
## is then 0, which clamps to 1 and coarsens the whole file into one giant
## replacement. That made `buildHunks` look like 51% of runtime when it is 3%.
## If you re-measure, resolve the options first — that is what `diff` does, and
## the internal entry points do not do it for you.
##
## Second, **inside Myers it is line comparison, but the obvious fixes to it
## do not work.** The search makes roughly 60k `linesEqual` calls per diff at
## this size, each about 12 ns for a 14-byte line, and two plausible levers were
## implemented and measured at the call site rather than in isolation:
##
## - marking the comparison `{.inline.}`: 7% in isolation
## - hoisting each side into a pointer-based `LineAccess` instead of passing the
##   48-byte `LineIndex` by value on every one of those 60k calls: 29% faster
##   in isolation
##
## Together they made `myersDiff` *9% slower* (1330 -> 1450 us). Both are
## reverted. The isolated numbers were real and misleading: the benchmark loop
## held the access values in registers across the call, which the search's
## inner loop does not, and inlining the comparison appears to cost the
## surrounding frontier loop more in register pressure than the comparison saves.
## Measure at the call site; a micro-benchmark of the inner op is not evidence.
##
## The comparison itself is the algorithm's actual work, not overhead around
## it, so nothing structural has been identified there.
##
## Third, **the byte searches were the one place SIMD could have helped, and
## libc already had it**: swapping the scalar newline loop for `memchr` took
## `indexLines` from 843 to ~1350 MB/s and the whole diff from 128 to ~172 MB/s
## on the (corrected) workload. It reads as 1.6x rather than 5-8x because the
## per-line bookkeeping around the scan is scalar regardless, and that is now
## the floor for the stage. A hand-written `nimsimd` lane was measured against
## this and not worth its parity-test surface.
##
## The anchoring strategies are several times slower than plain Myers almost
## entirely because `keyOf` allocates a `string` per line. That is the one
## allocation this design otherwise avoids, and it is the price of the better
## output. `daMyers` stays the default for exactly this reason; reach for
## patience or histogram when the output quality is worth 5x on a file where it
## actually matters.
##
## Three algorithms, all sharing one engine. Myers produces a minimal edit
## script and is the default because its cost is O((N+M)*D) in the *edit
## distance* rather than in file size. Patience and histogram pick better
## anchors for files full of repeated lines, which is a difference in output
## quality rather than in complexity. All three are bounded by
## `DiffOptions.maxEditDistance`; past that ceiling the result is coarsened and
## `Diff.truncated` says so, rather than the search grinding on.
##
## Bytes are never copied per line. `ByteView` is a borrowed pointer plus a
## length, so the line index is a table of offsets, comparing two lines is a
## `memcmp`, and a file can be memory-mapped without a read. `kernel.nim` holds
## every byte-scanning primitive as a small proc so a SIMD lane can be added
## later and parity-tested against the scalar version without the diff core
## noticing; see `plans/diff-module.md`.
##
## ```nim
## import openparser/diff
##
## let d = diff(before, after)
## echo renderUnified(d)          # git-compatible text
## echo d.stats.added             # for a summary view
## for hunk in d.hunks:
##   for line in hunk.lines:
##     echo line.kind, " ", line.aLine, " -> ", line.bLine
## ```
##
## ```nim
## # Files, mapped rather than read.
## var f = diffFile("a.txt", "b.txt")
## echo renderUnified(f)
## ```
import ./diff/[types, source, lines, script, myers, anchor, intraline,
                 ops, render]

export types
export source
export script
export lines
export ops
export render
export intraline

const
  diffVersion* = "0.1.0" ## module version, independent of the package's

# ---------------------------------------------------------------------------
# Pipeline: ByteView -> LineIndex -> algorithm -> script -> hunks -> Diff
# ---------------------------------------------------------------------------

proc resolved*(opts: DiffOptions): DiffOptions =
  ## `opts` with every zero filled in from the module defaults.
  ##
  ## Exposed because a caller that stores options needs to know what a stored
  ## `DiffOptions()` actually means, and because the renderer takes its own
  ## copy rather than trusting a partially filled one.
  result = opts
  # Zero means "unset" for every numeric option, since a plain object cannot
  # tell an omitted field from one deliberately set to zero. Asking for no
  # context at all therefore needs an explicit sentinel: `DiffNoContext`.
  # Negative is safe because no sane context count is below zero.
  if result.context == 0: result.context = DiffContext
  elif result.context < 0: result.context = 0
  if result.maxEditDistance == 0: result.maxEditDistance = DiffMaxEditDistance
  if result.maxSpanBytes == 0: result.maxSpanBytes = DiffMaxSpanBytes
  if result.intraLine == diAuto: result.intraLine = diOn

proc diff*(aView, bView: ByteView, opts: DiffOptions = DiffOptions()): Diff =
  ## Diff two byte views.
  ##
  ## Both views are borrowed: they must stay alive for as long as the result is
  ## used, since every `DiffLine` holds offsets into them. That is the one rule
  ## a caller has to respect, and `diffFile` exists so most never have to.
  let o = resolved(opts)
  let aIdx = indexLines(aView)
  let bIdx = indexLines(bView)

  result.a = DiffSide(name: "", view: aView, byteLen: aIdx.byteLen,
                      lineCount: aIdx.lines.len, crlf: aIdx.crlf)
  result.b = DiffSide(name: "", view: bView, byteLen: bIdx.byteLen,
                      lineCount: bIdx.lines.len, crlf: bIdx.crlf)
  result.algorithm = o.algorithm
  result.binary = aIdx.binary or bIdx.binary

  # Binary content has no line structure worth diffing, and a hunk full of NUL
  # bytes is unreadable. Detected after indexing because that is where the sniff
  # happens. The decision is recorded on the result so the renderer reports the
  # same thing the caller asked for.
  result.comparedBinary = result.binary and o.ignoreBinary
  if result.binary and not o.ignoreBinary:
    return

  var scriptOps: seq[LineOp] = @[]
  var truncated = false
  case o.algorithm
  of daMyers:
    let (ops, t) = myersDiff(aIdx, bIdx, o)
    scriptOps = ops
    truncated = t
  of daPatience:
    let (ops, t) = patienceDiff(aIdx, bIdx, o)
    scriptOps = ops
    truncated = t
  of daHistogram:
    let (ops, t) = histogramDiff(aIdx, bIdx, o)
    scriptOps = ops
    truncated = t

  result.truncated = truncated
  result.hunks = buildHunks(aIdx, bIdx, scriptOps, o)
  result.stats = computeStats(result.hunks)

proc diff*(a, b: string, opts: DiffOptions = DiffOptions()): Diff =
  ## Diff two strings.
  ##
  ## `a` and `b` are borrowed, not copied, so keep them alive if you intend to
  ## read `spans` or render text afterwards.
  let av = view(a)
  let bv = view(b)
  result = diff(av, bv, opts)
  # Names default to empty, which renders as /dev/null. Set them here rather
  # than inside `diff` so the view overload never has to guess.
  result.a.name = ""
  result.b.name = ""

proc diff*(a, b: seq[byte], opts: DiffOptions = DiffOptions()): Diff =
  ## Diff two byte sequences. Same borrowing rule as the `string` overload.
  diff(view(a), view(b), opts)

proc diffFile*(pathA, pathB: string, opts: DiffOptions = DiffOptions()): Diff =
  ## Diff two files, memory-mapping both.
  ##
  ## The mapping is unmapped when this returns, so the resulting `Diff` borrows
  ## bytes that no longer exist. That is fine for the statistics, hunks and
  ## line offsets, which are all the module reports, but *not* for
  ## `renderUnified`, which needs the bytes. For text output prefer `diff` on
  ## strings you already hold, or read the files yourself and pass the content.
  ##
  ## Raises `IOError` when either file cannot be opened, matching `memfiles`.
  var fa = openFile(pathA)
  defer: fa.deinit()
  var fb = openFile(pathB)
  defer: fb.deinit()
  result = diff(fa.view, fb.view, opts)
  result.a.name = pathA
  result.b.name = pathB

# ---------------------------------------------------------------------------
# Convenience wrappers
# ---------------------------------------------------------------------------

proc sameText*(a, b: string): bool =
  ## Whether two strings are byte-identical.
  ##
  ## Cheaper than a diff and the answer most callers want first. `memcmp` on
  ## equal lengths, so an immediate length check settles most comparisons.
  a.len == b.len and (a.len == 0 or equalMem(unsafeAddr a[0], unsafeAddr b[0],
                                            a.len))

proc diffStats*(a, b: string, opts: DiffOptions = DiffOptions()): DiffStats =
  ## Totals only, without building hunks.
  ##
  ## The hunk builder is the allocation-heavy tail of the pipeline, so a caller
  ## that only wants counts for a file list pays for the diff and not for the
  ## presentation.
  diff(a, b, resolved(opts)).stats