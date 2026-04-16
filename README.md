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
OpenParser is a collection of parsers and dumpers (serializers) for various data formats, written in Nim language. It provides a simple and efficient way to parse and dump data in different formats, such as JSON, CSV, and more.

## 😍 Key Features

- **JSON**
  - Zero-copy deserialization (via memfiles) for high performance and low memory usage
  - Direct-to-object parsing and serialization
  - Support for other Nim types (Similar to pkg/jsony)
  - Scientific notation support for numbers
- **CSV**
  - Zero-copy parsing for large files (via memfiles)
- **RSS & Atom**
  - Reader and writer for RSS and Atom feeds

>[!NOTE]
> Importing `openparser` directly will produce a compile-time error, you need to import the specific module for the data format you want to use, e.g. `openparser/json` for JSON parsing and dumping or `openparser/csv` for CSV parsing.

### Parse JSON

OpenParser provide a simple and efficient module for parsing JSON data using the zero-copy parsing approach, which allows you to parse JSOn data without copying it into memory, making it faster and more memory-efficient.

>[!NOTE]
>OpenParser's JSON parser is exporting the `std/json` module by default.

#### `fromJson` string into JsonNode

Here a simple example taking a stringified JSON and parsing it into a `JsonNode` tree structure:
```nim
import openparser/json

let data = """{"name":"Albush","age":40,"address":{"street":"456 Elm St","city":"Othertown","zip":67890},"friends":[]}"""

let jsonNode: JsonNode = fromJson(data)
echo jsonNode["name"].getStr # Albush
echo jsonNode["age"].getInt # 40
```

#### `fromJsonFile into JsonNode with memfiles
`fromJsonFile` function allows you to parse JSON data directly from a file using memfiles, which is a memory-mapped file that allows for zero-copy parsing:

```nim
let data = fromJsonFile("example.json")
echo data.kind # JsonNode object
```

#### `fromJson` string into Nim data structures
OpenParser also supports parsing JSON strings directly into Nim data structures (objects, sequences, etc.) similar to the `pkg/jsony` library, which allows you to easily convert JSON data into Nim objects without having to manually traverse the JSON tree.

#### `fromJSONL` for JSON Lines
OpenParser also supports parsing JSON Lines (JSONL) format, which is a convenient format for storing and processing large datasets where each line is a separate JSON object. You can use the `fromJSONL` function to parse JSONL data into a sequence of `JsonNode` objects or directly.

Use `fromJsonLFile` to parse JSONL data from a file using memfiles for efficient parsing of large files or `fromJsonL` to parse JSONL data from a string. The API is similar to `fromJson` and `fromJsonFile`, but it returns a sequence of `JsonNode` objects, one for each line in the JSONL input:

```nim
import openparser/json

let peeps: JsonNode = fromJsonL("peeps.json")
assert peeps.kind == JArray
```

#### `toJson` anything into a JSON string
OpenParser also provides a `toJson` function that allows you to serialize Nim data structures (objects, sequences, etc.) into JSON strings. This function can handle a wide range of Nim types, including custom types with the help of `dumpHook` procedures.

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
  "friends": ["Bob", "Charlie"]
}

# serialize the data into a minified JSON string
echo toJson(data) # {"name":"Alice"}
```

#### `toJson` pretty-printing
A todo for the future is to add support for pretty printing JSON while serializing, which would allow you to generate more human-readable JSON output with indentation and line breaks.

#### JSON custom hooks

Here an example of how to use a custom `parseHook` to parse JSON data into Nim types that are not natively supported by the default parser:
```nim
import std/times

import openparser/json
import semver

proc parseHook*(parser: var JsonParser, field: string, v: var Semver) =
  v = parseVersion(parser.curr.value)
  parser.walk() # move the parser forward after parsing the value

proc parseHook*(parser: var JsonParser, field: string, v: var Time) =
  v = parseTime(str, "yyyy-MM-dd'T'hh:mm:ss'.'ffffffz", local())
  parser.walk() # move the parser forward after parsing the value
```

A `dumpHook` is necessary to serialize custom Nim types back into JSON strings:
```nim
import openparser/json
import std/times

proc dumpHook*(s: var string, v: Time) =
  s.add('"')
  s.add(v.format("yyyy-MM-dd'T'hh:mm:ss'.'ffffffz", local()))
  s.add('"')
```

#### JSON error reporting
OpenParser's JSON parser is context-aware and provides detailed error reporting including a snippet of the JSON data around the error location, making it easier to identify and fix issues in the JSON input, for example:
```

```

### Direct-to-object JSON parsing
Inspired by other libraries like [pkg/jsony](https://github.com/treeform/jsony), OpenParser JSON module also supports direct-to-object parsing, which allows you to parse JSON strings directly into Nim data structures (objects, sequences, etc.) without having to manually traverse the JSON tree.

Here, a basic example of how to use direct-to-object JSON parsing with OpenParser:
```nim
import openparser/json

type
  Address = object
    street: string
    city: string
    zip: int

  Person = object
    name: string
    age: int
    address: Address
    friends: seq[Person]

let data = """{"name":"Alice","age":30,"address":{"street":"123 Main St","city":"Anytown","zip":12345},"friends":[]}"""

let person: Person = fromJson(data, Person)
echo person.name # Alice
echo person.age # 30
echo person.address.street # 123 Main St
```


### Parse large CSV files
OpenParser can parse large CSV files efficiently without loading the entire file into memory, making it ideal for processing big datasets.

For example, here will use a ~680MB CSV dataset from [Kaggle - TripAdvisor European restaurants](https://www.kaggle.com/datasets/stefanoleone992/tripadvisor-european-restaurants/data) that contains around 1 million rows and 42 columns.

```nim
import openparser/csv

var i = 0
parseFile("tripadvisor_european_restaurants.csv",
  proc(fields: openArray[CsvFieldSlice], row: int): bool =
    # this callback will be called for each row in the CSV file
    for _ in fields:
      inc(i)
      discard # do something with the fields, e.g. print them
    true # return true to continue parsing, false to stop
echo "Total rows: ", i - 1 # subtract 1 for the header row

let t = cpuTime()
parseFile("tripadvisor_european_restaurants.csv",
  proc(fields: openArray[CsvFieldSlice], row: int): bool =
    inc i
    true
)
let elapsed = cpuTime() - t
echo "Parsed ", i, " rows in ", elapsed, " seconds" # ~0.783363 seconds on my machine
```

### ❤ Contributions & Support
- 🐛 Found a bug? [Create a new Issue](https://github.com/openpeeps/openparser/issues)
- 👋 Wanna help? [Fork it!](https://github.com/openpeeps/openparser/fork)
- 😎 [Get €20 in cloud credits from Hetzner](https://hetzner.cloud/?ref=Hm0mYGM9NxZ4)

### 🎩 License
MIT license. [Made by Humans from OpenPeeps](https://github.com/openpeeps).<br>
Copyright OpenPeeps & Contributors &mdash; All rights reserved.
