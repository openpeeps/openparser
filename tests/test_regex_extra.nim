import std/[unittest, strutils]
import ../src/openparser/regex/[lexer, parser, compiler, prefilter, vm]

proc substr(input: string, m: MatchResult): string =
  if m.matched: input[m.start ..< m.stop] else: ""

suite "Negated class in execFull (captures)":
  test "[^X]* inside a capture group matches":
    var vm = initRegexVM(compile("\"([^\\\"]*)\""))
    let src = "say \"hello\" world"
    let m = vm.find(src)
    check m.matched
    check substr(src, m) == "\"hello\""
    check m.groupStr(src, 1) == "hello"

  test "[^X]* with capture between literals":
    var vm = initRegexVM(compile(r"a([^b]*)c"))
    let src = "axc"
    let m = vm.find(src)
    check m.matched
    check substr(src, m) == "axc"
    check m.groupStr(src, 1) == "x"

  test "block comment pattern (execFull) matches":
    var vm = initRegexVM(compile(r"/\*[^*]*\*+([^/*][^*]*\*+)*/"))
    let src = "/* foo */"
    let m = vm.find(src)
    check m.matched
    check substr(src, m) == "/* foo */"

  test "block comment pattern with inner stars":
    var vm = initRegexVM(compile(r"/\*[^*]*\*+([^/*][^*]*\*+)*/"))
    let src = "x /* a * b */ y"
    let m = vm.find(src)
    check m.matched
    check substr(src, m) == "/* a * b */"

suite "Negated class backtracking":
  test "a[^b]*c backtracks when suffix needs a shorter loop":
    var vm = initRegexVM(compile(r"a[^b]*c"))
    let src = "axc"
    let m = vm.find(src)
    check m.matched
    check substr(src, m) == "axc"

  test "a[^b]*c cannot cross a b":
    var vm = initRegexVM(compile(r"a[^b]*c"))
    check not vm.find("axbc").matched

  test "[^a]*ab requires the a-terminated run":
    var vm = initRegexVM(compile(r"[^a]*ab"))
    let m = vm.find("babb")
    check m.matched
    check substr("babb", m) == "bab"

  test "[^a]*b matches from a b-terminated run":
    var vm = initRegexVM(compile(r"[^a]*b"))
    let m = vm.find("zb")
    check m.matched
    check substr("zb", m) == "zb"
    ## leftmost match in "ab" is "b" at index 1 (the 'a' blocks the loop)
    check substr("ab", vm.find("ab")) == "b"
    var vmAnchored = initRegexVM(compile(r"^[^a]*b$"))
    check vmAnchored.match("zb").matched
    check not vmAnchored.match("ab").matched

  test "[^>]*> (safe successor) still SIMD-jumps correctly":
    var vm = initRegexVM(compile(r"<[^>]*>"))
    let m = vm.find("a <b> c")
    check m.matched
    check substr("a <b> c", m) == "<b>"

suite "Lazy negated class":
  test "lazy [^X]*? finds the shortest match":
    var vm = initRegexVM(compile("\"([^\\\"]*?)\""))
    let src = "say \"ab\" then \"cd\""
    let m = vm.find(src)
    check m.matched
    check substr(src, m) == "\"ab\""

suite "Multi-thread execFast with [^X]*":
  test "alternation with comment branch (multi-thread)" :
    var vm = initRegexVM(compile(r"//[^\n]*|foo"))
    let src = "// hi\nfoo"
    let m = vm.find(src)
    check m.matched
    check substr(src, m) == "// hi"

  test "alternation second branch matches when comment absent":
    var vm = initRegexVM(compile(r"//[^\n]*|foo"))
    let src = "foo"
    let m = vm.find(src)
    check m.matched
    check substr(src, m) == "foo"

  test "comment branch reaches end of input":
    var vm = initRegexVM(compile(r"//[^\n]*|foo"))
    let src = "// hi"
    let m = vm.find(src)
    check m.matched
    check substr(src, m) == "// hi"

  test "anchored [^\n]*$ still respects newline":
    var vm = initRegexVM(compile(r"//[^\n]*$"))
    check vm.match("// foo").matched
    check not vm.match("// foo\nbar").matched

suite "Word boundaries":
  test r"\b\w+\b finds first word":
    var vm = initRegexVM(compile(r"\b\w+\b"))
    let m = vm.find("hello world")
    check m.matched
    check substr("hello world", m) == "hello"

  test r"\bcat\b does not match inside a word":
    var vm = initRegexVM(compile(r"\bcat\b"))
    check not vm.find("concatenate").matched
    let m = vm.find("a cat")
    check m.matched
    check substr("a cat", m) == "cat"

  test r"^\b\d+\b$ anchored boundaries":
    var vm = initRegexVM(compile(r"^\b\d+\b$"))
    check vm.match("42").matched
    check not vm.match("4x2").matched

  test r"\b is an assertion, not a literal 'b'":
    var vm = initRegexVM(compile(r"\bfoo"))
    check vm.match("foo").matched
    check not vm.find("boo").matched

  test r"\B matches only inside a word":
    var vm = initRegexVM(compile(r"e\B"))
    let src = "here"
    let m = vm.find(src)
    check m.matched
    check substr(src, m) == "e"
    check not vm.find("the").matched

  test r"\b in a capture group (execFull)":
    var vm = initRegexVM(compile(r"(\b\w+\b)"))
    let src = "hi there"
    let m = vm.find(src)
    check m.matched
    check m.groupStr(src, 1) == "hi"
