import unittest, os, tables
import ../src/openparser/json

type
  MemberType* = enum
    mtAdmin = "admin"
    mtUser = "user"
    mtGuest = "guest"

  Address = object
    street: string
    city: string
    zip: int

  Person = ref object
    `type`: MemberType
    name: string
    age: int
    address: Address
    friends: seq[Person]
    
suite "JSON Parser Tests":
  let jsonStr = """{"type":"user","name":"Alice","age":30,"address":{"street":"123 Main St","city":"Anytown","zip":12345},"friends":[]}"""
  test "Direct-to-Object Parsing":
    let person = fromJson(jsonStr, Person)
    check person.`type` == mtUser
    check person.name == "Alice"
    check person.age == 30
    check person.address.street == "123 Main St"
    check person.address.city == "Anytown"
    check person.address.zip == 12345
    check person.friends.len == 0
  
  test "Object serialization":
    let person = Person(name: "Albush", age: 40, address: Address(street: "456 Elm St", city: "Othertown", zip: 67890), friends: @[])
    check toStaticJson(person) == """{"type":"admin","name":"Albush","age":40,"address":{"street":"456 Elm St","city":"Othertown","zip":67890},"friends":[]}"""

  test "Tables to JSON":
    var table: OrderedTable[string, int] = initOrderedTable[string, int]()
    table["one"] = 1
    table["two"] = 2
    let jsonTable = toJson(table)
    check jsonTable == """{"one":1,"two":2}"""

  test "JSON to Tables":
    let jsonStr = """{"one":1,"two":2}"""
    var table = fromJson(jsonStr, OrderedTable[string, int])
    check table["one"] == 1
    check table["two"] == 2

  test "JSONL Parsing":
    let jsonLStr = """
{"name":"Alice","age":30}
{"name":"Bob","age":25}
{"name":"Charlie","age":35}"""
    let people: JsonNode = fromJsonL(jsonLStr)
    check people.len == 3
    check people.kind == JArray
    
    check people[0]["name"].getStr == "Alice"
    check people[0]["age"].getInt == 30

    check people[1]["name"].getStr == "Bob"
    check people[1]["age"].getInt == 25

    check people[2]["name"].getStr == "Charlie"
    check people[2]["age"].getInt == 35

  # todo use a ~25MB json file from
  # https://github.com/json-iterator/test-data/blob/master/large-file.json
  test "JSON File Parsing":
    let data: JsonNode = fromJsonFile("tests" / "data" / "example.json")
    check data.kind == JObject
    check data["id"].getStr == "2489651126"
    check data["actor"]["avatar_url"].getStr == "https://avatars.githubusercontent.com/u/10162972?"
    