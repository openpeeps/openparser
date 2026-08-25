import std/[unittest, strutils, strformat]
import ../src/openparser/regex/[compiler, vm, lexer]
import ../src/openparser/regex/jit/compiler as jitc

proc jitMatchAt(pattern, input: string, pos: int): int =
  ## Anchored JIT run; -1 when compilation is unsupported or no match.
  let prog = compile(pattern)
  var cj = jitc.compileRegex(prog)
  if cj.fn == nil:
    return -1
  defer: cj.freeJit()
  result = cj.jitExec(input, pos)

proc jitScanAt(pattern, input: string): tuple[start, stop: int] =
  let prog = compile(pattern)
  var cj = jitc.compileRegex(prog)
  if cj.fn == nil:
    return (-1, -1)
  defer: cj.freeJit()
  result = cj.jitScan(input)

proc jitSupported*(pattern: string): bool =
  ## True when the JIT can compile this program.
  var cj = jitc.compileRegex(compile(pattern))
  result = cj.fn != nil
  if cj.fn != nil:
    cj.freeJit()

proc vmFindStop(pattern, input: string): tuple[start, stop: int] =
  ## Interpreter reference: leftmost match via the Pike VM.
  var vm = initRegexVM(compile(pattern))
  let m = vm.find(input)
  if m.matched: (m.start, m.stop) else: (-1, -1)

suite "Regex JIT: literals":
  test "simple literal match":
    check jitMatchAt("hello", "hello world", 0) == 5
  test "literal no match":
    check jitMatchAt("hello", "hellx world", 0) == -1
  test "literal at offset":
    check jitMatchAt("world", "hello world", 6) == 11
    check jitMatchAt("world", "hello world", 5) == -1  # space, not a match start
  test "literal longer than input":
    check jitMatchAt("hello!", "hello", 0) == -1
  test "empty pattern is rejected by parser":
    expect OpenParserRegexError:
      discard compile("")

suite "Regex JIT: any char and classes":
  test "dot matches any char except newline":
    check jitMatchAt("h.llo", "hello", 0) == 5
    check jitMatchAt("h.llo", "hx\nllo", 0) == -1
  test "positive char class":
    check jitMatchAt("[abc]+", "cabba dedab", 0) == 5
    check jitMatchAt("[abc]+", "dedab", 0) == -1
  test "negated char class":
    check jitMatchAt("[^ ]+", "hello world", 0) == 5
    check jitMatchAt("[^a-z]+", "abc123def", 3) == 6
  test "escape classes":
    check jitMatchAt("\\d+", "abc 1234", 4) == 8
    check jitMatchAt("\\d+", "abc", 0) == -1
    check jitMatchAt("\\w+", "  foo_bar99", 2) == 11
    check jitMatchAt("\\s+", "ab   cd", 2) == 5
    check jitMatchAt("\\D+", "1234abc56", 4) == 7
    check jitMatchAt("\\W+", "ab!!cd", 2) == 4
    check jitMatchAt("\\S+", "   abcd  ", 3) == 7

suite "Regex JIT: anchors and boundaries":
  test "start anchor":
    check jitMatchAt("^abc", "abcdef", 0) == 3
    check jitMatchAt("^abc", "xabc", 1) == -1
  test "end anchor":
    check jitMatchAt("abc$", "xxabc", 2) == 5
    check jitMatchAt("abc$", "abcd", 0) == -1
  test "both anchors":
    check jitMatchAt("^abc$", "abc", 0) == 3
    check jitMatchAt("^abc$", "zabcz", 1) == -1
  test "word boundary":
    check jitScanAt("\\bword\\b", "a word here") == (2, 6)
    check jitScanAt("\\bword\\b", "sword") == (-1, -1)
    check jitScanAt("\\bword\\B", "words") == (0, 4)

suite "Regex JIT: quantifiers and alternation (backtracking)":
  test "greedy plus with backtracking":
    check jitMatchAt("a+b", "aaab", 0) == 4
    check jitMatchAt("a+b", "aaa c", 0) == -1
  test "greedy star":
    check jitMatchAt("a*c", "aaac", 0) == 4
    check jitMatchAt("a*c", "c", 0) == 1
  test "lazy plus":
    check jitMatchAt("a+?b", "aaab", 0) == 4
  test "lazy star":
    check jitMatchAt("a*?b", "aab", 0) == 3
  test "alternation":
    check jitScanAt("cat|dog", "hotdog") == (3, 6)
    check jitScanAt("cat|dog", "cat dog") == (0, 3)
    check jitScanAt("cat|dog", "bird") == (-1, -1)
  test "optional":
    check jitMatchAt("colou?r", "color", 0) == 5
    check jitMatchAt("colou?r", "colour", 0) == 6
  test "nested quantifier":
    check jitMatchAt("(?:a+)+b", "aaab", 0) == 4
  test "zero-width loops fall back to interpreter":
    # nullable nested loops contain epsilon cycles; JIT rejects them
    # and the caller must use the interpreter instead.
    check not jitSupported("(?:a*)*b")
    check not jitSupported("(?:a?)*b")
    check jitSupported("(?:a)*b")          # consuming body: safe
    check jitSupported("(?:ab)*c")         # multi-char body: safe

suite "Regex JIT: parity with interpreter":
  proc checkParity(pattern, input: string) =
    let want = vmFindStop(pattern, input)
    let got = jitScanAt(pattern, input)
    if got != want:
      checkpoint(&"case: {pattern} on \"{input}\"")
    check got == want

  test "battery of unambiguous patterns vs VM":
    let cases = [
      ("hello", "say hello world"),
      ("hel+o", "say helllllo world"),
      ("[A-Z][a-z]+", "Hello World foo"),
      ("\\d\\d", "abc 12345"),
      ("a*b", "xaaab"),
      ("ab|a", "zab"),
      ("[aeiou]", "xyz"),
      ("[^0-9]+", "42 is the answer"),
      ("\\w+\\s*=", "foo = bar"),
      ("0[xX][0-9a-fA-F]+", "int x = 0xDEadBeef;"),
      ("\\d+[uUlL]*", "x = 42ULL + 1;"),
      ("end\\s*$", "the end   "),
      ("\\bif\\b", "an if statement"),
      ("\\w+@\\w+\\.com", "mail bob@mail.com now"),
      ("c*t", "tttcccct"),
      ("[ab]*abb", "ababab abba"),
      ("x.?y", "ay xy xyz"),
      ("\\n", "line1\nline2"),
      ("\\.", "a.b.c"),
    ]
    for (pat, inp) in cases:
      checkParity(pat, inp)

  test "alternation prefers first branch (PCRE semantics)":
    # Both the JIT and the interpreter-backed find() now use PCRE-style
    # leftmost-first-alternative matching.
    check jitScanAt("a|ab", "zab") == (1, 2)
    check vmFindStop("a|ab", "zab") == (1, 2)
    check jitScanAt("ab|a", "zab") == (1, 3)