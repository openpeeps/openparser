import unittest, os, options, strutils, memfiles
import openparser/nif

suite "NIF Lexer":
  test "tokenize basic with MemFile":
    let s = "(stmts 123)"
    let toks = tokenizeNif(s)
    check toks.len >= 4
    check toks[0].kind == ntkLParen
    check toks[1].kind == ntkIdent
    check toks[1].value == "stmts"
    # number
    check toks[2].kind == ntkInt

  test "memfile tokenization":
    let data = "(.nif27)\n(stmts 123)"
    writeFile("/tmp/nif_mem.nif", data)
    var mf = memfiles.open("/tmp/nif_mem.nif", fmRead)
    defer: mf.close()
    let toks = tokenizeNif(mf)
    check toks.len >= 5
    check toks[0].kind == ntkLParen

  test "escapes in string - \\20 and shortcuts":
    let nif = """(call "Hello\20World" "a\nb" "a\tb" "a\rb" "a\|b" "a\^b")"""
    let m = fromNif(nif)
    check m.len == 1
    let call = m[0]
    check call.tag == "call"
    # first string contains space (0x20) decoded
    check call.children[0].strVal == "Hello World"
    check call.children[1].strVal == "a\nb"
    check call.children[2].strVal == "a\tb"
    check call.children[5].strVal == "a\"b"

  test "empty nodes ... without whitespace":
    let m = fromNif("(stmts ...)")
    check m[0].tag == "stmts"
    # ... should be three empties (legacy: ... -> three Empty nodes)
    # Our lexer: ... without ws -> three nkEmpty children
    check m[0].children.len == 3
    for c in m[0].children:
      check c.kind == nkEmpty

  test "char literal with escapes":
    let m = fromNif("(stmts 'a' '\\n' '\\5C')")
    check m[0].children[0].kind == nkCharLit
    check m[0].children[0].charVal == "a"
    check m[0].children[1].charVal == "\n"
    check m[0].children[2].charVal == "\\"

suite "NIF Parser - spec example":
  test "spec example module":
    let specExample = """
(.nif27)
(stmts
(imp@2,5,sysio.nim (type :File (object . .)))
(imp (proc :write.1.sys . (pragmas varargs) (params (param f File)) .))
(call write.1.sys "Hello World!\0A")
)
"""
    let mods = fromNif(specExample)
    check mods.len == 2
    check mods[0].kind == nkDirective
    check mods[0].tag == ".nif27"
    check mods[1].tag == "stmts"
    check mods[1].children.len == 3
    # first imp tag suffix
    let imp = mods[1].children[0]
    check imp.tag == "imp"
    check isSome(imp.tagLineInfo)
    let li = imp.tagLineInfo.get
    check li.colDiff == 2
    check li.lineDiff == 5
    check li.filename.get == "sysio.nim"

  test "lineInfo shorthand ~":
    let m = fromNif("(stmts x~3 y@2)")
    check m[0].children.len == 2
    let x = m[0].children[0]
    let y = m[0].children[1]
    check x.ident == "x"
    check isSome(x.lineInfo)
    check x.lineInfo.get.colDiff == -3
    check x.lineInfo.get.hasTildeShorthand == true
    check y.lineInfo.get.colDiff == 2

  test "base62 decode":
    # A=10, Z=35, a=36 . So "A" =10, "10" =62
    let m = fromNif("(stmts x@A y@10)")
    check m[0].children[0].lineInfo.get.colDiff == 10
    check m[0].children[1].lineInfo.get.colDiff == 62

  test "comment suffix":
    let m = fromNif("(add#performs an addition# x y)")
    check m[0].tag == "add"
    check isSome(m[0].tagComment)
    check m[0].tagComment.get == "performs an addition"
    let m2 = fromNif("(stmts 123#answer#)")
    check m2[0].children[0].comment.get == "answer"

  test "combined lineInfo + comment":
    let m = fromNif("(stmts foo@5,3#why this token is here#)")
    let foo = m[0].children[0]
    check isSome(foo.lineInfo)
    check isSome(foo.comment)
    check foo.comment.get == "why this token is here"

  test "numbers: int, uint, float, negative":
    let m = fromNif("(stmts 12 -12 12u 3.14 1E10 1.2E-3)")
    check m[0].children[0].kind == nkInt
    check m[0].children[0].intVal == 12
    check m[0].children[1].intVal == -12
    check m[0].children[2].kind == nkUInt
    check m[0].children[2].uintVal == 12
    check m[0].children[3].kind == nkFloat
    check m[0].children[5].kind == nkFloat

  test "identifier with non-ascii and escaped":
    let m = fromNif("(stmts hello\\5Cworld)")
    check m[0].children[0].ident == "hello\\world"
    # raw preserved
    check m[0].children[0].rawIdent == "hello\\5Cworld"

  test "symbol and symbolDef":
    let m = fromNif("(stmts :File foo.1.bar :write.1.sys)")
    check m[0].children[0].kind == nkSymbolDef
    check m[0].children[0].symDef == "File"
    check m[0].children[1].kind == nkSymbol
    check m[0].children[1].symbol == "foo.1.bar"
    check m[0].children[2].symDef == "write.1.sys"

  test "lazy expansion of trailing dot":
    let opts = NifOptions(moduleSuffix: "mymod", expandGlobalSymbols: true)
    let m = fromNif("(stmts foo.0. bar.0.)", opts)
    check m[0].children[0].symbol == "foo.0.mymod"
    check m[0].children[1].symbol == "bar.0.mymod"
    # already expanded should stay
    let m2 = fromNif("(stmts foo.0.mymod)", opts)
    check m2[0].children[0].symbol == "foo.0.mymod"
    # disabled expansion
    let opts2 = NifOptions(moduleSuffix: "mymod", expandGlobalSymbols: false)
    let m3 = fromNif("(stmts foo.0.)", opts2)
    check m3[0].children[0].symbol == "foo.0."

  test "string with literal newline (EscapedData whitespace)":
    let s = "\"This is a single\\20\nliteral string\""
    let m = fromNif("(stmts " & s & ")")
    check "literal string" in m[0].children[0].strVal

suite "NIF Errors":
  test "unexpected EOF missing )":
    expect OpenParserNifError:
      discard fromNif("(stmts (call x y)")

  test "invalid escape":
    expect OpenParserNifError:
      discard fromNif("(stmts \"bad\\zz\")")

  test "error shows snippet + line:col":
    try:
      discard fromNif("(stmts \"bad\\zz\")")
      check false
    except OpenParserNifError as e:
      check "Error (" in e.msg
      check "^" in e.msg

  test "version directive must be at byte 0":
    expect OpenParserNifError:
      discard fromNif(" (.nif27)\n(stmts)")
    # ok when at 0
    let m = fromNif("(.nif27)\n(stmts)")
    check m[0].tag == ".nif27"

suite "NIF File IO":
  test "fromNifFile memfiles":
    let specExample = """(.nif27)
(stmts (call write.1.sys "hi"))
"""
    let path = "/tmp/test_nif_fromfile.nif"
    writeFile(path, specExample)
    let mods = fromNifFile(path)
    check mods.len == 2
    check mods[1].tag == "stmts"
    # moduleSuffix derived
    let opts = NifOptions(moduleSuffix: "testmod", expandGlobalSymbols: true)
    writeFile(path, "(stmts foo.0.)")
    let mods2 = fromNifFile(path, opts)
    check mods2[0].children[0].symbol == "foo.0.testmod"

  test "tokenizeNif empty input error":
    expect OpenParserNifError:
      discard fromNif("")

  test "spec: bytes >=128 in identifier":
    # \xC3\xA9 is utf8 é, bytes 0xC3 0xA9 each >=128 should be allowed directly
    let ident = "caf" & char(0xC3) & char(0xA9)
    let m = fromNif("(stmts " & ident & ")")
    check m[0].children[0].ident == ident

  test "NIF .lang directive":
    let sample = """
(.lang "html"
  (div (class "container")
    (p "Welcome")
    (.lang "css"
      (style
        (kv (background-color) "blue")))))

(.lang "json"
  (object
    (kv (name) "Alice")
    (kv (created) (isodate "2026-01-19"))))

(.lang "sql"
  (create-table users
    (column (id) (i +64))
    (column (name) string)))
"""
    let m = fromNif(sample)
    check m.len == 3
    check m[0].tag == ".lang"
    check m[0].children[0].strVal == "html"
    check m[1].tag == ".lang"
    check m[1].children[0].strVal == "json"
    check m[2].children[1].children[1].tag == "column"

  test "hyphenated identifiers and +64 number":
    let m = fromNif("(stmts background-color create-table +64)")
    check m[0].children[0].ident == "background-color"
    check m[0].children[1].ident == "create-table"
    check m[0].children[2].kind == nkInt
    check m[0].children[2].intVal == 64

suite "NIF Complex Strings":

  test "full compiler module with directives and lineInfo":
    let src = """
(.nif27)
(.vendor "Nifler")
(.platform "x86_64")
(.config "release")
(stmts
  (imp@1,2,sys.nim (type :MyType.0.sys (object (fld a (i 32)) (fld b string))))
  (proc :foo.1.mymod (params (param x (i 32)) (param y string)) (pragmas inline) . . (stmts (ret x)))
  (var :v.2.mymod (i 32) 42)
)
"""
    let m = fromNif(src)
    check m.len == 5
    check m[0].tag == ".nif27"
    check m[1].tag == ".vendor"
    check m[1].children[0].strVal == "Nifler"
    check m[4].tag == "stmts"
    check m[4].children.len == 3
    check m[4].children[1].tag == "proc"
    # verify suffix on imp
    check isSome(m[4].children[0].tagLineInfo)
    check m[4].children[0].tagLineInfo.get.filename.get == "sys.nim"

  test "deep .lang nesting - html/css/sql/json interleaved":
    let src = """
(.nif27)
(.lang "html"
  (html@1,1
    (head (title "Title\20Here"))
    (body
      (div (class "a-b_c") (p "Hello\20World"))
      (.lang "css"
        (style
          (kv (font-size) "12px")
          (kv (background-color) "blue")
          (kv (content) "a\5Cb"))))))
(.lang "sql"
  (create-table users
    (column (id) (i +64))
    (column (name) string)
    (column (data) (array (i 8)))))
(.lang "json"
  (object
    (kv (name) "Alice")
    (kv (age) 30)
    (kv (tags) (array "a" "b"))))
"""
    let m = fromNif(src)
    check m.len == 4
    check m[1].tag == ".lang"
    check m[1].children[0].strVal == "html"
    let htmlBody = m[1].children[1] # (html ...)
    check htmlBody.tag == "html"
    check htmlBody.children[1].tag == "body"
    let cssLang = htmlBody.children[1].children[1]
    check cssLang.tag == ".lang"
    check cssLang.children[0].strVal == "css"
    # verify hyphenated kv: (kv (font-size) "12px")
    let kv0 = cssLang.children[1].children[0]
    check kv0.tag == "kv"
    check kv0.children[0].tag == "font-size"

  test "suffix torture - base62 extremes and comment combos":
    let src = """
(stmts
  a@1
  b@A
  c@10
  d@ZZ
  e@a
  f@z
  g~1
  h~Z
  i@5,10
  j@5,10,foo.nim
  k@~3,2
  l~3#note#
  m#just comment#
  n@5#after li#
  o@5,3,bar.nim#with both#
)
"""
    let m = fromNif(src)
    let ch = m[0].children
    check ch.len == 15
    check ch[0].lineInfo.get.colDiff == 1
    check ch[1].lineInfo.get.colDiff == 10   # A
    check ch[2].lineInfo.get.colDiff == 62   # 10 base62
    check ch[3].lineInfo.get.colDiff == 35*62+35 # ZZ
    check ch[4].lineInfo.get.colDiff == 36   # a
    check ch[5].lineInfo.get.colDiff == 61   # z
    check ch[6].lineInfo.get.colDiff == -1
    check ch[6].lineInfo.get.hasTildeShorthand
    check ch[8].lineInfo.get.colDiff == 5
    check ch[8].lineInfo.get.lineDiff == 62
    check ch[9].lineInfo.get.filename.get == "foo.nim"
    check ch[10].lineInfo.get.colDiff == -3
    check ch[11].comment.get == "note"
    check ch[11].lineInfo.get.colDiff == -3
    check ch[12].comment.get == "just comment"
    check isNone(ch[12].lineInfo)
    check ch[14].lineInfo.get.filename.get == "bar.nim"
    check ch[14].comment.get == "with both"

  test "string and char escape torture":
    let src = """
(stmts
  "plain"
  "with\20space"
  "shortcuts:\n\t\r\|\^"
  "hex:\00\0A\FF"
  "multi
line
literal"
  'a' '\n' '\t' '\r' '\5C' '\22'
   "" "a\^b"
)
"""
    let m = fromNif(src)
    check m[0].children[0].strVal == "plain"
    check m[0].children[1].strVal == "with space"
    check m[0].children[2].strVal == "shortcuts:\n\t\r\\\"" 
    check m[0].children[3].strVal[0..3] == "hex:"
    check '\n' in m[0].children[4].strVal
    check m[0].children[5].charVal == "a"
    check m[0].children[6].charVal == "\n"
    check m[0].children[10].charVal == "\""

  test "empty and dot chains":
    let m1 = fromNif("(stmts .)")
    check m1[0].children[0].kind == nkEmpty
    let m2 = fromNif("(stmts ...)")
    check m2[0].children.len == 3
    let m3 = fromNif("(stmts . . .)")
    check m3[0].children.len == 3
    let m4 = fromNif("(stmts (call . . .) (type (object . .)))")
    check m4[0].children[0].children[0].kind == nkEmpty
    # suffix on empty
    let m5 = fromNif("(stmts .@5#empty with suffix#)")
    check isSome(m5[0].children[0].lineInfo)
    check m5[0].children[0].comment.get == "empty with suffix"

  test "symbol corpus with hyphens, trailing dot, generic":
    let opts = NifOptions(moduleSuffix: "mymod", expandGlobalSymbols: true)
    let src = """
(stmts
  :File
  :foo.0
  :foo.1.bar
  :foo.2.T.mymod
  foo.0.
  foo.1.
  bar.3.qux.4.
  my-ident-with-hyphens.0.foo
  :my-def.9
)
"""
    let m = fromNif(src, opts)
    check m[0].children[0].symDef == "File"
    check m[0].children[1].symDef == "foo.0"
    check m[0].children[3].symDef == "foo.2.T.mymod"
    check m[0].children[4].symbol == "foo.0.mymod"
    check m[0].children[6].symbol == "bar.3.qux.4.mymod"
    check m[0].children[7].symbol == "my-ident-with-hyphens.0.foo"

  test "numeric extremes and type constructors":
    let src = """
(stmts
  0 42 -7 +64 12u 0u
  3.14 -0.5 1E10 1.2E-3 1E+10 2.5e-5
  (type (i 8) (i 16) (i +32) (u 64) (f 32) (f 64) (array (i 8)) (ptr string))
)
"""
    let m = fromNif(src)
    let ch = m[0].children
    check ch[0].intVal == 0
    check ch[3].intVal == 64
    check ch[4].uintVal == 12
    check ch[6].kind == nkFloat
    check ch[12].tag == "type"
    check ch[12].children[2].children[0].intVal == 32

  test "index and indexat directives - diff chain":
    let src = """
(.nif27)
(.indexat 1234)
(stmts (proc :foo.0.mymod .) (var :bar.0.mymod (i 32)))
(.index
  (x foo.0.mymod 12)
  (h bar.0.mymod 23)
  (x baz.2.T.mymod 5)
)
"""
    let m = fromNif(src)
    check m.len == 4
    check m[1].tag == ".indexat"
    check m[1].children[0].intVal == 1234
    check m[3].tag == ".index"
    check m[3].children[0].tag == "x"
    check m[3].children[1].tag == "h"
    # offsets are diffs - parser just keeps raw ints

  test "round-trip dump -> parse identity":
    let samples = @[
      "(stmts 123 \"hello\" :foo.1.bar)",
      "(.lang \"html\" (div (p \"hi\")))",
      "(stmts a@5 b~3#note# c#comm#)",
      "(stmts ...)",
      "(call foo.0. \"a\\20b\" 'x' 1u)"
    ]
    for s in samples:
      let m1 = fromNif(s)
      let dumped = dumpNif(m1)
      let m2 = fromNif(dumped)
      check $m1[0] == $m2[0]

  test "memfile large - 5k nodes":
    var big = "(stmts"
    for i in 0..<5000:
      big.add(" " & $i)
    big.add(")")
    # write and parse via memfile
    let path = "/tmp/nif_large.nif"
    writeFile(path, big)
    var mf = memfiles.open(path, fmRead)
    defer: mf.close()
    let toks = tokenizeNif(mf)
    check toks.len > 5000
    let m = fromNif(mf)
    check m[0].children.len == 5000

  test "error cases - unterminated string, invalid escape, bracket inside compound":
    expect OpenParserNifError:
      discard fromNif("(stmts \"unterminated)")
    expect OpenParserNifError:
      discard fromNif("(stmts \"bad\\zz\")")
    expect OpenParserNifError:
      discard fromNif("(stmts 'ab')") # char lit too long
    expect OpenParserNifError:
      discard fromNif("(stmts [1 2])") # brackets not allowed inside compound per current strict mode

  test "non-ascii ident bytes >=128 and escaped control in string":
    let ident = "café-" & char(0x80) & "x" # 0x80 is non-ascii byte
    let esc = "a\\5Cb\\20c" # "a\b c" where \5C is backslash
    let src = "(stmts " & ident & " \"" & esc & "\" )"
    let m = fromNif(src)
    check m[0].children[0].ident == ident
    check m[0].children[1].strVal == "a\\b c"

  test "directive .vendor .platform .config .unusedname":
    let src = """
(.nif27)
(.vendor "Nifler")
(.platform "x86_64")
(.config "release")
(.unusedname tmp.14)
(stmts)
"""
    let m = fromNif(src)
    check m[0].tag == ".nif27"
    check m[1].tag == ".vendor"
    check m[1].children[0].strVal == "Nifler"
    check m[2].children[0].strVal == "x86_64"
    check m[4].tag == ".unusedname"
    check m[4].children[0].symbol == "tmp.14"