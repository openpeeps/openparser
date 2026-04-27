# A collection of tiny parsers and dumpers
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/openparser

## This module implements the FBE (FastBinaryEncoding), a ultra fast
## and universal solution for encoding and decoding structured data in a compact binary format
## 
## FBE is designed for high performance and low overhead, making it ideal for use in game engines,
## network protocols, file formats, and any scenario where efficient serialization is needed.
## 
## When saving data to disk, storing in a database, or sending over the network, FBE can be compressed
## with zlib, lz4, or zxc ([bindings available for Nim](https://github.com/openpeeps/zxc-nim)) to further reduce size
## while maintaining fast decompression speeds.
## 
## [FastBinaryEncoding on GitHub](https://github.com/chronoxor/FastBinaryEncoding)


import std/[sequtils, strutils]

type
  StructCtx* = object
    startPos*: int        ## where the struct began (for root we patch total size here)
    headerPos*: int       ## position of header (same as startPos for our layout)
    fieldCountPos*: int   ## where fieldCount is stored (to patch at end)
    fieldCount*: uint32   ## total fields written (writer side)
    readFieldsLeft*: int  ## remaining fields to read (reader side)
    version*: uint32      ## struct version (from header)
    isRoot*: bool         ## whether this is a root struct (has total size) or inner struct (no total size)  
    totalSize*: int       ## total size read from root header (bytes) - used by final reader

  Buffer* = object
    data*: seq[uint8]
      ## The underlying byte buffer where data is written to or read from.
      ## It is a dynamic sequence of bytes (uint8).
    pos*: int
      ## The current position in the buffer for reading or writing.
    structStack*: seq[StructCtx]
      ## A stack of struct contexts used during encoding/decoding to manage
      ## nested structures.

proc initBuffer*(capacity = 256): Buffer =
  ## Initializes a new Buffer with an optional initial capacity. The
  ## buffer starts empty with position 0.
  result.data = newSeq[uint8](0)
  result.data.setLen(0)
  result.pos = 0
  if capacity > 0:
    # preallocate capacity by creating a seq with that capacity, but keep length 0
    result.data = newSeq[uint8](capacity)
    result.data.setLen(0)
  else:
    result.data = newSeq[uint8](0)
  result.pos = 0

proc reset*(b: var Buffer) =
  ## Resets the buffer to an empty state and position to 0, but keeps
  ## the allocated capacity for reuse.
  b.data.setLen(0)
  b.pos = 0

proc len*(b: Buffer): int {.inline.} =
  ## Returns the current length of the data in the buffer.
  b.data.len

proc remaining*(b: Buffer): int {.inline.} =
  ## Returns the number of bytes remaining from the current
  ## position to the end of the data.
  b.data.len - b.pos

proc ensureRead*(b: Buffer; n: int) =
  ## Ensures that there are at least `n` bytes available to read from the
  ## current position. Raises an exception if not enough data is available.
  if b.pos + n > b.data.len:
    raise newException(CatchableError, "FBE.Buffer: not enough data to read")

proc writeByte*(b: var Buffer; v: uint8) =
  ## Writes a single byte to the buffer at the current position and
  ## advances the position.
  b.data.add(v)

proc readByte*(b: var Buffer): uint8 =
  ## Reads a single byte from the buffer at the current position, advances
  ## the position, and returns the byte.
  ensureRead(b, 1)
  let v = b.data[b.pos]
  b.pos.inc()
  result = v

proc appendReserve*(b: var Buffer; n: int): int =
  ## Reserve `n` bytes at the end of buffer and return start index.
  ## This lets callers fill bytes via direct assignment or copyMem,
  ## avoiding repeated seq.add overhead in hot paths.
  if n <= 0:
    return b.data.len
  let oldLen = b.data.len
  b.data.setLen(oldLen + n)
  result = oldLen

# Little-endian integer writers/readers
# proc writeUint16LE*(b: var Buffer; v: uint16) =
#   b.data.add(uint8(v and 0xFF'u16))
#   b.data.add(uint8((v shr 8) and 0xFF'u16))

proc writeUint16LE*(b: var Buffer; v: uint16) =
  let p = appendReserve(b, 2)
  b.data[p]     = uint8(v and 0xFF'u16)
  b.data[p + 1] = uint8((v shr 8) and 0xFF'u16)

proc readUint16LE*(b: var Buffer): uint16 =
  ensureRead(b, 2)
  let lo = uint16(b.data[b.pos])
  let hi = uint16(b.data[b.pos + 1])
  b.pos += 2
  result = (hi.shl(8)) or lo

# proc writeUint32LE*(b: var Buffer; v: uint32) =
#   b.data.add(uint8(v and 0xFF'u32))
#   b.data.add(uint8((v shr 8) and 0xFF'u32))
#   b.data.add(uint8((v shr 16) and 0xFF'u32))
#   b.data.add(uint8((v shr 24) and 0xFF'u32))


proc writeUint32LE*(b: var Buffer; v: uint32) =
  let p = appendReserve(b, 4)
  b.data[p]     = uint8(v and 0xFF'u32)
  b.data[p + 1] = uint8((v shr 8) and 0xFF'u32)
  b.data[p + 2] = uint8((v shr 16) and 0xFF'u32)
  b.data[p + 3] = uint8((v shr 24) and 0xFF'u32)

proc readUint32LE*(b: var Buffer): uint32 =
  ensureRead(b, 4)
  let b0 = uint32(b.data[b.pos])
  let b1 = uint32(b.data[b.pos+1])
  let b2 = uint32(b.data[b.pos+2])
  let b3 = uint32(b.data[b.pos+3])
  b.pos += 4
  result = (b3.shl(24)) or (b2.shl(16)) or (b1.shl(8)) or b0

# proc writeUint64LE*(b: var Buffer; v: uint64) =
#   for i in 0..7:
#     b.data.add(uint8((v shr (i * 8)) and 0xFF'u64))

proc writeUint64LE*(b: var Buffer; v: uint64) =
  let p = appendReserve(b, 8)
  for i in 0..7:
    b.data[p + i] = uint8((v shr (i * 8)) and 0xFF'u64)

proc readUint64LE*(b: var Buffer): uint64 =
  ensureRead(b, 8)
  var r: uint64 = 0
  for i in 0..7:
    r = r or (uint64(b.data[b.pos + i]).shl(i * 8))
  b.pos += 8
  result = r

# Signed integers
proc writeInt8*(b: var Buffer; v: int8) = writeByte(b, uint8(v))
proc readInt8*(b: var Buffer): int8 = int8(readByte(b))

proc writeInt16LE*(b: var Buffer; v: int16) =
  writeUint16LE(b, uint16(v))

proc readInt16LE*(b: var Buffer): int16 =
  int16(readUint16LE(b))

proc writeInt32LE*(b: var Buffer; v: int32) =
  writeUint32LE(b, uint32(v))

proc readInt32LE*(b: var Buffer): int32 =
  int32(readUint32LE(b))

proc writeInt64LE*(b: var Buffer; v: int64) =
  writeUint64LE(b, uint64(v))

proc readInt64LE*(b: var Buffer): int64 =
  int64(readUint64LE(b))

# bool
proc writeBool*(b: var Buffer; v: bool) =
  writeByte(b, if v: 1'u8 else: 0'u8)

proc readBool*(b: var Buffer): bool =
  readByte(b) != 0'u8

# float/double (bitwise)
proc writeFloat32LE*(b: var Buffer; x: float32) =
  var u: uint32
  copyMem(addr u, addr x, sizeof(u))
  writeUint32LE(b, u)

proc readFloat32LE*(b: var Buffer): float32 =
  let u = readUint32LE(b)
  var x: float32
  copyMem(addr x, addr u, sizeof(u))
  result = x

proc writeFloat64LE*(b: var Buffer; x: float64) =
  var u: uint64
  copyMem(addr u, addr x, sizeof(u))
  writeUint64LE(b, u)

proc readFloat64LE*(b: var Buffer): float64 =
  let u = readUint64LE(b)
  var x: float64
  copyMem(addr x, addr u, sizeof(u))
  result = x

# wchar (uint32 little-endian) and char (uint8)
proc writeChar*(b: var Buffer; c: uint8) = writeByte(b, c)
proc readChar*(b: var Buffer): uint8 = readByte(b)

proc writeWChar*(b: var Buffer; wc: uint32) = writeUint32LE(b, wc)
proc readWChar*(b: var Buffer): uint32 = readUint32LE(b)

# proc writeBytes*(b: var Buffer; data: seq[uint8]) =
#   writeUint32LE(b, uint32(data.len))
#   if data.len > 0:
#     for x in data:
#       b.data.add(x)

proc writeBytes*(b: var Buffer; data: seq[uint8]) =
  writeUint32LE(b, uint32(data.len))
  if data.len > 0:
    let p = appendReserve(b, data.len)
    copyMem(addr b.data[p], addr data[0], data.len)

proc readBytes*(b: var Buffer): seq[uint8] =
  let n = int(readUint32LE(b))
  ensureRead(b, n)
  result = newSeq[uint8](n)
  for i in 0..<n:
    result[i] = b.data[b.pos + i]
  b.pos += n

# proc writeString*(b: var Buffer; s: string) =
#   ## Write UTF-8 string as 4-byte length (bytes) + raw bytes
#   let n = s.len
#   writeUint32LE(b, uint32(n))
#   if n > 0:
#     let oldLen = b.data.len
#     b.data.setLen(oldLen + n)
#     # copy raw UTF-8 bytes from s.cstring (null-terminated) into seq storage
#     copyMem(addr b.data[oldLen], cast[ptr uint8](s.cstring), n)

proc writeString*(b: var Buffer; s: string) =
  ## Write UTF-8 string as 4-byte length (bytes) + raw bytes
  # Note: s.len in Nim is number of codepoints; using cstring length for byte count.
  var byteCount = 0
  var pc = s.cstring
  while pc[byteCount] != '\0':
    byteCount.inc()
  writeUint32LE(b, uint32(byteCount))
  if byteCount > 0:
    let p = appendReserve(b, byteCount)
    copyMem(addr b.data[p], cast[ptr uint8](s.cstring), byteCount)

proc readString*(b: var Buffer): string =
  let n = int(readUint32LE(b))
  ensureRead(b, n)
  result = newStringOfCap(n)
  result.setLen(n)
  if n > 0:
    copyMem(cast[ptr uint8](addr result[0]), cast[ptr uint8](addr b.data[b.pos]), n)
  b.pos += n

# timestamp (uint64 nanoseconds little-endian)
proc writeTimestamp*(b: var Buffer; ns: uint64) = writeUint64LE(b, ns)
proc readTimestamp*(b: var Buffer): uint64 = readUint64LE(b)

# uuid (16 bytes, stored big-endian per spec)
# proc writeUUID*(b: var Buffer; u: openArray[uint8]) =
#   if u.len != 16:
#     raise newException(ValueError, "UUID must be 16 bytes")
#   # store in big-endian order (as-is)
#   for i in 0..<16:
#     b.data.add(u[i])
proc writeUUID*(b: var Buffer; u: openArray[uint8]) =
  if u.len != 16:
    raise newException(ValueError, "UUID must be 16 bytes")
  let p = appendReserve(b, 16)
  copyMem(addr b.data[p], addr u[0], 16)

proc readUUID*(b: var Buffer): seq[uint8] =
  ensureRead(b, 16)
  result = newSeq[uint8](16)
  for i in 0..<16:
    result[i] = b.data[b.pos + i]
  b.pos += 16

# Generic helpers to write/read custom values via callbacks
proc writeWith*(b: var Buffer; writeFn: proc (b: var Buffer)) =
  writeFn(b)

proc readWith*[T](b: var Buffer; readFn: proc (b: var Buffer): T): T =
  result = readFn(b)

# convenience: append raw bytes to buffer
proc appendRaw*(b: var Buffer; data: openArray[uint8]) =
  for x in data: b.data.add(x)


# Collections
# - array: fixed count, uses index-based writer callback
# - vector/list: length-prefixed dynamic sequences (uint32 length)
# - map/hash: length-prefixed sequences of key/value pairs
#
# All element serializers/deserializers are passed as callbacks so the
# caller controls how individual elements are encoded/decoded.

proc writeArrayFixed*(b: var Buffer; count: int; writeElem: proc (b: var Buffer; idx: int)) =
  ## Writes a fixed-size array of `count` elements. `writeElem` must encode
  ## element at given index into the buffer.
  for i in 0..<count:
    writeElem(b, i)

proc readArrayFixed*[T](b: var Buffer; count: int; readElem: proc (b: var Buffer): T): seq[T] =
  ## Reads `count` elements using `readElem` callback and returns them as a seq.
  result = newSeq[T](count)
  for i in 0..<count:
    result[i] = readElem(b)

proc writeVector*[T](b: var Buffer; items: seq[T]; writeElem: proc (b: var Buffer; v: T)) =
  ## Writes a dynamic vector: uint32 length followed by elements encoded
  ## by `writeElem`.
  writeUint32LE(b, uint32(items.len))
  for v in items:
    writeElem(b, v)

proc readVector*[T](b: var Buffer; readElem: proc (b: var Buffer): T): seq[T] =
  ## Reads a length-prefixed vector and returns seq[T].
  let n = int(readUint32LE(b))
  result = newSeq[T](n)
  for i in 0..<n:
    result[i] = readElem(b)

# list behaves like vector (same on-wire representation)
proc writeList*[T](b: var Buffer; items: seq[T]; writeElem: proc (b: var Buffer; v: T)) =
  writeVector[T](b, items, writeElem)

proc readList*[T](b: var Buffer; readElem: proc (b: var Buffer): T): seq[T] =
  readVector[T](b, readElem)

proc writeMap*[K, V](b: var Buffer;
                     items: seq[tuple[key: K, val: V]];
                     writeKey: proc (b: var Buffer; k: K);
                     writeVal: proc (b: var Buffer; v: V)) =
  ## Writes a map as uint32 length followed by key/value pairs.
  writeUint32LE(b, uint32(items.len))
  for it in items:
    writeKey(b, it.key)
    writeVal(b, it.val)

proc readMap*[K, V](b: var Buffer;
                    readKey: proc (b: var Buffer): K;
                    readVal: proc (b: var Buffer): V): seq[tuple[key: K, val: V]] =
  ## Reads a map (length-prefixed key/value pairs) and returns seq of tuples.
  let n = int(readUint32LE(b))
  result = newSeq[tuple[key: K, val: V]](n)
  for i in 0..<n:
    let k = readKey(b)
    let v = readVal(b)
    result[i] = (key: k, val: v)

# hash is the same on-wire as map; provide alias functions for clarity
proc writeHash*[K, V](b: var Buffer;
                      items: seq[tuple[key: K, val: V]];
                      writeKey: proc (b: var Buffer; k: K);
                      writeVal: proc (b: var Buffer; v: V)) =
  writeMap[K, V](b, items, writeKey, writeVal)

proc readHash*[K, V](b: var Buffer;
                     readKey: proc (b: var Buffer): K;
                     readVal: proc (b: var Buffer): V): seq[tuple[key: K, val: V]] =
  readMap[K, V](b, readKey, readVal)


# Optional type (final model): 1 byte presence + value
proc writeOptional*[T](b: var Buffer; hasValue: bool; value: T; writeVal: proc (b: var Buffer; v: T)) =
  b.data.add(if hasValue: 1'u8 else: 0'u8)
  if hasValue:
    writeVal(b, value)

proc readOptional*[T](b: var Buffer; readVal: proc (b: var Buffer): T; hasValue: bool): T =
  ensureRead(b, 1)
  hasValue = b.data[b.pos] != 0'u8
  b.pos.inc()
  if hasValue:
    result = readVal(b)
  else:
    result = default(T)

# Enum / Flags (generic helpers) - write underlying integer of specified size
proc writeEnum8*(b: var Buffer; v: int8) = writeInt8(b, v)
proc readEnum8*(b: var Buffer): int8 = readInt8(b)

proc writeEnum16*(b: var Buffer; v: int16) = writeInt16LE(b, v)
proc readEnum16*(b: var Buffer): int16 = readInt16LE(b)

proc writeEnum32*(b: var Buffer; v: int32) = writeInt32LE(b, v)
proc readEnum32*(b: var Buffer): int32 = readInt32LE(b)

proc writeEnum64*(b: var Buffer; v: int64) = writeInt64LE(b, v)
proc readEnum64*(b: var Buffer): int64 = readInt64LE(b)

# unsigned / smaller underlying enum variants (byte/char/etc)
proc writeEnum8u*(b: var Buffer; v: uint8) = writeByte(b, v)
proc readEnum8u*(b: var Buffer): uint8 = readByte(b)

proc writeEnum16u*(b: var Buffer; v: uint16) = writeUint16LE(b, v)
proc readEnum16u*(b: var Buffer): uint16 = readUint16LE(b)

proc writeEnum32u*(b: var Buffer; v: uint32) = writeUint32LE(b, v)
proc readEnum32u*(b: var Buffer): uint32 = readUint32LE(b)

proc writeEnum64u*(b: var Buffer; v: uint64) = writeUint64LE(b, v)
proc readEnum64u*(b: var Buffer): uint64 = readUint64LE(b)


# Flags helpers (multiple sizes)
proc writeFlags8*(b: var Buffer; v: uint8) = writeByte(b, v)
proc readFlags8*(b: var Buffer): uint8 = readByte(b)

proc writeFlags16*(b: var Buffer; v: uint16) = writeUint16LE(b, v)
proc readFlags16*(b: var Buffer): uint16 = readUint16LE(b)

proc writeFlags32*(b: var Buffer; v: uint32) = writeUint32LE(b, v)
proc readFlags32*(b: var Buffer): uint32 = readUint32LE(b)

proc writeFlags64*(b: var Buffer; v: uint64) = writeUint64LE(b, v)
proc readFlags64*(b: var Buffer): uint64 = readUint64LE(b)

# proc writeDecimal*(b: var Buffer; data: openArray[uint8]) =
#   ## Writes a 128-bit decimal value as 16 bytes little-endian.
#   if data.len != 16:
#     raise newException(ValueError, "Decimal must be 16 bytes")
#   for i in 0..<16:
#     b.data.add(data[i])

proc writeDecimal*(b: var Buffer; data: openArray[uint8]) =
  if data.len != 16:
    raise newException(ValueError, "Decimal must be 16 bytes")
  let p = appendReserve(b, 16)
  copyMem(addr b.data[p], addr data[0], 16)

proc readDecimal*(b: var Buffer): seq[uint8] =
  ## Reads a 128-bit decimal value (16 bytes little-endian) and returns as seq[uint8].
  ensureRead(b, 16)
  result = newSeq[uint8](16)
  for i in 0..<16:
    result[i] = b.data[b.pos + i]
  b.pos += 16

proc ensureStructStackInit(b: var Buffer) =
  if b.structStack.len == 0:
    b.structStack = newSeq[StructCtx](0)

proc patchUint32At*(b: var Buffer; pos: int; v: uint32) =
  ## Patches a uint32 value at given position in buffer (little-endian).
  b.data[pos]     = uint8(v and 0xFF'u32)
  b.data[pos + 1] = uint8((v shr 8) and 0xFF'u32)
  b.data[pos + 2] = uint8((v shr 16) and 0xFF'u32)
  b.data[pos + 3] = uint8((v shr 24) and 0xFF'u32)

proc patchUint16At*(b: var Buffer; pos: int; v: uint16) =
  ## Patches a uint16 value at given position in buffer (little-endian).
  b.data[pos]     = uint8(v and 0xFF'u16)
  b.data[pos + 1] = uint8((v shr 8) and 0xFF'u16)

# Header sizes per spec
const
  ROOT_HEADER_SIZE* = 16      # totalSize:uint32, version:uint32, fieldCount:uint32, reserved:uint32
  INNER_HEADER_SIZE* = 12     # version:uint32, fieldCount:uint32, reserved:uint32

# Begin writing a root struct. Writes header placeholders and pushes writer context.
proc beginRootStruct*(b: var Buffer; version: uint32) =
  ensureStructStackInit(b)
  let startPos = b.data.len
  # totalSize placeholder (will patch at end)
  writeUint32LE(b, 0'u32)
  # version
  writeUint32LE(b, version)
  # fieldCount placeholder
  writeUint32LE(b, 0'u32)
  # reserved / metadata (unused for now)
  writeUint32LE(b, 0'u32)
  var ctx: StructCtx
  ctx.startPos = startPos
  ctx.headerPos = startPos
  ctx.fieldCountPos = startPos + 8
  ctx.fieldCount = 0'u32
  ctx.readFieldsLeft = 0
  ctx.version = version
  ctx.isRoot = true
  ctx.totalSize = 0
  b.structStack.add(ctx)

proc endRootStruct*(b: var Buffer) =
  ## Ends writing a root struct. Patches total size and field count in header,
  ## and pops context.
  if b.structStack.len == 0:
    raise newException(CatchableError, "endRootStruct: no struct context")
  var ctx = b.structStack[^1]
  if not ctx.isRoot:
    raise newException(CatchableError, "endRootStruct: top context is not root")
  let totalSize = uint32(b.data.len - ctx.startPos)
  patchUint32At(b, ctx.headerPos, totalSize)
  patchUint32At(b, ctx.fieldCountPos, ctx.fieldCount)
  b.structStack.del(b.structStack.len-1)

proc beginInnerStruct*(b: var Buffer; version: uint32) =
  ## Begins writing an inner struct. Writes version and fieldCount placeholder + reserved,
  ## and pushes context.
  ensureStructStackInit(b)
  let startPos = b.data.len
  writeUint32LE(b, version)
  writeUint32LE(b, 0'u32) # field count placeholder
  writeUint32LE(b, 0'u32) # reserved
  var ctx: StructCtx
  ctx.startPos = startPos
  ctx.headerPos = startPos
  ctx.fieldCountPos = startPos + 4
  ctx.fieldCount = 0'u32
  ctx.readFieldsLeft = 0
  ctx.version = version
  ctx.isRoot = false
  b.structStack.add(ctx)

# End writing inner struct. Patch field count and pop context.
proc endInnerStruct*(b: var Buffer) =
  ## Ends writing an inner struct. Patches field count and pops context.
  ## 
  ## Does not need to patch total size since inner structs don't have it.
  if b.structStack.len == 0:
    raise newException(CatchableError, "endInnerStruct: no struct context")
  var ctx = b.structStack[^1]
  if ctx.isRoot:
    raise newException(CatchableError, "endInnerStruct: top context is root")
  patchUint32At(b, ctx.fieldCountPos, ctx.fieldCount)
  b.structStack.del(b.structStack.len-1)

proc writeField*(b: var Buffer; fieldId: uint16; writeVal: proc (b: var Buffer)) =
  ## Writes a field with given `fieldId` and value encoded by `writeVal` callback.
  ## Handles writing field header (fieldId + valueSize) and patching field count in
  ## current struct context. `writeVal` should write the field value and nothing else.
  if b.structStack.len == 0:
    raise newException(CatchableError, "writeField: no struct context")
  var ctx = b.structStack[^1]
  ctx.fieldCount = ctx.fieldCount + 1'u32
  b.structStack[^1] = ctx
  writeUint16LE(b, fieldId)
  let sizePos = b.data.len
  writeUint32LE(b, 0'u32) # placeholder for size
  let valStart = b.data.len
  writeVal(b)
  let valSize = uint32(b.data.len - valStart)
  patchUint32At(b, sizePos, valSize)

# Reader helpers

proc beginReadRootStruct*(b: var Buffer): uint32 =
  ## Begins reading a root struct. Reads total size, version and field count, and
  ## pushes context. Returns the version of the struct.
  ensureRead(b, ROOT_HEADER_SIZE)
  let totalSize = readUint32LE(b)
  let version = readUint32LE(b)
  let fieldCount = readUint32LE(b)
  let reserved = readUint32LE(b) # currently unused
  ensureStructStackInit(b)
  var ctx: StructCtx
  ctx.startPos = b.pos - ROOT_HEADER_SIZE
  ctx.headerPos = ctx.startPos
  ctx.fieldCountPos = ctx.startPos + 8
  ctx.fieldCount = fieldCount
  ctx.readFieldsLeft = int(fieldCount)
  ctx.version = version
  ctx.isRoot = true
  b.structStack.add(ctx)
  result = version

proc endReadRootStruct*(b: var Buffer) =
  ## Skips any remaining fields in current root struct and pops context. Should be
  ## called after finishing reading all fields (or if you want to skip unread fields).
  if b.structStack.len == 0:
    raise newException(CatchableError, "endReadRootStruct: no struct context")
  var ctx = b.structStack[^1]
  if not ctx.isRoot:
    raise newException(CatchableError, "endReadRootStruct: top context is not root")
  while ctx.readFieldsLeft > 0:
    let fid = readUint16LE(b)
    let sz = int(readUint32LE(b))
    b.pos += sz
    ctx.readFieldsLeft = ctx.readFieldsLeft - 1
  b.structStack.del(b.structStack.len-1)

proc beginReadInnerStruct*(b: var Buffer): uint32 =
  ## Begins reading an inner struct. Reads version and field count, and
  ## pushes context.
  ensureRead(b, INNER_HEADER_SIZE)
  let version = readUint32LE(b)
  let fieldCount = readUint32LE(b)
  let reserved = readUint32LE(b)
  ensureStructStackInit(b)
  var ctx: StructCtx
  ctx.startPos = b.pos - INNER_HEADER_SIZE
  ctx.headerPos = ctx.startPos
  ctx.fieldCountPos = ctx.startPos + 4
  ctx.fieldCount = fieldCount
  ctx.readFieldsLeft = int(fieldCount)
  ctx.version = version
  ctx.isRoot = false
  b.structStack.add(ctx)
  result = version

proc endReadInnerStruct*(b: var Buffer) =
  ## Skips any remaining fields in current inner struct and pops context.
  ## Should be called after finishing reading all fields (or if you want to
  ## skip unread fields).
  if b.structStack.len == 0:
    raise newException(CatchableError, "endReadInnerStruct: no struct context")
  var ctx = b.structStack[^1]
  if ctx.isRoot:
    raise newException(CatchableError, "endReadInnerStruct: top context is root")
  while ctx.readFieldsLeft > 0:
    let fid = readUint16LE(b)
    let sz = int(readUint32LE(b))
    b.pos += sz
    ctx.readFieldsLeft = ctx.readFieldsLeft - 1
  b.structStack.del(b.structStack.len-1)

proc readFieldHeader*(b: var Buffer; fieldId: var uint16; valueSize: var int): bool =
  ## Reads the next field header (fieldId and valueSize) within current
  ## struct context.
  if b.structStack.len == 0:
    raise newException(CatchableError, "readFieldHeader: no struct context")
  var ctx = b.structStack[^1]
  if ctx.readFieldsLeft <= 0:
    return false
  fieldId = readUint16LE(b)
  valueSize = int(readUint32LE(b))
  ctx.readFieldsLeft = ctx.readFieldsLeft - 1
  b.structStack[^1] = ctx
  result = true

#
# Decode with generics
#
proc readFieldValue*[T](b: var Buffer; valueSize: int;
                    readFn: proc (b: var Buffer): T): T =
  ## Reads a field value of given size using `readFn` callback.
  ## Ensures that `readFn` does not consume more bytes than `valueSize` and
  ## skips any remaining bytes if it consumes less.
  let start = b.pos
  let endPos = start + valueSize
  ensureRead(b, valueSize)
  result = readFn(b)
  if b.pos < endPos:
    b.pos = endPos
  elif b.pos > endPos:
    raise newException(CatchableError,
      "readFieldValue: field reader consumed more bytes than field size")

# Generic decode helpers: iterate fields and dispatch to a caller-provided handler.
# Handler is responsible for reading field payload (using readFieldValue/read* helpers)
# but this helper will skip any remaining bytes if the handler reads less.
proc decodeRootInto*[T](b: var Buffer;
                        into: var T;
                        handleField: proc (fieldId: uint16; fieldSize: int; b: var Buffer; into: var T);
                        outVersion: var uint32) =
  ## Decodes a root struct from buffer `b` into `into` by iterating fields
  ## and invoking `handleField` for each field. `handleField` is responsible
  ## for reading the
  outVersion = beginReadRootStruct(b)
  while true:
    var fid: uint16
    var fsz: int
    if not readFieldHeader(b, fid, fsz): break
    let payloadStart = b.pos
    let payloadEnd = payloadStart + fsz
    # call user handler to decode payload (may read 0..fsz bytes)
    handleField(fid, fsz, b, into)
    # ensure we don't under- or over-consume field payload
    if b.pos < payloadEnd:
      b.pos = payloadEnd
    elif b.pos > payloadEnd:
      raise newException(CatchableError, "decodeRootInto: field handler consumed more bytes than field size")
  endReadRootStruct(b)

proc decodeInnerInto*[T](b: var Buffer;
                         into: var T;
                         handleField: proc (fieldId: uint16; fieldSize: int; b: var Buffer; into: var T);
                         outVersion: var uint32) =
  outVersion = beginReadInnerStruct(b)
  while true:
    var fid: uint16
    var fsz: int
    if not readFieldHeader(b, fid, fsz): break
    let payloadStart = b.pos
    let payloadEnd = payloadStart + fsz
    handleField(fid, fsz, b, into)
    if b.pos < payloadEnd:
      b.pos = payloadEnd
    elif b.pos > payloadEnd:
      raise newException(CatchableError, "decodeInnerInto: field handler consumed more bytes than field size")
  endReadInnerStruct(b)

#
# Symmetric encode helpers
#
proc encodeRootFrom*[T](b: var Buffer; `from`: T; writeFields: proc (b: var Buffer; `from`: T); version: uint32) =
  ## Encodes a root struct for `from` by invoking `writeFields` to emit fields.
  ## `writeFields` should call writeField(...) for each field it wants to emit.
  beginRootStruct(b, version)
  writeFields(b, `from`)
  endRootStruct(b)

proc encodeInnerFrom*[T](b: var Buffer; `from`: T; writeFields: proc (b: var Buffer; `from`: T); version: uint32) =
  ## Encodes an inner struct for `from` by invoking `writeFields`.
  beginInnerStruct(b, version)
  writeFields(b, `from`)
  endInnerStruct(b)


#
# High-level Nim-style API
#
proc encodeHook*(b: var Buffer; fieldId: uint16; v: string) =
  writeField(b, fieldId, proc (bb: var Buffer) = bb.writeString(v))

proc encodeHook*(b: var Buffer; fieldId: uint16; v: bool) =
  writeField(b, fieldId, proc (bb: var Buffer) = bb.writeBool(v))

proc encodeHook*(b: var Buffer; fieldId: uint16; v: int8) =
  writeField(b, fieldId, proc (bb: var Buffer) = bb.writeInt8(v))

proc encodeHook*(b: var Buffer; fieldId: uint16; v: uint8) =
  writeField(b, fieldId, proc (bb: var Buffer) = bb.writeByte(v))

proc encodeHook*(b: var Buffer; fieldId: uint16; v: int16) =
  writeField(b, fieldId, proc (bb: var Buffer) = bb.writeInt16LE(v))

proc encodeHook*(b: var Buffer; fieldId: uint16; v: uint16) =
  writeField(b, fieldId, proc (bb: var Buffer) = bb.writeUint16LE(v))

proc encodeHook*(b: var Buffer; fieldId: uint16; v: int32) =
  writeField(b, fieldId, proc (bb: var Buffer) = bb.writeInt32LE(v))

proc encodeHook*(b: var Buffer; fieldId: uint16; v: uint32) =
  writeField(b, fieldId, proc (bb: var Buffer) = bb.writeUint32LE(v))

proc encodeHook*(b: var Buffer; fieldId: uint16; v: int64) =
  writeField(b, fieldId, proc (bb: var Buffer) = bb.writeInt64LE(v))

proc encodeHook*(b: var Buffer; fieldId: uint16; v: uint64) =
  writeField(b, fieldId, proc (bb: var Buffer) = bb.writeUint64LE(v))

proc encodeHook*(b: var Buffer; fieldId: uint16; v: float32) =
  writeField(b, fieldId, proc (bb: var Buffer) = bb.writeFloat32LE(v))

proc encodeHook*(b: var Buffer; fieldId: uint16; v: float64) =
  writeField(b, fieldId, proc (bb: var Buffer) = bb.writeFloat64LE(v))

# seq of bytes as length-prefixed bytes
proc encodeHook*(b: var Buffer; fieldId: uint16; v: seq[uint8]) =
  writeField(b, fieldId, proc (bb: var Buffer) = bb.writeBytes(v))

# UUID (exact 16 bytes) helper
proc encodeHookUUID*(b: var Buffer; fieldId: uint16; v: openArray[uint8]) =
  writeField(b, fieldId, proc (bb: var Buffer) = bb.writeUUID(v))

# Decimal (16 bytes) helper
proc encodeHookDecimal*(b: var Buffer; fieldId: uint16; v: openArray[uint8]) =
  writeField(b, fieldId, proc (bb: var Buffer) = bb.writeDecimal(v))

# Generic vector hook: pass element writer
proc encodeHookVector*[T](b: var Buffer; fieldId: uint16; items: seq[T];
                          writeElem: proc (b: var Buffer; v: T)) =
  writeField(b, fieldId, proc (bb: var Buffer) = writeVector[T](bb, items, writeElem))

# Generic hook for distinct-like / other types where caller provides writer
proc encodeHookWith*[T](b: var Buffer; fieldId: uint16; v: T; writer: proc (b: var Buffer; x: T)) =
  writeField(b, fieldId, proc (bb: var Buffer) = writer(bb, v))

proc encode*[T](obj: T; version: uint32; fieldIdOf: proc (name: string): uint16): Buffer =
  ## Encodes `obj` as a root FBE buffer using `fieldIdOf` to map field names to ids.
  ## `fieldIdOf` should return 0 to skip a field.
  result = initBuffer()
  result.reset()
  beginRootStruct(result, version)
  var tmp: T
  for name, val, _ in fieldPairs(obj, tmp):
    let fid = fieldIdOf(name)
    if fid != 0'u16:
      encodeHook(result, fid, val)
  endRootStruct(result)

proc encode*[T](obj: T, version: uint32 = 1): Buffer =
  result = initBuffer()
  result.reset()
  beginRootStruct(result, version)
  var tmp: T
  var fid: uint16 = 1'u16
  for name, val, _ in fieldPairs(obj, tmp):
    # write every field using sequential ids; caller can skip by setting zero-length/defaults
    encodeHook(result, fid, val)
    fid = fid + 1'u16
  endRootStruct(result)

#
# Sequence overloads: encode seq[T] using element inner structs
#
proc encode*[T](items: seq[T]; version: uint32; fieldIdOf: proc (name: string): uint16): Buffer =
  ## Encodes a sequence of items; items are encoded as a vector inside field id=1.
  ## Each element is written as an inner struct using the provided fieldIdOf mapper.
  result = initBuffer()
  result.reset()
  beginRootStruct(result, version)
  writeField(result, 1'u16, proc (bb: var Buffer) =
    writeVector[T](bb, items, proc (bbb: var Buffer; it: T) =
      beginInnerStruct(bbb, version)
      var tmp: T
      for name, val, _ in fieldPairs(it, tmp):
        let fid = fieldIdOf(name)
        if fid != 0'u16:
          encodeHook(bbb, fid, val)
      endInnerStruct(bbb)
    )
  )
  endRootStruct(result)

proc encode*[T](items: seq[T]; version: uint32 = 1): Buffer =
  ## Encodes a sequence of items using automatic field ids (1..n) for each element.
  result = initBuffer()
  result.reset()
  beginRootStruct(result, version)
  writeField(result, 1'u16, proc (bb: var Buffer) =
    writeVector[T](bb, items, proc (bbb: var Buffer; it: T) =
      beginInnerStruct(bbb, version)
      var tmp: T
      var fid: uint16 = 1'u16
      for name, val, _ in fieldPairs(it, tmp):
        encodeHook(bbb, fid, val)
        fid = fid + 1'u16
      endInnerStruct(bbb)
    )
  )
  endRootStruct(result)


#
# Decode helpers
#
proc decode*[T](b: var Buffer; into: var T; fieldIdOf: proc (name: string): uint16; outVersion: var uint32) =
  ## High-level decode: fills `into` by mapping incoming field ids to field names
  ## using `fieldIdOf(name)`. Supports common primitive types and strings.
  var tmp: T
  proc handler(fieldId: uint16; fieldSize: int; bb: var Buffer; dest: var T) =
    # iterate fields of dest at compile-time to produce per-field checks
    for name, val, fld in fieldPairs(tmp, dest):
      let fid = fieldIdOf(name)
      if fid != 0'u16:
        if fieldId == fid:
          when typeof(val) is string:
            fld = readFieldValue[string](bb, fieldSize, proc (b2: var Buffer): string = b2.readString())
          elif typeof(val) is bool:
            fld = readFieldValue[bool](bb, fieldSize, proc (b2: var Buffer): bool = b2.readBool())
          elif typeof(val) is int8:
            fld = readFieldValue[int8](bb, fieldSize, proc (b2: var Buffer): int8 = b2.readInt8())
          elif typeof(val) is uint8:
            fld = readFieldValue[uint8](bb, fieldSize, proc (b2: var Buffer): uint8 = b2.readByte())
          elif typeof(val) is int16:
            fld = readFieldValue[int16](bb, fieldSize, proc (b2: var Buffer): int16 = b2.readInt16LE())
          elif typeof(val) is uint16:
            fld = readFieldValue[uint16](bb, fieldSize, proc (b2: var Buffer): uint16 = b2.readUint16LE())
          elif typeof(val) is int32:
            fld = readFieldValue[int32](bb, fieldSize, proc (b2: var Buffer): int32 = b2.readInt32LE())
          elif typeof(val) is uint32:
            fld = readFieldValue[uint32](bb, fieldSize, proc (b2: var Buffer): uint32 = b2.readUint32LE())
          elif typeof(val) is int64:
            fld = readFieldValue[int64](bb, fieldSize, proc (b2: var Buffer): int64 = b2.readInt64LE())
          elif typeof(val) is uint64:
            fld = readFieldValue[uint64](bb, fieldSize, proc (b2: var Buffer): uint64 = b2.readUint64LE())
          elif typeof(val) is float32:
            fld = readFieldValue[float32](bb, fieldSize, proc (b2: var Buffer): float32 = b2.readFloat32LE())
          elif typeof(val) is float64:
            fld = readFieldValue[float64](bb, fieldSize, proc (b2: var Buffer): float64 = b2.readFloat64LE())
          elif typeof(val) is seq[uint8]:
            fld = readFieldValue[seq[uint8]](bb, fieldSize, proc (b2: var Buffer): seq[uint8] = b2.readBytes())
          else:
            # unsupported high-level type -> skip (decodeRootInto will advance if handler reads less)
            discard

  decodeRootInto(b, into, handler, outVersion)

proc decode*[T](b: var Buffer; into: var T; outVersion: var uint32) =
  ## High-level decode using auto-assigned field ids (1..n) by declaration order.
  var tmp: T
  proc handler(fieldId: uint16; fieldSize: int; bb: var Buffer; dest: var T) =
    var fidIdx: uint16 = 1'u16
    for name, val, fld in fieldPairs(tmp, dest):
      if fieldId == fidIdx:
        when typeof(val) is string:
          fld = readFieldValue[string](bb, fieldSize, proc (b2: var Buffer): string = b2.readString())
        elif typeof(val) is bool:
          fld = readFieldValue[bool](bb, fieldSize, proc (b2: var Buffer): bool = b2.readBool())
        elif typeof(val) is int8:
          fld = readFieldValue[int8](bb, fieldSize, proc (b2: var Buffer): int8 = b2.readInt8())
        elif typeof(val) is uint8:
          fld = readFieldValue[uint8](bb, fieldSize, proc (b2: var Buffer): uint8 = b2.readByte())
        elif typeof(val) is int16:
          fld = readFieldValue[int16](bb, fieldSize, proc (b2: var Buffer): int16 = b2.readInt16LE())
        elif typeof(val) is uint16:
          fld = readFieldValue[uint16](bb, fieldSize, proc (b2: var Buffer): uint16 = b2.readUint16LE())
        elif typeof(val) is int32:
          fld = readFieldValue[int32](bb, fieldSize, proc (b2: var Buffer): int32 = b2.readInt32LE())
        elif typeof(val) is uint32:
          fld = readFieldValue[uint32](bb, fieldSize, proc (b2: var Buffer): uint32 = b2.readUint32LE())
        elif typeof(val) is int64:
          fld = readFieldValue[int64](bb, fieldSize, proc (b2: var Buffer): int64 = b2.readInt64LE())
        elif typeof(val) is uint64:
          fld = readFieldValue[uint64](bb, fieldSize, proc (b2: var Buffer): uint64 = b2.readUint64LE())
        elif typeof(val) is float32:
          fld = readFieldValue[float32](bb, fieldSize, proc (b2: var Buffer): float32 = b2.readFloat32LE())
        elif typeof(val) is float64:
          fld = readFieldValue[float64](bb, fieldSize, proc (b2: var Buffer): float64 = b2.readFloat64LE())
        elif typeof(val) is seq[uint8]:
          fld = readFieldValue[seq[uint8]](bb, fieldSize, proc (b2: var Buffer): seq[uint8] = b2.readBytes())
        else:
          discard
      fidIdx.inc()

  decodeRootInto(b, into, handler, outVersion)

  #
  # Final 
  #

const
  FINAL_ROOT_HEADER_SIZE* = 8
  FINAL_INNER_HEADER_SIZE* = 0

proc beginFinalRootStruct*(b: var Buffer) =
  ensureStructStackInit(b)
  let startPos = b.data.len
  # totalSize placeholder
  writeUint32LE(b, 0'u32)
  # reserved
  writeUint32LE(b, 0'u32)
  var ctx: StructCtx
  ctx.startPos = startPos
  ctx.headerPos = startPos
  ctx.fieldCountPos = -1
  ctx.fieldCount = 0'u32
  ctx.readFieldsLeft = 0
  ctx.version = 0
  ctx.isRoot = true
  b.structStack.add(ctx)

proc endFinalRootStruct*(b: var Buffer) =
  if b.structStack.len == 0:
    raise newException(CatchableError, "endFinalRootStruct: no struct context")
  var ctx = b.structStack[^1]
  if not ctx.isRoot:
    raise newException(CatchableError, "endFinalRootStruct: top context is not root")
  let totalSize = uint32(b.data.len - ctx.startPos)
  patchUint32At(b, ctx.headerPos, totalSize)
  b.structStack.del(b.structStack.len-1)

proc beginFinalInnerStruct*(b: var Buffer) =
  ## Final inner struct: no header emitted. Push a context to optionally check bounds in nested cases.
  ensureStructStackInit(b)
  var ctx: StructCtx
  ctx.startPos = b.data.len
  ctx.headerPos = ctx.startPos
  ctx.fieldCountPos = -1
  ctx.fieldCount = 0'u32
  ctx.readFieldsLeft = 0
  ctx.version = 0
  ctx.isRoot = false
  b.structStack.add(ctx)

proc endFinalInnerStruct*(b: var Buffer) =
  if b.structStack.len == 0:
    raise newException(CatchableError, "endFinalInnerStruct: no struct context")
  var ctx = b.structStack[^1]
  if ctx.isRoot:
    raise newException(CatchableError, "endFinalInnerStruct: top context is root")
  b.structStack.del(b.structStack.len-1)

proc beginReadFinalRootStruct*(b: var Buffer): uint32 =
  ensureRead(b, FINAL_ROOT_HEADER_SIZE)
  let totalSize = readUint32LE(b)
  let reserved = readUint32LE(b)
  ensureStructStackInit(b)
  var ctx: StructCtx
  ctx.startPos = b.pos - FINAL_ROOT_HEADER_SIZE
  ctx.headerPos = ctx.startPos
  ctx.fieldCountPos = -1
  ctx.fieldCount = 0'u32
  let payloadBytes = int(totalSize) - FINAL_ROOT_HEADER_SIZE
  if payloadBytes < 0:
    raise newException(CatchableError, "beginReadFinalRootStruct: invalid total size")
  ctx.readFieldsLeft = payloadBytes
  ctx.version = 0
  ctx.isRoot = true
  ctx.totalSize = int(totalSize)
  b.structStack.add(ctx)
  result = uint32(payloadBytes)

proc endReadFinalRootStruct*(b: var Buffer) =
  if b.structStack.len == 0:
    raise newException(CatchableError, "endReadFinalRootStruct: no struct context")
  var ctx = b.structStack[^1]
  if not ctx.isRoot:
    raise newException(CatchableError, "endReadFinalRootStruct: top context is not root")
  # ensure we've consumed exactly the root payload
  let expectedEnd = ctx.startPos + ctx.totalSize
  # we can't re-read totalSize here safely — instead compute end from stack
  # totalSize = current buffer length - ctx.startPos (if buffer built by us)
  # For reader case: ensure pos is at ctx.startPos + totalSize
  # But we don't have totalSize stored; check by using ctx.readFieldsLeft and pos
  let consumed = b.pos - (ctx.startPos + FINAL_ROOT_HEADER_SIZE)
  if consumed < ctx.readFieldsLeft:
    # skip remaining bytes
    b.pos = b.pos + (ctx.readFieldsLeft - consumed)
  elif consumed > ctx.readFieldsLeft:
    raise newException(CatchableError,
      "endReadFinalRootStruct: read more than structure size")
  b.structStack.del(b.structStack.len-1)

template writeFinalFields(b, obj: untyped) =
  ## Emit direct writes for each field of `obj` (final/compact layout).
  var tmp: typeof(obj)
  for name, val, fld in fieldPairs(tmp, obj):
    when typeof(val) is string:
      b.writeString(fld)
    elif typeof(val) is bool:
      b.writeBool(fld)
    elif typeof(val) is int8:
      b.writeInt8(fld)
    elif typeof(val) is uint8:
      b.writeByte(fld)
    elif typeof(val) is int16:
      b.writeInt16LE(fld)
    elif typeof(val) is uint16:
      b.writeUint16LE(fld)
    elif typeof(val) is int32:
      b.writeInt32LE(fld)
    elif typeof(val) is uint32:
      b.writeUint32LE(fld)
    elif typeof(val) is int64:
      b.writeInt64LE(fld)
    elif typeof(val) is uint64:
      b.writeUint64LE(fld)
    elif typeof(val) is float32:
      b.writeFloat32LE(fld)
    elif typeof(val) is float64:
      b.writeFloat64LE(fld)
    elif typeof(val) is seq[uint8]:
      b.writeBytes(fld)
    else:
      # unsupported type -> compile-time skip
      discard

template readFinalFields(b, obj: untyped) =
  ## Emit direct reads/assigns for each field of `obj` (final/compact layout).
  var tmp: typeof(obj)
  for name, val, fld in fieldPairs(tmp, obj):
    when typeof(val) is string:
      fld = b.readString()
    elif typeof(val) is bool:
      fld = b.readBool()
    elif typeof(val) is int8:
      fld = b.readInt8()
    elif typeof(val) is uint8:
      fld = b.readByte()
    elif typeof(val) is int16:
      fld = b.readInt16LE()
    elif typeof(val) is uint16:
      fld = b.readUint16LE()
    elif typeof(val) is int32:
      fld = b.readInt32LE()
    elif typeof(val) is uint32:
      fld = b.readUint32LE()
    elif typeof(val) is int64:
      fld = b.readInt64LE()
    elif typeof(val) is uint64:
      fld = b.readUint64LE()
    elif typeof(val) is float32:
      fld = b.readFloat32LE()
    elif typeof(val) is float64:
      fld = b.readFloat64LE()
    elif typeof(val) is seq[uint8]:
      fld = b.readBytes()
    else:
      discard

# High-level compact encode/decode: fields written sequentially in declaration order.
proc encodeFinal*[T](obj: T): Buffer =
  result = initBuffer()
  result.reset()
  beginFinalRootStruct(result)
  # expand compile-time direct writers
  writeFinalFields(result, obj)
  endFinalRootStruct(result)

proc decodeFinal*[T](b: var Buffer; into: var T) =
  var tmp: T
  let payloadBytes = beginReadFinalRootStruct(b)
  # expand compile-time direct readers
  readFinalFields(b, into)
  # pop final root context
  if b.structStack.len > 0:
    b.structStack.del(b.structStack.len-1)

proc encodeFinal*[T](items: seq[T]): Buffer =
  result = initBuffer()
  result.reset()
  beginFinalRootStruct(result)
  writeUint32LE(result, uint32(items.len))
  for it in items:
    # inline per-item writes (no inner header)
    writeFinalFields(result, it)
  endFinalRootStruct(result)

proc decodeFinal*[T](b: var Buffer; into: var seq[T]) =
  let payloadBytes = beginReadFinalRootStruct(b)
  let n = int(b.readUint32LE())
  into.setLen(n)
  for i in 0..<n:
    var item: T
    readFinalFields(b, item)
    into[i] = item
  if b.structStack.len > 0:
    b.structStack.del(b.structStack.len-1)