<p align="center">
  A tiny collection of high-performance parsers and dumpers<br>
  JSON &bullet; YAML &bullet; XML &bullet; TOML &bullet; CSV <br>
  BSON &bullet; Plist &bullet; HTML &bullet; CSS &bullet; RSS &bullet; Atom<br>
  DotEnv &bullet; iCal &bullet; NIF &bullet; SQL &bullet; Regex &bullet; Gettext &bullet; FBE &bullet; QR &bullet; SVG &bullet; Colors<br>
  Written in Nim language
</p>

<p align="center">
  <code>nimble install openparser</code>
</p>

<p align="center">
  <a href="https://openpeeps.github.io/openparser/">API reference</a><br>
  <img src="https://github.com/openpeeps/openparser/workflows/test/badge.svg" alt="Github Actions">  <img src="https://github.com/openpeeps/openparser/workflows/docs/badge.svg" alt="Github Actions">
</p>

## About

OpenParser is a collection of parsers and dumpers (serializers) for various data formats, written in Nim. Each module provides zero-copy parsing via memory-mapped files, direct-to-object deserialization, custom hooks for extending type support, and context-aware error reporting.

> [!NOTE]
> Importing `openparser` directly will produce a compile-time error. Import the specific module you need, e.g. `openparser/json` for JSON.

---

## Key features

- JSON parser with SIMD-accelerated tokenization and direct-to-object parsing
- YAML 1.2 parser with block and inline syntax, comments, and block scalars
- Full-featured XML parser with element/attribute mapping and memfile support
- TOML config parser with datetime support and inline tables
- Zero-copy CSV parser using memory-mapped files for large file streaming
- BSON binary encoding/decoding following the BSON 1.1 spec
- Plist XML and binary `bplist00` codec with autodetect and NSKeyedArchiver unarchiving
- HTML5 parser with configurable parsing policies and DOM tree output
- RSS & Atom feed parsing, fetching, and serialization
- DotEnv parser with variable expansion and command substitution
- iCalendar (RFC 5545) parser and serializer with line unfolding, TEXT codecs and typed components
- NIF (2027 Nim Intermediate Format) parser with MemFile support, Base62 LineInfo and lazy symbol expansion
- SQL parser supporting PostgreSQL, MySQL, and SQLite dialects
- SIMD-accelerated regex engine with capture groups and quantifiers
- GNU Gettext PO/MO translation file parsing and compilation
- Fast Binary Encoding (FBE) with zero-copy buffer-based encoding
- QR code generation and decoding for Model 2, Micro QR, rMQR, and SQRC
- SVG parser with typed DOM, path data, transforms and serializer
- Colors module with CSS Color 4, harmonies, contrast and manipulation
- Context-aware error reporting with input snippets across all parsers
- Zero-copy parsing via memory-mapped files for performance-critical workloads
- Custom type extensibility through `parseHook`/`dumpHook` hooks
- Field renaming and context-aware parsing with `renameHook` and `currentField`

---

## JSON

Zero-copy JSON parser with SIMD-accelerated tokenization, direct-to-object parsing, and full hook support. Exports `std/json` for `JsonNode` compatibility.

```nim
import openparser/json

type
  Person = object
    name: string
    age: int
    email: string

# Parse to JsonNode
let data = """{"name":"Albush","age":40,"email":"al@ex.com"}"""
let node: JsonNode = fromJson(data)
echo node["name"].getStr  # Albush

# Parse directly into Nim objects
let person: Person = fromJson(data, Person)
echo person.name  # Albush

# Serialize back to JSON
echo toJson(person)  # {"name":"Albush","age":40,"email":"al@ex.com"}

# Memfile-based parsing for large files
let bigNode = fromJsonFile("huge.json")
```

**Features:** `parseHook`/`dumpHook` for custom types, `renameHook` for field name mapping, `currentField` context, `skipValue`, `toStaticJson` compile-time optimization, line-delimited JSON (`fromJsonL`), `Option[T]` support, `maxDepth` DoS protection.

### Depth limit protection
Protect against deeply nested JSON that could cause stack overflow:
```nim
import openparser/json

# Limit nesting depth to prevent DoS attacks
let opts = JsonOptions(maxDepth: 10)
let data = """{"a":{"b":{"c":1}}}"""

# Raises OpenParserJsonError if depth exceeds 10
let node = fromJson(data, opts)

# Also works with typed parsing
let user = fromJson(data, User, opts)
```

### Custom field mapping via pragma
Map JSON keys to Nim field names using the `{.json: "wireName".}` pragma (works for compile-time serialization):
```nim
import openparser/json

type
  User = object
    name {.json: "username".}: string
    age {.json: "user_age".}: int
    email: string  # no pragma - uses field name

# Dump: field "name" outputs as "username" using toStaticJson
let user = User(name: "Alice", age: 30)
let jsonStr = toStaticJson(user)
echo jsonStr  # {"username":"Alice","user_age":30}
```

> [!NOTE]
> The `{.json: "xx".}` pragma currently works for `toStaticJson` (compile-time dump). Runtime `toJson` and `fromJson` support is a TODO.

- [Tests](https://github.com/openpeeps/openparser/blob/main/tests/test_json_skip_value.nim) | [API Reference](https://openpeeps.github.io/openparser/openparser/json.html)

---

## YAML

YAML 1.2 parser with block and inline syntax, comments, block scalars, and the same hook-based API as JSON.

```nim
import openparser/yaml

type
  Config = object
    host: string
    port: int
    debug: bool

let yaml = """
host: localhost
port: 8080
debug: true
"""

# Parse to YAMLObject tree
let obj: YAMLObject = parseYAML(yaml)
echo obj["host"].strValue  # localhost

# Parse directly into Nim objects
let config: Config = parseYAML(yaml, Config)
echo config.port  # 8080
```

**Features:** Inline and block sequences/mappings, nested structures, comments, block scalars (`|`, `>`), dot-notation access, direct-to-object parsing via `parseHook`/`dumpHook`, `renameHook`, `currentField`.

- [Tests](https://github.com/openpeeps/openparser/blob/main/tests/test3.nim) | [API Reference](https://openpeeps.github.io/openparser/openparser/yaml.html)

---

## XML

Full-featured XML parser with element/attribute mapping to Nim objects, CDATA, comments, entities, self-closing tags, and memfile support. Same hook-based API as JSON/YAML.

```nim
import openparser/xml

type
  Person = object
    name: string
    age: int
    email: string

let xml = """
<person name="Alice" age="30">
  <email>alice@example.com</email>
</person>
"""

# Parse to XmlNode tree
let node: XmlNode = fromXml(xml)
echo node["email"].children[0].text  # alice@example.com

# Parse directly into Nim objects (attributes + child elements)
let person: Person = fromXml(xml, Person)
echo person.name  # Alice

# Serialize back to XML
echo toXml(person, XmlOptions(rootTag: "person"))
# <person><name>Alice</name><age>30</age><email>alice@example.com</email></person>

# Memfile-based parsing
let doc = fromXmlFile("large.xml")
```

**Features:** Attributes and child elements both map to object fields, repeated child tags -> `seq[T]`, enum/discriminator attributes for variant objects, `parseHook`/`dumpHook` for custom types, `renameHook`, `xmlAttrHook` for attribute vs element control, entity decoding (`&amp;`, `&#xHH;`), CDATA, comments, processing instructions, `XmlNode` DOM tree.

- [Tests](https://github.com/openpeeps/openparser/blob/main/tests/test_xml.nim) | [API Reference](https://openpeeps.github.io/openparser/openparser/xml.html)

---

## TOML

TOML config file parser with datetime support, inline tables, arrays, and the same hook-based direct-to-object API.

```nim
import openparser/toml

type
  ServerConfig = object
    host: string
    port: int

let toml = """
[server]
host = "localhost"
port = 8080
"""

# Parse to TomlDocument
let doc: TomlDocument = parseTOML(toml)

# Parse directly into Nim objects
let config: ServerConfig = parseTOML(toml, ServerConfig)
echo config.port  # 8080
```

**Features:** Sections, inline tables, arrays, datetime types, `parseHook`/`dumpHook`, direct-to-object parsing.

- [API Reference](https://openpeeps.github.io/openparser/openparser/toml.html)

---

## CSV

Zero-copy CSV parser using memory-mapped files. Processes rows via callback without loading the entire file into memory.

```nim
import openparser/csv

# Stream-parse a large CSV file
var i = 0
parseFile("data.csv",
  proc(fields: openArray[CsvFieldSlice], row: int): bool =
    inc i
    for field in fields:
      echo field.toString()
    true  # return true to continue, false to stop
)
echo "Parsed ", i, " rows"
```

**Features:** Zero-copy parsing via `MemFile`, configurable delimiters and quote characters, streaming row callback, handles ~600MB+ files efficiently.

- [Tests](https://github.com/openpeeps/openparser/blob/main/tests/test2.nim) | [API Reference](https://openpeeps.github.io/openparser/openparser/csv.html)

---

## BSON

Binary JSON encoding/decoding following the [BSON 1.1 spec](https://bsonspec.org/spec.html). Converts between `JsonNode` and raw BSON bytes.

```nim
import openparser/[json, bson]

# Encode JSON to BSON
let json = fromJson("""{"name":"Alice","age":30,"active":true}""")
let bsonBytes: seq[byte] = json.toBson()

# Decode BSON back to JSON
let decoded: JsonNode = fromBson(bsonBytes)
echo decoded["name"].getStr  # Alice
```

**Features:** Full BSON type support (ObjectId, Date, Binary, Regex, Timestamp, Code, Decimal128), extended JSON v2 notation, streaming encode/decode.

- [Tests](https://github.com/openpeeps/openparser/blob/main/tests/test6.nim) | [API Reference](https://openpeeps.github.io/openparser/openparser/bson.html)

---

## Plist

Apple Property List codec covering XML (`<plist version="1.0">`) and binary `bplist00` interchangeably. Same two-decoder API as JSON/YAML: `JsonNode` tree or direct-to-object via `{.plist.}` pragma / `parseHook`.

```nim
import openparser/plist
import std/times

type Person = object
  name {.plist: "Name".}: string
  age {.plist: "Age".}: int
  payload: seq[byte]   # <data> Base64
  created: DateTime    # <date> ISO8601 UTC

# Autodetect (XML or binary) -> JsonNode
let node = parsePlist(readFile("Info.plist"))
echo node["Name"].getStr

# Autodetect -> typed object (works for XML and bplist00)
let p = parsePlist(readFile("Info.plist"), Person)
echo p.payload.len

# Explicit XML / binary
let xmlNode = parseXmlPlist(xmlString)
let bNode = parseBPlist(bplistBytes)
let xmlOut = toXmlPlist(node)      # -> string with prolog+DTD
let bOut = toBPlist(p)             # -> seq[byte] bplist00

# File helpers (autodetect)
let fromFile = parsePlistFile("Info.plist")
let xmlOnly = parseXmlPlistFile("Info.plist")
let binOnly = parseBPlistFile("Info.bplist")

# NSKeyedArchiver graphs are unarchived automatically (opt-out via PlistOptions)
var opts = defaultPlistOptions()
opts.unarchive = false
let archived = parsePlist(archiverPlist, opts) # retains $archiver/$objects/$top
```

**Features:** XML entity decoding, comments, `<data>` Base64 ws-tolerance, `<date>` UTC, `integer` hex/decimal, `real` inf/nan, `true/false/array/dict/string`; binary `bplist00` header/trailer/offset table validation, marker `0x00/08/09/0F/1n/2n/33/4n/5n/6n/8n/An/Cn/Dn` + extended `0xF` counts, `UID` (`PlistUID distinct int` ↔ `{"CF$UID": int}`), `seq[byte]`/`DateTime`/`PlistUID`/`Option[T]` typed hooks, `{.plist.}` with `{.json.}` fallback, `PlistOptions` (`maxDepth`, `allowDuplicateKeys`, `strictDTD`, `xmlSortKeys`/`binarySortKeys`, `unarchive`), `detectPlistFormat`, double-unarchive-safe autodetect, file helpers for all three formats, cross-validated against `python plistlib` fixtures.

- [Tests](https://github.com/openpeeps/openparser/blob/main/tests/test_plist.nim) | [API Reference](https://openpeeps.github.io/openparser/openparser/plist.html)

---

## HTML

HTML5 parser with configurable parsing policies, memfile support, and a DOM tree output. Handles real-world HTML gracefully.

```nim
import openparser/html

let html = """<html><body><h1>Hello</h1><p>World</p></body></html>"""

# Parse with default policy (tolerant)
let doc = parseHtml(html)

# Parse a file with a strict policy
let policy = defaulHtmlParsingPolicy()
let doc2 = parseHtmlFile("page.html", policy)
```

**Features:** Configurable parsing policy (self-closing tags, unclosed tags, comments, CDATA, entities, etc.), memfile-based file parsing, `HtmlDocument` DOM tree.

- [API Reference](https://openpeeps.github.io/openparser/openparser/html.html)

---

## RSS & Atom Feeds

Parse, read, fetch, and serialize RSS and Atom feeds.

```nim
import openparser/rss
import openparser/feed

# RSS
let feed = parseRss(rssXmlString)
echo feed.title
let xml = toRssXml(feed)

# Atom
let atom = parseAtom(atomXmlString)
echo atom.title
let atomXml = toAtomXml(atom)

# Read from file or fetch from URL
let rssFromFile = readRss("feed.xml")
let rssFromUrl = fetchRss("https://example.com/feed.xml")
```

**Features:** Parse from string/file/URL, serialize back to XML, full feed metadata and entry access.

---

## DotEnv

Parse and load `.env` files with variable expansion, command substitution, and environment-specific overrides.

```nim
import openparser/dotenv

# Load a .env file into the environment
loadDotenv(".env")

# Parse without loading
let entries = parseEnv("DB_HOST=localhost\nDB_PORT=5432")
for entry in entries:
  echo entry.key, "=", entry.value

# Access loaded values
echo get("DB_HOST")  # localhost

# Environment-specific loading
loadDotenvForEnv("production")
```

**Features:** Variable expansion (`${VAR}`), command substitution (`${CMD:default}`), override control, `get`/`set`/`del`/`has` API.

- [API Reference](https://openpeeps.github.io/openparser/openparser/dotenv.html)

---

## iCal

RFC 5545 iCalendar parser and serializer. Parse from string or file, work with typed Nim objects, and serialize back with correct folding and escaping.

```nim
import openparser/ical

# Parse
let cal = parseIcal(readFile("meet.ics"))
echo cal.prodId           # PRODID
for c in cal.components:
  if c.kind == cckEvent:
    echo c.event.summary  # unescaped TEXT
    echo c.event.dtStart  # IcalDt with TZID

# Build from objects
var cal2 = IcalCalendar(prodId: some("-//MyApp//EN"), version: some("2.0"))
var ev = IcalEvent(uid: "evt1@example.com")
ev.dtstamp = some(IcalDt(dt: parseIcalDateTime("20240115T120000Z")))
ev.dtStart = some(IcalDt(dt: parseIcalDateTime("20240115T130000Z")))
ev.summary = some("Hello, world; with escapes\nnewline")
ev.attendees.add(IcalPerson(uri: "mailto:alice@example.com", cn: some("Alice")))
cal2.components.add(IcalComponent(kind: cckEvent, event: ev))

# Serialize (CRLF + 75-octet folding, TEXT escaping)
writeFile("out.ics", toIcal(cal2))

# File convenience
let fromFile = parseIcalFile("out.ics")
```

**Features:** Line unfolding/folding at 75 octets (UTF-8 safe), TEXT `\, \; \\ \n` codecs, DATE / DATE-TIME (`Z` UTC) / DURATION (`-P1W`, `PT15M`), parameters with quoted values (`CN="Doe, Jane"`), `VTIMEZONE` `STANDARD`/`DAYLIGHT`, nested `VALARM`, `VEVENT`/`VTODO`/`VJOURNAL` typed objects with `extraProps` fallback for `X-` and future components, `RRULE`/`EXDATE`/`CATEGORIES` handling, `OpenParserIcalError` with line context.

- [Tests](https://github.com/openpeeps/openparser/blob/main/tests/test_ical.nim) | [API Reference](https://openpeeps.github.io/openparser/openparser/ical.html)

---

## SQL

SQL parser and AST builder supporting PostgreSQL, MySQL, and SQLite dialects.

```nim
import openparser/sql

let ast = parseSql("SELECT name, age FROM users WHERE active = true ORDER BY name")
echo ast  # select name, age from users where active = true order by name
```

**Features:** SELECT/INSERT/UPDATE/DELETE, JOINs, subqueries, GROUP BY, HAVING, ORDER BY, LIMIT, AST manipulation, query builder.

- [Tests](https://github.com/openpeeps/openparser/blob/main/tests/test11.nim) | [API Reference](https://openpeeps.github.io/openparser/openparser/sql.html)

---

## Regex Engine

SIMD-accelerated regex engine with a full parser, compiler, and VM.

```nim
import openparser/regex

# Simple match
let result = match("hello world", "hello")
echo result.matched  # true
echo result.start    # 0
echo result.stop     # 5

# Find in string
let found = find("hello world", r"world")
echo found.matched   # true
echo found.start     # 6

# Find all occurrences
let all = findAll("aabbcc", r"[a-c]+")
echo all.len         # 3

# Capture groups
let m = match("2024-01-15", r"(\d{4})-(\d{2})-(\d{2})")
if m.matched:
  echo m.groupStr("2024-01-15", 1)  # "2024"
  echo m.groupStr("2024-01-15", 2)  # "01"
  echo m.groupStr("2024-01-15", 3)  # "15"

# Character classes and quantifiers
let email = match("user@example.com", r"[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}")
echo email.matched  # true
```

**Features:** SSE2/AVX2 acceleration, character classes, quantifiers, alternation, capture groups, anchoring.

---

## i18n (GNU Gettext)

Parse and compile PO/MO translation files with plural form support.

```nim
import openparser/gettext/[po, mo]

# Parse a .po file and compile it
let cat = openPoCatalog("messages.po")
let cc = compilePo(cat)

# Simple translation
let greeting = cc.translate("Hello, world!")
echo greeting

# Plural forms (English: singular vs plural)
let msg = cc.ntranslate("apple", "apples", 5)
echo msg  # "apples"

# Russian plural forms (3 forms)
let ruMsg = cc.ntranslate("товар", "товара", 5)
echo ruMsg  # "товаров"

# Parse headers
let headers = parsePoHeaders(cat)
echo headers["Language"]  # "en"

# Compile to .mo binary format
writeMoFile(cc, "messages.mo")
close(cat)

# Or parse .mo directly
let moCat = openMoCatalog("messages.mo")
let moMsg = moCat.translate("Hello")
close(moCat)
```

**Features:** PO/MO parsing, plural form expressions, header extraction, binary MO compilation.

---

## FBE (Fast Binary Encoding)

Encode and decode structured data using [Fast Binary Encoding](https://github.com/chronoxor/FastBinaryEncoding). Supports both a high-level compact API and a low-level field-based API with custom field IDs.

```nim
import openparser/fbe

type
  Person = object
    name: string
    age: int32
    bio: string

# High-level: encodeFinal/decodeFinal (compact, automatic field ordering)
let alice = Person(name: "Alice", age: 30, bio: "hello")
let buf = encodeFinal(alice)        # -> Buffer
var decoded = Person()
decodeFinal(buf, decoded)            # round-trip
assert decoded.name == "Alice"

# Encode/decode sequences
let people = @[Person(name: "Bob", age: 25), Person(name: "Carol", age: 28)]
let seqBuf = encodeFinal(people)
var decodedPeople: seq[Person]
decodeFinal(seqBuf, decodedPeople)

# Low-level: custom field IDs and versioning
let buf2 = encode(alice, 7'u32, proc (fieldName: string): uint16 =
  if fieldName == "name": 1'u16
  elif fieldName == "age": 2'u16
  elif fieldName == "bio": 3'u16
  else: 0'u16
)
```

**Features:** Zero-copy buffer-based encoding, custom field IDs, struct versioning, disk round-trip, UUID/timestamp/decimal/vector support, UTF-8 strings, inner structs, benchmarked at 10K+ objects.

---

## NIF

NIF parser for the 2027 Nim Intermediate Format. Re-exports `nif/ast`, `nif/lexer`, `nif/parser` and provides `fromNif`, `fromNifFile`, `tokenizeNif` with MemFile support, lazy global-symbol expansion, depth limiting and context-aware errors via `OpenParserNifError`.

```nim
import openparser/nif

# Parse from string (spec example)
let src = """
(.nif27)
(stmts
  (imp@2,5,sysio.nim (type :File (object . .)))
  (call write.1.sys "Hello World!\0A"))
"""
let mods = fromNif(src)
echo mods[1].tag              # stmts
echo mods[1].children[0].tag  # imp with lineInfo

# Parse from file with MemFile and module suffix expansion
let mods2 = fromNifFile("module.nif")
let nodes = fromNif("(stmts foo.0. bar.0.)",
  NifOptions(moduleSuffix: "mymod", expandGlobalSymbols: true))
echo nodes[0].children[0].symbol  # foo.0.mymod

# Tokenize without parsing
let toks = tokenizeNif("(stmts 123 \"hi\" :sym)")
echo toks[2].kind  # ntkInt
```

**Features:** Full nifspec 2027 token set (`() [] {} .` atoms, `nkIdent/Symbol/SymbolDef/Int/UInt/Float/CharLit/StrLit/Compound/Directive`), escapes `\n \t \r \| \^ \xx`, Base62 `LineInfo @col[,line[,file]]` and `~` shorthand, `#comment#` suffixes, hyphenated identifiers, trailing-dot global symbols `foo.0.` with lazy `moduleSuffix` expansion, `.nif27` directive at byte 0, `.index/.indexat` support, `maxDepth` and `preserveComments` options, MemFile zero-copy `tokenizeNif`/`fromNif`, round-trip `dumpNif`.

- [Tests](https://github.com/openpeeps/openparser/blob/main/tests/test_nif.nim) | [API Reference](https://openpeeps.github.io/openparser/openparser/nif.html)

---

## Colors

CSS Color Module Level 4 parser with conversions, manipulation, harmonies and WCAG contrast. Parses any CSS color string and converts between hex, rgb, hsl, hsv, hwb, cmyk, lab, lch, oklab, oklch.

```nim
import openparser/colors

# Parse any CSS color
let c = parseColor("oklch(0.7 0.15 180)")
echo c.toHex()          # #00c0a0
echo c.toRgbString()    # rgb(0, 192, 160)
echo c.toHslString()    # hsl(172, 100%, 38%)

# Hex, named, functions, transparent
echo parseColor("#ff0000").toHex()        # #ff0000
echo parseColor("rebeccapurple").toHex()  # #663399
echo parseColor("rgb(255 0 0 / 0.5)").toHex8()  # #ff000080
echo parseColor("hsl(0 100% 50%)").toHex()      # #ff0000
echo parseColor("lab(53.2 80.1 67.2)").toHex()  # #ff0000

# Conversions
let hsl = c.toHsl()
let lab = c.toLab()
let oklch = c.toOklch()
echo fromHsl(hsl).toHex()
echo fromLab(lab).toHex()

# Manipulation (chainable, immutable)
let lighter = parseColor("red").lighten(20).saturate(10).spin(30)
echo lighter.toHex()           # lighter rotated red
echo parseColor("red").complement().toHex()  # #00ffff
echo parseColor("red").mix(parseColor("blue"), 50).toHex()  # #800080
echo parseColor("red").tint(20).toHex()      # pastel
echo parseColor("red").shade(20).toHex()     # darker

# Harmonies
echo parseColor("red").triad()        # [red, lime, blue]
echo parseColor("red").tetrad()       # 4 colors
echo parseColor("red").analogous(5)   # 5 analogous colors

# Contrast & readability (WCAG 2.1)
echo luminance(parseColor("white"))   # 1.0
echo contrastRatio(parseColor("white"), parseColor("black"))  # 21.0
echo isReadable(parseColor("white"), parseColor("black"))     # true
echo mostReadable(parseColor("black"), @[parseColor("white"), parseColor("red")]).toName()  # white

# Validation
echo isValidColor("notacolor")  # false
echo parseColor("transparent").toHex8()  # #00000000
```

**Features:** Hex `#rgb #rgba #rrggbb #rrggbbaa` with/without `#`, 148 named colors, `rgb/rgba` with comma/space/slash syntax, `hsl/hsla`, `hsv/hsva/hsb`, `hwb`, `cmyk/device-cmyk`, `lab/lch/oklab/oklch`, `color(srgb ...)` and `transparent`, `isValidColor`, round-trip `toHex/toHex8/toRgb/toHsl/toHsv/toHwb/toCmyk/toLab/toLch/toOklab/toOklch` + `*String` helpers, manipulation `lighten/darken/saturate/desaturate/greyscale/spin/brighten/mix/tint/shade/setAlpha/fadeIn/fadeOut/complement`, harmonies `triad/tetrad/splitComplement/analogous/monochromatic`, WCAG `luminance/contrastRatio/isReadable/readability/mostReadable/isLight/isDark`, random `randomColor/randomColors`.

- [Tests](https://github.com/openpeeps/openparser/blob/main/tests/test_colors.nim) | [API Reference](https://openpeeps.github.io/openparser/openparser/colors.html)

---

## SVG

Full SVG 1.1 parser with typed DOM, path, lengths, transforms and CSS bridge. Built on top of the XML and Colors modules.

```nim
import openparser/svg

# Parse from string or file (MemFile)
let src = """
  <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24">
    <rect x="2" y="2" width="20" height="20" rx="4" fill="oklch(0.7 0.15 180)" />
    <path d="M12 2 L22 22 L2 22 Z" fill="red" stroke="none"/>
    <g transform="translate(10) rotate(45)">
      <circle cx="12" cy="12" r="10" fill="none" stroke="currentColor"/>
    </g>
  </svg>
"""
let doc = parseSvg(src)
echo doc.root.tag              # svgSvg
echo doc.root.width.get().value  # 24.0
echo doc.root.viewBox.get().width  # 24.0

# Typed access
let rect = doc.root.children[0]
echo rect.common.fill.get().toHex()       # #00c0a0 (oklch resolved via Colors)
echo rect.width.get().value               # 20.0

let path = doc.root.children[1]
echo path.d.get()                         # M12 2 L22 22 L2 22 Z
echo path.dSegs.len                       # 4 segments (M, L, L, Z)

# Lengths, viewBox, transforms
echo parseSvgLength("50%").unit           # luPercent
echo parseSvgViewBox("0 0 100 100").width # 100.0
echo parseSvgTransform("translate(10) rotate(45)").len  # 2

# Modify DOM and serialize
rect.common.fill = some(parseColor("rebeccapurple"))
rect.attrsRaw["fill"] = "rebeccapurple"  # keep raw in sync for serializer
let minified = doc.toSvg()  # compact: <svg ...><rect .../></svg>
let pretty = doc.toSvg(SvgSerializeOptions(pretty: true, indentSize: 2, xmlDecl: true))
echo pretty

# File & error handling
let doc2 = parseSvgFile("icon.svg")
# strict mode via policy
let policy = SVGParserPolicy(requireXmlns: true, allowUnknownTags: false)
# parseSvg(src, policy) raises SvgParseError on unknown tags

# CSS style attribute bridge
let styled = parseSvg("""<svg><rect style="fill: hsl(0 100% 50%); stroke: blue; opacity: 0.5"/></svg>""")
echo styled.root.children[0].common.styleDecls[0].property  # fill
```

**Features:** All SVG tags via `SvgTag` enum + `rawTag` fallback, typed `SvgLength` (`px % em ex pt pc cm mm in` + exponent handling), `SvgViewBox`, `SvgPreserveAspectRatio`, `SvgTransform` (`matrix/translate/scale/rotate/skewX/skewY`), full path `d` parser (`M L H V C S Q T A Z` with implicit lineto), points for `polygon/polyline`, `fill/stroke` resolved to `Color` (via `openparser/colors`) + `fillRaw/strokeRaw` for `none/currentColor`, `style` attribute parsed into `styleDecls` via CSS bridge, `x/y/rx/ry/cx/cy/r/x1/y1/x2/y2` lengths, `opacity/fillOpacity/strokeOpacity`, `href` (incl. `xlink:href`), `SVGParserPolicy` (`requireXmlns/allowUnknownTags/allowUnknownAttrs/preserveComments/strictColors/strictLengths/allowEntities`), `MemFile` `parseSvgFile`/`parseSvg(mf)`, serializer `toSvg` with `pretty/minify/xmlDecl/sortAttrs/preserveComments` and self-closing/escaping handling, round-trip preservation.

- [Tests](https://github.com/openpeeps/openparser/blob/main/tests/test_svg.nim) | [API Reference](https://openpeeps.github.io/openparser/openparser/svg.html)

---

## Cross-cutting Features

| Feature | JSON | YAML | XML | TOML | CSV | Plist |
|---|:---:|:---:|:---:|:---:|:---:|:---:|
| Zero-copy / Memfiles | x | | x | | x |  |
| Direct-to-object | x | x | x | x | | x |
| `parseHook` / `dumpHook` | x | x | x | x | | x |
| `renameHook` | x | x | x | x | | x |
| `currentField` context | x | x | x | x | | x |
| `skipValue` | x | x | x | x | |  |
| `XmlNode` / `JsonNode` tree | x | x | x | x | | x |
| SIMD acceleration | x | | x | | |  |
| Context-aware errors | x | x | x | x | x | x |
| Binary format |  |  |  |  |  | x |

## Error Reporting

Most parsers provide context-aware error reporting with a snippet of the input around the error location:

```
<person name="Alice" age="30"/>
                           ^
Error (1:26) Unexpected EOF while parsing `element`
```

```
{"name":"Alice","age":"isMember":true}
                                ^
Error (1:33) Unexpected token `:`
```

## QR Codes

Full QR symbology family: generators and readers for Model 2, Micro QR, rMQR and legacy Model 1, plus SQRC-style encrypted payloads, payload builders and an SVG renderer.

```nim
import openparser/qr

# Model 2 (versions 1-40, L/M/Q/H, auto segmentation)
let qr = encodeQr("https://openpeeps.dev")
echo decodeQrMatrix(qr).text  # https://openpeeps.dev

# Micro QR (M1-M4)
let micro = encodeMicro("HELLO MICRO")

# rMQR (ISO/IEC 23941), all 32 sizes at levels M/H
let rmqr = encodeRmqr("rectangular micro qr", ecMedium, "R11x139")
echo decodeRmqrMatrix(rmqr).text

# SQRC-style public/private payload (AES via nimcypher)
var key: array[16, uint8]
for i in 0 ..< 16: key[i] = uint8(i * 17 + 3)
let sqrc = encodeSqrc(publicData = "serial 4711",
                      privateData = "warranty code 99-FOO",
                      key)
let opened = decodeSqrcMatrix(sqrc, key)
echo opened.publicText, " / ", opened.privateText
```

**Payload builders** feed straight into any encoder:

```nim
import openparser/qr

encodeQr(makeVCard(VCard(fullName: "Ada Lovelace",
                         org: "OpenPeeps", email: "ada@example.org")))
encodeQr(makeWifi("home-net", "secret123"))
encodeQr(makeUrl("openpeeps.dev"))
```

**Rendering** produces a compact standalone SVG (one merged path):

```nim
writeFile("qr.svg", encodeQr("hi").toSvg(scale = 8, border = 4))
```

**Decoding from images:** pass an 8-bit grayscale `GrayImage` to `decodeQrImage`; the reader binarizes (hybrid Otsu/adaptive), locates finder patterns, fits an affine grid and Reed-Solomon-corrects what it finds. Handles rotation up to about 30 degrees and moderate noise.

Notes:
- Encoder output is byte-compatible with segno/zxing for Model 2 and byte-identical for Micro QR and rMQR.
- Model 1 is a legacy closed-system format; versions 1-12 are supported.
- The SQRC profile and AQR ring format are documented openparser profiles inspired by DENSO WAVE's proprietary formats.

---

## Roadmap

- [x] JSON depth/size limit to prevent DoS attacks
- [ ] JSON schema validation support
- [x] JSON custom field mapping (compile-time `{.json: "xx".}` pragma)

> [!NOTE]
> Some implementations (dotenv, fbe, gettext) may be incomplete. Contributions are welcome!

### Contributions & Support

- Found a bug? [Create a new Issue](https://github.com/openpeeps/openparser/issues)
- Want to help? [Fork it!](https://github.com/openpeeps/openparser/fork)

### License

MIT license. [Made by Humans from OpenPeeps](https://github.com/openpeeps).<br>
Copyright OpenPeeps & Contributors &mdash; All rights reserved.
