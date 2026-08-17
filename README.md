<p align="center">
  A tiny collection of high-performance parsers and dumpers<br>
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

## Cross-cutting Features

| Feature | JSON | YAML | XML | TOML | CSV |
|---|:---:|:---:|:---:|:---:|:---:|
| Zero-copy / Memfiles | x | | x | | x |
| Direct-to-object | x | x | x | x | |
| `parseHook` / `dumpHook` | x | x | x | x | |
| `renameHook` | x | x | x | x | |
| `currentField` context | x | x | x | x | |
| `skipValue` | x | x | x | x | |
| `XmlNode` / `JsonNode` tree | x | x | x | x | |
| SIMD acceleration | x | | x | | |
| Context-aware errors | x | x | x | x | x |

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
