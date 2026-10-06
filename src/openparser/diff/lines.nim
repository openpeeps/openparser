# A collection of tiny parsers and dumpers
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/openparser

## One pass over a `ByteView` producing the line table every later stage
## reads. Splitting lines is O(bytes) and happens exactly once per side, so
## this is where the newline scan cost is paid and nowhere else. The scan itself
## is libc `memchr`; the per-line bookkeeping around it is scalar either way,
## which is why the whole stage does not get the full speed-up.
##
## Terminator handling is byte-exact, deliberately. `git diff --no-index`
## splits on `\n` and leaves the `\r` inside the line content, so a file that
## changed only its line endings really did change on every line. Normalising
## here would quietly hide that, and whether to forgive line-ending changes is
## the caller's decision, not the scanner's.
##
## One consequence worth stating plainly: a `\r` immediately before the `\n`
## is content, not terminator, so `LineSpan.contentLen` counts it. That is
## what keeps a CRLF file byte-identical to itself, and it is why `DiffEol`
## records terminator style separately from content length.

import ./types
import ./kernel

type
  LineSpan* = object
    ## One line, as a range into the original bytes.
    ##
    ## `contentLen` includes any `\r` preceding the `\n` and excludes the
    ## `\n` itself. `eol` records how the line was terminated, so the
    ## renderer can reproduce the file byte for byte and annotate a missing
    ## final newline without re-inspecting the source.
    byteStart*: int
    contentLen*: int
    eol*: DiffEol

  LineIndex* = object
    ## Every line in one input, plus the facts a diff header reports.
    ##
    ## Holds no copies of the bytes: each line is an offset into `view`, and
    ## the index borrows that view. Cost is one `LineSpan` per line instead
    ## of one `string` per line, and the index stays valid exactly as long as
    ## its view does.
    view*: ByteView
    lines*: seq[LineSpan]
    byteLen*: int
    crlf*: bool           ## every terminator was CRLF
    trailingNewline*: bool
    binary*: bool         ## a NUL byte appeared in the sniffed prefix

  LineTables* = object
    ## Both inputs indexed at once: the shape the diff core consumes.
    a*: LineIndex
    b*: LineIndex

proc indexLines*(v: ByteView, sniff = DiffBinarySniff): LineIndex =
  ## Scan a view once, recording a `LineSpan` per line.
  ##
  ## The table is sized from a byte heuristic rather than grown a line at a
  ## time. Text lines average tens of bytes, so `bytes / 32` is a close first
  ## guess and one allocation usually covers the whole file.
  result.view = v
  result.byteLen = v.len
  if v.isEmpty:
    # An empty file holds no lines, not one empty line. `git` agrees: no hunk
    # for two empty files, and `@@ -0,0` against a non-empty one.
    result.crlf = true
    return

  # Binary detection is one bounded scan over the sniff window, done before the
  # line loop rather than inside it. The per-line form it replaces re-derived
  # the same running window on every iteration, which meant a second pass over
  # the first `sniff` bytes interleaved with the first `sniff / lineLen`
  # iterations of the main scan.
  result.binary = findByte(v, 0, min(v.len, max(0, sniff)), nulByte) >= 0

  result.lines = newSeqOfCap[LineSpan](max(8, v.len div 32))
  var pos = 0
  var crlfCount = 0
  var lfCount = 0

  while pos < v.len:
    let nl = findNewline(v, pos, v.len)
    if nl < 0:
      # Trailing bytes with no terminator: still a line, just unterminated.
      # This is the case that produces "\ No newline at end of file".
      result.lines.add LineSpan(byteStart: pos, contentLen: v.len - pos,
                                eol: eolNone)
      break
    if nl > pos and v[nl - 1] == crByte:
      inc crlfCount
      result.lines.add LineSpan(byteStart: pos, contentLen: nl - pos,
                                eol: eolCrlf)
    else:
      inc lfCount
      result.lines.add LineSpan(byteStart: pos, contentLen: nl - pos,
                                eol: eolLf)
    pos = nl + 1

  result.trailingNewline = endsWithNewline(v)
  result.crlf = crlfCount > 0 and lfCount == 0

proc lineCount*(ix: LineIndex): int = ix.lines.len

proc isLastUnterminated*(ix: LineIndex): bool =
  ## Whether the final line lacks a terminator, the only case worth
  ## annotating in the output.
  ix.lines.len > 0 and ix.lines[^1].eol == eolNone

proc eolOf*(ix: LineIndex, idx: int): DiffEol =
  ## Terminator style of line `idx`, or `eolNone` when out of range.
  if idx < 0 or idx >= ix.lines.len: eolNone else: ix.lines[idx].eol

proc linesEqual*(a: LineIndex, aIdx: int, b: LineIndex, bIdx: int): bool =
  ## Whether two lines are identical in content *and* termination.
  ##
  ## The terminator counts as part of the line. `git` treats "c" and "c\n" as
  ## different, and so must this: comparing content alone would report two
  ## files as identical when one gained its final newline, which is precisely
  ## the change a trailing-newline check exists to catch.
  ##
  ## Content length is compared first because it settles most mismatched pairs
  ## without touching memory, and the byte comparison means lines are never
  ## copied into strings merely to be tested. Indices are bounds-checked
  ## because a caller deep in a recursion can legitimately arrive at a range
  ## where one side is exhausted.
  if aIdx < 0 or bIdx < 0: return false
  if aIdx >= a.lines.len or bIdx >= b.lines.len: return false
  let la = a.lines[aIdx]
  let lb = b.lines[bIdx]
  if la.contentLen != lb.contentLen or la.eol != lb.eol: return false
  if la.contentLen == 0: return true
  equalRange(a.view, la.byteStart, b.view, lb.byteStart, la.contentLen)

proc contentOf*(ix: LineIndex, idx: int): string =
  ## Copy one line's content as a `string`.
  ##
  ## Only for keys that must outlive the borrow, namely the patience and
  ## histogram anchor tables. Comparing lines never goes through here, since
  ## that is the one allocation this design is built to avoid.
  if idx < 0 or idx >= ix.lines.len: return ""
  lineContent(ix.view, ix.lines[idx].byteStart, ix.lines[idx].contentLen)

proc keyOf*(ix: LineIndex, idx: int): string =
  ## Line content plus a terminator marker, as a hashable key.
  ##
  ## The marker goes at the *front* so it cannot collide with line content: a
  ## line reading "a" must not key the same as a line reading "a\n", and any
  ## byte could legitimately appear in content. Prefix placement makes the key
  ## unambiguous for any content at all, and keeps `keyOf` agreeing with
  ## `linesEqual` about what a line is.
  if idx < 0 or idx >= ix.lines.len:
    return "\x00-"
  case ix.lines[idx].eol
  of eolCrlf: result = "\x00\r"
  of eolLf: result = "\x00\n"
  of eolNone: result = "\x00"
  result.add lineContent(ix.view, ix.lines[idx].byteStart,
                         ix.lines[idx].contentLen)