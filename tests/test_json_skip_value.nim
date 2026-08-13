## Tests for `skipValue`: parsing JSON into typed objects that only declare a
## subset of the fields, with in-depth coverage of complex, deeply-nested
## structures such as Chrome DevTools Protocol DOM trees.
##
## Previously `skipValue` mis-positioned the parser when skipping an unknown
## value that itself contained nested arrays/objects, causing errors like
## `Got `{`, expected <string>`.

import unittest
import std/options
import ../src/openparser/json

# ── Types mirroring chopchop's CDP getDocument shape ────────────────────────

type
  DomNode = object
    nodeId: int
    backendNodeId: int
    nodeType: int
    nodeName: string
    localName: string
    nodeValue: string
    childNodeCount: int
    # fields that appear AFTER the deeply-nested `children` array in the wire
    # payload, so a successful parse proves skipping resumed correctly
    documentURL: string
    baseURL: string

  GetDocumentResult = object
    root: DomNode

  CdpEnvelope = object
    id: int
    result: GetDocumentResult

# A realistic CDP `DOM.getDocument` response. The `children` arrays (objects
# with their own nested `children`/`attributes` arrays) are NOT part of the
# typed shapes above and must be skipped by `skipValue`.
const domTree = """{
  "id": 7,
  "result": {
    "root": {
      "nodeId": 1, "backendNodeId": 2, "nodeType": 9, "nodeName": "#document",
      "localName": "", "nodeValue": "", "childNodeCount": 2,
      "children": [
        { "nodeId": 2, "parentId": 1, "backendNodeId": 3, "nodeType": 10,
          "nodeName": "html", "localName": "", "nodeValue": "",
          "publicId": "", "systemId": "" },
        { "nodeId": 3, "parentId": 1, "backendNodeId": 4, "nodeType": 1,
          "nodeName": "HTML", "localName": "html", "nodeValue": "",
          "childNodeCount": 2, "attributes": ["lang", "en"],
          "children": [
            { "nodeId": 4, "parentId": 3, "backendNodeId": 5, "nodeType": 1,
              "nodeName": "HEAD", "localName": "head", "nodeValue": "",
              "childNodeCount": 4, "attributes": [] },
            { "nodeId": 5, "parentId": 3, "backendNodeId": 6, "nodeType": 1,
              "nodeName": "BODY", "localName": "body", "nodeValue": "",
              "childNodeCount": 1,
              "children": [
                { "nodeId": 6, "parentId": 5, "backendNodeId": 7, "nodeType": 1,
                  "nodeName": "P", "localName": "p", "nodeValue": "",
                  "childNodeCount": 1, "attributes": [],
                  "children": [
                    { "nodeId": 7, "parentId": 6, "backendNodeId": 8, "nodeType": 3,
                      "nodeName": "#text", "localName": "", "nodeValue": "hello",
                      "childNodeCount": 0 }
                  ] }
              ] }
          ] }
      ],
      "documentURL": "https://example.com/",
      "baseURL": "https://example.com/",
      "xmlVersion": "",
      "compatibilityMode": "NoQuirksMode"
    }
  },
  "sessionId": "8E7A376CA12175F252A52F2D0C222860"
}"""

suite "skipValue on complex DOM tree":
  test "parse document root, skipping deeply-nested children":
    let jsn = fromJson(domTree)
    let res = fromJson($jsn["result"], GetDocumentResult)
    check res.root.nodeId == 1
    check res.root.backendNodeId == 2
    check res.root.nodeType == 9
    check res.root.nodeName == "#document"
    check res.root.childNodeCount == 2
    # fields following the skipped `children` array are parsed correctly,
    # proving the parser was left on the right token after skipping
    check res.root.documentURL == "https://example.com/"
    check res.root.baseURL == "https://example.com/"

  test "parse the full CDP envelope into a typed object":
    let res = fromJson(domTree, CdpEnvelope)
    check res.id == 7
    check res.result.root.nodeId == 1
    check res.result.root.documentURL == "https://example.com/"

  test "array of nodes, each with its own nested unknown fields":
    let payload = """{
      "nodes": [
        { "nodeId": 1, "attributes": ["id", "a"], "children": [{"nodeId": 10}] },
        { "nodeId": 2, "attributes": [], "children": [{"nodeId": 20}, {"nodeId": 21}] },
        { "nodeId": 3 }
      ]
    }"""
    type Nodes = object
      nodes: seq[DomNode]
    let res = fromJson(payload, Nodes)
    check res.nodes.len == 3
    check res.nodes[0].nodeId == 1
    check res.nodes[1].nodeId == 2
    check res.nodes[2].nodeId == 3

suite "skipValue on nested structures":
  test "object nested in object":
    let payload = """{"keep":"a","obj":{"x":1,"inner":{"y":2,"z":3}},"after":"b"}"""
    type O = object
      keep: string
      after: string
    let res = fromJson(payload, O)
    check res.keep == "a"
    check res.after == "b"

  test "array of objects":
    let payload = """{"keep":"a","arr":[{"n":1},{"n":2},{"n":3}],"after":"b"}"""
    type O = object
      keep: string
      after: string
    let res = fromJson(payload, O)
    check res.keep == "a"
    check res.after == "b"

  test "array of arrays":
    let payload = """{"keep":"a","arr":[[1,2],[3,4],[[5]]],"after":"b"}"""
    type O = object
      keep: string
      after: string
    let res = fromJson(payload, O)
    check res.keep == "a"
    check res.after == "b"

  test "empty object and empty array as unknown fields":
    let payload = """{"keep":"a","obj":{},"arr":[],"after":"b"}"""
    type O = object
      keep: string
      after: string
    let res = fromJson(payload, O)
    check res.keep == "a"
    check res.after == "b"

  test "deeply nested structure (10 levels)":
    var payload = """{"keep":"a","v":"""
    for i in 0 ..< 10:
      payload.add("""{"l":[""")
    payload.add("42")
    for i in 0 ..< 10:
      payload.add("""]}""")
    payload.add(""","after":"b"}""")
    type O = object
      keep: string
      after: string
    let res = fromJson(payload, O)
    check res.keep == "a"
    check res.after == "b"

  test "mixed scalar values in unknown fields":
    let payload = """{
      "keep": "a",
      "u1": null,
      "u2": true,
      "u3": false,
      "u4": 0,
      "u5": -17,
      "u6": 3.14,
      "u7": 1.0e10,
      "u8": -2.5e-3,
      "u9": "",
      "u10": "héllo wörld 😀",
      "u11": "escaped \" quote",
      "after": "b"
    }"""
    type O = object
      keep: string
      after: string
    let res = fromJson(payload, O)
    check res.keep == "a"
    check res.after == "b"

  test "unicode and special characters in unknown keys":
    let payload = """{"keep":"a","ключ":"значение","键":"值","a b":"c","a\"b":"d","after":"b"}"""
    type O = object
      keep: string
      after: string
    let res = fromJson(payload, O)
    check res.keep == "a"
    check res.after == "b"

suite "skipValue preserves surrounding parsing":
  test "known field before and after every value type":
    let payload = """{
      "before": "x",
      "obj": {"a": {"b": [1, 2, {"c": [{"d": null}, "e"]}]}},
      "after": "y"
    }"""
    type O = object
      before: string
      after: string
    let res = fromJson(payload, O)
    check res.before == "x"
    check res.after == "y"

  test "skipValue is used for each unknown field, not just the first":
    let payload = """{"a":1,"x":{"n":1},"b":2,"y":[{"n":2}],"c":3,"z":[[1]]}"""
    type O = object
      a: int
      b: int
      c: int
    let res = fromJson(payload, O)
    check res.a == 1
    check res.b == 2
    check res.c == 3

  test "toJson / round-trip is unaffected":
    type Simple = object
      name: string
      count: int
    let obj = Simple(name: "x", count: 3)
    let jsonStr = toJson(obj)
    check jsonStr == """{"name":"x","count":3}"""
    let back = fromJson(jsonStr, Simple)
    check back.name == "x"
    check back.count == 3
