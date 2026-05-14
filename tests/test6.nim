import std/[unittest, json, times, strutils, sequtils, os, base64]
import ../src/openparser/bson

proc writeInt32LeAt(buf: var seq[byte], pos: int, v: int32) =
  let u = cast[uint32](v)
  buf[pos + 0] = byte(u and 0xff'u32)
  buf[pos + 1] = byte((u shr 8) and 0xff'u32)
  buf[pos + 2] = byte((u shr 16) and 0xff'u32)
  buf[pos + 3] = byte((u shr 24) and 0xff'u32)

suite "BSON 1.1 encode/decode":

  test "roundtrip object – primitive types":
    let obj = %*{
      "a": 123,
      "b": 3.14,
      "c": "hello",
      "d": true,
      "e": false,
      "f": %*{"x": 1, "y": 2},
      "g": %*["foo", "bar", 42],
      "h": nil
    }
    check fromBson(toBson(obj)) == obj

  test "roundtrip array":
    let arr = %*[1, 2, 3, "abc", false, nil, %*{"z": 9}]
    check fromBson(toBson(arr)) == arr

  test "empty string roundtrip":
    let obj = %*{"empty": ""}
    check fromBson(toBson(obj)) == obj

  test "int32 boundary values":
    let obj = %*{
      "min32": int32.low.int,
      "max32": int32.high.int,
      "min64": int64.low.int,
      "max64": int64.high.int
    }
    check fromBson(toBson(obj)) == obj

  test "large array":
    var arr = newJArray()
    for i in 0 ..< 10_000:
      arr.add(%*{"i": i, "v": $i})
    check fromBson(toBson(arr)) == arr

  # ── BSON type 0x05 – Binary ──────────────────────────────────────────────

  test "binary roundtrip – generic subtype 00":
    let raw  = "hello binary\x00\x01\x02"
    let b64  = base64.encode(raw)
    let obj  = %*{"bin": {"$binary": {"base64": b64, "subType": "00"}}}
    let rt   = fromBson(toBson(obj))
    check rt["bin"]["$binary"]["base64"].getStr == b64
    check rt["bin"]["$binary"]["subType"].getStr == "00"

  test "binary roundtrip – user-defined subtype 80":
    let raw  = "\xff\xfe\xfd"
    let b64  = base64.encode(raw)
    let obj  = %*{"d": {"$binary": {"base64": b64, "subType": "80"}}}
    let rt   = fromBson(toBson(obj))
    check rt["d"]["$binary"]["subType"].getStr == "80"
    check rt["d"]["$binary"]["base64"].getStr == b64

  test "binary empty payload":
    let obj = %*{"empty": {"$binary": {"base64": "", "subType": "00"}}}
    let rt  = fromBson(toBson(obj))
    check rt["empty"]["$binary"]["base64"].getStr == ""

  # ── BSON type 0x07 – ObjectId ────────────────────────────────────────────

  test "ObjectId roundtrip":
    let oid = "507f1f77bcf86cd799439011"
    let obj = %*{"id": {"$oid": oid}}
    check fromBson(toBson(obj)) == obj

  test "ObjectId invalid length rejected":
    let obj = %*{"id": {"$oid": "tooshort"}}
    expect ValueError:
      discard toBson(obj)

  # ── BSON type 0x09 – UTC datetime ────────────────────────────────────────

  test "UTC datetime roundtrip – integer":
    let ms  = 1_700_000_000_000'i64
    let obj = %*{"ts": {"$date": ms}}
    let rt  = fromBson(toBson(obj))
    check rt["ts"]["$date"].getBiggestInt == ms

  test "UTC datetime roundtrip – $numberLong string":
    let obj = %*{"ts": {"$date": {"$numberLong": "1700000000000"}}}
    let rt  = fromBson(toBson(obj))
    check rt["ts"]["$date"].getBiggestInt == 1_700_000_000_000'i64

  # ── BSON type 0x0B – Regex ───────────────────────────────────────────────

  test "regex roundtrip":
    let obj = %*{"re": {"$regularExpression": {"pattern": "^foo.*", "options": "im"}}}
    check fromBson(toBson(obj)) == obj

  test "regex empty options roundtrip":
    let obj = %*{"re": {"$regularExpression": {"pattern": "bar", "options": ""}}}
    check fromBson(toBson(obj)) == obj

  # ── BSON type 0x0D – JavaScript code ────────────────────────────────────

  test "JS code roundtrip":
    let obj = %*{"fn": {"$code": "function() { return 42; }"}}
    check fromBson(toBson(obj)) == obj

  # ── BSON type 0x11 – Timestamp ──────────────────────────────────────────

  test "timestamp roundtrip":
    let obj = %*{"ts": {"$timestamp": {"t": 1_700_000_000, "i": 7}}}
    let rt  = fromBson(toBson(obj))
    check rt["ts"]["$timestamp"]["t"].getInt == 1_700_000_000
    check rt["ts"]["$timestamp"]["i"].getInt == 7

  test "timestamp zero values":
    let obj = %*{"ts": {"$timestamp": {"t": 0, "i": 0}}}
    check fromBson(toBson(obj)) == obj

  # ── BSON type 0xFF / 0x7F – Min / Max key ───────────────────────────────

  test "MinKey roundtrip":
    let obj = %*{"mk": {"$minKey": 1}}
    check fromBson(toBson(obj)) == obj

  test "MaxKey roundtrip":
    let obj = %*{"mk": {"$maxKey": 1}}
    check fromBson(toBson(obj)) == obj

  # ── BSONDocument wrapper ─────────────────────────────────────────────────

  test "BSONDocument roundtrip bytes with version":
    let obj    = %*{"k": "v", "n": 7}
    let doc    = newBSONDocument(obj, version = 3'i32)
    let blob   = toBytes(doc)
    let parsed = fromBytes(blob)
    check parsed.version == 3'i32
    check toJsonNode(parsed) == obj

  test "BSONDocument file IO":
    let obj  = %*{"name": "openpeeps", "ok": true}
    let doc  = newBSONDocument(obj, version = 2'i32)
    let path = "tests" / "data" / ("openparser_bson_" & $epochTime().int64 & ".bson")
    writeBSONDocument(path, doc)
    check fileExists(path)
    let loaded = openBSONDocument(path)
    check loaded.version == 2'i32
    check toJsonNode(loaded) == obj

  test "invalid BSONDocument version rejected":
    expect ValueError:
      discard newBSONDocument(%*{"x": 1}, version = 0'i32)

  test "fromBytes rejects bad magic":
    var blob = toBytes(newBSONDocument(%*{"x": 1}, version = 1'i32))
    blob[0] = byte(ord('X'))
    expect ValueError:
      discard fromBytes(blob)

  test "fromBytes rejects truncated blob":
    let blob = toBytes(newBSONDocument(%*{"x": 1}, version = 1'i32))
    expect ValueError:
      discard fromBytes(blob[0 ..< blob.len - 1])

  test "fromBytes rejects bad payload length":
    var blob = toBytes(newBSONDocument(%*{"x": 1}, version = 1'i32))
    writeInt32LeAt(blob, BSONDocMagic.len + 4, 1'i32)
    expect ValueError:
      discard fromBytes(blob)

  test "openBSONDocument rejects missing file":
    expect ValueError:
      discard openBSONDocument("tests" / "data" / ("missing_" & $epochTime().int64 & ".bdoc"))

  # ── Performance ──────────────────────────────────────────────────────────

  test "performance encode/decode":
    let big = %*{
      "ints":    (0..9999).toSeq.mapIt(%it),
      "floats":  (0..9999).toSeq.mapIt(%(it.float / 3)),
      "strings": (0..9999).toSeq.mapIt(%("str" & $it)),
      "bools":   (0..9999).toSeq.mapIt(%(it mod 2 == 0))
    }
    let t0 = cpuTime()
    let raw = toBson(big)
    let t1 = cpuTime()
    let decoded = fromBson(raw)
    let t2 = cpuTime()
    check decoded == big
    echo "Encode: ", formatFloat(t1 - t0, ffDecimal, 4), "s  Decode: ",
         formatFloat(t2 - t1, ffDecimal, 4), "s  Size: ", raw.len, " bytes"