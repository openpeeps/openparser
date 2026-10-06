# A collection of tiny parsers and dumpers
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/openparser

## Types for the diff model: the public surface that UIs, formatters and
## language servers consume. Nothing here allocates or scans, so a `Diff`
## can be built by any producer and read by any consumer without either
## side knowing about the other.
##
## `ByteView` lives here rather than in `source.nim` because `DiffSide` holds
## one, and everything that reads a `DiffLine` needs it.

type
  ByteView* = object
    ## A read-only window of bytes that live somewhere else.
    ##
    ## A `string` and a memory-mapped file are both just bytes, and the diff
    ## core should not be able to tell them apart, or it stops being testable
    ## with string literals. This is that boundary: a raw pointer plus a
    ## length, mirroring the `data`/`len` pair `json.nim` keeps alongside its
    ## owning `string`.
    ##
    ## A view is a *borrowed* reference. Keeping the bytes alive is the
    ## caller's responsibility; `source.nim` holds the constructors and the
    ## file-backed owner that makes that easy. The zero value is a valid
    ## empty view, which matters because an empty input is a normal case
    ## rather than an error.
    data*: ptr UncheckedArray[byte]
    len*: int

  DiffAlgorithm* = enum
    ## Which search produced the edit script. All three agree on cost and
    ## differ only in output quality. See `DiffAlgorithm`'s use in `diff`.
    daMyers     ## edit-distance shortest script; the default
    daPatience  ## anchor on lines unique to both sides, recurse into Myers
    daHistogram ## anchor on the rarest lines, recurse into Myers

  DiffLineKind* = enum
    dlEqual   ## present on both sides, unchanged
    dlInsert  ## present only on side B
    dlDelete  ## present only on side A

  DiffIntra* = enum
    diAuto  ## compute intra-line spans (the default)
    diOn    ## compute them, stated explicitly
    diOff   ## skip them: line-level detail only, and cheaper

  DiffEol* = enum
    eolNone  ## no line terminator: the file ended without one
    eolLf    ## terminated by a single \n
    eolCrlf  ## terminated by \r\n

  DiffSpan* = object
    ## A half-open byte range `[start, stop)` inside a single line.
    ##
    ## Populated only when `DiffOptions.intraLine` is true and only on
    ## changed lines, so a UI can highlight the words that moved instead of
    ## the whole line. The range refers to the owning side: side A for
    ## `dlDelete`, side B for `dlInsert`.
    start*: int
    stop*: int

  DiffLine* = object
    ## One line of the diff, anchored on both sides where it exists.
    kind*: DiffLineKind
    aLine*: int   ## 0-based line index in side A, or -1 when absent
    bLine*: int   ## 0-based line index in side B, or -1 when absent
    aByte*: int   ## byte offset of the line start in side A, -1 when absent
    bByte*: int   ## byte offset of the line start in side B, -1 when absent
    aLen*: int    ## content length in bytes, excluding the terminator, -1 when absent
    bLen*: int
    spans*: seq[DiffSpan] ## intra-line changed ranges; empty when not computed
    eol*: DiffEol       ## terminator style seen on whichever side carries the line

  DiffHunk* = object
    ## A contiguous run of lines plus surrounding context.
    aStart*, aCount*: int ## 0-based; `-0,0`-style empty side is `aStart == 0, aCount == 0`
    bStart*, bCount*: int
    lines*: seq[DiffLine]
    heading*: string
      ## Source line immediately before the hunk, as `git` prints after `@@`.
      ##
      ## Empty when the hunk starts at the first line of the file, or when the
      ## preceding line is unavailable. Reproduced because `git` prints it, not
      ## because it carries meaning: for plain text it is usually the last line
      ## of leading context, and `git` labels it "function" only when a
      ## language definition matches.

  DiffSide* = object
    ## Metadata for one input, plus the bytes themselves.
    ##
    ## `name` is whatever the caller passed and is echoed by `renderUnified` in
    ## the `---`/`+++` headers. `view` is the borrowed source the offsets in
    ## every `DiffLine` refer to, kept here so a caller can render text long
    ## after the diff without keeping the original string alive itself. It is
    ## only valid while those bytes are: see `ByteView`.
    name*: string
    view*: ByteView
    byteLen*: int  ## total bytes, terminators included
    lineCount*: int
    crlf*: bool    ## true when the file uses CRLF terminators throughout

  DiffStats* = object
    ## Precomputed totals so a caller never has to walk the hunks to draw a
    ## summary bar.
    added*: int      ## whole lines present only in B
    removed*: int    ## whole lines present only in A
    changed*: int    ## lines paired across a replacement that got intra-line spans
    bytesAdded*: int ## content bytes on added lines, terminators excluded
    bytesRemoved*: int
    hunkCount*: int

  Diff* = object
    ## The whole result. A `Diff` with no hunks means the inputs are
    ## byte-identical, which is the cheap thing a caller checks first.
    a*, b*: DiffSide
    hunks*: seq[DiffHunk]
    stats*: DiffStats
    algorithm*: DiffAlgorithm ## which algorithm produced this
    binary*: bool   ## a NUL byte was found in the first 8000 bytes of either side
    truncated*: bool ## `maxEditDistance` was exceeded; hunks are a coarse but valid script
    comparedBinary*: bool
      ## Binary content was diffed anyway, because `DiffOptions.ignoreBinary`
      ## asked for it.
      ##
      ## Recorded rather than left to the renderer because the decision was made
      ## once, at diff time: the hunks exist or they do not, and
      ## `renderUnified` must not contradict the result it was handed.

  DiffOptions* = object
    context*: int           ## unchanged lines kept around each change, default 3
    algorithm*: DiffAlgorithm ## default `daMyers`
    maxEditDistance*: int   ## search-cost ceiling before coarsening, default 2000
    intraLine*: DiffIntra   ## default `diAuto`, which behaves as `diOn`
    maxSpanBytes*: int      ## skip intra-line work above this line length, default 512
    ignoreBinary*: bool     ## diff binary files anyway, default false

  DiffError* = object of ValueError

const
  DiffContext* = 3             ## git's default number of context lines
  DiffMaxEditDistance* = 1000  ## ceiling on the Myers search cost, see `myers.nim`
  DiffMaxSpanBytes* = 512      ## longest line still diffed byte-by-byte
  DiffBinarySniff* = 8000      ## bytes inspected for a NUL, matching git

  DiffNoContext* = -1
    ## Pass as `DiffOptions.context` to ask for no context lines at all.
    ##
    ## Needed because zero means "unset" for a numeric field in a plain object,
    ## so `context: 0` cannot be told apart from omitting it. Matches git's
    ## `-U0`, which is the one caller that genuinely wants changed lines alone.

proc `[]`*(v: ByteView, i: int): byte {.inline.} =
  ## One byte. Bounds are checked, because a wrong index means a bug and
  ## silence would only move the failure somewhere less obvious.
  v.data[i]

proc at*(v: ByteView, i: int): ptr UncheckedArray[byte] {.inline.} =
  ## Address of byte `i` as a typed pointer, for the bulk primitives that want
  ## one rather than a per-byte accessor.
  ##
  ## The one escape hatch in the module. Reached only from `kernel.nim` and only
  ## after a length check, so no caller can read out of bounds through it. Nil
  ## for an empty view, which callers never index.
  ##
  ## Offsetting goes through `uint` rather than `p + i` because Nim defines
  ## arithmetic on a scalar pointer but not on an `UncheckedArray` one.
  if v.data == nil:
    return cast[ptr UncheckedArray[byte]](nil)
  cast[ptr UncheckedArray[byte]](cast[uint](cast[pointer](v.data)) + uint(i))

proc size*(v: ByteView): int {.inline.} = v.len

proc isEmpty*(v: ByteView): bool {.inline.} = v.data == nil or v.len == 0

proc `==`*(a, b: DiffSpan): bool = a.start == b.start and a.stop == b.stop

proc spanLen*(s: DiffSpan): int {.inline.} = s.stop - s.start

proc contains*(s: DiffSpan, index: int): bool =
  ## True when `index` falls inside the span, `[start, stop)`.
  index >= s.start and index < s.stop

proc slice*(s: DiffSpan, content: string): string =
  ## The span's slice of a line's content, for a caller that wants the changed
  ## text rather than the range.
  content[s.start ..< s.stop]

proc `$`*(k: DiffLineKind): string =
  ## Short name, for logs and error messages.
  case k
  of dlEqual: "equal"
  of dlInsert: "insert"
  of dlDelete: "delete"

proc `$`*(a: DiffAlgorithm): string =
  ## Short name, matching the enum field.
  case a
  of daMyers: "myers"
  of daPatience: "patience"
  of daHistogram: "histogram"

proc `$`*(d: DiffStats): string =
  ## Compact summary: `+12 -3 ~1, 2 hunks`.
  "+" & $d.added & " -" & $d.removed & " ~" & $d.changed & ", " &
    $d.hunkCount & " hunks"