import std/[unittest, times, strformat, sequtils, strutils]
import ../src/openparser/regex/[lexer, parser, compiler, prefilter, vm]

# ---------------------------------------------------------------------------
# Lexer
# ---------------------------------------------------------------------------

suite "Lexer":
  test "plain characters":
    var lex = initRegexLexer("abc")
    let t1 = lex.getToken()
    check t1.kind == tkChar and t1.lexeme == "a"
    let t2 = lex.getToken()
    check t2.kind == tkChar and t2.lexeme == "b"
    let t3 = lex.getToken()
    check t3.kind == tkChar and t3.lexeme == "c"
    check lex.getToken().kind == tkEof

  test "meta tokens":
    var lex = initRegexLexer(r"^$.|*+?")
    check lex.getToken().kind == tkCaret
    check lex.getToken().kind == tkDollar
    check lex.getToken().kind == tkDot
    check lex.getToken().kind == tkPipe
    check lex.getToken().kind == tkStar
    check lex.getToken().kind == tkPlus
    check lex.getToken().kind == tkQuestion
    check lex.getToken().kind == tkEof

  test "brackets and braces":
    var lex = initRegexLexer("()[]{}")
    check lex.getToken().kind == tkLParen
    check lex.getToken().kind == tkRParen
    check lex.getToken().kind == tkLBracket
    check lex.getToken().kind == tkRBracket
    check lex.getToken().kind == tkLBrace
    check lex.getToken().kind == tkRBrace

  test "escaped sequences":
    var lex = initRegexLexer(r"\d\w\s\D\W\S\n\t")
    for expected in ['d','w','s','D','W','S','n','t']:
      let tok = lex.getToken()
      check tok.kind == tkEscaped
      check tok.lexeme[0] == expected
    check lex.getToken().kind == tkEof

  test "digits as numbers":
    var lex = initRegexLexer("123")
    let t = lex.getToken()
    check t.kind == tkNumber
    check t.lexeme == "123"

  test "digits as numbers – single digit":
    var lex = initRegexLexer("5")
    let t = lex.getToken()
    check t.kind == tkNumber
    check t.lexeme == "5"

  test "hyphen inside brackets":
    var lex = initRegexLexer("[a-z]")
    check lex.getToken().kind == tkLBracket
    check lex.getToken().kind == tkChar       # 'a'
    check lex.getToken().kind == tkHyphen
    check lex.getToken().kind == tkChar       # 'z'
    check lex.getToken().kind == tkRBracket

  test "position tracking":
    var lex = initRegexLexer("ab")
    let t1 = lex.getToken()
    check t1.col == 1
    let t2 = lex.getToken()
    check t2.col == 2

# ---------------------------------------------------------------------------
# Parser
# ---------------------------------------------------------------------------

suite "Parser":
  test "single char":
    var p = initRegexParser("a")
    let ast = p.parse()
    check ast.kind == rnChar
    check ast.ch == 'a'

  test "concat":
    var p = initRegexParser("ab")
    let ast = p.parse()
    check ast.kind == rnConcat
    check ast.children.len == 2

  test "alternation":
    var p = initRegexParser("a|b")
    let ast = p.parse()
    check ast.kind == rnAlternation
    check ast.children.len == 2

  test "triple alternation":
    var p = initRegexParser("a|b|c")
    let ast = p.parse()
    check ast.kind == rnAlternation
    check ast.children.len == 3

  test "group":
    var p = initRegexParser("(a)")
    let ast = p.parse()
    check ast.kind == rnGroup
    check ast.child.kind == rnChar

  test "star quantifier":
    var p = initRegexParser("a*")
    let ast = p.parse()
    check ast.kind == rnQuantifier
    check ast.min == 0
    check ast.max == -1
    check not ast.lazy

  test "plus quantifier":
    var p = initRegexParser("a+")
    let ast = p.parse()
    check ast.kind == rnQuantifier
    check ast.min == 1
    check ast.max == -1

  test "question quantifier":
    var p = initRegexParser("a?")
    let ast = p.parse()
    check ast.kind == rnQuantifier
    check ast.min == 0
    check ast.max == 1

  test "lazy star":
    var p = initRegexParser("a*?")
    let ast = p.parse()
    check ast.kind == rnQuantifier
    check ast.lazy

  test "range quantifier exact":
    var p = initRegexParser("a{3}")
    let ast = p.parse()
    check ast.kind == rnQuantifier
    check ast.min == 3
    check ast.max == 3

  test "range quantifier bounded":
    var p = initRegexParser("a{2,5}")
    let ast = p.parse()
    check ast.kind == rnQuantifier
    check ast.min == 2
    check ast.max == 5

  test "range quantifier unbounded":
    var p = initRegexParser("a{2,}")
    let ast = p.parse()
    check ast.kind == rnQuantifier
    check ast.min == 2
    check ast.max == -1

  test "dot":
    var p = initRegexParser(".")
    let ast = p.parse()
    check ast.kind == rnDot

  test "anchors":
    var p = initRegexParser("^a$")
    let ast = p.parse()
    check ast.kind == rnConcat
    check ast.children[0].kind == rnAnchorStart
    check ast.children[2].kind == rnAnchorEnd

  test "char class simple":
    var p = initRegexParser("[abc]")
    let ast = p.parse()
    check ast.kind == rnCharClass
    check not ast.negated

  test "char class negated":
    var p = initRegexParser("[^abc]")
    let ast = p.parse()
    check ast.kind == rnCharClass
    check ast.negated

  test "char class range":
    var p = initRegexParser("[a-z]")
    let ast = p.parse()
    check ast.kind == rnCharClass
    check ast.items.len == 1
    check ast.items[0].isRange
    check ast.items[0].lo == 'a'
    check ast.items[0].hi == 'z'

  test "escaped digit class":
    var p = initRegexParser(r"\d")
    let ast = p.parse()
    check ast.kind == rnEscaped
    check ast.escape == 'd'

  test "nested group":
    var p = initRegexParser("((a))")
    let ast = p.parse()
    check ast.kind == rnGroup
    check ast.child.kind == rnGroup

  test "capture count":
    var p = initRegexParser("(a)(b)")
    discard p.parse()
    check p.captureCount == 2

# ---------------------------------------------------------------------------
# Compiler
# ---------------------------------------------------------------------------

suite "Compiler":
  test "single char emits CHAR + MATCH":
    let prog = compile("a")
    check prog.instrs.len == 2
    check prog.instrs[0].op == opChar
    check prog.instrs[0].arg1 == ord('a')
    check prog.instrs[1].op == opMatch

  test "concat emits sequential CHARs":
    let prog = compile("ab")
    check prog.instrs[0].op == opChar
    check prog.instrs[0].arg1 == ord('a')
    check prog.instrs[1].op == opChar
    check prog.instrs[1].arg1 == ord('b')
    check prog.instrs[2].op == opMatch

  test "alternation a|b":
    let prog = compile("a|b")
    check prog.instrs[0].op in {opSplit, opSplitLazy}

  test "star quantifier a*":
    let prog = compile("a*")
    check prog.instrs.anyIt(it.op in {opSplit, opSplitLazy})

  test "plus quantifier a+":
    let prog = compile("a+")
    check prog.instrs.anyIt(it.op == opChar)
    check prog.instrs.anyIt(it.op in {opSplit, opSplitLazy})

  test "dot emits ANYCHAR":
    let prog = compile(".")
    check prog.instrs[0].op == opAnyChar

  test "anchor start":
    let prog = compile("^a")
    check prog.instrs[0].op == opAnchorStart

  test "anchor end":
    let prog = compile("a$")
    check prog.instrs[1].op == opAnchorEnd

  test "char class stored in classes table":
    let prog = compile("[abc]")
    check prog.classes.len == 1

  test "escape class emits opEscapeClass":
    let prog = compile(r"\d")
    check prog.instrs[0].op == opEscapeClass

  test "capture group emits opSave":
    let prog = compile("(a)")
    check prog.instrs.anyIt(it.op == opSave)

  test "numCaptures set correctly – one group":
    let prog = compile("(a)")
    check prog.numCaptures == 1

  test "numCaptures set correctly – two groups":
    let prog = compile("(a)(b)")
    check prog.numCaptures == 2

  test "range quantifier {3} emits 3 copies":
    let prog = compile("a{3}")
    check prog.instrs.countIt(it.op == opChar and it.arg1 == ord('a')) == 3

  test "disassembler produces non-empty string":
    let prog = compile("a+")
    check disassemble(prog).len > 0

# ---------------------------------------------------------------------------
# VM – match (anchored)
# ---------------------------------------------------------------------------

suite "VM – match (anchored)":
  test "exact match":
    var vm = initRegexVM(compile("^abc$"))
    check vm.match("abc").matched

  test "no match":
    var vm = initRegexVM(compile("^abc$"))
    check not vm.match("abd").matched

  test "star – zero repetitions":
    var vm = initRegexVM(compile("^ab*c$"))
    check vm.match("ac").matched

  test "star – multiple":
    var vm = initRegexVM(compile("^ab*c$"))
    check vm.match("abbbbc").matched

  test "plus – at least one":
    var vm = initRegexVM(compile("^ab+c$"))
    check not vm.match("ac").matched
    check vm.match("abbc").matched

  test "question – optional present":
    var vm = initRegexVM(compile("^colou?r$"))
    check vm.match("colour").matched

  test "question – optional absent":
    var vm = initRegexVM(compile("^colou?r$"))
    check vm.match("color").matched

  test "alternation":
    var vm = initRegexVM(compile("^cat|dog$"))
    check vm.match("cat").matched

  test "char class":
    var vm = initRegexVM(compile("^[abc]+$"))
    check vm.match("abcba").matched
    check not vm.match("abcd").matched

  test "negated char class":
    var vm = initRegexVM(compile("^[^aeiou]+$"))
    check vm.match("rhythm").matched
    check not vm.match("aaa").matched

  test "dot matches any non-newline":
    var vm = initRegexVM(compile("^a.c$"))
    check vm.match("abc").matched
    check vm.match("axc").matched
    check not vm.match("a\nc").matched

  test "anchor start":
    check vm.find("^hello", "hello world").matched
    check not vm.find("^hello", "say hello").matched

  test "anchor end":
    check vm.find(r"world$", "hello world").matched
    check not vm.find(r"world$", "world tour").matched

  test "escape \\d":
    var vm = initRegexVM(compile(r"^\d+$"))
    check vm.match("12345").matched
    check not vm.match("123a5").matched

  test "escape \\w":
    var vm = initRegexVM(compile(r"^\w+$"))
    check vm.match("hello_1").matched
    check not vm.match("hello!").matched

  test "escape \\s":
    var vm = initRegexVM(compile(r"^\s+$"))
    check vm.match("   \t").matched
    check not vm.match("a b").matched

  test "escape \\D":
    var vm = initRegexVM(compile(r"^\D+$"))
    check vm.match("abc").matched
    check not vm.match("abc1").matched

  test "range quantifier exact":
    var vm = initRegexVM(compile(r"^\d{4}$"))
    check vm.match("1234").matched
    check not vm.match("123").matched

  test "range quantifier bounded":
    var vm = initRegexVM(compile(r"^\d{2,4}$"))
    check vm.match("12").matched
    check vm.match("1234").matched
    check not vm.match("1").matched

  test "range quantifier unbounded":
    var vm = initRegexVM(compile(r"^\d{2,}$"))
    check vm.match("12").matched
    check vm.match("123456").matched
    check not vm.match("1").matched

  test "lazy star":
    var vm = initRegexVM(compile(r"^a.*?b$"))
    check vm.match("ab").matched
    check vm.match("aXXb").matched

  test "whole match via groupStr idx 0":
    let m = vm.find(r"\d+", "price: 42")
    check m.matched
    check groupStr(m, "price: 42", 0) == "42"

# ---------------------------------------------------------------------------
# VM – find (substring)
# ---------------------------------------------------------------------------

suite "VM – find (substring)":
  test "find in middle":
    let m = vm.find("hello", "say hello world")
    check m.matched
    check m.start == 4

  test "find digit sequence":
    let m = vm.find(r"\d+", "abc 123 def")
    check m.matched
    check groupStr(m, "abc 123 def", 0) == "123"

  test "find no match":
    let m = vm.find(r"\d+", "no digits here")
    check not m.matched

  test "find first of multiple":
    let m = vm.find(r"\d+", "1 and 2 and 3")
    check m.matched
    check m.start == 0

  test "find with anchor only at pos 0":
    let m = vm.find("^hello", "hello world")
    check m.matched
    check m.start == 0

  test "find anchored no match in middle":
    let m = vm.find("^hello", "say hello")
    check not m.matched

# ---------------------------------------------------------------------------
# VM – findAll
# ---------------------------------------------------------------------------

suite "VM – findAll":
  test "all digits":
    let ms = findAll(r"\d+", "1 22 333")
    check ms.len == 3

  test "no overlapping":
    let src = "aaa"
    let ms = findAll("a", src)
    check ms.len == 3
    for i in 1 ..< ms.len:
      check ms[i].start >= ms[i-1].stop

  test "empty result":
    let ms = findAll(r"\d+", "no digits")
    check ms.len == 0

  test "single char repeated":
    let ms = findAll("x", "xAxBxCx")
    check ms.len == 4

# ---------------------------------------------------------------------------
# VM – complex patterns
# ---------------------------------------------------------------------------

suite "VM – complex patterns":
  test "email-like":
    let m = vm.find(r"\w+@\w+\.\w+", "send to user@example.com today")
    check m.matched

  test "hex color":
    let m = vm.find(r"#[0-9a-fA-F]{6}", "color: #ff0080 end")
    check m.matched
    check groupStr(m, "color: #ff0080 end", 0) == "#ff0080"

  test "ip-like":
    let m = vm.find(r"\d+\.\d+\.\d+\.\d+", "addr 192.168.1.1 port")
    check m.matched

  test "greedy vs lazy":
    let src = "<b>bold</b>"
    let lazy   = vm.find(r"<.+?>", src)
    let greedy = vm.find(r"<.+>",  src)
    check lazy.matched
    check greedy.matched
    check groupStr(lazy,   src, 0) == "<b>"
    check groupStr(greedy, src, 0) == "<b>bold</b>"

  test "optional group – whole match":
    let m = vm.find(r"colou?r", "The color is nice")
    check m.matched
    check groupStr(m, "The color is nice", 0) == "color"

# ---------------------------------------------------------------------------
# Benchmarks (smoke – just ensure no crash)
# ---------------------------------------------------------------------------

proc bench(name: string, iters: int, body: proc()) =
  let t0 = cpuTime()
  for _ in 0 ..< iters:
    body()
  let elapsed = cpuTime() - t0
  let ns = (elapsed / iters.float) * 1e9
  echo &"  [{name}] {iters} iters  total={elapsed*1000:.2f}ms  avg={ns:.1f}ns/op"

suite "Benchmarks":
  const N = 100_000

  test "compile simple pattern":
    bench("compile 'a+'", 1_000) do():
      discard compile("a+")

  test "compile complex pattern":
    bench("compile complex", 1_000) do():
      discard compile(r"[a-zA-Z_]\w*@\w+\.\w+")

  test "match short string":
    var vm = initRegexVM(compile("hello"))
    bench("match 'hello'", N) do():
      discard vm.match("hello")

  test "match digit sequence":
    var vm = initRegexVM(compile(r"^\d+$"))
    bench("match '12345678'", N) do():
      discard vm.match("12345678")

  test "find in 1KB string":
    let big = "x".repeat(900) & "42" & "y".repeat(98)
    var vm = initRegexVM(compile(r"\d+"))
    bench("find digits in 1KB", 10_000) do():
      discard vm.find(big)

  test "find in 10KB string":
    let big = "x".repeat(9_900) & "42" & "y".repeat(98)
    var vm = initRegexVM(compile(r"\d+"))
    bench("find digits in 10KB", 1_000) do():
      discard vm.find(big)

  test "alternation 3 branches":
    var vm = initRegexVM(compile("cat|dog|fish"))
    bench("find 3-alt", N) do():
      discard vm.find("I have a dog here")

  test "compile + match one-shot":
    bench("one-shot match", 1_000) do():
      discard match("hello", "hello world")

  test "repeated findAll small":
    let src = "1 2 3 4 5 6 7 8 9 10"
    bench("findAll digits short", 10_000) do():
      discard findAll(r"\d+", src)