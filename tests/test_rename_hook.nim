import unittest
import std/strutils
import ../src/openparser/json

type
  Tagged = ref object of RootObj
    tag: string
    name: string

proc renameHook*(v: Tagged, fieldName: var string) {.inline.} =
  ## Maps the JSON key `_tag` to the Nim field `tag` and back.
  if fieldName == "_tag":
    fieldName = "tag"
  elif fieldName == "tag":
    fieldName = "_tag"

suite "renameHook":
  test "parse JSON `_tag` into Nim `tag` field":
    let data = fromJson("""{"_tag":"hello","name":"world"}""", Tagged)
    check data.tag == "hello"
    check data.name == "world"

  test "dump Nim `tag` field as JSON `_tag`":
    let jsonStr = toJson(Tagged(tag: "hello", name: "world"))
    check jsonStr == """{"_tag":"hello","name":"world"}"""

  test "round-trip":
    let obj = fromJson(toJson(Tagged(tag: "x", name: "y")), Tagged)
    check obj.tag == "x"
    check obj.name == "y"

  test "unaffected fields keep their names":
    let jsonStr = toJson(Tagged(tag: "a", name: "b"))
    check jsonStr.contains("\"name\":\"b\"")
    check not jsonStr.contains("\"tag\":\"a\"")
