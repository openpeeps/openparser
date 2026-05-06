# A collection of tiny parsers and dumpers
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/openparser

## This module provides functions to encode and decode BSON (Binary JSON) data. It supports a
## subset of BSON types that can be represented in JSON, including objects, arrays, strings,
## numbers, booleans, and null.

import std/[json, strutils]

type ParseMode = enum
  pmAuto, pmObject, pmArray

proc fail(msg: string) {.noreturn.} =
  raise newException(ValueError, msg)

proc ensure(dataLen, pos, needed: int) =
  if pos + needed > dataLen:
    fail("Invalid BSON: unexpected end of input")

proc writeInt32LE(buf: var seq[byte], v: int32) =
  let u = cast[uint32](v)
  buf.add(byte(u and 0xff'u32))
  buf.add(byte((u shr 8) and 0xff'u32))
  buf.add(byte((u shr 16) and 0xff'u32))
  buf.add(byte((u shr 24) and 0xff'u32))

proc writeInt64LE(buf: var seq[byte], v: int64) =
  let u = cast[uint64](v)
  buf.add(byte(u and 0xff'u64))
  buf.add(byte((u shr 8) and 0xff'u64))
  buf.add(byte((u shr 16) and 0xff'u64))
  buf.add(byte((u shr 24) and 0xff'u64))
  buf.add(byte((u shr 32) and 0xff'u64))
  buf.add(byte((u shr 40) and 0xff'u64))
  buf.add(byte((u shr 48) and 0xff'u64))
  buf.add(byte((u shr 56) and 0xff'u64))

proc readInt32LE(data: openArray[byte], pos: var int): int32 =
  ensure(data.len, pos, 4)
  let u =
    uint32(data[pos]) or
    (uint32(data[pos + 1]) shl 8) or
    (uint32(data[pos + 2]) shl 16) or
    (uint32(data[pos + 3]) shl 24)
  pos += 4
  result = cast[int32](u)

proc readInt64LE(data: openArray[byte], pos: var int): int64 =
  ensure(data.len, pos, 8)
  let u =
    uint64(data[pos]) or
    (uint64(data[pos + 1]) shl 8) or
    (uint64(data[pos + 2]) shl 16) or
    (uint64(data[pos + 3]) shl 24) or
    (uint64(data[pos + 4]) shl 32) or
    (uint64(data[pos + 5]) shl 40) or
    (uint64(data[pos + 6]) shl 48) or
    (uint64(data[pos + 7]) shl 56)
  pos += 8
  result = cast[int64](u)

proc writeFloat64LE(buf: var seq[byte], v: float64) =
  var bits: uint64
  copyMem(addr bits, unsafeAddr v, 8)
  writeInt64LE(buf, cast[int64](bits))

proc readFloat64LE(data: openArray[byte], pos: var int): float64 =
  let bits = cast[uint64](readInt64LE(data, pos))
  var f: float64
  copyMem(addr f, unsafeAddr bits, 8)
  result = f

proc writeCString(buf: var seq[byte], s: string) =
  for ch in s:
    if ch == '\0':
      fail("Invalid BSON key: NUL byte in cstring")
    buf.add(byte(ord(ch)))
  buf.add(0)

proc readCString(data: openArray[byte], pos: var int): string =
  result = newStringOfCap(16)
  while true:
    ensure(data.len, pos, 1)
    let b = data[pos]
    inc pos
    if b == 0:
      break
    result.add(char(b))

proc writeBsonString(buf: var seq[byte], s: string) =
  writeInt32LE(buf, int32(s.len + 1))
  for ch in s:
    buf.add(byte(ord(ch)))
  buf.add(0)

proc readBsonString(data: openArray[byte], pos: var int): string =
  let n = readInt32LE(data, pos).int
  if n <= 0:
    fail("Invalid BSON string length")
  ensure(data.len, pos, n)
  if data[pos + n - 1] != 0:
    fail("Invalid BSON string: missing terminator")
  result = newString(n - 1)
  for i in 0 ..< n - 1:
    result[i] = char(data[pos + i])
  pos += n

proc encodeDocument(node: JsonNode, isArray: bool): seq[byte]
proc encodeElement(buf: var seq[byte], key: string, node: JsonNode)

proc encodeElement(buf: var seq[byte], key: string, node: JsonNode) =
  case node.kind
  of JNull:
    buf.add(0x0A'u8)
    writeCString(buf, key)
  of JBool:
    buf.add(0x08'u8)
    writeCString(buf, key)
    buf.add(if node.getBool: 1'u8 else: 0'u8)
  of JInt:
    let v = node.getBiggestInt
    if v >= int32.low.BiggestInt and v <= int32.high.BiggestInt:
      buf.add(0x10'u8)
      writeCString(buf, key)
      writeInt32LE(buf, int32(v))
    else:
      buf.add(0x12'u8)
      writeCString(buf, key)
      writeInt64LE(buf, int64(v))
  of JFloat:
    buf.add(0x01'u8)
    writeCString(buf, key)
    writeFloat64LE(buf, node.getFloat)
  of JString:
    buf.add(0x02'u8)
    writeCString(buf, key)
    writeBsonString(buf, node.getStr)
  of JObject:
    buf.add(0x03'u8)
    writeCString(buf, key)
    buf.add(encodeDocument(node, false))
  of JArray:
    buf.add(0x04'u8)
    writeCString(buf, key)
    buf.add(encodeDocument(node, true))

proc encodeDocument(node: JsonNode, isArray: bool): seq[byte] =
  var body: seq[byte] = @[]
  if isArray:
    for i in 0 ..< node.len:
      encodeElement(body, $i, node[i])
  else:
    for k, v in pairs(node):
      encodeElement(body, k, v)

  result = @[]
  writeInt32LE(result, int32(body.len + 5)) # size + terminator
  result.add(body)
  result.add(0)

proc isSequentialArray(entries: seq[(string, JsonNode)]): bool =
  if entries.len == 0:
    return false
  for i, e in entries:
    if e[0] != $i:
      return false
  true

proc parseValue(t: byte, data: openArray[byte], pos: var int, limit: int): JsonNode
proc parseDocument(data: openArray[byte], pos: var int, limit: int, mode: ParseMode): JsonNode

proc parseValue(t: byte, data: openArray[byte], pos: var int, limit: int): JsonNode =
  case t
  of 0x01'u8: # double
    result = newJFloat(readFloat64LE(data, pos))
  of 0x02'u8: # string
    result = newJString(readBsonString(data, pos))
  of 0x03'u8: # object
    result = parseDocument(data, pos, limit, pmObject)
  of 0x04'u8: # array
    result = parseDocument(data, pos, limit, pmArray)
  of 0x08'u8: # bool
    ensure(data.len, pos, 1)
    let b = data[pos]
    inc pos
    result = newJBool(b != 0)
  of 0x0A'u8: # null
    result = newJNull()
  of 0x10'u8: # int32
    result = newJInt(readInt32LE(data, pos))
  of 0x12'u8: # int64
    result = newJInt(readInt64LE(data, pos))
  else:
    fail("Unsupported BSON type: 0x" & t.toHex(2))

proc parseDocument(data: openArray[byte], pos: var int, limit: int, mode: ParseMode): JsonNode =
  let start = pos
  let totalLen = readInt32LE(data, pos).int
  if totalLen < 5:
    fail("Invalid BSON document length")
  let docEnd = start + totalLen
  if docEnd > limit:
    fail("Invalid BSON document boundary")

  var entries: seq[(string, JsonNode)] = @[]

  while pos < docEnd - 1:
    ensure(data.len, pos, 1)
    let t = data[pos]
    inc pos
    let key = readCString(data, pos)
    let val = parseValue(t, data, pos, docEnd)
    entries.add((key, val))

  if pos != docEnd - 1:
    fail("Invalid BSON document element alignment")
  ensure(data.len, pos, 1)
  if data[pos] != 0:
    fail("Invalid BSON document terminator")
  inc pos

  case mode
  of pmObject:
    let obj = newJObject()
    for e in entries:
      obj[e[0]] = e[1]
    result = obj
  of pmArray:
    let arr = newJArray()
    for e in entries:
      arr.add(e[1]) # BSON arrays are ordered by element sequence
    result = arr
  of pmAuto:
    if isSequentialArray(entries):
      let arr = newJArray()
      for e in entries:
        arr.add(e[1])
      result = arr
    else:
      let obj = newJObject()
      for e in entries:
        obj[e[0]] = e[1]
      result = obj

proc encodeBson*(node: JsonNode): seq[byte] =
  ## Encode a JsonNode into BSON format. Only JObject and JArray are valid top-level types
  case node.kind
  of JObject:
    encodeDocument(node, false)
  of JArray:
    encodeDocument(node, true)
  else:
    fail("Top-level BSON must be JObject or JArray")

proc decodeBson*(data: openArray[byte]): JsonNode =
  ## Decode BSON data into a JsonNode. Automatically detects if it's an object or array based on the content.
  var pos = 0
  result = parseDocument(data, pos, data.len, pmAuto)
  if pos != data.len:
    fail("Trailing bytes after BSON document")

proc toBson*(node: JsonNode): seq[byte] =
  ## Convert a JsonNode to BSON format. Only JObject and JArray are valid top-level types.
  encodeBson(node)

proc fromBson*(data: openArray[byte]): JsonNode =
  ## Parse BSON data into a JsonNode. Returns JObject or JArray depending on the content.
  decodeBson(data)