import unittest
import std/[json, base64, times, os, sequtils, strutils]
import openparser/plist as plist

suite "Plist XML decode to JsonNode":
  test "simple dict with all types":
    let xml = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Name</key><string>Alice &amp; Bob</string>
  <key>Age</key><integer>30</integer>
  <key>Hex</key><integer>0xFF</integer>
  <key>Neg</key><integer>-5</integer>
  <key>Height</key><real>1.75</real>
  <key>Inf</key><real>inf</real>
  <key>Ninf</key><real>-inf</real>
  <key>Nan</key><real>nan</real>
  <key>Alive</key><true/>
  <key>Dead</key><false/>
  <key>Data</key><data>SGVsbG8=</data>
  <key>Date</key><date>2020-01-02T03:04:05Z</date>
  <key>Arr</key><array><string>a</string><integer>1</integer></array>
  <key>EmptyArr</key><array/>
  <key>EmptyDict</key><dict/>
  <key>EmptyStr</key><string/>
</dict>
</plist>"""
    let node = plist.parseXmlPlist(xml)
    check node["Name"].getStr == "Alice & Bob"
    check node["Age"].getInt == 30
    check node["Hex"].getInt == 255
    check node["Neg"].getInt == -5
    check node["Height"].getFloat == 1.75
    check node["Inf"].getFloat == Inf
    check node["Ninf"].getFloat == NegInf
    check node["Nan"].getFloat != node["Nan"].getFloat # NaN
    check node["Alive"].getBool == true
    check node["Dead"].getBool == false
    check node["Data"].getStr == "SGVsbG8="
    check base64.decode(node["Data"].getStr) == "Hello"
    check node["Date"].getStr == "2020-01-02T03:04:05Z"
    check node["Arr"].len == 2
    check node["EmptyArr"].kind == JArray and node["EmptyArr"].len == 0
    check node["EmptyDict"].kind == JObject and node["EmptyDict"].len == 0
    check node["EmptyStr"].getStr == ""

  test "entity decoding and comments":
    let xml = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<!-- comment -->
<dict>
  <key>k</key><string>&lt;hello&gt; &quot;world&quot; &#x41; &#65;</string>
</dict>
</plist>"""
    let node = plist.parseXmlPlist(xml)
    check node["k"].getStr == "<hello> \"world\" A A"

  test "self-closing array/dict/string":
    let xml = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>a</key><array/>
  <key>d</key><dict/>
  <key>s</key><string/>
  <key>data</key><data/>
</dict>
</plist>"""
    let node = plist.parseXmlPlist(xml)
    check node["a"].kind == JArray
    check node["d"].kind == JObject
    check node["s"].getStr == ""
    check node["data"].getStr == ""


suite "Plist Binary decode to JsonNode":
  test "binary roundtrip via plist.toBPlist":
    let xml = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Name</key><string>Bob</string>
  <key>Age</key><integer>42</integer>
  <key>Flag</key><true/>
  <key>Arr</key><array><integer>1</integer><integer>2</integer></array>
  <key>Data</key><data>SGVsbG8=</data>
  <key>Date</key><date>2020-01-02T03:04:05Z</date>
</dict>
</plist>"""
    let node = plist.parseXmlPlist(xml)
    let bdata = plist.toBPlist(node)
    check bdata.len > 0
    check plist.detectPlistFormat(bdata) == pfBinary
    let node2 = plist.parseBPlist(bdata)
    check node == node2

  test "binary UID":
    let node = %* {"root": {"CF$UID": 5}, "value": 42}
    check plist.isPlistUIDObject(node["root"])
    let bdata = plist.toBPlist(node)
    let node2 = plist.parseBPlist(bdata)
    check plist.isPlistUIDObject(node2["root"])
    check int(plist.toPlistUID(node2["root"])) == 5

  test "binary detects format":
    let xmlStr = """<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>a</key><string>b</string></dict></plist>"""
    check plist.detectPlistFormat(xmlStr) == pfXml
    let bdata = plist.toBPlist(plist.parseXmlPlist(xmlStr))
    check plist.detectPlistFormat(bdata) == pfBinary
    check plist.detectPlistFormat(cast[seq[byte]](bdata)) == pfBinary


suite "Plist Typed decoding":
  type Person = object
    name {.plist: "Name".}: string
    age {.plist: "Age".}: int
    alive: bool

  test "plist pragma wire mapping":
    let xml = """<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>Name</key><string>Alice</string><key>Age</key><integer>30</integer><key>alive</key><true/></dict></plist>"""
    let p = plist.parseXmlPlist(xml, Person)
    check p.name == "Alice"
    check p.age == 30
    check p.alive == true

  type WithData = object
    payload: seq[byte]
    created: DateTime

  test "seq[byte] and DateTime via plist":
    let dt = parse("2020-01-02T03:04:05Z", "yyyy-MM-dd'T'HH:mm:ss'Z'", utc())
    let xml = """<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>payload</key><data>SGVsbG8=</data><key>created</key><date>2020-01-02T03:04:05Z</date></dict></plist>"""
    let o = plist.parseXmlPlist(xml, WithData)
    check cast[string](o.payload) == "Hello"
    check o.created == dt
    # binary
    let bdata = plist.toBPlist(plist.parseXmlPlist(xml))
    let o2 = plist.parseBPlist(bdata, WithData)
    check cast[string](o2.payload) == "Hello"
    check o2.created == dt

  type WithUID = object
    root: plist.PlistUID
    value: int

  test "plist.PlistUID typed":
    let node = %* {"root": {"CF$UID": 5}, "value": 42}
    let bdata = plist.toBPlist(node)
    let o = plist.parseBPlist(bdata, WithUID)
    check int(o.root) == 5
    check o.value == 42

  type JsonCompat = object
    fullName {.json: "Name".}: string
    Age: int

  test "json pragma compat":
    let xml = """<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>Name</key><string>Bob</string><key>Age</key><integer>25</integer></dict></plist>"""
    let o = plist.parseXmlPlist(xml, JsonCompat)
    check o.fullName == "Bob"
    check o.Age == 25


suite "Plist encoders":
  test "xml encoder emits data/date tags for typed":
    type Obj = object
      name: string
      payload: seq[byte]
      created: DateTime
    let dt = parse("2020-01-02T03:04:05Z", "yyyy-MM-dd'T'HH:mm:ss'Z'", utc())
    let o = Obj(name: "Alice", payload: cast[seq[byte]]("Hello"), created: dt)
    let xml = plist.toXmlPlist(o)
    check "<data>SGVsbG8=</data>" in xml
    check "<date>2020-01-02T03:04:05Z</date>" in xml
    let o2 = plist.parseXmlPlist(xml, Obj)
    check o2.name == "Alice"
    check cast[string](o2.payload) == "Hello"
    check o2.created == dt

  test "bplist encoder roundtrip typed":
    type Obj = object
      name: string
      payload: seq[byte]
      created: DateTime
    let dt = parse("2020-01-02T03:04:05Z", "yyyy-MM-dd'T'HH:mm:ss'Z'", utc())
    let o = Obj(name: "Alice", payload: cast[seq[byte]]("Hello"), created: dt)
    let bdata = plist.toBPlist(o)
    let o2 = plist.parseBPlist(bdata, Obj)
    check o2.name == "Alice"
    check cast[string](o2.payload) == "Hello"
    check o2.created == dt

  test "JsonNode xml/bplist roundtrip":
    let node = %* {"a": 1, "b": "hello", "c": true, "d": [1,2,3]}
    let xml = plist.toXmlPlist(node)
    let node2 = plist.parseXmlPlist(xml)
    check node == node2
    let bdata = plist.toBPlist(node)
    let node3 = plist.parseBPlist(bdata)
    check node == node3


suite "Plist autodetect and file helpers":
  test "plist.parsePlist autodetect":
    let xml = """<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>a</key><string>b</string></dict></plist>"""
    let node = plist.parseXmlPlist(xml)
    let bdata = plist.toBPlist(node)
    let n1 = plist.parsePlist(xml)
    let n2 = plist.parsePlist(bdata)
    check n1 == node
    check n2 == node
    check n1["a"].getStr == "b"

  test "file helpers":
    let xml = """<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>x</key><integer>5</integer></dict></plist>"""
    let path = getTempDir() / "test_plist_tmp.plist"
    writeFile(path, xml)
    let node = plist.parsePlistFile(path)
    check node["x"].getInt == 5
    let bpath = getTempDir() / "test_plist_tmp.bplist"
    writeFile(bpath, cast[string](plist.toBPlist(node)))
    let node2 = plist.parsePlistFile(bpath)
    check node2["x"].getInt == 5
    removeFile(path)
    removeFile(bpath)


suite "Plist NSKeyedArchiver":
  test "unarchive xml":
    let xml = """<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>$archiver</key><string>NSKeyedArchiver</string><key>$objects</key><array><string>$null</string><dict><key>name</key><string>Alice</string><key>age</key><integer>30</integer></dict><dict><key>CF$UID</key><integer>1</integer></dict></array><key>$top</key><dict><key>root</key><dict><key>CF$UID</key><integer>2</integer></dict></dict><key>$version</key><integer>100000</integer></dict></plist>"""
    let node = plist.parsePlist(xml)
    # should be unarchived automatically to {"name":"Alice","age":30}
    check node.hasKey("name")
    check node["name"].getStr == "Alice"
    check node["age"].getInt == 30

  test "unarchive disabled":
    let xml = """<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>$archiver</key><string>NSKeyedArchiver</string><key>$objects</key><array><string>$null</string><dict><key>name</key><string>Alice</string></dict></array><key>$top</key><dict><key>root</key><dict><key>CF$UID</key><integer>1</integer></dict></dict><key>$version</key><integer>100000</integer></dict></plist>"""
    var opts = plist.defaultPlistOptions()
    opts.unarchive = false
    let node = plist.parsePlist(xml, opts)
    check node.hasKey("$archiver")

  test "binary archiver via plist.toBPlist not needed":
    # create archiver JsonNode and ensure unarchive works for binary as well (via plist.parseBPlist)
    let arch = %* {"$archiver": "NSKeyedArchiver", "$objects": ["$null", {"name": "Bob"}], "$top": {"root": {"CF$UID": 1}}, "$version": 100000}
    let bdata = plist.toBPlist(arch)
    let node = plist.parseBPlist(bdata)
    # bplist archiver will be unarchived to {"name":"Bob"}
    check node["name"].getStr == "Bob"
