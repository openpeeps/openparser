## Tests for the TOML parser and serializer.

import std/[strutils, tables, times, sequtils]
import unittest
import ../src/openparser/toml

suite "toml":

  test "scalars, arrays, booleans":
    let doc = parseTOML("""
title = "demo"
port = 25
ratio = 1.5
enabled = true
tags = ["a", "b", "c"]
empty = []
""")
    check doc.get("title").getStr() == "demo"
    check doc.get("port").getInt() == 25
    check doc.get("ratio").getFloat() == 1.5
    check doc.get("enabled").getBool()
    check doc.get("tags").getArray().len == 3
    check doc.get("tags").getArray()[1].getStr() == "b"
    check doc.get("empty").getArray().len == 0

  test "dotted table headers":
    let doc = parseTOML("""
[smtp]
enabled = true
hostname = "meowmail.local"

[smtp.listen.port25]
enabled = true
host = "0.0.0.0"
port = 25

[smtp.auth.users]
"relay-user@example.com" = "change-me"
""")
    check doc.get("smtp.hostname").getStr() == "meowmail.local"
    check doc.get("smtp.listen.port25.port").getInt() == 25
    check doc.get("smtp.listen.port25.host").getStr() == "0.0.0.0"
    check doc.get("smtp.auth.users").getObject()["relay-user@example.com"].getStr() == "change-me"

  test "quoted keys with special characters":
    let doc = parseTOML("""
"a.b" = 1
'weird key' = "value"
""")
    check doc.get("a.b").getInt() == 1
    check doc.get("weird key").getStr() == "value"

  test "inline tables":
    let doc = parseTOML("""
point = { x = 1, y = 2 }
""")
    let obj = doc.get("point").getObject()
    check obj["x"].getInt() == 1
    check obj["y"].getInt() == 2

  test "array of tables":
    let doc = parseTOML("""
[[products]]
name = "Hammer"
sku = 1

[[products]]
name = "Nail"
sku = 2
""")
    let arr = doc.get("products").getArray()
    check arr.len == 2
    check arr[0].getObject()["name"].getStr() == "Hammer"
    check arr[1].getObject()["sku"].getInt() == 2

  test "dump round-trips":
    let doc = parseTOML("""
title = "demo"
port = 25
tags = ["a", "b"]

[smtp]
enabled = true

[smtp.auth.users]
"relay-user@example.com" = "change-me"

[[products]]
name = "Hammer"
""")
    let re = parseTOML(dumpTOML(doc))
    check re.get("title").getStr() == "demo"
    check re.get("port").getInt() == 25
    check re.get("tags").getArray().len == 2
    check re.get("smtp.enabled").getBool()
    check re.get("smtp.auth.users").getObject()["relay-user@example.com"].getStr() == "change-me"
    check re.get("products").getArray().len == 1

  test "comments are ignored":
    let doc = parseTOML("""
# leading comment
key = "value" # trailing comment
""")
    check doc.get("key").getStr() == "value"
