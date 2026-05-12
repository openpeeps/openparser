<p align="center">
  A tiny collection of high-performance parsers and dumpers<br>
  👑 Written in Nim language
</p>

<p align="center">
  <code>nimble install openparser</code>
</p>

<p align="center">
  <a href="https://openpeeps.github.io/openparser/">API reference</a><br>
  <img src="https://github.com/openpeeps/openparser/workflows/test/badge.svg" alt="Github Actions">  <img src="https://github.com/openpeeps/openparser/workflows/docs/badge.svg" alt="Github Actions">
</p>

## About
OpenParser is a collection of parsers and dumpers (serializers) for various data formats, written in Nim language. It provides a simple and efficient way to parse and dump data in different formats, such as JSON, TOML, YAML, BSON, CSV, FBE and more

## 😍 Key Features
- Parse [JSON](#parse-json), [CSV data](#parse-csv), [YAML](#parse-yaml), [TOML configs](#toml-configs) and more
- **DotEnv** parser for `.env` files
- **BSON** encoding and decoding from `JsonNode` objects
- [FBE](https://github.com/chronoxor/FastBinaryEncoding) for Fast Binary Encoding and Decoding
- i18n [GNU Gettext](https://www.gnu.org/software/gettext/) PO and MO file parsing and dumping
- **RSS & Atom** feed reader and writer
- **CSV** zero-copy parsing for **large files**
- [Regex Engine](#simd-accelerated-regex-engine) with SIMD acceleration

### Other features
- **Zero-copy** JSON parsing via Memfiles for high performance and low memory usage
- **Direct-to-object** parsing for JSON, YAML and TOML
- **Context-aware error** reporting while deserializing data
- Custom Hooks API for parsing and dumping
- Scientific notation support
- Dot notation access for nested data structures

### Why?
Initially I wanted to create a simple JSON parser with fine-grained control over the parsing process (jsonl, custom hooks, error reporting, zero-copy tokenization), then I thought it would be fun to add a YAML parser that parses YAML documents in the same way as JSON. Once I started talking with the chatbot I ended up creating a collection of parsers and dumpers for various data formats.

>[!NOTE]
> Importing `openparser` directly will produce a compile-time error, you need to import the specific module for the data format you want to use, e.g. `openparser/json` for JSON parsing and dumping or `openparser/csv` for CSV parsing.

## Parse JSON

OpenParser provide a simple and efficient module for parsing JSON data using the zero-copy parsing approach, which allows you to parse JSOn data without copying it into memory, making it faster and more memory-efficient.

>[!NOTE]
>OpenParser's JSON parser is exporting the `std/json` module by default.

### `fromJson` string into JsonNode or Nim data structures

Here a simple example taking a stringified JSON and parsing it into a `JsonNode` tree structure:
```nim
import openparser/json

let data = """{"name":"Albush","age":40,"address":{"street":"456 Elm St","city":"Othertown","zip":67890},"friends":[]}"""

let jsonNode: JsonNode = fromJson(data)
echo jsonNode["name"].getStr # Albush
echo jsonNode["age"].getInt # 40
```
### `toJson` serialize Nim data structures into JSON strings
`toJson` function allows you to serialize Nim data structures into JSON strings:
```nim
import openparser/json

var data = %*{
  "name": "Alice",
  "age": 30,
  "isMember": true,
  "address": {
    "street": "123 Main St",
    "city": "Anytown",
    "zip": 12345
  },
  "friends": ["Bob"]
}

echo toJson(data) # {"name":"Alice"...}
```

### `toJson` pretty-printing
A **todo** for the future is to add support for pretty printing JSON while serializing, which would allow you to generate more human-readable JSON output with indentation and line breaks.

## JSON custom hooks

Here an example of how to use a custom `parseHook` to parse JSON data into Nim types that are not natively supported by the default parser:
```nim
import std/times

import openparser/json
import semver

proc parseHook*(parser: var JsonParser, v: var Semver) =
  v = parseVersion(parser.curr.value)
  parser.walk() # move the parser forward after parsing the value

proc parseHook*(parser: var JsonParser, v: var Time) =
  v = parseTime(str, "yyyy-MM-dd'T'hh:mm:ss'.'ffffffz", local())
  parser.walk() # move the parser forward after parsing the value
```

To determine the field name being parsed in the `parseHook`, you can use the `currentField` property
available in the `JsonParser` object. This is a `Option[string]` that holds the name of the current field being parsed, if available:
```
if parser.currentField.isSome:
  let fieldName = parser.currentField.get()
  echo "Parsing field: ", fieldName
```

- Check the [unit tests](https://github.com/openpeeps/openparser/blob/main/tests/test1.nim) for JSON parsing and dumping with custom hooks.
- [JSON API Reference](https://openpeeps.github.io/openparser/openparser/json.html)

## CSV documents
OpenParser can parse large CSV files efficiently without loading the entire file into memory, making it ideal for processing big datasets.

For example, here will use a ~680MB CSV dataset from [Kaggle - TripAdvisor European restaurants](https://www.kaggle.com/datasets/stefanoleone992/tripadvisor-european-restaurants/data) that contains around 1 million rows and 42 columns.

```nim
import openparser/csv

var i = 0
let t = cpuTime()
parseFile("tripadvisor_european_restaurants.csv",
  proc(fields: openArray[CsvFieldSlice], row: int): bool =
    inc i
    for field in fields:
      discard # do something with the fields, e.g. print them
    true
)

let elapsed = cpuTime() - t

echo "Parsed ", i, " rows in ", elapsed, " seconds"
# ~0.783363 seconds on my machine
# memory usage should be minimal due to zero-copy parsing with memfiles
```

- Check the [unit tests](https://github.com/openpeeps/openparser/blob/main/tests/test2.nim) for CSV parsing.
- [CSV API Reference](https://openpeeps.github.io/openparser/openparser/csv.html)

## Parse YAML
Parse YAML documents into a `YamlNode` tree structure or directly into Nim data structures using custom hooks, similar to JSON parsing and dumping.

```
import openparser/yaml
let yamlData = """
name: Alice
age: 30
isMember: true
address:
  street: 123 Main St
  city: Anytown
  zip: 12345
friends:
  - Bob
  - Charlie
"""

let yamlNode: YamlNode = fromYaml(yamlData)
let yamlNode2: Person = fromYaml(yamlData, Person) # using custom hooks to parse directly into Nim data structures
```

- Check the [unit tests](https://github.com/openpeeps/openparser/blob/main/tests/test3.nim)
- [YAML API Reference](https://openpeeps.github.io/openparser/openparser/yaml.html)

## TOML Configs
Another **work-in-progress parser** and dumper module, this one provides support for working with TOML config files. It parses the TOML input into a `TomlNode` tree structure or directly into Nim data structures using custom hooks.

## SIMD-accelerated Regex engine
OpenParser includes a regex engine that provides support for regular expresion matching and searching, with SIMD acceleration for improved performance.
```nim
import openparser/regex
echo regex.match("hello world", "hello") # true
```

## BSON encoding and decoding
You can combine OpenParser's JSON parsing capabilities with BSON encoding and decoding to efficiently convert between JSON and BSON formats
```nim
import openparser/[json, bson]

# Convert JSON to BSON
let jsonData = """{"name":"Alice","age":30,"isMember":true}"""
let bsonDoc: seq[byte] = fromJson(jsonData).toBson()

# To convert BSON back to JSON
let jsonNode: JsonNode = fromBson(bsonDoc)
echo jsonNode["name"].getStr # Alice
```
- Check the [unit tests](https://github.com/openpeeps/openparser/blob/main/tests/test6.nim)
- [BSON API Reference](https://openpeeps.github.io/openparser/openparser/bson.html)

## Error Reporting
Most of the included parsers provide context-aware error reporting, including a snippet of the data around the error location, making it easier to identify and fix issues in the JSON input.

#### JSON error reporting example
```
{"name":"Alice","age":"isMember":true}
                                ^
Error (1:33) Unexpected token `:`
```

## Roadmap
- [ ] JSON depth/size limit to prevent DoS attacks
- [ ] JSON schema validation support
- [ ] JSON skippable fields
- [ ] JSON custom field mapping

> [!NOTE]
> Some implementations are made with the chatbot (dotenv, fbe, gettext) and may be buggy or incomplete, contributions are welcome to improve them!

### ❤ Contributions & Support
- 🐛 Found a bug? [Create a new Issue](https://github.com/openpeeps/openparser/issues)
- 👋 Wanna help? [Fork it!](https://github.com/openpeeps/openparser/fork)
- 😎 [Get €20 in cloud credits from Hetzner](https://hetzner.cloud/?ref=Hm0mYGM9NxZ4)

### 🎩 License
MIT license. [Made by Humans from OpenPeeps](https://github.com/openpeeps).<br>
Copyright OpenPeeps & Contributors &mdash; All rights reserved.
