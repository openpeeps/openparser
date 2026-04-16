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
    case `type`: MemberType
    of mtAdmin:
      adminLevel: int
    else: discard
    name: string
    age: int
    address: Address
    friends: seq[Person]

suite "Deserializers":
  test "Direct-to-Object Parsing":
    let jsonStr = """{"type":"user","name":"Alice","age":30,"address":{"street":"123 Main St","city":"Anytown","zip":12345},"friends":[]}"""
    let person = fromJson(jsonStr, Person)
    check person.`type` == mtUser # default case
    check person.name == "Alice"
    check person.age == 30
    check person.address.street == "123 Main St"
    check person.address.city == "Anytown"
    check person.address.zip == 12345
    check person.friends.len == 0

  test "JSON to Tables":
    let jsonStr = """{"one":1,"two":2}"""
    var table = fromJson(jsonStr, OrderedTable[string, int])
    check table["one"] == 1
    check table["two"] == 2

  test "JSON to JsonNode":
    let jsonStr = """{"name":"Alice","age":30,"isMember":true,"address":{"street":"123 Main St","city":"Anytown","zip":12345},"friends":["Bob","Charlie"]}"""
    let data: JsonNode = fromJson(jsonStr)
    check data.kind == JObject
    check data["name"].getStr == "Alice"
    check data["age"].getInt == 30
    check data["isMember"].getBool == true
    check data["address"]["street"].getStr == "123 Main St"
    check data["address"]["city"].getStr == "Anytown"
    check data["address"]["zip"].getInt == 12345
    check data["friends"].kind == JArray
    check data["friends"][0].getStr == "Bob"
    check data["friends"][1].getStr == "Charlie"

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

  test "Zero-copy deserialization":
    let data: JsonNode = fromJsonFile("tests" / "data" / "example.json")
    check data.kind == JObject
    check data["id"].getStr == "2489651126"
    check data["actor"]["avatar_url"].getStr == "https://avatars.githubusercontent.com/u/10162972?"

  test "JSON scientific notation parsing":
    let jsonStr = """{"value":1.23e-4}"""
    let data: JsonNode = fromJson(jsonStr)
    check data["value"].getFloat == 1.23e-4

  test "JSON enum parsing with string values":
    let jsonStr = """{"type":"admin","adminLevel":5}"""
    let person = fromJson(jsonStr, Person)
    check person.`type` == mtAdmin
    check person.adminLevel == 5

suite "Serializers":
  test "Object serialization":
    let person = Person(name: "Albush", age: 40, address: Address(street: "456 Elm St", city: "Othertown", zip: 67890), friends: @[])
    check toStaticJson(person) == """{"type":"admin","adminLevel":0,"name":"Albush","age":40,"address":{"street":"456 Elm St","city":"Othertown","zip":67890},"friends":[]}"""

  test "Tables to JSON":
    var table: OrderedTable[string, int] = initOrderedTable[string, int]()
    table["one"] = 1
    table["two"] = 2
    let jsonTable = toJson(table)
    check jsonTable == """{"one":1,"two":2}"""
  
  test "JsonNode to JSON string":
    var data = newJObject()
    data["name"] = newJString("Alice")
    data["age"] = newJInt(30)
    data["isMember"] = newJBool(true)
    data["address"] = newJObject()
    data["address"]["street"] = newJString("123 Main St")
    data["address"]["city"] = newJString("Anytown")
    data["address"]["zip"] = newJInt(12345)
    data["friends"] = newJArray()
    data["friends"].add(newJString("Bob"))
    data["friends"].add(newJString("Charlie"))
    let jsonStr = toJson(data)
    check jsonStr == """{"name":"Alice","age":30,"isMember":true,"address":{"street":"123 Main St","city":"Anytown","zip":12345},"friends":["Bob","Charlie"]}"""

  test "Bad JSON parsing should raise an error":
    let badJsonStr = """{"name":"Alice","age":30,"isMember":true,"address": "street":"123 Main St","city":"Anytown","zip":12345},"friends":["Bob","Charlie"]}"""
    try:
      let data = fromJson(badJsonStr)
      check false # should not reach here
    except OpenParserJsonError as e: 
      echo e.msg
      check true # expected error