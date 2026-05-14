# A collection of tiny parsers and dumpers
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/openparser

## This module provides functions to encode and decode BSON (Binary JSON) data.
## Implements BSON Specification Version 1.1.
##
## Extended JSON v2 notation is used to represent BSON-specific types in JsonNode:
##   - Binary:    ``{"$binary": {"base64": "...", "subType": "00"}}``
##   - ObjectId:  ``{"$oid": "507f1f77bcf86cd799439011"}``
##   - Date:      ``{"$date": 1234567890000}`` (UTC milliseconds)
##   - Regex:     ``{"$regularExpression": {"pattern": "...", "options": "..."}}``
##   - Timestamp: ``{"$timestamp": {"t": 123, "i": 1}}``
##   - Code:      ``{"$code": "function() {}"}``
##   - MinKey:    ``{"$minKey": 1}``
##   - MaxKey:    ``{"$maxKey": 1}``
##   - Decimal128:``{"$numberDecimal": "hexbytes..."}``

import std/[strutils, os, base64]
import ./json

type
  BSONDocument* = object
    version*: int32
      ## Version number for the BSON document format.
    data*: seq[byte]
      ## A BSONDocument is a wrapper around raw BSON bytes

  ParseMode = enum
    pmAuto, pmObject, pmArray

const
  BSONDocMagic* = "OPBSON1\0"
    ## Magic signature for BSON documents.

proc fail(msg: string) {.noreturn.} =
  raise newException(ValueError, msg)

# fwd decl
proc toBson*(node: JsonNode): seq[byte]
proc fromBson*(data: openArray[byte]): JsonNode

proc bytesToString(b: openArray[byte]): string =
  result = newString(b.len)
  for i in 0 ..< b.len:
    result[i] = char(b[i])

proc stringToBytes(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i, ch in s:
    result[i] = byte(ord(ch))

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
  if n < 1:
    fail("Invalid BSON string length: " & $n)
  ensure(data.len, pos, n)
  if data[pos + n - 1] != 0:
    fail("Invalid BSON string: missing null terminator")
  result = newString(n - 1)
  for i in 0 ..< n - 1:
    result[i] = char(data[pos + i])
  pos += n

#
# Extended-JSON type detectors
#
proc isExtJsonBinary(n: JsonNode): bool =
  n.kind == JObject and n.hasKey("$binary") and n["$binary"].kind == JObject and
  n["$binary"].hasKey("base64") and n["$binary"].hasKey("subType")

proc isExtJsonOid(n: JsonNode): bool =
  n.kind == JObject and n.len == 1 and n.hasKey("$oid")

proc isExtJsonDate(n: JsonNode): bool =
  n.kind == JObject and n.len == 1 and n.hasKey("$date")

proc isExtJsonRegex(n: JsonNode): bool =
  n.kind == JObject and n.len == 1 and n.hasKey("$regularExpression")

proc isExtJsonTimestamp(n: JsonNode): bool =
  n.kind == JObject and n.len == 1 and n.hasKey("$timestamp")

proc isExtJsonCode(n: JsonNode): bool =
  n.kind == JObject and n.len == 1 and n.hasKey("$code")

proc isExtJsonMinKey(n: JsonNode): bool =
  n.kind == JObject and n.len == 1 and n.hasKey("$minKey")

proc isExtJsonMaxKey(n: JsonNode): bool =
  n.kind == JObject and n.len == 1 and n.hasKey("$maxKey")

#
# Forward declarations
#
proc encodeDocument(node: JsonNode, isArray: bool): seq[byte]
proc encodeElement(buf: var seq[byte], key: string, node: JsonNode)
proc parseValue(t: byte, data: openArray[byte], pos: var int, limit: int): JsonNode
proc parseDocument(data: openArray[byte], pos: var int, limit: int, mode: ParseMode): JsonNode

#
# Encoder
#
proc encodeElement(buf: var seq[byte], key: string, node: JsonNode) =
  case node.kind
  of JNull:
    buf.add(0x0A'u8)
    writeCString(buf, key)

  of JBool:
    buf.add(0x08'u8)
    writeCString(buf, key)
    buf.add(if node.getBool: 0x01'u8 else: 0x00'u8)

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

  of JArray:
    buf.add(0x04'u8)
    writeCString(buf, key)
    buf.add(encodeDocument(node, true))

  of JObject:
    # Extended JSON dispatch
    if isExtJsonBinary(node):
      buf.add(0x05'u8)
      writeCString(buf, key)
      let binObj   = node["$binary"]
      let raw      = base64.decode(binObj["base64"].getStr)
      let subType  = byte(parseHexInt(binObj["subType"].getStr))
      writeInt32LE(buf, int32(raw.len))
      buf.add(subType)
      for ch in raw:
        buf.add(byte(ord(ch)))

    elif isExtJsonOid(node):
      buf.add(0x07'u8)
      writeCString(buf, key)
      let hexStr = node["$oid"].getStr
      if hexStr.len != 24:
        fail("Invalid ObjectId: expected 24 hex chars, got " & $hexStr.len)
      for i in 0 ..< 12:
        buf.add(byte(parseHexInt(hexStr[i * 2 .. i * 2 + 1])))

    elif isExtJsonDate(node):
      buf.add(0x09'u8)
      writeCString(buf, key)
      let dateVal = node["$date"]
      var ms: int64
      if dateVal.kind == JInt:
        ms = dateVal.getBiggestInt.int64
      elif dateVal.kind == JObject and dateVal.hasKey("$numberLong"):
        ms = parseBiggestInt(dateVal["$numberLong"].getStr).int64
      else:
        fail("Invalid $date value: expected integer or {\"$numberLong\":\"...\"}")
      writeInt64LE(buf, ms)

    elif isExtJsonRegex(node):
      buf.add(0x0B'u8)
      writeCString(buf, key)
      let rxObj = node["$regularExpression"]
      if not rxObj.hasKey("pattern"):
        fail("$regularExpression missing 'pattern'")
      writeCString(buf, rxObj["pattern"].getStr)
      writeCString(buf, rxObj.getOrDefault("options").getStr)

    elif isExtJsonCode(node):
      buf.add(0x0D'u8)
      writeCString(buf, key)
      writeBsonString(buf, node["$code"].getStr)

    elif isExtJsonTimestamp(node):
      buf.add(0x11'u8)
      writeCString(buf, key)
      let tsObj = node["$timestamp"]
      let t = uint32(tsObj["t"].getInt)   # seconds
      let i = uint32(tsObj["i"].getInt)   # increment/ordinal
      # wire: LE uint64 — low 32 bits = increment, high 32 bits = seconds
      let combined = uint64(i) or (uint64(t) shl 32)
      writeInt64LE(buf, cast[int64](combined))

    elif isExtJsonMinKey(node):
      buf.add(0xFF'u8)
      writeCString(buf, key)

    elif isExtJsonMaxKey(node):
      buf.add(0x7F'u8)
      writeCString(buf, key)

    else:
      buf.add(0x03'u8)
      writeCString(buf, key)
      buf.add(encodeDocument(node, false))

proc encodeDocument(node: JsonNode, isArray: bool): seq[byte] =
  var body: seq[byte] = @[]
  if isArray:
    for i in 0 ..< node.len:
      encodeElement(body, $i, node[i])
  else:
    for k, v in pairs(node):
      encodeElement(body, k, v)
  result = @[]
  # total size = 4 (int32) + body + 1 (terminator)
  writeInt32LE(result, int32(body.len + 5))
  result.add(body)
  result.add(0x00'u8)

# Decoder

proc parseValue(t: byte, data: openArray[byte], pos: var int, limit: int): JsonNode =
  case t

  of 0x01'u8: # double
    result = newJFloat(readFloat64LE(data, pos))

  of 0x02'u8: # UTF-8 string
    result = newJString(readBsonString(data, pos))

  of 0x03'u8: # embedded document
    result = parseDocument(data, pos, limit, pmObject)

  of 0x04'u8: # array
    result = parseDocument(data, pos, limit, pmArray)

  of 0x05'u8: # binary
    let n = readInt32LE(data, pos).int
    if n < 0:
      fail("Invalid BSON binary length: " & $n)
    ensure(data.len, pos, 1 + n)
    let subType = data[pos]
    inc pos
    var raw = newString(n)
    for i in 0 ..< n:
      raw[i] = char(data[pos + i])
    pos += n
    let b64str      = base64.encode(raw)
    let subTypeHex  = toHex(int(subType), 2).toLowerAscii
    result = %*{"$binary": {"base64": b64str, "subType": subTypeHex}}

  of 0x06'u8: # undefined – deprecated, no payload
    result = newJNull()

  of 0x07'u8: # ObjectId (12 bytes)
    ensure(data.len, pos, 12)
    var hexStr = newStringOfCap(24)
    for i in 0 ..< 12:
      hexStr.add(toHex(int(data[pos + i]), 2).toLowerAscii)
    pos += 12
    result = %*{"$oid": hexStr}

  of 0x08'u8: # boolean
    ensure(data.len, pos, 1)
    let b = data[pos]
    inc pos
    if b != 0x00'u8 and b != 0x01'u8:
      fail("Invalid BSON boolean byte: 0x" & b.toHex(2))
    result = newJBool(b == 0x01'u8)

  of 0x09'u8: # UTC datetime (int64 milliseconds)
    result = %*{"$date": readInt64LE(data, pos)}

  of 0x0A'u8: # null
    result = newJNull()

  of 0x0B'u8: # regex – two cstrings (pattern, options)
    let pattern = readCString(data, pos)
    let options  = readCString(data, pos)
    result = %*{"$regularExpression": {"pattern": pattern, "options": options}}

  of 0x0C'u8: # DBPointer – deprecated: string + 12 bytes ObjectId
    discard readBsonString(data, pos)
    ensure(data.len, pos, 12)
    pos += 12
    result = newJNull()

  of 0x0D'u8: # JavaScript code
    result = %*{"$code": readBsonString(data, pos)}

  of 0x0E'u8: # Symbol – deprecated, treat as string
    result = newJString(readBsonString(data, pos))

  of 0x0F'u8: # JavaScript code with scope – deprecated
    # code_w_s ::= int32 string document  (int32 = total byte length of code_w_s)
    let startCws = pos
    let totalLen = readInt32LE(data, pos).int
    if totalLen < 8:
      fail("Invalid code_w_s length")
    let endCws = startCws + totalLen
    let code = readBsonString(data, pos)
    discard parseDocument(data, pos, endCws, pmObject)
    pos = endCws
    result = %*{"$code": code}

  of 0x10'u8: # int32
    result = newJInt(readInt32LE(data, pos))

  of 0x11'u8: # Timestamp (uint64)
    let u  = cast[uint64](readInt64LE(data, pos))
    let i  = int(uint32(u and 0xFFFFFFFF'u64))   # increment (low 32)
    let tv = int(uint32(u shr 32))               # seconds   (high 32)
    result = %*{"$timestamp": {"t": tv, "i": i}}

  of 0x12'u8: # int64
    result = newJInt(readInt64LE(data, pos))

  of 0x13'u8: # Decimal128 (16 bytes)
    ensure(data.len, pos, 16)
    var hexStr = newStringOfCap(32)
    for i in 0 ..< 16:
      hexStr.add(toHex(int(data[pos + i]), 2).toLowerAscii)
    pos += 16
    result = %*{"$numberDecimal": hexStr}

  of 0x7F'u8: # Max key
    result = %*{"$maxKey": 1}

  of 0xFF'u8: # Min key
    result = %*{"$minKey": 1}

  else:
    fail("Unsupported BSON type: 0x" & t.toHex(2))

proc isSequentialArray(entries: seq[(string, JsonNode)]): bool =
  if entries.len == 0:
    return false
  for i, e in entries:
    if e[0] != $i:
      return false
  true

proc parseDocument(data: openArray[byte], pos: var int, limit: int, mode: ParseMode): JsonNode =
  let start    = pos
  let totalLen = readInt32LE(data, pos).int
  if totalLen < 5:
    fail("Invalid BSON document length: " & $totalLen)
  let docEnd = start + totalLen
  if docEnd > limit:
    fail("Invalid BSON document boundary")

  var entries: seq[(string, JsonNode)] = @[]

  while pos < docEnd - 1:
    ensure(data.len, pos, 1)
    let t   = data[pos]
    inc pos
    let key = readCString(data, pos)
    let val = parseValue(t, data, pos, docEnd)
    entries.add((key, val))

  if pos != docEnd - 1:
    fail("Invalid BSON document element alignment")
  ensure(data.len, pos, 1)
  if data[pos] != 0x00'u8:
    fail("Invalid BSON document terminator")
  inc pos

  case mode
  of pmObject:
    let obj = newJObject()
    for e in entries: obj[e[0]] = e[1]
    result = obj
  of pmArray:
    let arr = newJArray()
    for e in entries: arr.add(e[1])
    result = arr
  of pmAuto:
    if isSequentialArray(entries):
      let arr = newJArray()
      for e in entries: arr.add(e[1])
      result = arr
    else:
      let obj = newJObject()
      for e in entries: obj[e[0]] = e[1]
      result = obj

#
# Public API
#
proc encodeBson*(node: JsonNode): seq[byte] =
  ## Encode a JsonNode into BSON format. Only JObject and JArray are valid top-level types.
  case node.kind
  of JObject: encodeDocument(node, false)
  of JArray:  encodeDocument(node, true)
  else: fail("Top-level BSON must be JObject or JArray")

proc decodeBson*(data: openArray[byte]): JsonNode =
  ## Decode BSON data into a JsonNode. Automatically detects object or array.
  var pos = 0
  result = parseDocument(data, pos, data.len, pmAuto)
  if pos != data.len:
    fail("Trailing bytes after BSON document")

proc toBson*(node: JsonNode): seq[byte] =
  ## Convert a JsonNode to BSON format.
  encodeBson(node)

proc fromBson*(data: openArray[byte]): JsonNode =
  ## Parse BSON bytes into a JsonNode.
  decodeBson(data)

proc fromBson*(s: BSONDocument): JsonNode =
  ## Parse a BSONDocument into a JsonNode.
  fromBson(s.data)

proc newBSONDocument*(node: JsonNode, version: int32 = 1'i32): BSONDocument =
  if version <= 0:
    fail("Invalid BSONDocument version")
  BSONDocument(version: version, data: toBson(node))

proc toJsonNode*(doc: BSONDocument): JsonNode =
  fromBson(doc.data)

proc toBytes*(doc: BSONDocument): seq[byte] =
  if doc.version <= 0:
    fail("Invalid BSONDocument version")
  if doc.data.len > int(high(int32)):
    fail("BSONDocument payload too large")
  result = @[]
  for ch in BSONDocMagic:
    result.add(byte(ord(ch)))
  writeInt32LE(result, doc.version)
  writeInt32LE(result, int32(doc.data.len))
  result.add(doc.data)

proc fromBytes*(data: openArray[byte]): BSONDocument =
  let minLen = BSONDocMagic.len + 8
  if data.len < minLen:
    fail("Invalid BSONDocument: too small")
  for i, ch in BSONDocMagic:
    if data[i] != byte(ord(ch)):
      fail("Invalid BSONDocument: bad magic")
  var pos = BSONDocMagic.len
  let ver = readInt32LE(data, pos)
  let n   = readInt32LE(data, pos).int
  if ver <= 0:
    fail("Invalid BSONDocument: bad version")
  if n < 0 or pos + n != data.len:
    fail("Invalid BSONDocument: bad payload length")
  result.version = ver
  result.data = newSeq[byte](n)
  for i in 0 ..< n:
    result.data[i] = data[pos + i]

proc writeBSONDocument*(path: string, doc: BSONDocument) =
  ## Write a BSONDocument to a file. A `.bson` extension will be added to the path
  let blob = toBytes(doc)
  writeFile(path.changeFileExt("bson"), bytesToString(blob))

proc openBSONDocument*(path: string): BSONDocument =
  ## Read a BSONDocument from a file. The path should have a `.bson` extension
  let path = path.changeFileExt("bson")
  if not fileExists(path):
    fail("BSONDocument file not found: " & path)
  let blob = readFile(path)
  fromBytes(stringToBytes(blob))
