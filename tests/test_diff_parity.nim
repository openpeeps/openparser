import std/[unittest, os, osproc, strutils, sequtils]
import ../src/openparser/diff

## Byte-for-byte comparison against real `git diff --no-index`.
##
## The unit tests pin expected strings inline, which proves we agree with what
## we wrote down. This file proves we agree with git, which is the only oracle
## that cannot drift: every expected string below was produced by git itself,
## not by this module.
##
## Opt-in, because it shells out to git and writes files. Compile with
##
##     -d:diffParity
##
## which the per-file `test_diff_parity.nims` supplies, so plain `clue test`
## leaves it inert and CI stays hermetic. Run it with:
##
##     clue test test_diff_parity
##
## Even when compiled, each test skips itself rather than failing when git is
## not installed, so a missing toolchain cannot look like a diff bug.

const diffParity = defined(diffParity)

proc hasGit(): bool =
  ## Whether git can actually be invoked here.
  ##
  ## Probed once at startup rather than per test, since each probe forks a
  ## process and the answer cannot change mid-run.
  try:
    discard execCmdEx("git --version")
    true
  except OSError:
    false

let gitAvailable = hasGit()

proc enabled(): bool =
  ## Whether the bodies should run at all.
  ##
  ## Both conditions, and both matter. Without `-d:diffParity` the ordinary
  ## `clue test` sweep must not fork git or write files, or CI stops being
  ## hermetic. Without git installed, a failure would look like a diff bug
  ## rather than a missing tool, so the tests skip instead.
  diffParity and gitAvailable

proc runGit(args: string, dest: string): bool =
  ## Run git, redirecting its output to a file, and report success.
  ##
  ## Not `execCmdEx`: on this platform that call strips carriage returns from
  ## captured output, which would delete the exact `\r` this file exists to
  ## compare. Writing to a file and reading it back with `readFile` keeps every
  ## byte, which is why CRLF cases are checked at all.
  let cmd = "git " & args & " > " & quoteShell(dest) & " 2>/dev/null"
  try:
    discard execCmdEx(cmd, options = {poUsePath})
    true
  except OSError:
    false

proc bodyOf(text: string): string =
  ## git's unified output with the lines this module deliberately omits removed,
  ## keeping every remaining byte exactly as git wrote it.
  ##
  ## `index <hash>..<hash> <mode>` carries blob hashes, which are the caller's
  ## business. `diff --git` is compared separately, since it names the file pair
  ## and this module only knows the names it was given.
  ##
  ## Filtering happens on a byte scan rather than via `splitLines`, which treats
  ## `\r\n` as one terminator and would silently drop every carriage return from
  ## the comparison. This file exists to catch exactly that class of difference.
  var start = 0
  var line = 0
  while start <= text.len:
    var stop = start
    while stop < text.len and text[stop] != '\n':
      inc stop
    let isLast = stop >= text.len
    if not (text[start ..< stop].startsWith("index ")):
      if result.len > 0: result.add '\n'
      result.add text[start ..< stop]
    inc line
    if isLast: break
    start = stop + 1

proc rawLines(s: string): seq[string] =
  ## Each line including its trailing `\r`, if any, and excluding the `\n`.
  var start = 0
  for i in 0 ..< s.len:
    if s[i] == '\n':
      result.add s[start .. i]
      start = i + 1

suite "Diff: git parity":
  test "unified output matches git byte for byte":
    ## Cases cover the corners that are easy to get wrong and invisible in a
    ## happy-path test: an empty side, a missing trailing newline on either
    ## side, CRLF against LF, the hunk-coalescing boundary, a whole-file
    ## replacement, and unequal replacement lengths.
    if enabled():
      let dir = getTempDir() / "openparser_diff_parity"
      createDir(dir)
      defer: removeDir(dir)

      # One scratch file for git's output, reused: this is the file that keeps
      # carriage returns intact where `execCmdEx` would drop them.
      let scratch = dir / "git.out"

      proc gitDiff(a, b: string): string =
        discard runGit("diff --no-index --no-prefix " & quoteShell(a) & " " &
                       quoteShell(b), scratch)
        bodyOf(readFile(scratch))

      proc compareCase(name, a, b: string) =
        let pa = dir / (name & ".a")
        let pb = dir / (name & ".b")
        writeFile(pa, a)
        writeFile(pb, b)
        # Names have to be set explicitly: the string overload has no files to
        # take them from, and git echoes the paths it was handed.
        var d = diff(a, b)
        d.a.name = pa.strip(chars = {'/'}, trailing = false)
        d.b.name = pb.strip(chars = {'/'}, trailing = false)
        # Compared as raw lines, not as stripped text: a trailing `\r` is part of
        # the output for a CRLF input and `strip` would quietly discard it.
        check rawLines(renderUnified(d)) == rawLines(gitDiff(pa, pb))

      compareCase("simple", "a\nb\nc\n", "a\nB\nc\n")
      compareCase("one-line-change",
        (1 .. 20).mapIt("line " & $it).join("\n") & "\n",
        (1 .. 20).mapIt(if it == 8: "LINE 8" else: "line " & $it).join("\n") & "\n")
      compareCase("insert-at-top", "", "x\ny\n")
      compareCase("insert-in-middle",
        (1 .. 20).mapIt("l" & $it).join("\n") & "\n",
        ((1 .. 20).mapIt("l" & $it) & @["new1", "new2"]).join("\n") & "\n")
      compareCase("delete-in-middle",
        (1 .. 20).mapIt("l" & $it).join("\n") & "\n",
        ((1 .. 20).mapIt("l" & $it))[1 .. ^1].join("\n") & "\n")
      compareCase("delete-everything", (1 .. 20).mapIt("l" & $it).join("\n") & "\n", "")
      compareCase("both-empty", "", "")
      compareCase("blank-against-one-line", "", "x\n")
      compareCase("unterminated-single-line", "a", "b")
      compareCase("no-trailing-newline-on-a", "a\nb\nc", "a\nb\nc\n")
      compareCase("no-trailing-newline-on-b", "a\nb\nc\n", "a\nb\nc")
      compareCase("no-trailing-newline-on-both", "a\nb\nc", "a\nb\nc")
      compareCase("crlf-to-lf", "a\r\nb\r\n", "a\nb\n")
      compareCase("distant-hunks",
        (1 .. 40).mapIt("x" & $it).join("\n") & "\n",
        (1 .. 40).mapIt(if it in [5, 35]: "CHANGED" else: "x" & $it).join("\n") & "\n")
      compareCase("coalescing-boundary",
        (1 .. 40).mapIt("x" & $it).join("\n") & "\n",
        (1 .. 40).mapIt(if it in [10, 17]: "CHANGED" else: "x" & $it).join("\n") & "\n")
      compareCase("whole-file-replaced",
        (1 .. 5).mapIt("a" & $it).join("\n") & "\n",
        (1 .. 5).mapIt("b" & $it).join("\n") & "\n")
      compareCase("unequal-replacement-lengths",
        (1 .. 3).mapIt("aaa" & $it).join("\n") & "\n",
        (1 .. 3).mapIt("x" & $it).join("\n") & "\n")
      compareCase("two-edits-around-context",
        "k1\nk2\nk3\n", "K1\nk2\nK3\n")
      compareCase("blank-lines", "a\n\n\nb\n", "a\n\nb\n")
      compareCase("trailing-blank-line", "a\nb\n", "a\nb\n\n")
      compareCase("leading-blank-line", "\na\n", "\nb\n")

  test "hunk coalescing boundary matches git":
    ## The rule is "two changes share a hunk when at most 2 * context equal lines
    ## separate them". Swept rather than checked at one point, because being off
    ## by one is invisible in any single example.
    if enabled():
      let dir = getTempDir() / "openparser_diff_parity_coalesce"
      createDir(dir)
      defer: removeDir(dir)

      let base = (1 .. 40).mapIt("l" & $it).join("\n") & "\n"
      proc renumbered(src: string, idx: int, text: string): string =
        var ls = src.splitLines()
        # splitLines yields a trailing "" for a terminated file; drop it so the
        # indices here line up with the 0-based line numbers the module reports.
        discard ls.pop()
        ls[idx] = text
        ls.join("\n") & "\n"

      for gap in 1 .. 12:
        let second = 10 + gap
        let b = renumbered(renumbered(base, 9, "CHANGED"), second - 1, "CHANGED")
        let pa = dir / ("gap" & $gap & ".base")
        let pb = dir / ("gap" & $gap & ".mod")
        writeFile(pa, base)
        writeFile(pb, b)
        let scratch = dir / "git.out"
        discard runGit("diff --no-index --no-prefix " & quoteShell(pa) & " " &
                       quoteShell(pb), scratch)
        let wantHunks = readFile(scratch).splitLines().countIt(it.startsWith("@@"))
        check diff(base, b).hunks.len == wantHunks

  test "binary input matches git":
    if enabled():
      let dir = getTempDir() / "openparser_diff_parity_binary"
      createDir(dir)
      defer: removeDir(dir)
      let pa = dir / "bin.a"
      let pb = dir / "bin.b"
      writeFile(pa, "a\0b\n")
      writeFile(pb, "a\0c\n")
      let scratch = dir / "git.out"
      discard runGit("diff --no-index --no-prefix " & quoteShell(pa) & " " &
                     quoteShell(pb), scratch)
      var d = diff("a\0b\n", "a\0c\n")
      d.a.name = pa.strip(chars = {'/'}, trailing = false)
      d.b.name = pb.strip(chars = {'/'}, trailing = false)
      check rawLines(renderUnified(d)) == rawLines(bodyOf(readFile(scratch)))

  test "identical files produce empty output, as git does":
    ## The case a caller relies on most: exit-status-style "no differences" is
    ## an empty string, not a header with no hunks.
    if enabled():
      let dir = getTempDir() / "openparser_diff_parity_same"
      createDir(dir)
      defer: removeDir(dir)
      let pa = dir / "same.txt"
      writeFile(pa, "a\nb\nc\n")
      let scratch = dir / "git.out"
      discard runGit("diff --no-index --no-prefix " & quoteShell(pa) & " " &
                     quoteShell(pa), scratch)
      check readFile(scratch).strip == ""
      check renderUnified(diff("a\nb\nc\n", "a\nb\nc\n")) == ""
