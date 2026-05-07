import std/[unittest, json, times, strutils, sequtils, os]
import ../src/openparser/bson

proc writeInt32LeAt(buf: var seq[byte], pos: int, v: int32) =
  let u = cast[uint32](v)
  buf[pos + 0] = byte(u and 0xff'u32)
  buf[pos + 1] = byte((u shr 8) and 0xff'u32)
  buf[pos + 2] = byte((u shr 16) and 0xff'u32)
  buf[pos + 3] = byte((u shr 24) and 0xff'u32)

suite "BSON encode/decode":

  test "roundtrip object":
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
    let raw = toBson(obj)
    let decoded = fromBson(raw)
    check decoded == obj

  test "roundtrip array":
    let arr = %*[
      1, 2, 3, "abc", false, nil, %*{"z": 9}
    ]
    let raw = toBson(arr)
    let decoded = fromBson(raw)
    check decoded == arr

  test "large array":
    var arr = newJArray()
    for i in 0 ..< 10000:
      arr.add(%*{"i": i, "v": $i})
    let raw = toBson(arr)
    let decoded = fromBson(raw)
    check decoded == arr

  test "BSONDocument roundtrip bytes with version":
    let obj = %*{"k": "v", "n": 7}
    let doc = newBSONDocument(obj, version = 3'i32)
    let blob = toBytes(doc)
    let parsed = fromBytes(blob)

    check parsed.version == 3'i32
    check toJsonNode(parsed) == obj

  test "BSONDocument file IO":
    let obj = %*{"name": "openpeeps", "ok": true}
    let doc = newBSONDocument(obj, version = 2'i32)

    let path = "tests" / "data" / ("openparser_bson_" & $epochTime().int64 & ".bdoc")

    writeBSONDocument(path, doc)
    check fileExists(path)

    let loaded = openBSONDocument(path)
    check loaded.version == 2'i32
    check toJsonNode(loaded) == obj

  test "invalid BSONDocument version rejected":
    let obj = %*{"x": 1}
    expect ValueError:
      discard newBSONDocument(obj, version = 0'i32)

  test "fromBytes rejects bad magic":
    let doc = newBSONDocument(%*{"x": 1}, version = 1'i32)
    var blob = toBytes(doc)
    blob[0] = byte(ord('X')) # corrupt magic
    expect ValueError:
      discard fromBytes(blob)

  test "fromBytes rejects truncated blob":
    let doc = newBSONDocument(%*{"x": 1}, version = 1'i32)
    let blob = toBytes(doc)
    let truncated = blob[0 ..< blob.len - 1]
    expect ValueError:
      discard fromBytes(truncated)

  test "fromBytes rejects bad payload length":
    let doc = newBSONDocument(%*{"x": 1}, version = 1'i32)
    var blob = toBytes(doc)
    let lenPos = BSONDocMagic.len + 4 # after version field
    writeInt32LeAt(blob, lenPos, 1'i32) # wrong declared payload size
    expect ValueError:
      discard fromBytes(blob)

  test "openBSONDocument rejects missing file":
    let path = "tests" / "data" / ("missing_" & $epochTime().int64 & ".bdoc")
    expect ValueError:
      discard openBSONDocument(path)

  test "performance encode/decode":
    let big = %*{
      "ints": (0..9999).toSeq.mapIt(%it),
      "floats": (0..9999).toSeq.mapIt(%(it.float / 3)),
      "strings": (0..9999).toSeq.mapIt(%("str" & $it)),
      "bools": (0..9999).toSeq.mapIt(%(it mod 2 == 0))
    }
    let t0 = cpuTime()
    let raw = toBson(big)
    let t1 = cpuTime()
    let decoded = fromBson(raw)
    let t2 = cpuTime()

    check decoded == big
    echo "Encode time: ", formatFloat(t1 - t0, ffDecimal, 4), "s"
    echo "Decode time: ", formatFloat(t2 - t1, ffDecimal, 4), "s"
    echo "BSON size: ", raw.len, " bytes"