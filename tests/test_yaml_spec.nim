import std/[unittest, strutils, tables, options, sets, critbits]
import ../src/openparser/[yaml, json]

type Tag = enum
  tgA, tgB, tgC

type Inner = object
  a: int
  b: string
  c: seq[string]
  d: Option[string]
  e: bool
  f: float

type Post = object
  title: string
  draft: bool
  tags: seq[string]

type Outer = object
  name: string
  items: seq[Inner]
  meta: Table[string, string]
  count: int
  ratio: float
  flag: bool
  note: Option[int]
  tags: set[Tag]
  tup: tuple[x: int, y: string]
  j: JsonNode

proc mustReject(src: string): bool =
  try:
    discard parseYAMLNode(src)
    result = false
  except CatchableError:
    result = true

proc mustAccept(src: string): bool =
  try:
    discard parseYAMLNode(src)
    result = true
  except CatchableError:
    result = false

template rejects(src: string) =
  ## Asserts that `src` is rejected by the parser.
  check mustReject(src)

template accepts(src: string) =
  ## Asserts that `src` is accepted by the parser.
  check mustAccept(src)

suite "YAML spec: plain scalars (7.3.3)":
  test "multi-line plain scalar folds to spaces":
    check parseYAMLNode("a: hello\n  world\n").get("a").getStr == "hello world"
    check parseYAMLNode("a: one\n  two\n  three\nb: 1\n").get("a").getStr ==
      "one two three"
  test "multi-line plain scalar keeps internal spacing":
    check parseYAMLNode("a: one  two\n  three\n").get("a").getStr == "one  two three"
  test "plain scalar as root spans lines":
    check parseYAMLNode("hello\n  world\n").getStr == "hello world"
  test "plain keys may contain spaces":
    check parseYAMLNode("a b c: 1\n").get("a b c").getInt == 1
    check parseYAMLNode("hello world: v\n").get("hello world").getStr == "v"
  test "empty and punctuation keys":
    check parseYAMLNode("'': 1\n").get("").getInt == 1
    check parseYAMLNode("'a: b': 1\n").get("a: b").getInt == 1
    check parseYAMLNode("\"\\u00e9\": 1\n").get("\u00e9").getInt == 1
    check parseYAMLNode("@: 1\n").get("@").getInt == 1
    check parseYAMLNode("50%: 1\n").kind == yamlObject
    check parseYAMLNode("!: 1\n").kind == yamlObject
    check parseYAMLNode("1: one\n").get("1").getStr == "one"
    check parseYAMLNode("null: 1\n").kind == yamlObject
    check parseYAMLNode("2001-12-14: d\n").kind == yamlObject
  test "plain scalars that look like other syntax":
    check parseYAMLNode("a: 50%").get("a").getStr == "50%"
    check parseYAMLNode("a: x%y").get("a").getStr == "x%y"
    check parseYAMLNode("a: '!weird'").get("a").getStr == "!weird"
    check parseYAMLNode("a: x!y").get("a").getStr == "x!y"
    check parseYAMLNode("a: b:c").get("a").getStr == "b:c"
    check parseYAMLNode("a: -b").get("a").getStr == "-b"
    check parseYAMLNode("a: ..x").get("a").getStr == "..x"
    check parseYAMLNode("a: @x").get("a").getStr == "@x"
    check parseYAMLNode("a: `x").get("a").getStr == "`x"
    check parseYAMLNode("a: 12:30:00").get("a").getStr == "12:30:00"
  test "a nested mapping value needs its own line":
    # `a: b: c` is rejected by both reference implementations.
    rejects("a: b: c\n")
  test "hash needs preceding space to start a comment":
    check parseYAMLNode("a: x#y").get("a").getStr == "x#y"
    check parseYAMLNode("a: x #y").get("a").getStr == "x"

suite "YAML spec: block scalars (8.1)":
  test "literal keep/strip/clip":
    check parseYAMLNode("a: |-\n  x\n  y\n").get("a").getStr == "x\ny"
    check parseYAMLNode("a: |\n  x\n  y\n").get("a").getStr == "x\ny\n"
    check parseYAMLNode("a: |+\n  x\n\n\n").get("a").getStr == "x\n\n\n"
    check parseYAMLNode("a: |-\n  x\n\n\n").get("a").getStr == "x"
  test "folded joins with spaces":
    check parseYAMLNode("a: >\n  one\n  two\n").get("a").getStr == "one two\n"
    check parseYAMLNode("a: >-\n  one\n  two\n").get("a").getStr == "one two"
  test "folded keeps more-indented lines verbatim":
    check parseYAMLNode("a: >\n  one\n    indented\n  two\n").get("a").getStr ==
      "one\n  indented\ntwo\n"
  test "folded paragraph break":
    check parseYAMLNode("a: >\n  p1\n\n  p2\n").get("a").getStr == "p1\np2\n"
    check parseYAMLNode("a: >\n  p1\n\n\n  p2\n").get("a").getStr == "p1\n\np2\n"
  test "explicit indent indicator":
    check parseYAMLNode("a: |2\n   x\n   y\n").get("a").getStr == " x\n y\n"
    check parseYAMLNode("a: |2-\n   x\n   y\n").get("a").getStr == " x\n y"
  test "header comment and order of indicators":
    check parseYAMLNode("a: | # hdr\n  x\n").get("a").getStr == "x\n"
    check parseYAMLNode("a: |2-\n   x\n").get("a").getStr == " x"
    check parseYAMLNode("a: >2-\n   x\n").get("a").getStr == " x"
    # The indent indicator must precede the chomping indicator (§8.1.1.1).
    rejects("a: |-2\n   x\n")
  test "block scalar content is raw":
    check parseYAMLNode("a: |\n  x # not a comment\n").get("a").getStr ==
      "x # not a comment\n"
    check parseYAMLNode("a: |\n  - not a list\n  'not quoted'\n").get("a").getStr ==
      "- not a list\n'not quoted'\n"
  test "block scalar as root and in a sequence":
    check parseYAMLNode("|\n  x\n").getStr == "x\n"
    check parseYAMLNode("a:\n  - |\n    x\n  - plain\n").get("a").getArray().len == 2
  test "empty block scalar":
    check parseYAMLNode("a: |\nb: 1\n").get("a").getStr == ""
  test "block scalar inside flow is rejected":
    rejects("a: [|\n  x\n]")

suite "YAML spec: flow collections (7.4)":
  test "a trailing comma before the close is allowed":
    # `[1, 2, ]` is `[1, 2]`: `in-flow` permits a final separator (§7.4.1).
    check parseYAMLNode("[1, 2, ]").getArray().len == 2
    check parseYAMLNode("{a: 1, b: 2, }").kind == yamlObject
  test "an empty entry between commas is not a value":
    # `[1, , 2]` is rejected by both reference implementations.
    rejects("[1, , 2]")
  test "unterminated flow is rejected":
    rejects("[1, 2")
    rejects("{a: 1")
  test "empty flow collections":
    check parseYAMLNode("[]").getArray().len == 0
    check parseYAMLNode("{}").kind == yamlObject
  test "an empty value in a flow mapping is null":
    check parseYAMLNode("{a: , b: 2}").get("a").kind == yamlNull
  test "flow may span lines":
    check parseYAMLNode("[\n  1,\n  2\n]").getArray().len == 2
    check parseYAMLNode("{\n  a: 1,\n  b: 2\n}").get("b").getInt == 2
    check parseYAMLNode("a: [\n  1,\n  2,\n]").kind == yamlObject
  test "quoted flow keys and values":
    check parseYAMLNode("{'a b': 1}").get("a b").getInt == 1
    check parseYAMLNode("{a: 'x, y'}").get("a").getStr == "x, y"
    check parseYAMLNode("[a, 'b,c']").getArray()[1].getStr == "b,c"
  test "nested flow":
    check parseYAMLNode("a: [[[1]]]").get("a").getArray()[0].getArray()[0].getArray().len == 1
    check parseYAMLNode("{a: {b: [1, {c: 2}]}}").get("a.b").getArray()[1].get("c").getInt == 2

suite "YAML spec: explicit keys (8.2.2)":
  test "block mapping explicit key/value":
    check parseYAMLNode("? a\n: 1\n").get("a").getInt == 1
    check parseYAMLNode("? a\n:\n").get("a").kind == yamlNull
    check parseYAMLNode("? a\n").get("a").kind == yamlNull
  test "set-like mapping":
    check parseYAMLNode("? a\n: 1\n? b\n: 2\n").get("b").getInt == 2
  test "flow mapping explicit key":
    check parseYAMLNode("{? a : 1}").get("a").getInt == 1
  test "complex key is rendered":
    check parseYAMLNode("? [1, 2]\n: 1\n").kind == yamlObject
    check parseYAMLNode("? {a: 1}\n: 1\n").kind == yamlObject
  test "explicit null key":
    check parseYAMLNode(": 1\n").kind == yamlObject

suite "YAML spec: tags (7.1, 10.2)":
  test "core schema tags coerce":
    check parseYAMLNode("a: !!str 12").get("a").kind == yamlString
    check parseYAMLNode("a: !!int '12'").get("a").getInt == 12
    check parseYAMLNode("a: !!float '1.5'").get("a").getFloat == 1.5
    check parseYAMLNode("a: !!bool yes").get("a").getBool == true
    check parseYAMLNode("a: !!null x").get("a").kind == yamlNull
  test "structural tags":
    check parseYAMLNode("a: !!seq [1]").get("a").getArray().len == 1
    check parseYAMLNode("a: !!map {b: 1}").get("a").kind == yamlObject
  test "an application-specific tag keeps the raw scalar text":
    # `!foo 12` is not resolved by the Core Schema, so the node stays a string
    # rather than becoming the integer 12 (§3.3.3).
    check parseYAMLNode("a: !<tag:example.com,2000:x> 1").get("a").getStr == "1"
    check parseYAMLNode("a: !weird 12").get("a").getStr == "12"
  test "a tag with no content is an empty scalar":
    # `!weird` alone is an empty node carrying a tag, so it is the string "".
    check parseYAMLNode("a: !weird\nb: 2\n").get("a").getStr == ""
  test "tagged block scalar":
    check parseYAMLNode("a: !!str |\n  x\n").get("a").getStr == "x\n"
  test "tag on mapping key":
    check parseYAMLNode("!!str a: 1\n").get("a").getInt == 1

suite "YAML spec: anchors and aliases (3.2.2, 7.1)":
  test "scalar, sequence and mapping aliases":
    check parseYAMLNode("a: &x 5\nb: *x\n").get("b").getInt == 5
    check parseYAMLNode("b: &s [1,2]\nd: *s\n").get("d").getArray().len == 2
    check parseYAMLNode("b: &m\n  x: 1\nd: *m\n").get("d").get("x").getInt == 1
  test "alias of an alias":
    check parseYAMLNode("x: &a 1\ny: &b *a\nz: *b\n").get("z").getInt == 1
    check parseYAMLNode("a: &m {k: 1}\nb: &n *m\nc: *n\n").get("c").get("k").getInt == 1
  test "undefined alias is an error":
    rejects("a: *nope")
    rejects("&a [*a]")
  test "anchor on a key":
    check parseYAMLNode("&k key: 1\n").get("key").getInt == 1
  test "anchor inside a sequence":
    check parseYAMLNode("l:\n  - &a 1\n  - *a\n").get("l").getArray()[1].getInt == 1
  test "merge key":
    check parseYAMLNode("b: &b {x: 1}\nd: {<<: *b, y: 2}\n").get("d").get("x").getInt == 1
    check parseYAMLNode("b: &b {x: 1}\nd: {<<: *b, y: 2}\n").get("d").get("y").getInt == 2

suite "YAML spec: core schema types (10.3.2)":
  test "integers":
    check parseYAMLNode("a: 12").get("a").getInt == 12
    check parseYAMLNode("a: 0x1F").get("a").getInt == 31
    check parseYAMLNode("a: 0o17").get("a").getInt == 15
    check parseYAMLNode("a: 1_000").get("a").getInt == 1000
    check parseYAMLNode("a: -5").get("a").getInt == -5
    check parseYAMLNode("a: 012").get("a").getInt == 12
    check parseYAMLNode("a: 9223372036854775807").get("a").getInt == 9223372036854775807'i64
  test "floats":
    check parseYAMLNode("a: 1.5").get("a").getFloat == 1.5
    check parseYAMLNode("a: 1e3").get("a").getFloat == 1000.0
    check parseYAMLNode("a: 1_2.3_4e1_0").get("a").getFloat == 12.34e10
    check parseYAMLNode("a: .inf").get("a").getFloat == Inf
    check parseYAMLNode("a: -.inf").get("a").getFloat == -Inf
    check parseYAMLNode("a: .nan").get("a").getFloat != parseYAMLNode("a: .nan").get("a").getFloat
  test "booleans use the exact Core Schema case set":
    # §10.3.2 lists true|True|TRUE and false|False|FALSE. `yes`/`no`/`on`/
    # `off` are YAML 1.1 spellings and stay strings.
    check parseYAMLNode("a: true").get("a").getBool == true
    check parseYAMLNode("a: True").get("a").getBool == true
    check parseYAMLNode("a: TRUE").get("a").getBool == true
    check parseYAMLNode("a: false").get("a").getBool == false
    check parseYAMLNode("a: False").get("a").getBool == false
    check parseYAMLNode("a: FALSE").get("a").getBool == false
    check parseYAMLNode("a: yes").get("a").getStr == "yes"
    check parseYAMLNode("a: off").get("a").getStr == "off"
    check parseYAMLNode("a: y").get("a").getStr == "y"
  test "nulls":
    check parseYAMLNode("a: null").get("a").kind == yamlNull
    check parseYAMLNode("a: Null").get("a").kind == yamlNull
    check parseYAMLNode("a: NULL").get("a").kind == yamlNull
    check parseYAMLNode("a: ~").get("a").kind == yamlNull
    check parseYAMLNode("a:").get("a").kind == yamlNull
    check parseYAMLNode("a: nil").get("a").getStr == "nil"
  test "quoted scalars are never resolved":
    check parseYAMLNode("a: '12'").get("a").getStr == "12"
    check parseYAMLNode("a: \"true\"").get("a").getStr == "true"
  test "version-like and date-like stay strings":
    check parseYAMLNode("a: 1.0.0").get("a").getStr == "1.0.0"
    check parseYAMLNode("a: 2001-12-14").get("a").getStr == "2001-12-14"
    check parseYAMLNode("a: 12abc").get("a").getStr == "12abc"

suite "YAML spec: quoted scalars (7.3.1, 7.3.2, 7.7)":
  test "double quoted escapes":
    check parseYAMLNode("a: \"x\\ny\"").get("a").getStr == "x\ny"
    check parseYAMLNode("a: \"x\\ty\"").get("a").getStr == "x\ty"
    check parseYAMLNode("a: \"\\u00e9\"").get("a").getStr == "\u00e9"
    check parseYAMLNode("a: \"\\U0001F600\"").get("a").getStr == "😀"
    check parseYAMLNode("a: \"\\x41\"").get("a").getStr == "A"
    check parseYAMLNode("a: \"a\\\\b\"").get("a").getStr == "a\\b"
    check parseYAMLNode("a: \"\\e\"").get("a").getStr == "\x1b"
    check parseYAMLNode("a: \"\\N\"").get("a").getStr == "\u0085"
    check parseYAMLNode("a: \"\\L\"").get("a").getStr == "\u2028"
    check parseYAMLNode("a: \"\\P\"").get("a").getStr == "\u2029"
    check parseYAMLNode("a: \"\\_\"").get("a").getStr == "\u00a0"
  test "double quoted line continuations and folding":
    check parseYAMLNode("a: \"one \\\n  two\"").get("a").getStr == "one two"
    check parseYAMLNode("a: \"one\n  two\"").get("a").getStr == "one two"
    check parseYAMLNode("a: \"one\n\n  two\"").get("a").getStr == "one\ntwo"
  test "single quoted doubling":
    check parseYAMLNode("a: 'it''s'").get("a").getStr == "it's"
    check parseYAMLNode("a: 'x\\ny'").get("a").getStr == "x\\ny"
    check parseYAMLNode("a: 'one\n  two'").get("a").getStr == "one two"
  test "invalid escapes are rejected":
    rejects("a: \"\\q\"")
    rejects("a: \"\\xZZ\"")
    rejects("a: \"abc")
    rejects("a: 'abc")

suite "YAML spec: structure":
  test "nested sequences":
    check parseYAMLNode("- - 1\n  - 2\n").getArray()[0].getArray().len == 2
    check parseYAMLNode("- - 1\n  - 2\n- 3\n").getArray().len == 2
    check parseYAMLNode("- - - 1\n").getArray()[0].getArray()[0].getArray().len == 1
  test "sequence at the same indent as its key":
    check parseYAMLNode("a:\n- 1\n- 2\n").get("a").getArray().len == 2
    check parseYAMLNode("a:\n- 1\nb: 2\n").get("b").getInt == 2
  test "sequence indented under key":
    check parseYAMLNode("a:\n  - 1\n  - 2\n").get("a").getArray().len == 2
  test "compact mapping in sequence":
    check parseYAMLNode("- a: 1\n  b: 2\n").getArray()[0].get("b").getInt == 2
  test "empty sequence entry is null":
    check parseYAMLNode("-\n- 1\n").getArray()[0].kind == yamlNull
  test "negative numbers in a sequence":
    check parseYAMLNode("- -1\n- 2\n").getArray()[0].getInt == -1

suite "YAML spec: documents and directives (9)":
  test "document markers":
    check parseYAMLNode("---\na: 1\n").get("a").getInt == 1
    check parseYAMLNode("a: 1\n...\n").get("a").getInt == 1
  test "directives":
    check parseYAMLNode("%YAML 1.2\n---\na: 1\n").get("a").getInt == 1
    check parseYAMLNode("%TAG !e! tag:example.com,2000:\n---\na: 1\n").get("a").getInt == 1
  test "a 1.2 processor accepts 1.1 and 1.2 documents":
    # §6.8.1: 1.2 is a superset of 1.1, so a 1.1 document is processed as 1.2.
    check parseYAMLNode("%YAML 1.1\n---\na: 1\n").get("a").getInt == 1
    check parseYAMLNode("%YAML 1.0\n---\na: 1\n").get("a").getInt == 1
    # A higher minor version is accepted with a warning, so parsing succeeds.
    check parseYAMLNode("%YAML 1.3\n---\na: 1\n").get("a").getInt == 1
  test "a higher major version is rejected":
    # §6.8.1 requires an error for `%YAML 2.0`.
    rejects("%YAML 2.0\n--- a\n")
    rejects("%YAML 3.1\n--- a\n")
  test "a malformed %YAML directive is rejected":
    rejects("%YAML\n--- a\n")
    rejects("%YAML 1\n--- a\n")
    rejects("%YAML one.two\n--- a\n")
  test "a malformed %TAG directive is rejected":
    rejects("%TAG\n--- a\n")
    rejects("%TAG !e!\n--- a\n")
  test "a reserved directive is rejected":
    # §3.2.3.4: %YAML and %TAG are the only directives this version defines.
    rejects("%FOO bar baz\n--- a\n")
    rejects("%\n--- a\n")
  test "a %TAG handle expands to its prefix":
    # §6.8.2: `!e!foo` with `%TAG !e! tag:example.com,2000:app/` is
    # `tag:example.com,2000:app/foo`, which the Core Schema does not resolve,
    # so the value keeps its raw text as a string.
    let tagged = parseYAMLNode(
      "%TAG !e! tag:example.com,2000:app/\n---\n!e!foo 1\n")
    check tagged.kind == yamlString
    check tagged.getStr == "1"
  test "the non-specific ! tag resolves by kind":
    # §10.3.2: `!` means "resolve as if untagged", so a plain scalar still gets
    # Core Schema treatment.
    check parseYAMLNode("! 12\n").getInt == 12
    check parseYAMLNode("a: ! 12").get("a").getInt == 12
    check parseYAMLNode("a: ! [1]").get("a").getArray().len == 1
    check parseYAMLNode("! \"12\"").getStr == "12"
  test "multi-document streams":
    check parseYAMLStreamNodes("---\na: 1\n---\nb: 2\n---\n- x\n").len == 3
    check parseYAMLStreamNodes("a: 1\n...\n---\nb: 2\n").len == 2
  test "BOM and CRLF":
    check parseYAMLNode("\xEF\xBB\xBFa: 1\n").get("a").getInt == 1
    check parseYAMLNode("a: 1\r\nb: 2\r\n").get("b").getInt == 2
    check parseYAMLNode("a: |\r\n  x\r\n  y\r\n").get("a").getStr == "x\ny\n"

suite "YAML spec: character escapes (5.1, 5.2)":
  test "every escape in the table":
    # Example 5.13, §5.1.
    check parseYAMLNode("\"\\0\"").getStr == "\0"
    check parseYAMLNode("\"\\a\"").getStr == "\x07"
    check parseYAMLNode("\"\\b\"").getStr == "\x08"
    check parseYAMLNode("\"\\t\"").getStr == "\t"
    check parseYAMLNode("\"\\n\"").getStr == "\n"
    check parseYAMLNode("\"\\v\"").getStr == "\x0B"
    check parseYAMLNode("\"\\f\"").getStr == "\x0C"
    check parseYAMLNode("\"\\r\"").getStr == "\r"
    check parseYAMLNode("\"\\e\"").getStr == "\x1B"
    # `\/` is ns-esc-slash, valid per §5.1 even though go-yaml rejects it.
    check parseYAMLNode("\"\\ \"").getStr == " "
    check parseYAMLNode("\"\\\"\"").getStr == "\""
    check parseYAMLNode("\"\\\\\"").getStr == "\\"
    check parseYAMLNode("\"\\/\"").getStr == "/"
    # U+0085 NEL, encoded as UTF-8 (\x85 alone is not a valid encoding).
    check parseYAMLNode("\"\\N\"").getStr == "\xC2\x85"
    check parseYAMLNode("\"\\_\"").getStr == "\xC2\xA0"
    check parseYAMLNode("\"\\L\"").getStr == "\xE2\x80\xA8"
    check parseYAMLNode("\"\\P\"").getStr == "\xE2\x80\xA9"
    check parseYAMLNode("\"\\x41\\u0041\\U00000041\"").getStr == "AAA"
  test "a non-breaking space and NEL survive a round trip":
    check parseYAMLNode("\"a\xC2\xA0b\"").getStr == "a\xC2\xA0b"
    check parseYAMLNode("\"a\xC2\x85b\"").getStr == "a\xC2\x85b"
  test "an escape needs its full width":
    rejects("\"\\x4\"")
    rejects("\"\\u12\"")
    rejects("\"\\U1234\"")
    rejects("\"\\xZZ\"")
  test "a code point beyond the Unicode range is rejected":
    # ns-esc-32-bit is 8 hex digits, but the value must still be a code point.
    rejects("\"\\U00110000\"")
    check parseYAMLNode("\"\\U0010FFFF\"").getStr.len == 4
  test "a lone surrogate escape becomes the replacement character":
    # §4.2.2 excludes surrogates from printable characters, and a Nim string
    # cannot hold one, so U+FFFD is substituted rather than failing to parse.
    check parseYAMLNode("\"\\uD800\"").getStr == "\xEF\xBF\xBD"
  test "an unknown escape is rejected":
    rejects("\"\\q\"")
    rejects("\"abc\\")

suite "YAML spec: allowed characters and indicators (4.3, 4.4)":
  test "an indicator followed by content is part of a plain scalar":
    # ns-plain-first allows `?`, `:` and `-` when a plain-safe char follows.
    check parseYAMLNode("a: ?x").get("a").getStr == "?x"
    check parseYAMLNode("a: -x").get("a").getStr == "-x"
    check parseYAMLNode("a: :x").get("a").getStr == ":x"
    rejects("a: :")
  test "a colon inside a plain scalar is kept":
    # `x:y` is one scalar; only `: ` (colon plus space) ends it (§7.3.3).
    check parseYAMLNode("a: x:y").get("a").getStr == "x:y"
    check parseYAMLNode("a: https://example.com/p?q=1").get("a").getStr ==
      "https://example.com/p?q=1"
  test "a hash only starts a comment after a space":
    check parseYAMLNode("a: x#y").get("a").getStr == "x#y"
    check parseYAMLNode("a: x #y").get("a").getStr == "x"
  test "a percent that is not in column zero is ordinary text":
    check parseYAMLNode("a: 50%").get("a").getStr == "50%"
    check parseYAMLNode("a: x%y").get("a").getStr == "x%y"
  test "an indicator that cannot start a plain scalar is an error":
    # These characters are c-indicators, so no plain scalar may begin with
    # them in block context (§7.3.3).
    rejects("a: ,x")
    rejects("a: }x")
    rejects("a: ]x")
  test "a block collection may not start on a value's own line":
    # `- x` and `? x` after `a: ` need their own, more indented line.
    rejects("a: - x")
    rejects("a: ? x")
  test "the reserved indicators are accepted as plain text":
    # `@` and backtick are c-reserved: they may not *start* a plain scalar,
    # but the 1.2 grammar here is applied leniently rather than rejecting.
    check parseYAMLNode("a: x@y").get("a").getStr == "x@y"
  test "an apostrophe inside a plain scalar is not a quote":
    check parseYAMLNode("a: STANDBY LC's").get("a").getStr == "STANDBY LC's"

suite "YAML spec: flow collections (7.4)":
  test "a single pair may be a sequence entry":
    # §7.4.1: `[ns-flow-pair]` is a valid entry, so `[x: y]` is a mapping.
    let single = parseYAMLNode("a: [x: y]").get("a")
    check single.kind == yamlArray
    check single.getArray().len == 1
    check single.getArray()[0].kind == yamlObject
    check single.getArray()[0].get("x").getStr == "y"
    check parseYAMLNode("[x: y, z: w]").getArray().len == 2
    check parseYAMLNode("[a: b, c]").getArray()[1].getStr == "c"
  test "a complex collection may be a key":
    # §8.2.2 allows any node as an explicit key.
    let complex = parseYAMLNode("[[a]: b]")
    check complex.getArray().len == 1
    check complex.getArray()[0].get("[a]").getStr == "b"
  test "content after a flow collection is rejected":
    # A flow collection ends the node, so trailing text is not allowed.
    rejects("a: [1, 2]c")
    rejects("a: {b: 1}c")
    accepts("a: [[[1]]]")
    accepts("a: [1] # note")
  test "a block scalar may not appear in flow context":
    rejects("a: [|]")
    rejects("a: {b: [|\n  x\n]}")
  test "an unterminated flow collection is rejected":
    rejects("a: [1, 2")
    rejects("a: {b: 1")
    rejects("a: [[1]")
  test "flow collections may span lines":
    let spread = parseYAMLNode("a: [\n  1,\n  2\n]\n")
    check spread.get("a").getArray().len == 2
    let wide = parseYAMLNode("a: {b: 1,\n  c: 2}\n")
    check wide.get("a").get("b").getInt == 1
    check wide.get("a").get("c").getInt == 2

suite "YAML spec: block collections (8.2.1, 8.2.2)":
  test "a sequence entry may take its node from the next line":
    check parseYAMLNode("-\n  a\n").getArray()[0].getStr == "a"
    check parseYAMLNode("-\n  - x\n  - y\n").getArray().len == 1
    check parseYAMLNode("-\n  a: 1\n  b: 2\n").getArray()[0].get("b").getInt == 2
  test "an empty entry is null and does not swallow the next line":
    check parseYAMLNode("-\n- a\n- - b\n").getArray().len == 3
    check parseYAMLNode("-\n- a\n- - b\n").getArray()[0].kind == yamlNull
    check parseYAMLNode("-\n- a\n- - b\n").getArray()[1].getStr == "a"
  test "a sequence may sit at its key's indent or deeper":
    check parseYAMLNode("a:\n- 1\n- 2\n").get("a").getArray().len == 2
    check parseYAMLNode("a:\n  - 1\n  - 2\n").get("a").getArray().len == 2
  test "a nested mapping needs its own line":
    # `a: b: c` has no valid reading: the value of `a` would be a mapping on
    # the same line, which §8.2.1 does not allow.
    rejects("a: b: c")
    check parseYAMLNode("a:\n  b: c\n").get("a").get("b").getStr == "c"
  test "a more indented sibling ends the entry":
    check parseYAMLNode("a: 1\nb: 2\n").get("b").getInt == 2
    check parseYAMLNode("- a: 1\n  b: 2\n- c: 3\n").getArray().len == 2
    check parseYAMLNode("- a: 1\n  b: 2\n- c: 3\n").getArray()[0].get("b").getInt == 2
    check parseYAMLNode("- a: 1\n  b: 2\n- c: 3\n").getArray()[1].get("c").getInt == 3

suite "YAML spec: indentation and tabs (6.1)":
  test "tabs may not indent":
    rejects("a:\n\tb: 1\n")
    rejects("- a\n\t- b\n")
  test "tabs elsewhere are fine":
    accepts("a: \"x\ty\"")
    accepts("a: 'x\ty'")
    accepts("a:\t1\n")
  test "deep nesting":
    var deep = "root:\n"
    for i in 1 .. 25: deep &= "  " & "l" & $i & ":\n"
    deep &= "  " & "leaf: 1\n"
    accepts( deep)

suite "YAML spec: options":
  test "duplicate keys are rejected when asked":
    var o = defaultYamlOptions()
    o.allowDuplicateKeys = false
    var raised = false
    try:
      discard parseYAMLNode("a: 1\na: 2\n", o)
    except CatchableError:
      raised = true
    check raised
  test "duplicate keys are last-wins by default":
    check parseYAMLNode("a: 1\na: 2\n").get("a").getInt == 2
  test "maxDepth is enforced":
    var o = defaultYamlOptions()
    o.maxDepth = 3
    var raised = false
    try:
      discard parseYAMLNode("a:\n  b:\n    c:\n      d: 1\n", o)
    except CatchableError:
      raised = true
    check raised
    var shallow = false
    try:
      discard parseYAMLNode("a:\n  b: 1\n", o)
    except CatchableError:
      shallow = true
    check not shallow
  test "YAML 1.1 booleans are opt-in":
    var o = defaultYamlOptions()
    o.allowYaml11Booleans = true
    check parseYAMLNode("a: yes", o).get("a").getBool == true
    check parseYAMLNode("a: ON", o).get("a").getBool == true
    check parseYAMLNode("a: Off", o).get("a").getBool == false
    check parseYAMLNode("a: 'yes'", o).get("a").getStr == "yes"
    check parseYAMLNode("a: yes").get("a").getStr == "yes"

suite "YAML spec: typed objects":
  test "nested object graph":
    let yaml = """
name: root
items:
  - a: 1
    b: "quoted, with comma"
    c: [x, y, z]
    d: null
    e: true
    f: 1.5
  - a: 2
    b: |
      line one
      line two
    c:
      - p
      - q
    d: hello
    e: false
    f: -0.25
meta:
  k1: v1
  k2: v2
count: 42
ratio: 3.14159
flag: true
note: 7
tags: [tgA, tgB]
tup: {x: 1, y: two}
j: {any: [1, 2, {deep: true}]}
"""
    let o = parseYAML(yaml, Outer)
    check o.name == "root"
    check o.items.len == 2
    check o.items[0].b == "quoted, with comma"
    check o.items[0].c.len == 3
    check o.items[0].d == none(string)
    check o.items[0].e == true
    check o.items[0].f == 1.5
    check o.items[1].b == "line one\nline two\n"
    check o.items[1].c == @["p", "q"]
    check o.items[1].d == some("hello")
    check o.items[1].f == -0.25
    check o.meta["k2"] == "v2"
    check o.count == 42
    check o.ratio == 3.14159
    check o.flag == true
    check o.note == some(7)
    check tgA in o.tags
    check tgC notin o.tags
    check o.tup.x == 1
    check o.tup.y == "two"
    check o.j["any"][2]["deep"].getBool == true
  test "multi-line plain scalar into a string field":
    type R = object
      a: string
      b: string
    let r = parseYAML("a: one\n  two\nb: x\n", R)
    check r.a == "one two"
    check r.b == "x"
  test "null into scalar fields":
    type R = object
      a: int
      b: float
      c: bool
      d: string
    let r = parseYAML("a: null\nb: ~\nc: null\nd: null\n", R)
    check r.a == 0
    check r.b == 0.0
    check r.c == false
    check r.d == ""
  test "sequence field at parent indent":
    type R = object
      a: seq[string]
      b: string
    let r = parseYAML("a:\n- x\n- y\nb: z\n", R)
    check r.a == @["x", "y"]
    check r.b == "z"
  test "table, CritBitTree, set, enum, tuple and array fields":
    type R = object
      m: Table[string, int]
      c: CritBitTree[string]
      s: set[Tag]
      e: Tag
      t: tuple[a: int, b: string]
      arr: array[3, int]
    let r = parseYAML("""
m: {a: 1}
c: {x: 1, y: 2}
s: [tgA, tgC]
e: tgB
t: {a: 1, b: two}
arr: [1, 2, 3]
""", R)
    check r.m["a"] == 1
    check r.c.len == 2
    check r.s == {tgA, tgC}
    check r.e == tgB
    check r.t.b == "two"
    check r.arr[2] == 3
  test "root sequences, ref objects and anchors":
    type Bank = object
      name: string
      swift: string
    check parseYAML("- name: A\n  swift: X\n", seq[Bank]).len == 1
    type R = ref object
      a: int
    var r: R
    var p = initYamlParser("a: 5\n")
    p.parseYAML(r)
    check r.a == 5
    type A = object
      p1: int
      q: string
    let a = parseYAML("p1: &v 1\nq: *v\n", A)
    check a.q == "1"
  test "unknown keys are skipped":
    type R = object
      a: int
    let r = parseYAML("a: 1\nunknown:\n  nested: [1, 2]\n  more: {x: y}\n", R)
    check r.a == 1

suite "YAML spec: dumper":
  test "round-trips through the dumper":
    let doc = """{"a":1,"b":[1,2],"c":{"d":"e"},"h":"x y","i":"12","k":"","m":"#hash","n":"- dash","o":"yes","p":"x: y","q":"multi\nline\n","r":"café 日本 🚀","s":"a'b","t":"a\"b","u":[],"v":{},"w":null,"x":true,"y":1.5,"z":[[1,2],[3]]}"""
    let back = parseYAMLNode(dump(parseJson(doc)))
    check back.get("a").getInt == 1
    check back.get("b").getArray().len == 2
    check back.get("c").get("d").getStr == "e"
    check back.get("h").getStr == "x y"
    check back.get("i").getStr == "12"
    check back.get("k").getStr == ""
    check back.get("m").getStr == "#hash"
    check back.get("n").getStr == "- dash"
    check back.get("o").getStr == "yes"
    check back.get("p").getStr == "x: y"
    check back.get("q").getStr == "multi\nline\n"
    check back.get("r").getStr == "café 日本 🚀"
    check back.get("s").getStr == "a'b"
    check back.get("t").getStr == "a\"b"
    check back.get("u").getArray().len == 0
    check back.get("v").kind == yamlObject
    check back.get("w").kind == yamlNull
    check back.get("x").getBool == true
    check back.get("y").getFloat == 1.5
    check back.get("z").getArray()[0].getArray().len == 2
  test "keys that need quoting survive the round trip":
    let back = parseYAMLNode(dump(parseJson("""{"a b":1,"x:y":2,"1":3,"":4,"a ":5,"-":6,"#x":7}""")))
    check back.get("a b").getInt == 1
    check back.get("x:y").getInt == 2
    check back.get("1").getInt == 3
    check back.get("").getInt == 4
    check back.get("a ").getInt == 5
    check back.get("-").getInt == 6
    check back.get("#x").getInt == 7
  test "dumps YamlNode and YAMLObject":
    let n = parseYAMLNode("a: 1\nb:\n  - x\n  - y\n")
    let yamlOut = dump(n)
    check yamlOut == "a: 1\nb:\n  - x\n  - y"
    check dump(n.getObject) == "a: 1\nb:\n  - x\n  - y"
    check ($n).len > 0
  test "multi-document dump":
    let docs = parseYAMLStreamNodes("a: 1\n---\nb: 2\n")
    let docOut = dump(docs)
    check docOut.contains("---")
    let back = parseYAMLStreamNodes(docOut)
    check back.len == 2

suite "YAML spec: frontmatter":
  # Frontmatter is a widespread convention (Jekyll, Hugo, Obsidian) rather
  # than part of YAML 1.2, so it is only recognised by these entry points and
  # never by `parseYAML`.

  const postDoc = """---
title: Hello World
draft: true
tags: [a, b]
---

# Heading

Body text with --- inside.
"""

  test "splits the block from the body":
    let fm = splitFrontmatter(postDoc)
    check fm.found
    check fm.frontmatter == "title: Hello World\ndraft: true\ntags: [a, b]"
    check fm.body == "\n# Heading\n\nBody text with --- inside.\n"
  test "the parts reproduce the input":
    let fm = splitFrontmatter(postDoc)
    check "---\n" & fm.frontmatter & "\n---\n" & fm.body == postDoc
  test "bodyOffset points into the original input":
    let fm = splitFrontmatter(postDoc)
    check postDoc[fm.bodyOffset .. ^1] == fm.body
  test "parses the block as a node":
    let meta = parseYAMLFrontmatter(postDoc)
    check meta.get("title").getStr == "Hello World"
    check meta.get("draft").getBool
    check meta.get("tags").getArray().len == 2
  test "parses the block into a typed object":
    var body: string
    let post = parseYAMLFrontmatter[Post](postDoc, body)
    check post.title == "Hello World"
    check post.draft
    check post.tags == @["a", "b"]
    check body == "\n# Heading\n\nBody text with --- inside.\n"
  test "a document without frontmatter is returned unchanged":
    let plain = "# Just markdown\n\ntext"
    let fm = splitFrontmatter(plain)
    check not fm.found
    check fm.frontmatter == ""
    check fm.body == plain
    check fm.bodyOffset == 0
  test "an absent block raises when parsing is asked for":
    var raised = false
    try:
      discard parseYAMLFrontmatter("# no frontmatter\n")
    except CatchableError:
      raised = true
    check raised
  test "a `---` document start is still frontmatter":
    # The block is delimited by the markers regardless of what follows, so
    # `--- a: 1 --- b: 2` has `a: 1` as its frontmatter.
    let fm = splitFrontmatter("---\na: 1\n---\nb: 2\n")
    check fm.found
    check fm.frontmatter == "a: 1"
    check fm.body == "b: 2\n"
  test "`...` also closes the block":
    let fm = splitFrontmatter("---\na: 1\n...\nbody\n")
    check fm.found
    check fm.frontmatter == "a: 1"
    check fm.body == "body\n"
  test "an unterminated block raises":
    var raised = false
    try:
      discard splitFrontmatter("---\na: 1\nno end\n")
    except CatchableError:
      raised = true
    check raised
  test "an empty block is null":
    let fm = splitFrontmatter("---\n---\n")
    check fm.found
    check fm.frontmatter == ""
    check fm.body == ""
    check parseYAMLFrontmatter("---\n---\n").kind == yamlNull
  test "an empty block with a body":
    let fm = splitFrontmatter("---\n---\nbody\n")
    check fm.found
    check fm.frontmatter == ""
    check fm.body == "body\n"
  test "CRLF line endings":
    let fm = splitFrontmatter("---\r\ntitle: x\r\n---\r\nbody\r\n")
    check fm.found
    check fm.frontmatter == "title: x"
    check fm.body == "body\r\n"
    check parseYAMLFrontmatter("---\r\ntitle: x\r\n---\r\nbody\r\n").get("title").getStr == "x"
  test "a byte order mark is tolerated":
    let fm = splitFrontmatter("\xEF\xBB\xBF---\na: 1\n---\nbody")
    check fm.found
    check fm.frontmatter == "a: 1"
  test "a delimiter with trailing text is not a delimiter":
    check not splitFrontmatter("--- \na: 1\n---\nb\n").found
    check not splitFrontmatter("----\na: 1\n----\n").found
  test "a delimiter only counts at the start of a line":
    # The trailing `---` follows content, so the block never closes.
    var raised = false
    try:
      discard splitFrontmatter("---\na: 1 ---\n")
    except CatchableError:
      raised = true
    check raised
  test "frontmatter may hold any YAML node":
    let seqFm = splitFrontmatter("---\n- a\n- b\n---\nbody\n")
    check seqFm.found
    check parseYAMLFrontmatter("---\n- a\n- b\n---\nbody\n").getArray().len == 2
  test "blank lines inside the block are kept":
    let fm = splitFrontmatter("---\na: 1\n\nb: 2\n---\nbody\n")
    check fm.frontmatter == "a: 1\n\nb: 2"
    check parseYAMLFrontmatter("---\na: 1\n\nb: 2\n---\nbody\n").get("b").getInt == 2
  test "a multi-line scalar in the block":
    check parseYAMLFrontmatter("---\nsummary: |\n  one\n  two\n---\nbody\n")
      .get("summary").getStr == "one\ntwo\n"
  test "options apply to the block":
    var o = defaultYamlOptions()
    o.allowDuplicateKeys = false
    var raised = false
    try:
      discard parseYAMLFrontmatter("---\na: 1\na: 2\n---\nbody\n", o)
    except CatchableError:
      raised = true
    check raised
