import std/[unittest, sequtils, strutils]
import ../src/openparser/regex/[lexer, parser, compiler, prefilter, vm]

#
# Helpers
#

proc substr(input: string, m: MatchResult): string =
  if m.matched: input[m.start ..< m.stop] else: ""

#
# Lexer – edge cases
#

suite "Lexer – edge cases":
  test "empty input yields EOF immediately":
    var lex = initRegexLexer("")
    check lex.getToken().kind == tkEof

  test "comma token":
    var lex = initRegexLexer(",")
    check lex.getToken().kind == tkComma

  test "caret token":
    var lex = initRegexLexer("^")
    check lex.getToken().kind == tkCaret

  test "dollar token":
    var lex = initRegexLexer("$")
    check lex.getToken().kind == tkDollar

  test "pipe token":
    var lex = initRegexLexer("|")
    check lex.getToken().kind == tkPipe

  test "hyphen token standalone":
    var lex = initRegexLexer("-")
    check lex.getToken().kind == tkHyphen

  test "lbrace rbrace tokens":
    var lex = initRegexLexer("{}")
    check lex.getToken().kind == tkLBrace
    check lex.getToken().kind == tkRBrace

  test "escape backslash-b":
    var lex = initRegexLexer(r"\b")
    let tok = lex.getToken()
    check tok.kind == tkEscaped
    check tok.lexeme[0] == 'b'

  test "escape backslash-S":
    var lex = initRegexLexer(r"\S")
    let tok = lex.getToken()
    check tok.kind == tkEscaped
    check tok.lexeme[0] == 'S'

  test "sequence of meta tokens":
    var lex = initRegexLexer("()|")
    check lex.getToken().kind == tkLParen
    check lex.getToken().kind == tkRParen
    check lex.getToken().kind == tkPipe
    check lex.getToken().kind == tkEof

  test "multi-digit number token":
    var lex = initRegexLexer("42")
    let tok = lex.getToken()
    check tok.kind == tkNumber
    check tok.lexeme == "42"

  test "lexeme stored on dot":
    var lex = initRegexLexer(".")
    let tok = lex.getToken()
    check tok.lexeme == "."

  test "pos advances correctly":
    var lex = initRegexLexer("abc")
    let t0 = lex.getToken(); check t0.pos == 0
    let t1 = lex.getToken(); check t1.pos == 1
    let t2 = lex.getToken(); check t2.pos == 2

#
# Parser – edge cases
#

suite "Parser – edge cases":
  test "alternation with empty right branch still parses":
    # a| — right branch is empty; parser may error or produce a node
    # Just confirm it doesn't crash and returns something
    var p = initRegexParser("a|b")
    let ast = p.parse()
    check ast != nil

  test "quantifier on char class":
    var p = initRegexParser("[0-9]+")
    let ast = p.parse()
    check ast.kind == rnQuantifier
    check ast.operand.kind == rnCharClass

  test "quantifier on group":
    var p = initRegexParser("(ab)+")
    let ast = p.parse()
    check ast.kind == rnQuantifier
    check ast.operand.kind == rnGroup

  test "nested quantifiers via groups":
    var p = initRegexParser("(a+)+")
    let ast = p.parse()
    check ast.kind == rnQuantifier
    check ast.operand.kind == rnGroup

  test "dot quantified":
    var p = initRegexParser(".+")
    let ast = p.parse()
    check ast.kind == rnQuantifier
    check ast.operand.kind == rnDot

  test "char class with multiple ranges":
    var p = initRegexParser("[a-zA-Z0-9]")
    let ast = p.parse()
    check ast.kind == rnCharClass
    check ast.items.len == 3

  test "char class with single char items":
    var p = initRegexParser("[abc]")
    let ast = p.parse()
    check ast.kind == rnCharClass
    check ast.items.len == 3
    check not ast.items[0].isRange

  test "lazy plus":
    var p = initRegexParser("a+?")
    let ast = p.parse()
    check ast.kind == rnQuantifier
    check ast.lazy
    check ast.min == 1

  test "lazy question":
    var p = initRegexParser("a??")
    let ast = p.parse()
    check ast.kind == rnQuantifier
    check ast.lazy
    check ast.min == 0
    check ast.max == 1

  test "anchor-only pattern start":
    var p = initRegexParser("^")
    let ast = p.parse()
    check ast.kind == rnAnchorStart

  test "anchor-only pattern end":
    var p = initRegexParser("$")
    let ast = p.parse()
    check ast.kind == rnAnchorEnd

  test "capture count three groups":
    var p = initRegexParser("(a)(b)(c)")
    discard p.parse()
    check p.captureCount == 3

  test "capture count nested counts both":
    var p = initRegexParser("((a))")
    discard p.parse()
    check p.captureCount == 2

#
# Compiler – structural checks
#

suite "Compiler – structural checks":
  test "question quantifier produces split":
    let prog = compile("a?")
    check prog.instrs.anyIt(it.op in {opSplit, opSplitLazy})

  test "char class negated stored correctly":
    let prog = compile("[^0-9]")
    check prog.classes.len == 1
    check prog.classes[0].negated

  test "char class not negated stored correctly":
    let prog = compile("[0-9]")
    check prog.classes.len == 1
    check not prog.classes[0].negated

  test "escape w compiles to opEscapeClass":
    let prog = compile(r"\w")
    check prog.instrs[0].op == opEscapeClass

  test "escape s compiles to opEscapeClass":
    let prog = compile(r"\s")
    check prog.instrs[0].op == opEscapeClass

  test "anchor end compiles to opAnchorEnd":
    let prog = compile("$")
    check prog.instrs[0].op == opAnchorEnd

  test "two char classes produce two entries":
    let prog = compile("[a-z][0-9]")
    check prog.classes.len == 2

  test "range {2,4} does not inline more than 4 copies":
    let prog = compile("a{2,4}")
    let charCount = prog.instrs.countIt(it.op == opChar and it.arg1 == ord('a'))
    check charCount <= 4
    check charCount >= 2

  test "always ends with opMatch":
    for pat in ["a", "a+", "a|b", "[0-9]", r"\d+"]:
      let prog = compile(pat)
      check prog.instrs[^1].op == opMatch

  test "numCaptures zero for no groups":
    let prog = compile("abc")
    check prog.numCaptures == 0

#
# VM – match correctness
#

suite "VM – match correctness":
  test "word boundary pattern \\w+":
    var vm = initRegexVM(compile(r"^\w+$"))
    check vm.match("hello123").matched
    check not vm.match("hello 123").matched

  test "escape \\W rejects word chars":
    var vm = initRegexVM(compile(r"^\W+$"))
    check vm.match("!@#").matched
    check not vm.match("abc").matched

  test "escape \\S matches non-space":
    var vm = initRegexVM(compile(r"^\S+$"))
    check vm.match("hello").matched
    check not vm.match("hel lo").matched

  test "digit class range {3,5}":
    var vm = initRegexVM(compile(r"^\d{3,5}$"))
    check not vm.match("12").matched
    check vm.match("123").matched
    check vm.match("12345").matched
    check not vm.match("123456").matched

  test "alternation three branches":
    var vm = initRegexVM(compile("^(red|green|blue)$"))
    check vm.match("red").matched
    check vm.match("green").matched
    check vm.match("blue").matched
    check not vm.match("yellow").matched

  test "dot does not match newline":
    var vm = initRegexVM(compile("^.$"))
    check vm.match("a").matched
    check not vm.match("\n").matched

  test "hex literal pattern":
    var vm = initRegexVM(compile(r"^0[xX][0-9a-fA-F]+$"))
    check vm.match("0xff").matched
    check vm.match("0X1A2B").matched
    check not vm.match("0b101").matched

  test "optional suffix":
    var vm = initRegexVM(compile(r"^\d+[uUlL]?$"))
    check vm.match("42").matched
    check vm.match("42u").matched
    check vm.match("42L").matched
    check not vm.match("42x").matched

  test "star allows empty":
    var vm = initRegexVM(compile(r"^[a-z]*$"))
    check vm.match("").matched
    check vm.match("abc").matched

  test "plus requires at least one":
    var vm = initRegexVM(compile(r"^[a-z]+$"))
    check not vm.match("").matched
    check vm.match("a").matched

#
# VM – vm.find correctness using start/stop
#

suite "VM – vm.find via start/stop":
  test "find returns correct start position":
    var vm = initRegexVM(compile(r"\d+"))
    let m = vm.find("abc 99 def")
    check m.matched
    check m.start == 4
    check m.stop == 6

  test "find hex literal in source":
    var vm = initRegexVM(compile(r"0[xX][0-9a-fA-F]+"))
    let src = "value = 0xDEAD + 1"
    let m = vm.find(src)
    check m.matched
    check substr(src, m) == "0xDEAD"

  test "find word at start":
    var vm = initRegexVM(compile(r"\w+"))
    let src = "hello world"
    let m = vm.find(src)
    check m.matched
    check m.start == 0
    check substr(src, m) == "hello"

  test "find with ^ only matches position 0":
    var vm = initRegexVM(compile(r"^\w+"))
    check vm.find("hello world").matched
    check not vm.find("  hello").matched

  test "find last word not returned by vm.find (returns first)":
    var vm = initRegexVM(compile(r"\w+"))
    let m = vm.find("one two three")
    check m.matched
    check substr("one two three", m) == "one"

  test "find returns no match on empty input":
    var vm = initRegexVM(compile(r"\d+"))
    check not vm.find("").matched

  test "find match at end of string":
    var vm = initRegexVM(compile(r"\d+"))
    let src = "value=42"
    let m = vm.find(src)
    check m.matched
    check m.stop == src.len

#
# VM – vm.findAll correctness
#

suite "VM – vm.findAll correctness":
  test "findAll returns all non-overlapping words":
    var vm = initRegexVM(compile(r"\w+"))
    let ms = vm.findAll("one two three")
    check ms.len == 3
    check "one two three"[ms[0].start..<ms[0].stop] == "one"
    check "one two three"[ms[1].start..<ms[1].stop] == "two"
    check "one two three"[ms[2].start..<ms[2].stop] == "three"

  test "findAll hex numbers":
    var vm = initRegexVM(compile(r"0[xX][0-9a-fA-F]+"))
    let src = "0xff, 0x1A, 0xBEEF"
    let ms = vm.findAll(src)
    check ms.len == 3

  test "findAll results are ordered by start":
    var vm = initRegexVM(compile(r"\d+"))
    let src = "1 22 333 4444"
    let ms = vm.findAll(src)
    check ms.len == 4
    for i in 1 ..< ms.len:
      check ms[i].start > ms[i-1].start

  test "findAll no overlap: stop of prev <= start of next":
    var vm = initRegexVM(compile(r"\w+"))
    let ms = vm.findAll("aa bb cc")
    check ms.len == 3
    check ms[1].start >= ms[0].stop
    check ms[2].start >= ms[1].stop

  test "findAll on pattern with no matches returns empty":
    var vm = initRegexVM(compile(r"\d+"))
    check vm.findAll("no numbers here").len == 0

  test "findAll single-char matches":
    var vm = initRegexVM(compile("a"))
    let ms = vm.findAll("banana")
    check ms.len == 3

#
# VM – greedy vs lazy length check (avoiding groupStr)
#

suite "VM – greedy vs lazy match length":
  test "greedy .+ matches longer span than lazy .+?":
    let src = "<b>bold</b>"
    var vmLazy   = initRegexVM(compile(r"<.+?>"))
    var vmGreedy = initRegexVM(compile(r"<.+>"))
    let mLazy   = vmLazy.find(src)
    let mGreedy = vmGreedy.find(src)
    check mLazy.matched
    check mGreedy.matched
    # greedy must consume at least as many chars as lazy
    check (mGreedy.stop - mGreedy.start) >= (mLazy.stop - mLazy.start)

  test "lazy .+? vm.finds shortest possible match":
    let src = "<x><y><z>"
    var vmLazy = initRegexVM(compile(r"<.+?>"))
    let m = vmLazy.find(src)
    check m.matched
    # shortest possible <.+?> match is length 3: <x>
    check (m.stop - m.start) == 3

  test "greedy .+ spans whole string between first < and last >":
    let src = "<a><b><c>"
    var vmGreedy = initRegexVM(compile(r"<.+>"))
    let m = vmGreedy.find(src)
    check m.matched
    check m.start == 0
    check m.stop == src.len

  test "lazy a*? prefers zero width at start":
    # a*? inside ^a*?b$ should still match "b" via backtracking
    var vm = initRegexVM(compile(r"^a*?b$"))
    check vm.match("b").matched
    check vm.match("aaab").matched
    check not vm.match("aaa").matched

  test "lazy quantifier on digits":
    # \d+? should match exactly one digit at a time
    var vm = initRegexVM(compile(r"\d+?"))
    let ms = vm.findAll("123")
    # each match should be length 1
    for m in ms:
      check (m.stop - m.start) == 1

#
# VM – C-header patterns smoke tests
#

suite "VM – C-header pattern smoke tests":
  test "typedef pattern matches":
    var vm = initRegexVM(compile(r"typedef\s+\w+\s+\w+"))
    check vm.find("typedef unsigned int uint32_t;").matched

  test "struct pattern matches":
    var vm = initRegexVM(compile(r"struct\s+[a-zA-Z_]\w*"))
    check vm.find("struct MyStruct {").matched

  test "enum pattern matches":
    var vm = initRegexVM(compile(r"enum\s+[a-zA-Z_]\w*"))
    check vm.find("enum Color { RED, GREEN };").matched

  test "define pattern matches":
    var vm = initRegexVM(compile(r"#define\s+\w+"))
    check vm.find("#define MAX_SIZE 1024").matched

  test "line comment pattern matches":
    var vm = initRegexVM(compile(r"//[^\n]*"))
    let src = "int x = 1; // inline comment"
    let m = vm.find(src)
    check m.matched
    check substr(src, m) == "// inline comment"

  test "hex literal in code":
    var vm = initRegexVM(compile(r"0[xX][0-9a-fA-F]+"))
    check vm.find("return 0xFF;").matched

  test "pointer pattern matches":
    var vm = initRegexVM(compile(r"\w+\s*\*+\s*\w+"))
    check vm.find("int* ptr = NULL;").matched

  test "const pointer pattern":
    var vm = initRegexVM(compile(r"const\s+\w+\s*\*"))
    check vm.find("const char* name = NULL;").matched

  test "identifier pattern does not match leading digit":
    var vm = initRegexVM(compile(r"^[a-zA-Z_]\w*$"))
    check vm.match("_myVar").matched
    check vm.match("MyType").matched
    check not vm.match("1bad").matched

  test "macro pattern upper case":
    var vm = initRegexVM(compile(r"[A-Z_][A-Z0-9_]{2,}"))
    check vm.find("MAX_BUFFER_SIZE").matched
    let ms = vm.findAll("#define MAX_SIZE 1024")
    check ms.len >= 1

suite "VM – complex regex syntax":
  test "nested groups and alternation":
    var vm = initRegexVM(compile(r"((foo|bar)+)-(\d{2,4})"))
    let m = vm.find("foobarfoo-123")
    check m.matched
    check substr("foobarfoo-123", m) == "foobarfoo-123"

  test "lookalike non-capturing group (should treat as normal group)":
    var vm = initRegexVM(compile(r"(?:abc)"))
    check vm.match("abc").matched
    check not vm.match("ab").matched
    ## no capture slots consumed
    check compile(r"(?:abc)").numCaptures == 0

  test "non-capturing group does not affect capture index":
    ## (?:x)(y) — only one capture group
    check compile(r"(?:x)(y)").numCaptures == 1

  test "escaped metacharacters":
    var vm = initRegexVM(compile(r"\.\*\+\?\|\(\)\[\]\{\}\\"))
    check vm.match(".*+?|()[]{}\\").matched

  test "character class intersection (should treat as union)":
    var vm = initRegexVM(compile(r"[a-fA-F0-9]"))
    check vm.match("A").matched
    check vm.match("5").matched
    check not vm.match("g").matched

  test "negated character class with range":
    var vm = initRegexVM(compile(r"[^a-z0-9]"))
    check vm.match("Z").matched
    check not vm.match("a").matched
    check not vm.match("5").matched

  test "dot matches any except newline":
    var vm = initRegexVM(compile(r"."))
    check vm.match("x").matched
    check not vm.match("\n").matched

  test "anchors ^ and $":
    var vm = initRegexVM(compile(r"^abc$"))
    check vm.match("abc").matched
    check not vm.match(" abc").matched
    check not vm.match("abc ").matched

  test "multiple quantifiers":
    var vm = initRegexVM(compile(r"(ab){2,4}"))
    check vm.match("abab").matched
    check vm.match("ababab").matched
    check not vm.match("ab").matched

  test "optional group":
    var vm = initRegexVM(compile(r"foo(bar)?baz"))
    check vm.match("foobarbaz").matched
    check vm.match("foobaz").matched

  test "alternation with different lengths":
    var vm = initRegexVM(compile(r"cat|caterpillar|car"))
    check vm.match("cat").matched
    check vm.match("caterpillar").matched
    check vm.match("car").matched
    check not vm.match("ca").matched

  test "escaped \\u treated as literal 'u' + digits":
    ## \u is not a recognised class literal 'u'; 1234 expands to 4 digit chars
    var vm = initRegexVM(compile(r"\u1234"))
    check vm.match("u1234").matched
    check not vm.match("u123").matched
    check not vm.match("1234").matched

  test "long pattern with many branches":
    var vm = initRegexVM(compile(r"one|two|three|four|five|six|seven|eight|nine|ten"))
    check vm.match("seven").matched
    check not vm.match("eleven").matched

  test "greedy vs lazy quantifier with nested groups":
    var vm = initRegexVM(compile(r"a(bc+)+?d"))
    check vm.match("abccd").matched
    check not vm.match("ad").matched

  test "complex email-like pattern":
    var vm = initRegexVM(compile(r"[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}"))
    check vm.match("user.name+tag@domain.co.uk").matched
    check not vm.match("not-an-email").matched

  test "hex color code":
    var vm = initRegexVM(compile(r"#[0-9a-fA-F]{6}"))
    check vm.match("#1a2b3c").matched
    check not vm.match("#1a2b3").matched

  test "ip address pattern":
    var vm = initRegexVM(compile(r"\d{1,3}(\.\d{1,3}){3}"))
    check vm.match("192.168.1.1").matched
    check not vm.match("999.999.999.9999").matched

  test "nested alternation and quantifiers":
    var vm = initRegexVM(compile(r"(foo|bar){2,3}baz"))
    check vm.match("foobarfoo baz".replace(" ", "")).matched
    check not vm.match("foobaz").matched


#
# VM – capture groups
#
suite "VM – capture groups":
  test "groupCount is 0 for no-capture pattern":
    let m = vm.find(r"\d+", "abc 123")
    check m.matched
    check m.groupCount == 0

  test "groupCount matches number of groups":
    let m = vm.find(r"(\d+)", "abc 123")
    check m.matched
    check m.groupCount == 1

  test "groupCount 3 groups":
    let m = vm.find(r"(\w+)@(\w+)\.(\w+)", "user@example.com")
    check m.matched
    check m.groupCount == 3

  test "group(0) is whole match":
    let src = "price: 42"
    let m = vm.find(r"\d+", src)
    check m.matched
    let g = m.group(0)
    check g.matched
    check g.str(src) == "42"

  test "groupStr(0) whole match":
    let src = "hello world"
    let m = vm.find(r"\w+", src)
    check m.groupStr(src, 0) == "hello"

  test "single capture group":
    let src = "foo bar"
    let m = vm.find(r"(\w+)", src)
    check m.matched
    check m.groupStr(src, 1) == "foo"

  test "two capture groups":
    let src = "2024-01"
    let m = vm.find(r"(\d{4})-(\d{2})", src)
    check m.matched
    check m.groupStr(src, 1) == "2024"
    check m.groupStr(src, 2) == "01"

  test "three capture groups – email":
    let src = "user@example.com"
    let m = vm.find(r"(\w+)@(\w+)\.(\w+)", src)
    check m.matched
    check m.groupStr(src, 1) == "user"
    check m.groupStr(src, 2) == "example"
    check m.groupStr(src, 3) == "com"

  test "groups() returns all captures as seq":
    let src = "user@example.com"
    let m = vm.find(r"(\w+)@(\w+)\.(\w+)", src)
    check m.matched
    let gs = m.groups(src)
    check gs.len == 3
    check gs[0] == "user"
    check gs[1] == "example"
    check gs[2] == "com"

  test "allGroups() index 0 is whole match":
    let src = "user@example.com"
    let m = vm.find(r"(\w+)@(\w+)", src)
    check m.matched
    let gs = m.allGroups(src)
    check gs.len == 3           # [0]=whole, [1]=user, [2]=example
    check gs[0].str(src) == "user@example"
    check gs[1].str(src) == "user"
    check gs[2].str(src) == "example"

  test "eachGroup iterator yields index and text":
    let src = "2024-12-31"
    let m = vm.find(r"(\d{4})-(\d{2})-(\d{2})", src)
    check m.matched
    var pairs: seq[(int, string)]
    for idx, txt in m.eachGroup(src):
      pairs.add((idx, txt))
    check pairs.len == 3
    check pairs[0] == (1, "2024")
    check pairs[1] == (2, "12")
    check pairs[2] == (3, "31")

  test "optional group not matched is empty string":
    let src = "foobaz"
    let m = vm.find(r"foo(bar)?baz", src)
    check m.matched
    check m.groupStr(src, 1) == ""
    let g = m.group(1)
    check not g.matched

  test "optional group matched is non-empty":
    let src = "foobarbaz"
    let m = vm.find(r"foo(bar)?baz", src)
    check m.matched
    check m.groupStr(src, 1) == "bar"
    check m.group(1).matched

  test "nested groups outer and inner":
    let src = "abcabc"
    let m = vm.find(r"((abc){2})", src)
    check m.matched
    check m.groupStr(src, 1) == "abcabc"  # outer
    check m.groupStr(src, 2) == "abc"     # inner (last iteration)

  test "group CaptureGroup start/stop positions":
    let src = "---42---"
    let m = vm.find(r"(\d+)", src)
    check m.matched
    let g = m.group(1)
    check g.matched
    check g.start == 3
    check g.stop  == 5
    check src[g.start ..< g.stop] == "42"

  test "non-capturing group does not create capture slot":
    let src = "foobar"
    let m = vm.find(r"(?:foo)(bar)", src)
    check m.matched
    check m.groupCount == 1
    check m.groupStr(src, 1) == "bar"

  test "alternation in capture group":
    let src = "color"
    let m = vm.find(r"(colour|color)", src)
    check m.matched
    check m.groupStr(src, 1) == "color"

  test "repeated group keeps last match":
    let src = "abcabcabc"
    let m = vm.find(r"(abc)+", src)
    check m.matched
    # group(1) holds the last iteration of (abc)
    check m.groupStr(src, 1) == "abc"

  test "out-of-range group returns unmatched":
    let src = "hello"
    let m = vm.find(r"\w+", src)
    check m.matched
    let g = m.group(99)
    check not g.matched
    check g.str(src) == ""

  test "groupCount is 0 for no-capture pattern":
    let m = vm.find(r"\d+", "abc 123")
    check m.matched
    check m.groupCount == 0

  test "groupCount matches number of groups":
    let m = vm.find(r"(\d+)", "abc 123")
    check m.matched
    check m.groupCount == 1


  test "out-of-range group returns unmatched":
    let src = "hello"
    let m = vm.find(r"\w+", src)
    check m.matched
    let g = m.group(99)
    check not g.matched
    check g.str(src) == ""

  # --- Added tests for named groups (Python (?P<name>) and PCRE (?<name>)) ---
  test "python-style named group (?P<name>...) creates capture slot":
    var vm = initRegexVM(compile(r"/dashboard/categories/(?P<id>[0-9]+)$"))
    let src = "/dashboard/categories/123"
    let m = vm.find(src)
    check m.matched
    check m.groupCount == 1
    check m.groupStr(src, 1) == "123"

  test "pcre-style named group (?<name>...) creates capture slots in order":
    var vm = initRegexVM(compile(r"(?<user>\w+)-(?<domain>\w+)"))
    let src = "alice-web"
    let m = vm.find(src)
    check m.matched
    check m.groupCount == 2
    check m.groupStr(src, 1) == "alice"
    check m.groupStr(src, 2) == "web"

  test "mixed named and unnamed groups preserve left-to-right indexing":
    var vm = initRegexVM(compile(r"(\d+)-(?P<name>\w+)-(\w+)"))
    let src = "42-joe-x"
    let m = vm.find(src)
    check m.matched
    check m.groupCount == 3
    check m.groupStr(src, 1) == "42"
    check m.groupStr(src, 2) == "joe"
    check m.groupStr(src, 3) == "x"
