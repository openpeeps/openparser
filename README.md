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
- JSON parsing and dumping
- - Direct-to-object JSON parsing
- - JSON-L (JSON Lines) parsing
- - Zero-copy parsing for large JSON datasets
- CSV parsing and dumping
- - Memory-efficient zero-copy parsing for large CSV datasets
- RSS/Atom feed parsing

### Parse JSON

OpenParser provide a simple and efficient module for parsing JSON data using the zero-copy parsing approach, which allows you to parse JSOn data without copying it into memory, making it faster and more memory-efficient.

```nim
import openparser/json

let data = """{"name":"Albush","age":40,"address":{"street":"456 Elm St","city":"Othertown","zip":67890},"friends":[]}"""

let jsonNode: JsonNode = fromJson(data)
echo jsonNode["name"].getStr # Albush
echo jsonNode["age"].getInt # 40
```

### Direct-to-object JSON parsing
Inspired by other libraries like jsony, OpenParser JSON module also supports direct-to-object parsing, which allows you to parse JSON strings directly into Nim data structures (objects, sequences, etc.) without having to manually traverse the JSON tree.

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

let person: Person = fromJson(data)
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
```


### ❤ Contributions & Support
- 🐛 Found a bug? [Create a new Issue](https://github.com/openpeeps/openparser/issues)
- 👋 Wanna help? [Fork it!](https://github.com/openpeeps/openparser/fork)
- 😎 [Get €20 in cloud credits from Hetzner](https://hetzner.cloud/?ref=Hm0mYGM9NxZ4)

### 🎩 License
MIT license. [Made by Humans from OpenPeeps](https://github.com/openpeeps).<br>
Copyright OpenPeeps & Contributors &mdash; All rights reserved.
