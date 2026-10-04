## Tests for the TOML parser and serializer.

import std/[strutils, tables, times, os, math, unicode, sequtils]
import unittest
import ../src/openparser/toml

suite "toml":

  test "scalars, arrays, booleans":
    let doc = parseTOML("""
title = "demo"
port = 25
ratio = 1.5
enabled = true
tags = ["a", "b", "c"]
empty = []
""")
    check doc.get("title").getStr() == "demo"
    check doc.get("port").getInt() == 25
    check doc.get("ratio").getFloat() == 1.5
    check doc.get("enabled").getBool()
    check doc.get("tags").getArray().len == 3
    check doc.get("tags").getArray()[1].getStr() == "b"
    check doc.get("empty").getArray().len == 0

  test "dotted table headers":
    let doc = parseTOML("""
[smtp]
enabled = true
hostname = "meowmail.local"

[smtp.listen.port25]
enabled = true
host = "0.0.0.0"
port = 25

[smtp.auth.users]
"relay-user@example.com" = "change-me"
""")
    check doc.get("smtp.hostname").getStr() == "meowmail.local"
    check doc.get("smtp.listen.port25.port").getInt() == 25
    check doc.get("smtp.listen.port25.host").getStr() == "0.0.0.0"
    check doc.get("smtp.auth.users").getObject()["relay-user@example.com"].getStr() == "change-me"

  test "quoted keys with special characters":
    let doc = parseTOML("""
"a.b" = 1
'weird key' = "value"
""")
    check doc.get("a.b").getInt() == 1
    check doc.get("weird key").getStr() == "value"

  test "inline tables":
    let doc = parseTOML("""
point = { x = 1, y = 2 }
""")
    let obj = doc.get("point").getObject()
    check obj["x"].getInt() == 1
    check obj["y"].getInt() == 2

  test "array of tables":
    let doc = parseTOML("""
[[products]]
name = "Hammer"
sku = 1

[[products]]
name = "Nail"
sku = 2
""")
    let arr = doc.get("products").getArray()
    check arr.len == 2
    check arr[0].getObject()["name"].getStr() == "Hammer"
    check arr[1].getObject()["sku"].getInt() == 2

  test "dump round-trips":
    let doc = parseTOML("""
title = "demo"
port = 25
tags = ["a", "b"]

[smtp]
enabled = true

[smtp.auth.users]
"relay-user@example.com" = "change-me"

[[products]]
name = "Hammer"
""")
    let re = parseTOML(dumpTOML(doc))
    check re.get("title").getStr() == "demo"
    check re.get("port").getInt() == 25
    check re.get("tags").getArray().len == 2
    check re.get("smtp.enabled").getBool()
    check re.get("smtp.auth.users").getObject()["relay-user@example.com"].getStr() == "change-me"
    check re.get("products").getArray().len == 1

  test "comments are ignored":
    let doc = parseTOML("""
# leading comment
key = "value" # trailing comment
""")
    check doc.get("key").getStr() == "value"

suite "toml typed mapping":
  type
    ServerConf = object
      root: string
      port: int
      address: string
      ratio: float
      enabled: bool
      tags: seq[string]
    TlsConf = object
      enabled: bool
      cert: string
    AppConf = object
      title: string
      server: ServerConf
      tls: TlsConf
      ports: seq[int]

  test "full document into object":
    let c = parseTOML("""
root = "./davroot"
port = 9001
address = "127.0.0.1"
ratio = 1.5
enabled = true
tags = ["a", "b"]
""", ServerConf)
    check c.root == "./davroot"
    check c.port == 9001
    check c.address == "127.0.0.1"
    check c.ratio == 1.5
    check c.enabled
    check c.tags == @["a", "b"]

  test "missing keys keep pre-filled defaults":
    var c = ServerConf(root: "./davroot", port: 9001, address: "127.0.0.1",
      ratio: 0.5, enabled: false, tags: @["keep"])
    fromToml(parseTOML("port = 8080"), c)
    check c.root == "./davroot"
    check c.port == 8080
    check c.address == "127.0.0.1"
    check c.ratio == 0.5
    check not c.enabled
    check c.tags == @["keep"]

  test "nested tables and seq of ints":
    let c = parseTOML("""
title = "demo"
ports = [80, 443]

[server]
root = "./x"
port = 1

[tls]
enabled = true
cert = "c.pem"
""", AppConf)
    check c.title == "demo"
    check c.server.root == "./x"
    check c.server.port == 1
    check c.tls.enabled
    check c.tls.cert == "c.pem"
    check c.ports == @[80, 443]

  test "unknown keys are ignored":
    let c = parseTOML("""
root = "./x"
future = "yes"

[server]
whatever = 1
""", ServerConf)
    check c.root == "./x"
    check c.port == 0

  test "ref object allocates on mapping":
    type RefConf = ref object
      root: string
      port: int
    let c = parseTOML("root = \"./x\"\nport = 7", RefConf)
    check not c.isNil
    check c.root == "./x"
    check c.port == 7

  test "type mismatch raises":
    expect OpenParserTomlError:
      discard parseTOML("port = \"not-a-number\"", ServerConf)
    expect OpenParserTomlError:
      discard parseTOML("tags = \"nope\"", ServerConf)
    expect OpenParserTomlError:
      discard parseTOML("[server]\nroot = 1", AppConf)

suite "toml v1.0.0 conformance":

  test "multi-line literal strings":
    # The closing-delimiter check used to be hard-coded to `"`, so every
    # '''...''' document was reported as unterminated.
    let doc = parseTOML("a = '''one\ntwo'''\nb = '''\n'''\nc = '''it's'''")
    check doc.get("a").getStr() == "one\ntwo"
    check doc.get("b").getStr() == ""
    check doc.get("c").getStr() == "it's"

  test "escape sequences":
    # A Nim raw string would hand TOML doubled backslashes, so build the
    # document with real escapes instead.
    let doc = parseTOML("bs = \"\\b\\f\\n\\r\\t\\\"\\\\\"\n" &
                        "uni = \"\\u00e9\\U0001F600\"\n")
    check doc.get("bs").getStr() == "\b\f\n\r\t\"\\"
    check doc.get("uni").getStr() == $Rune(0x00e9) & $Rune(0x1F600)

  test "unknown escapes are rejected":
    for src in ["a = \"\\q\"", "a = \"\\/\"", "a = \"\\x41\"",
                "a = \"\\u00\"", "a = \"\\UFFFFFFFF\"", "a = \"\\uD800\""]:
      expect OpenParserTomlError:
        discard parseTOML(src)

  test "multi-line line continuation":
    let doc = parseTOML("a = \"\"\"one \\\n     two\"\"\"")
    check doc.get("a").getStr() == "one two"
    let crlf = parseTOML("a = \"\"\"x\\\r\n    y\"\"\"")
    check crlf.get("a").getStr() == "xy"

  test "integer forms":
    let doc = parseTOML("""
dec = 1_000
neg = -1_1
hex = 0xDEADBEEF
hexus = 0xdead_beef
oct = 0o755
bin = 0b1_0_1
zero = -0
""")
    check doc.get("dec").getInt() == 1000
    check doc.get("neg").getInt() == -11
    check doc.get("hex").getInt() == 3735928559'i64
    check doc.get("hexus").getInt() == 3735928559'i64
    check doc.get("oct").getInt() == 493
    check doc.get("bin").getInt() == 5
    check doc.get("zero").getInt() == 0

  test "int64 limits":
    let doc = parseTOML("""
max = 9223372036854775807
min = -9223372036854775808
""")
    check doc.get("max").getInt() == high(int64)
    check doc.get("min").getInt() == low(int64)

  test "malformed numbers are rejected":
    for src in ["a = 01", "a = 1_", "a = _1", "a = 1__0", "a = 1.", "a = .1",
                "a = 1e", "a = 0x", "a = 0xG", "a = 0o8", "a = 0b2",
                "a = Inf", "a = NAN", "a = in", "a = nan_", "a = +", "a = -"]:
      expect OpenParserTomlError:
        discard parseTOML(src)

  test "special floats":
    let doc = parseTOML("""
inf = inf
posinf = +inf
neginf = -inf
notanum = nan
e = 3e2
neg = -9_007_199_254_740_991.0
""")
    check doc.get("inf").getFloat() == Inf
    check doc.get("posinf").getFloat() == Inf
    check doc.get("neginf").getFloat() == -Inf
    check classify(doc.get("notanum").getFloat()) == fcNan
    check doc.get("e").getFloat() == 300.0
    check doc.get("neg").getFloat() == -9_007_199_254_740_991.0

  test "bare keys may start with a digit or a dash":
    let doc = parseTOML("""
1 = "one"
23.01 = "dotted"
-1 = "neg"
- = "dash"
[111]
111 = 9
[---]
--- = 7
""")
    check doc.get("1").getStr() == "one"
    check doc.get("23").get("01").getStr() == "dotted"
    check doc.get("-1").getStr() == "neg"
    check doc.get("-").getStr() == "dash"
    check doc.get("111.111").getInt() == 9
    check doc.get("---.---").getInt() == 7

  test "date and time types keep their identity":
    let doc = parseTOML("""
odt = 1979-05-27T00:32:00.999999-07:00
ldt = 1979-05-27 07:32:00
ld  = 1979-05-27
lt  = 07:32:00
""")
    let odt = doc.get("odt")
    check odt.kind == tvkDateTime
    check odt.dateKind == tdkOffsetDateTime
    check odt.dateRaw == "1979-05-27T00:32:00.999999-07:00"
    check doc.get("ldt").dateKind == tdkLocalDateTime
    check doc.get("ld").dateKind == tdkLocalDate
    check doc.get("lt").dateKind == tdkLocalTime
    check odt.dateTimeVal.year == 1979
    check odt.dateTimeVal.hour == 0
    check odt.dateTimeVal.minute == 32

  test "date and time values are range-checked":
    for src in ["a = 1979-13-01", "a = 1979-02-30", "a = 2023-02-29",
                "a = 1979-05-27T24:00:00", "a = 1979-05-27T00:60:00",
                "a = 1979-05-27T00:00:61", "a = 0000-01-01",
                "a = 1979-05-27T00:00:00+25:00"]:
      expect OpenParserTomlError:
        discard parseTOML(src)
    check parseTOML("a = 2024-02-29").get("a").getValue() == "2024-02-29"

  test "table redefinition is rejected":
    for src in ["a = 1\na = 2",
                "[a]\nb = 1\n[a]\nc = 2",
                "a.b = 1\n[a.b]",
                "[a]\nb.c = 1\n[a.b]",
                "[a.b]\nz = 9\n[a]\nb.c.t = 1",
                "[[a]]\n[a]",
                "a = []\na.b = 1",
                "a = 1\na.b = 2",
                "a = {b = 1}\na.c = 2",
                "a = {b = 1}\n[a.c]"]:
      expect OpenParserTomlError:
        discard parseTOML(src)

  test "super-tables may be defined after the fact":
    let doc = parseTOML("""
[a.b.c]
answer = 42

[a]
better = 43
""")
    check doc.get("a.b.c.answer").getInt() == 42
    check doc.get("a.better").getInt() == 43
    check parseTOML("[fruit]\napple.color = \"red\"").get("fruit.apple.color").getStr() == "red"

  test "array of tables nests and re-opens":
    let doc = parseTOML("""
[[a]]
[[a.b]]
[a.b.c]
d = 0
[[a.b]]
[a.b.c]
d = 1
""")
    check doc.get("a").getArray().len == 1
    let inners = doc.get("a").getArray()[0].getObject()["b"].getArray()
    check inners.len == 2
    check inners[0].getObject()["c"].getObject()["d"].getInt() == 0
    check inners[1].getObject()["c"].getObject()["d"].getInt() == 1

  test "inline tables are closed and single-line":
    for src in ["a = { b = 1, }",
                "a = { b = 1\n}",
                "a = { b = 1, b = 2 }",
                "a = { b = { c = 1 }, b.d = 2 }",
                "a = { \"\" = 1, \"\".x = 2 }"]:
      expect OpenParserTomlError:
        discard parseTOML(src)
    let doc = parseTOML("a = { b.c = 1, b.d = 2 }")
    check doc.get("a.b.c").getInt() == 1
    check doc.get("a.b.d").getInt() == 2

  test "control characters are rejected":
    for src in ["a = \"x\x08y\"", "a = 'x\x1Fy'", "a = 1 # c\x0c",
                "a\x00 = 1", "a = \"x\x7Fy\"",
                # A TOML triple quote cannot appear inside a Nim string,
                # so the last case is spliced together.
                "a = " & "\"\"\"" & "\x7f" & "\"\"\""]:
      expect OpenParserTomlError:
        discard parseTOML(src)

  test "one key/value pair per line":
    for src in ["a = 1 b = 2", "a = \"x\" b = \"y\"", "[t] a = 1\n[t] b = 2",
                "[[t]] a = 1", "[t] a = 1"]:
      expect OpenParserTomlError:
        discard parseTOML(src)

  test "header brackets must be adjacent when doubled":
    for src in ["[ [t]]", "[[t] ]", "[]", "[.]", "[..]", "[a.]", "[naughty..naughty]"]:
      expect OpenParserTomlError:
        discard parseTOML(src)

  test "raw control and lone carriage returns are rejected":
    expect OpenParserTomlError: discard parseTOML("a = 1\r\rb = 2")
    expect OpenParserTomlError: discard parseTOML("a = 1\rb")

  test "a leading byte order mark is accepted":
    let doc = parseTOML("\xEF\xBB\xBFa = 1")
    check doc.get("a").getInt() == 1
    expect OpenParserTomlError: discard parseTOML("a = 1\n\xEF\xBB\xBFb = 2")

  test "invalid utf-8 is rejected":
    expect OpenParserTomlError: discard parseTOML("a = \"\xED\xA0\x80\"")
    expect OpenParserTomlError: discard parseTOML("# \xED\xA0\x80")
    expect OpenParserTomlError: discard parseTOML("a = \"\xC0\x80\"")

  test "getValue reports the literal for dates":
    let doc = parseTOML("a = 1979-05-27T07:32:00Z")
    check doc.get("a").getValue() == "1979-05-27T07:32:00Z"

  test "dumpTOML escapes control characters and quotes odd keys":
    let doc = parseTOML("""
[plain]
"a.b" = 1
"with space" = "tab\there\nnewline"
""")
    let text = dumpTOML(doc)
    check text.contains("\"a.b\" = 1")
    check text.contains("\"with space\" = \"tab\\there\\nnewline\"")
    let again = parseTOML(text)
    check again.get("plain.a.b").getInt() == 1
    check again.get("plain").getObject()["with space"].getStr() == "tab\there\nnewline"

  test "dumpTOML round-trips dates and array of tables":
    let src = """
[[p]]
d = 1979-05-27T00:32:00.999999-07:00

[[p]]
d = 1987-07-05 17:45:00Z
"""
    let doc = parseTOML(src)
    let again = parseTOML(dumpTOML(doc))
    check again.get("p").getArray()[0].getObject()["d"].dateRaw ==
      "1979-05-27T00:32:00.999999-07:00"
    check again.get("p").getArray()[1].getObject()["d"].dateKind == tdkOffsetDateTime

  test "dumpTOML keeps an inline array of tables inline":
    let doc = parseTOML("a = [{b = 1}]")
    check dumpTOML(doc) == "a = [{b = 1}]\n"

  test "parseTOMLFile reads from disk":
    let path = getTempDir() / "openparser_toml_test.toml"
    writeFile(path, "a = 1\n")
    try:
      check parseTOMLFile(path).get("a").getInt() == 1
    finally:
      removeFile(path)

  test "DateTime fields map into objects":
    type Sched = object
      at: DateTime
    let c = parseTOML("at = 1979-05-27T07:32:00Z", Sched)
    check c.at.year == 1979
    check c.at.hour == 7
    expect OpenParserTomlError:
      discard parseTOML("at = \"nope\"", Sched)
