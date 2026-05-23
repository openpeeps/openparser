# A collection of tiny parsers and dumpers
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/openparser

## UUID implementation supporting versions 1-8 per RFC 4122 and newer drafts.

import std/[times, random, strutils,
        endians, sha1, md5, sysrand, hashes]

type
  UuidBytes* = array[16, byte]

  Uuid* = object
    bytes*: UuidBytes

  UuidVersion* = enum
    uuidV1 = 1
    uuidV2 = 2
    uuidV3 = 3
    uuidV4 = 4
    uuidV5 = 5
    uuidV6 = 6
    uuidV7 = 7
    uuidV8 = 8

  UuidVariant* = enum
    variantNCS       ## NCS backward compatibility
    variantRFC4122   ## RFC 4122
    variantMicrosoft ## Microsoft backward compatibility
    variantFuture    ## Future definition

  UuidNamespace* = enum
    nsDNS  = "6ba7b810-9dad-11d1-80b4-00c04fd430c8"
    nsURL  = "6ba7b811-9dad-11d1-80b4-00c04fd430c8"
    nsOID  = "6ba7b812-9dad-11d1-80b4-00c04fd430c8"
    nsX500 = "6ba7b814-9dad-11d1-80b4-00c04fd430c8"

  UuidError* = object of ValueError

# Helpers ──

proc setVersion(b: var UuidBytes, version: int) {.inline.} =
  b[6] = (b[6] and 0x0F'u8) or (byte(version) shl 4)

proc setVariant(b: var UuidBytes) {.inline.} =
  b[8] = (b[8] and 0x3F'u8) or 0x80'u8

proc toHex(b: byte): string {.inline.} =
  toHex(int(b), 2).toLowerAscii()

# String conversion ──

proc `$`*(u: Uuid): string =
  ## Format UUID as xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
  let b = u.bytes
  result = newStringOfCap(36)
  for i in 0..3:  result.add toHex(b[i])
  result.add '-'
  for i in 4..5:  result.add toHex(b[i])
  result.add '-'
  for i in 6..7:  result.add toHex(b[i])
  result.add '-'
  for i in 8..9:  result.add toHex(b[i])
  result.add '-'
  for i in 10..15: result.add toHex(b[i])

proc parseUuid*(s: string): Uuid =
  ## Parse a UUID string (with or without dashes).
  var clean = s.replace("-", "")
  if clean.len != 32:
    raise newException(UuidError, "Invalid UUID string: " & s)
  for i in 0..15:
    result.bytes[i] = byte(parseHexInt(clean[i*2 .. i*2+1]))

proc isValidUuid*(s: string): bool =
  try:
    discard parseUuid(s)
    true
  except UuidError:
    false

# Introspection 

proc version*(u: Uuid): int =
  ## Extract the version number from a UUID.
  int((u.bytes[6] and 0xF0'u8) shr 4)

proc variant*(u: Uuid): UuidVariant =
  ## Extract the variant from a UUID.
  let b = u.bytes[8]
  if   (b and 0x80'u8) == 0x00'u8: variantNCS
  elif (b and 0xC0'u8) == 0x80'u8: variantRFC4122
  elif (b and 0xE0'u8) == 0xC0'u8: variantMicrosoft
  else:                              variantFuture

proc isNil*(u: Uuid): bool =
  ## Check if UUID is the nil UUID (all zeros).
  for b in u.bytes:
    if b != 0: return false
  true

# Version 1 – Time-based ──

proc newUuidV1*(node: array[6, byte] = [0'u8,0,0,0,0,0]): Uuid =
  ## Version 1: time-based UUID using 100-ns intervals since Oct 15, 1582.
  ## Pass a MAC address as `node`, or leave blank for a random node.
  const gregorianOffset = 0x01B21DD213814000'u64
  let now = getTime()
  let ts  = uint64(now.toUnix()) * 10_000_000'u64 +
            uint64(now.nanosecond div 100) + gregorianOffset

  var b: UuidBytes
  var tsBytes: array[8, byte]
  bigEndian64(addr tsBytes[0], unsafeAddr ts)
  # time_low (32 bits) – bytes 4..7 of big-endian ts
  b[0] = tsBytes[4]; b[1] = tsBytes[5]; b[2] = tsBytes[6]; b[3] = tsBytes[7]
  # time_mid (16 bits) – bytes 2..3
  b[4] = tsBytes[2]; b[5] = tsBytes[3]
  # time_hi (16 bits) – bytes 0..1
  b[6] = tsBytes[0]; b[7] = tsBytes[1]

  var rng = initRand(now.toUnixFloat().int64)
  let clkSeq = uint16(rng.rand(0x3FFF))
  b[8] = byte(clkSeq shr 8)
  b[9] = byte(clkSeq and 0xFF)

  var n = node
  if n == [0'u8,0,0,0,0,0]:
    discard urandom(toOpenArray(n, 0, 5))
    n[0] = n[0] or 0x01'u8
  for i in 0..5: b[10+i] = n[i]

  b.setVersion(1)
  b.setVariant()
  result.bytes = b

# Version 2 – DCE Security 

proc newUuidV2*(domain: byte, localId: uint32): Uuid =
  ## Version 2: DCE Security UUID.
  ## domain: 0=person, 1=group, 2=org. localId: UID/GID value.
  result = newUuidV1()
  var b = result.bytes
  # Replace time_low with localId
  bigEndian32(addr b[0], unsafeAddr localId)
  b[9] = domain
  b.setVersion(2)
  b.setVariant()
  result.bytes = b

# Version 3 – Name-based MD5 ─

proc newUuidV3*(namespace: Uuid, name: string): Uuid =
  ## Version 3: MD5 name-based UUID.
  var ctx: MD5Context
  md5Init(ctx)
  md5Update(ctx, cast[cstring](unsafeAddr namespace.bytes[0]), 16)
  md5Update(ctx, cstring(name), name.len)
  var digest: MD5Digest
  md5Final(ctx, digest)
  for i in 0..15: result.bytes[i] = digest[i]
  result.bytes.setVersion(3)
  result.bytes.setVariant()

proc newUuidV3*(ns: UuidNamespace, name: string): Uuid =
  newUuidV3(parseUuid($ns), name)

# Version 4 – Random 

proc newUuidV4*(): Uuid =
  ## Version 4: cryptographically random UUID.
  if not urandom(result.bytes):
    raise newException(UuidError, "Failed to generate random bytes")
  result.bytes.setVersion(4)
  result.bytes.setVariant()

# Version 5 – Name-based SHA-1 ──

proc newUuidV5*(namespace: Uuid, name: string): Uuid =
  ## Version 5: SHA-1 name-based UUID.
  var ctx = newSha1State()
  ctx.update(cast[string](namespace.bytes))
  ctx.update(name)
  let digest = ctx.finalize()
  # SHA-1 produces 20 bytes; use first 16
  let raw = array[20, byte](digest)
  for i in 0..15: result.bytes[i] = raw[i]
  result.bytes.setVersion(5)
  result.bytes.setVariant()

proc newUuidV5*(ns: UuidNamespace, name: string): Uuid =
  newUuidV5(parseUuid($ns), name)

# Version 6 – Reordered Time-based ─

proc newUuidV6*(node: array[6, byte] = [0'u8,0,0,0,0,0]): Uuid =
  ## Version 6: reordered timestamp for better lexicographic ordering.
  const gregorianOffset = 0x01B21DD213814000'u64
  let now = getTime()
  let ts  = uint64(now.toUnix()) * 10_000_000'u64 +
            uint64(now.nanosecond div 100) + gregorianOffset

  var b: UuidBytes
  # Reorder: top 48 bits first, then version nibble, then low 12 bits
  let msb = (ts shr 12) and 0xFFFFFFFFFFFF'u64
  let lsb = ts and 0xFFF'u64

  b[0] = byte((msb shr 40) and 0xFF)
  b[1] = byte((msb shr 32) and 0xFF)
  b[2] = byte((msb shr 24) and 0xFF)
  b[3] = byte((msb shr 16) and 0xFF)
  b[4] = byte((msb shr  8) and 0xFF)
  b[5] = byte( msb         and 0xFF)
  b[6] = byte((lsb shr  8) and 0xFF)
  b[7] = byte( lsb         and 0xFF)

  var rng = initRand(now.toUnixFloat().int64)
  let clkSeq = uint16(rng.rand(0x3FFF))
  b[8] = byte(clkSeq shr 8)
  b[9] = byte(clkSeq and 0xFF)

  var n = node
  if n == [0'u8,0,0,0,0,0]:
    discard urandom(toOpenArray(n, 0, 5))
    n[0] = n[0] or 0x01'u8
  for i in 0..5: b[10+i] = n[i]

  b.setVersion(6)
  b.setVariant()
  result.bytes = b

# Version 7 – Unix Epoch Time-based 

proc newUuidV7*(): Uuid =
  ## Version 7: Unix timestamp ms in top 48 bits + random lower bits.
  let now     = getTime()
  let unixMs  = uint64(now.toUnix()) * 1000'u64 + uint64(now.nanosecond div 1_000_000)

  var b: UuidBytes
  if not urandom(b):
    raise newException(UuidError, "Failed to generate random bytes")

  # Overwrite top 48 bits with Unix timestamp in ms
  b[0] = byte((unixMs shr 40) and 0xFF)
  b[1] = byte((unixMs shr 32) and 0xFF)
  b[2] = byte((unixMs shr 24) and 0xFF)
  b[3] = byte((unixMs shr 16) and 0xFF)
  b[4] = byte((unixMs shr  8) and 0xFF)
  b[5] = byte( unixMs         and 0xFF)

  b.setVersion(7)
  b.setVariant()
  result.bytes = b

# Version 8 – Custom 

proc newUuidV8*(data: UuidBytes): Uuid =
  ## Version 8: custom/application-defined UUID.
  ## The caller provides 128 bits of custom data; version/variant bits are set.
  result.bytes = data
  result.bytes.setVersion(8)
  result.bytes.setVariant()

# Nil UUID ─

proc nilUuid*(): Uuid =
  ## Returns the nil UUID (all zeros).
  discard  # zero-initialized by default

# Equality ─

proc `==`*(a, b: Uuid): bool = a.bytes == b.bytes

proc hash*(u: Uuid): Hash =
  hash(u.bytes)


#
# Convenience aliases for common use cases
# 
proc v1*(node: array[6, byte] = [0'u8,0,0,0,0,0]): Uuid {.inline.} = newUuidV1(node)
proc v2*(domain: byte, localId: uint32): Uuid {.inline.} = newUuidV2(domain, localId)
proc v3*(namespace: Uuid, name: string): Uuid {.inline.} = newUuidV3(namespace, name)
proc v3*(ns: UuidNamespace, name: string): Uuid {.inline.} = newUuidV3(ns, name)
proc v4*(): Uuid {.inline.} = newUuidV4()
proc v5*(namespace: Uuid, name: string): Uuid {.inline.} = newUuidV5(namespace, name)
proc v5*(ns: UuidNamespace, name: string): Uuid {.inline.} = newUuidV5(ns, name)
proc v6*(node: array[6, byte] = [0'u8,0,0,0,0,0]): Uuid {.inline.} = newUuidV6(node)
proc v7*(): Uuid {.inline.} = newUuidV7()
proc v8*(data: UuidBytes): Uuid {.inline.} = newUuidV8(data)