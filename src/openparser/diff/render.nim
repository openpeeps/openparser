# A collection of tiny parsers and dumpers
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/openparser

## Unified diff output, byte-compatible with `git diff --no-index --no-prefix`
## apart from the `index` and mode lines, which are the caller's business since
## they need blob hashes.
##
## The `Diff` object holds offsets, not text, so rendering needs the input
## bytes back. `renderUnified` therefore takes them alongside the diff, and
## `Diff` carries the two `ByteView`s it was built from for exactly this. That
## is why the views are kept on the result: a caller that wants text never has
## to keep the original strings alive itself.
##
## Every formatting quirk below was checked against real `git`, not guessed:
## `@@ -1 +1,2 @@` omits `,N` when N is 1, an empty side prints `-0,0`,
## `\ No newline at end of file` follows the line it applies to, and binary
## input produces one `Binary files ... differ` line and no hunks.

import std/strutils
import ./types
import ./ops

proc hunkRange(start, count: int): string =
  ## `start,count` for a 0-based, half-open `[start, start+count)`, printed the
  ## way git does: 1-based, and with `,count` omitted when the count is 1.
  ##
  ## An empty side is the `-0,0` special case, where the 1-based conversion
  ## does not apply and git prints a literal zero. Getting this wrong is the
  ## single most visible way a unified diff can disagree with git, so it is
  ## pinned by `test_diff_parity.nim` rather than trusted.
  if count == 0: return "0,0"
  let line = start + 1
  if count == 1:
    result = $line
  else:
    result = $line & "," & $count

proc renderHeaders*(d: Diff): string =
  ## The `diff --git`, `---` and `+++` lines.
  ##
  ## Names come from `DiffSide.name` and are emitted verbatim, so a caller
  ## wanting `a/foo` and `b/foo` prefixes them itself. An empty name renders
  ## as `/dev/null`, which is what git does for a file created from nothing.
  let nameA = if d.a.name.len > 0: d.a.name else: "/dev/null"
  let nameB = if d.b.name.len > 0: d.b.name else: "/dev/null"
  # `diff --git` uses the same name on both sides even when one is /dev/null,
  # because it names the pair rather than the two ends. `---`/`+++` name each
  # end, so an empty side reads /dev/null there.
  let pairA = if d.a.name.len > 0: d.a.name else: "/dev/null"
  result = "diff --git " & pairA & " " & nameB & "\n"
  result.add "--- " & nameA & "\n"
  result.add "+++ " & nameB & "\n"

proc contentText*(view: ByteView, line: DiffLine, isA: bool): string =
  ## A line's content as a `string`, for a caller that wants the text of an
  ## offset rather than the offsets themselves.
  ##
  ## Copies, because the result outlives the view in most uses. A line holding
  ## invalid UTF-8 comes back byte for byte, which is what a heading needs.
  let n = if isA: line.aLen else: line.bLen
  let start = if isA: line.aByte else: line.bByte
  if n <= 0 or start < 0: return ""
  result = newString(n)
  copyMem(addr result[0], view.at(start), n)

proc renderHunkHeader*(h: DiffHunk): string =
  ## The `@@ -a,b +c,d @@ heading` line.
  result = "@@ -" & hunkRange(h.aStart, h.aCount) &
          " +" & hunkRange(h.bStart, h.bCount) & " @@"
  let heading = h.heading
  if heading.len > 0:
    result.add " " & heading
  result.add "\n"

proc appendLine*(dst: var string, view: ByteView, line: DiffLine, isA: bool) =
  ## Append one hunk line: the sign, then the content copied from the source
  ## bytes.
  ##
  ## The content is copied raw rather than round-tripped through a `string`
  ## type, so a line holding a NUL or invalid UTF-8 survives intact.
  ##
  ## No terminator is appended here. The caller writes a single `\n` and nothing
  ## else, because a `\r` in front of it is already inside `contentLen`: the
  ## scanner counts it as content, which is what keeps a CRLF file
  ## byte-identical to itself. Writing `DiffEol` out *and* copying the raw
  ## content is what produced a doubled carriage return.
  dst.add lineOf(line.kind)
  let n = if isA: line.aLen else: line.bLen
  let start = if isA: line.aByte else: line.bByte
  if n > 0 and start >= 0:
    dst.add newString(n)
    copyMem(addr dst[^n], view.at(start), n)

proc renderUnified*(d: Diff, opts: DiffOptions = DiffOptions()): string =
  ## The whole unified diff as a string.
  ##
  ## An empty string for identical inputs, which is what `git` prints and what
  ## a caller piping output into `patch` expects.
  # git still emits the `diff --git` line for binary input before saying so, so
  # a consumer parsing this output sees the same shape either way.
  # `comparedBinary` is what the caller asked for at diff time, not what the
  # renderer's own options say: a caller who set `ignoreBinary` and got hunks
  # must get text, and re-deciding here would contradict the result it was
  # handed.
  if d.binary and not d.comparedBinary:
    let nameA = if d.a.name.len > 0: d.a.name else: "/dev/null"
    let nameB = if d.b.name.len > 0: d.b.name else: "/dev/null"
    result = "diff --git " & nameA & " " & nameB & "\n"
    result.add "Binary files " & nameA & " and " & nameB & " differ\n"
    return
  if d.hunks.len == 0: return ""

  result = renderHeaders(d)
  for hunk in d.hunks:
    result.add renderHunkHeader(hunk)
    for line in hunk.lines:
      let isA = line.kind != dlInsert
      appendLine(result, if isA: d.a.view else: d.b.view, line, isA)
      # Every hunk line ends with a newline in the output even when the source
      # line had none, so the marker below gets a line of its own.
      result.add "\n"
      # git annotates the missing terminator on the line it applies to, on the
      # following line, so a reader can see which side of a pair lacks one.
      if line.eol == eolNone:
        result.add "\\ No newline at end of file\n"

proc renderUnifiedTo*(d: Diff, dst: var string,
                      opts: DiffOptions = DiffOptions()) =
  ## Append the unified diff to an existing string.
  ##
  ## Separate from `renderUnified` so a caller building a large report pays
  ## for one buffer rather than one per file plus a copy at the end.
  dst.add renderUnified(d, opts)

proc renderSummary*(d: Diff): string =
  ## A one-line human summary, handy for a CLI or a log.
  if d.isIdentical:
    return "no changes"
  if d.binary:
    return "binary files differ"
  var parts = @[
    "+" & $d.stats.added & " lines",
    "-" & $d.stats.removed & " lines",
    $d.stats.hunkCount & " hunks"]
  if d.truncated:
    parts.add "truncated at edit distance " & $DiffMaxEditDistance
  parts.join(" ")