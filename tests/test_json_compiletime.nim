import unittest, tables, std/options, std/strutils
import ../src/openparser/json

# ── Types for testing ────────────────────────────────────────────────────────

type
  Simple = object
    name: string
    age: int

  Nested = object
    street: string
    city: string
    zip: int

  Person = ref object
    name: string
    age: int
    address: Nested
    active: bool

  WithPragma = object
    username {.json: "username".}: string
    userAge {.json: "user_age".}: int
    email: string

  Kind = enum
    Admin, User, Guest

  Variant = object
    name: string
    case kind: Kind
    of Admin:
      level: int
    else:
      discard

  Empty = object
    discard

  Flat = object
    a: string
    b: int
    c: float
    d: bool
    e: string
    f: int
    g: string
    h: int

# ── Hash-based field dispatch (fromJson[T]) ──────────────────────────────────

suite "Compile-time hash dispatch":
  test "simple object":
    let s = """{"name":"Alice","age":30}"""
    let v = fromJson(s, Simple)
    check v.name == "Alice"
    check v.age == 30

  test "nested object":
    let s = """{"street":"123 Main","city":"Springfield","zip":62704}"""
    let v = fromJson(s, Nested)
    check v.street == "123 Main"
    check v.city == "Springfield"
    check v.zip == 62704

  test "ref object":
    let s = """{"name":"Bob","age":25,"address":{"street":"Oak","city":"Shelby","zip":12345},"active":true}"""
    let v = fromJson(s, Person)
    check v.name == "Bob"
    check v.age == 25
    check v.address.street == "Oak"
    check v.address.city == "Shelby"
    check v.address.zip == 12345
    check v.active == true

  test "ref object null":
    let s = "null"
    let v = fromJson(s, Person)
    check v.isNil

  test "object with many fields":
    let s = """{"a":"1","b":2,"c":3.14,"d":true,"e":"5","f":6,"g":"7","h":8}"""
    let v = fromJson(s, Flat)
    check v.a == "1"
    check v.b == 2
    check v.c == 3.14
    check v.d == true
    check v.e == "5"
    check v.f == 6
    check v.g == "7"
    check v.h == 8

  test "unknown fields are skipped":
    let s = """{"name":"X","age":10,"extra":"skip","nested":{"a":1}}"""
    let v = fromJson(s, Simple)
    check v.name == "X"
    check v.age == 10

  test "empty object":
    let s = """{}"""
    let v = fromJson(s, Empty)
    discard v # just verify it compiles and runs

# ── {json: wireName} pragma for parsing ──────────────────────────────────────

suite "Pragma wire name parsing":
  test "parse with pragma mapping":
    let s = """{"username":"Dave","user_age":40,"email":"dave@test.com"}"""
    let v = fromJson(s, WithPragma)
    check v.username == "Dave"
    check v.userAge == 40
    check v.email == "dave@test.com"

  test "round-trip with pragma":
    let orig = WithPragma(username: "Eve", userAge: 28, email: "eve@test.com")
    let s = toStaticJson(orig)
    let v = fromJson(s, WithPragma)
    check v.username == "Eve"
    check v.userAge == 28
    check v.email == "eve@test.com"

# ── renameHook with hash dispatch ───────────────────────────────────────────

type
  Tagged = ref object
    tag: string
    name: string

proc renameHook*(v: Tagged, fieldName: var string) {.inline.} =
  if fieldName == "_tag":
    fieldName = "tag"
  elif fieldName == "tag":
    fieldName = "_tag"

suite "renameHook with hash dispatch":
  test "parse with renameHook":
    let s = """{"_tag":"hello","name":"world"}"""
    let v = fromJson(s, Tagged)
    check v.tag == "hello"
    check v.name == "world"

  test "round-trip with renameHook":
    let obj = fromJson("""{"_tag":"x","name":"y"}""", Tagged)
    let s = toJson(obj)
    check s.contains("\"_tag\":\"x\"")
    check s.contains("\"name\":\"y\"")

# ── Variant objects ──────────────────────────────────────────────────────────

suite "Variant object parsing":
  test "parse variant with discriminator":
    let s = """{"name":"Admin User","kind":"Admin","level":5}"""
    let v = fromJson(s, Variant)
    check v.name == "Admin User"
    check v.kind == Admin
    check v.level == 5

  test "parse variant non-admin":
    let s = """{"name":"Regular","kind":"User"}"""
    let v = fromJson(s, Variant)
    check v.name == "Regular"
    check v.kind == User

# ── toJsonNode[T] direct conversion ──────────────────────────────────────────

suite "toJsonNode direct conversion":
  test "object to JsonNode":
    let s = """{"name":"Alice","age":30}"""
    let v = fromJson(s, Simple)
    let node = toJsonNode(v)
    check node.kind == JObject
    check node["name"].getStr == "Alice"
    check node["age"].getInt == 30

  test "ref object to JsonNode":
    let s = """{"name":"Bob","age":25,"address":{"street":"Oak","city":"Shelby","zip":12345},"active":true}"""
    let v = fromJson(s, Person)
    let node = toJsonNode(v)
    check node.kind == JObject
    check node["name"].getStr == "Bob"
    check node["age"].getInt == 25
    check node["address"]["street"].getStr == "Oak"
    check node["active"].getBool == true

  test "nil ref to JsonNode":
    let v: Person = nil
    let node = toJsonNode(v)
    check node.kind == JNull

  test "JsonNode passthrough":
    let s = """{"key":"value"}"""
    let v = fromJson(s)
    let node = toJsonNode(v)
    check node.kind == JObject
    check node["key"].getStr == "value"

  test "object with pragma to JsonNode":
    let orig = WithPragma(username: "X", userAge: 10, email: "x@x.com")
    let node = toJsonNode(orig)
    check node.kind == JObject
    check node["username"].getStr == "X"
    check node["user_age"].getInt == 10
    check node["email"].getStr == "x@x.com"
