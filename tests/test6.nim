import std/[unittest, json, times, strutils, sequtils]
import ../src/openparser/bson

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
    let bson = toBson(obj)
    let decoded = fromBson(bson)
    check decoded == obj

  test "roundtrip array":
    let arr = %*[
      1, 2, 3, "abc", false, nil, %*{"z": 9}
    ]
    let bson = toBson(arr)
    let decoded = fromBson(bson)
    check decoded == arr

  test "large array":
    var arr = newJArray()
    for i in 0 ..< 10000:
      arr.add(%*{"i": i, "v": $i})
    let bson = toBson(arr)
    let decoded = fromBson(bson)
    check decoded == arr

  test "performance encode/decode":
    let big = %*{
      "ints": (0..9999).toSeq.mapIt(%it),
      "floats": (0..9999).toSeq.mapIt(%(it.float / 3)),
      "strings": (0..9999).toSeq.mapIt(%("str" & $it)),
      "bools": (0..9999).toSeq.mapIt(%(it mod 2 == 0))
    }
    let t0 = cpuTime()
    let bson = toBson(big)
    let t1 = cpuTime()
    let decoded = fromBson(bson)
    let t2 = cpuTime()
    check decoded == big
    echo "Encode time: ", formatFloat(t1-t0, ffDecimal, 4), "s"
    echo "Decode time: ", formatFloat(t2-t1, ffDecimal, 4), "s"
    echo "BSON size: ", bson.len, " bytes"