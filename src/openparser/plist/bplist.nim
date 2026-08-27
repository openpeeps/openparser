import std/[json, strutils, sequtils, base64, tables, times, math, unicode, algorithm]
import ./common

type
  BPlistParser = object
    data: seq[byte]
    offsetTable: seq[int]
    offsetIntSize: int
    objectRefSize: int
    numObjects: int
    topObject: int
    opts: PlistOptions
    depth: int
    cache: seq[JsonNode]  # memoised decoded objects, nil = not yet decoded
    decodingStack: seq[int] # for cycle detection

proc bplistError(msg: string) =
  raise newException(PlistError, msg)

proc checkDepth(p: var BPlistParser) =
  if p.opts != nil and p.opts.maxDepth > 0 and p.depth > p.opts.maxDepth:
    bplistError("Plist maxDepth exceeded")

proc readIntBE(p: BPlistParser, pos, nbytes: int): int64 =
  ensure(p.data.len, pos, nbytes)
  var v: int64 = 0
  for i in 0..<nbytes:
    v = (v shl 8) or int64(p.data[pos+i])
  # sign-extend for 1,2,4 byte signed? Spec says 1/2/4 unsigned, 8 signed. We interpret as signed for len > 1?
  # For 1 byte: interpret as signed int8 if needed? Apple writes unsigned but values < 128 so fine.
  # For 2/4 bytes, if high bit set and size < 8, sign-extend negative? But 8-byte is signed.
  # We'll treat 8-byte as signed int64 via cast, 16-byte as big int -> overflow.
  # For simplicity, if nbytes == 1 treat as int8? Use unsigned for 1,2,4 then allow negative via 8-byte only.
  # Perform sign extension for 8 bytes already signed.
  # For smaller sizes, keep as unsigned unless caller expects signed – but plist ints are signed.
  # If value was negative, writer uses 8 bytes, so not needed for 1/2/4.
  v

proc readDoubleBE(p: BPlistParser, pos: int): float64 =
  ensure(p.data.len, pos, 8)
  var u: uint64 = readUInt64BE(p.data, pos)
  var f: float64
  copyMem(addr f, addr u, 8)
  # need to swap endian? readUInt64BE already assembled big-endian into host uint64 bits, but copyMem expects host order bits equal to float bits.
  # On little-endian, bits of float are little-endian representation, but we assembled big-endian integer bits.
  # So we must reverse bytes if host is little endian.
  # Instead, read as bytes big-endian double via manual.
  # Our readUInt64BE assembled val as big-endian integer. For float, we need to interpret those bytes as IEEE754 BE.
  # So we can byte-swap to host if little endian.
  when cpuEndian == littleEndian:
    # swap
    var swapped: uint64 = 0
    for i in 0..<8:
      swapped = (swapped shl 8) or (u and 0xFF) # wrong already shl? Simpler: use bytes.
    # Instead do byte reversal via builtin?
    var bytes: array[8, byte]
    copyMem(addr bytes[0], addr u, 8) # u is already host order of BE integer, bytes are BE? This is messy.
    # Let's directly read bytes and assemble float via swap
    discard
  f = cast[float64](u) # placeholder
  # Simpler: read bytes directly and swap if LE
  var bytesBE: array[8, byte]
  for i in 0..<8: bytesBE[i] = p.data[pos+i]
  when cpuEndian == littleEndian:
    var bytesLE: array[8, byte]
    for i in 0..<8: bytesLE[i] = bytesBE[7-i]
    copyMem(addr f, addr bytesLE[0], 8)
  else:
    copyMem(addr f, addr bytesBE[0], 8)
  f

proc readFloatBE(p: BPlistParser, pos: int): float64 =
  ensure(p.data.len, pos, 4)
  var bytesBE: array[4, byte]
  for i in 0..<4: bytesBE[i] = p.data[pos+i]
  var f: float32
  when cpuEndian == littleEndian:
    var bytesLE: array[4, byte]
    for i in 0..<4: bytesLE[i] = bytesBE[3-i]
    copyMem(addr f, addr bytesLE[0], 4)
  else:
    copyMem(addr f, addr bytesBE[0], 4)
  float64(f)

proc readSizedInt(p: BPlistParser, pos: var int): int =
  # reads integer object at pos (marker 0x10-0x13) and advances pos past it, returns int value
  if pos >= p.data.len: bplistError("truncated sized int")
  let marker = p.data[pos]
  if (marker and 0xF0) != 0x10:
    bplistError("expected integer marker for count, got " & $marker)
  let n = 1 shl (marker and 0x0F)
  if n notin [1,2,4,8,16]:
    bplistError("invalid int size")
  if n == 16:
    bplistError("128-bit integer not supported")
  inc pos
  ensure(p.data.len, pos, n)
  let v = p.readIntBE(pos, n)
  pos += n
  int(v)

proc decodeBplistObject(p: var BPlistParser, idx: int): JsonNode

proc decodeCountAndAdvance(p: var BPlistParser, marker: byte, pos: var int): int =
  let low = marker and 0x0F
  if low != 0x0F:
    return int(low)
  # extended count -> integer object follows
  result = p.readSizedInt(pos)

proc decodeBplistObjectByPos(p: var BPlistParser, pos: int, outNextPos: var int): JsonNode =
  if pos >= p.data.len: bplistError("object offset out of range")
  let marker = p.data[pos]
  let typ = marker shr 4
  var cur = pos + 1
  case typ
  of 0x0: # null/false/true/fill
    outNextPos = cur
    if marker == 0x00: return newJNull()
    elif marker == 0x08: return newJBool(false)
    elif marker == 0x09: return newJBool(true)
    elif marker == 0x0F: return newJNull() # fill
    else: bplistError("unknown null/false/true marker " & $marker)
  of 0x1: # int
    let n = 1 shl (marker and 0x0F)
    if n == 16: bplistError("128-bit int unsupported")
    ensure(p.data.len, cur, n)
    let v = p.readIntBE(cur, n)
    outNextPos = cur + n
    # For 1/2/4 bytes, writer uses unsigned; but we treat as signed via 8-byte sign extension logic?
    # If value was > max int64 positive, keep as is; for small n keep unsigned value.
    # If high bit set for 1-byte 0xFF (-1) but stored as 1 byte 0xFF, our read returns 255 not -1.
    # However spec says negative ints for 1/2/4 are emitted as 8 bytes, so 1-byte negative shouldn't appear.
    # So return as int.
    return newJInt(v)
  of 0x2: # real
    let n = 1 shl (marker and 0x0F)
    if n == 4:
      let f = p.readFloatBE(cur)
      outNextPos = cur + 4
      return newJFloat(f)
    elif n == 8:
      let f = p.readDoubleBE(cur)
      outNextPos = cur + 8
      return newJFloat(f)
    else:
      bplistError("invalid real size " & $n)
  of 0x3: # date 0x33 only
    if marker != 0x33: bplistError("invalid date marker " & $marker)
    let f = p.readDoubleBE(cur)
    outNextPos = cur + 8
    # CF epoch -> unix
    let unixSecs = f + 978307200.0
    # Keep as ISO8601 string for JsonNode
    let dt = fromUnix(int64(unixSecs)).utc
    let iso = dt.format("yyyy-MM-dd'T'HH:mm:ss'Z'")
    return newJString(iso)
  of 0x4: # data
    let count = p.decodeCountAndAdvance(marker, cur)
    ensure(p.data.len, cur, count)
    var raw = newString(count)
    for i in 0..<count: raw[i] = char(p.data[cur+i])
    outNextPos = cur + count
    # dataAsBase64: encode to base64 string for JsonNode
    let b64 = base64.encode(raw)
    return newJString(b64)
  of 0x5: # ascii string
    let count = p.decodeCountAndAdvance(marker, cur)
    ensure(p.data.len, cur, count)
    var s = newString(count)
    for i in 0..<count: s[i] = char(p.data[cur+i])
    outNextPos = cur + count
    return newJString(s)
  of 0x6: # utf16
    let count = p.decodeCountAndAdvance(marker, cur)
    ensure(p.data.len, cur, count*2)
    var outStr = newStringOfCap(count*3)
    var i = 0
    while i < count:
      let hi = p.data[cur + i*2]
      let lo = p.data[cur + i*2+1]
      let cp = (int(hi) shl 8) or int(lo)
      if cp >= 0xD800 and cp <= 0xDBFF and i+1 < count:
        let hi2 = p.data[cur + (i+1)*2]
        let lo2 = p.data[cur + (i+1)*2+1]
        let cp2 = (int(hi2) shl 8) or int(lo2)
        if cp2 >= 0xDC00 and cp2 <= 0xDFFF:
          let codepoint = 0x10000 + ((cp - 0xD800) shl 10) + (cp2 - 0xDC00)
          outStr.add(Rune(codepoint).toUTF8)
          i += 2
          continue
      if cp < 0x80:
        outStr.add(char(cp))
      elif cp < 0x800:
        outStr.add(char(0xC0 or (cp shr 6)))
        outStr.add(char(0x80 or (cp and 0x3F)))
      elif cp < 0xD800 or cp >= 0xE000:
        outStr.add(char(0xE0 or (cp shr 12)))
        outStr.add(char(0x80 or ((cp shr 6) and 0x3F)))
        outStr.add(char(0x80 or (cp and 0x3F)))
      else:
        outStr.add('?')
      inc i
    outNextPos = cur + count*2
    return newJString(outStr)
  of 0x7: # utf8 v1?
    let count = p.decodeCountAndAdvance(marker, cur)
    ensure(p.data.len, cur, count)
    var s = newString(count)
    for i in 0..<count: s[i] = char(p.data[cur+i])
    outNextPos = cur + count
    return newJString(s)
  of 0x8: # uid
    let n = int(marker and 0x0F) + 1
    ensure(p.data.len, cur, n)
    var v: uint64 = 0
    for i in 0..<n: v = (v shl 8) or uint64(p.data[cur+i])
    outNextPos = cur + n
    var obj = newJObject()
    obj[plistCFUIDKey] = newJInt(int64(v))
    return obj
  of 0xA: # array
    let count = p.decodeCountAndAdvance(marker, cur)
    ensure(p.data.len, cur, count * p.objectRefSize)
    result = newJArray()
    var refs = newSeq[int](count)
    for i in 0..<count:
      var r: int = 0
      for b in 0..<p.objectRefSize:
        r = (r shl 8) or int(p.data[cur+b])
      cur += p.objectRefSize
      refs[i] = r
    outNextPos = cur
    # depth check
    inc p.depth; p.checkDepth()
    for r in refs:
      if r < 0 or r >= p.numObjects: bplistError("array ref out of range")
      result.add(p.decodeBplistObject(r))
    dec p.depth
    return result
  of 0xC, 0xB: # set / ordset (treat as array)
    let count = p.decodeCountAndAdvance(marker, cur)
    ensure(p.data.len, cur, count * p.objectRefSize)
    result = newJArray()
    var refs = newSeq[int](count)
    for i in 0..<count:
      var r: int = 0
      for b in 0..<p.objectRefSize:
        r = (r shl 8) or int(p.data[cur+b])
      cur += p.objectRefSize
      refs[i]=r
    outNextPos = cur
    inc p.depth; p.checkDepth()
    for r in refs: result.add(p.decodeBplistObject(r))
    dec p.depth
    return result
  of 0xD: # dict
    let count = p.decodeCountAndAdvance(marker, cur)
    ensure(p.data.len, cur, count*2 * p.objectRefSize)
    var keyRefs = newSeq[int](count)
    var valRefs = newSeq[int](count)
    for i in 0..<count:
      var r: int = 0
      for b in 0..<p.objectRefSize:
        r = (r shl 8) or int(p.data[cur+b])
      cur += p.objectRefSize
      keyRefs[i]=r
    for i in 0..<count:
      var r: int = 0
      for b in 0..<p.objectRefSize:
        r = (r shl 8) or int(p.data[cur+b])
      cur += p.objectRefSize
      valRefs[i]=r
    outNextPos = cur
    result = newJObject()
    inc p.depth; p.checkDepth()
    for i in 0..<count:
      let kNode = p.decodeBplistObject(keyRefs[i])
      if kNode.kind != JString:
        # plist spec says keys must be strings – permissive: coerce via $kNode
        let keyStr = if kNode.kind == JString: kNode.getStr else: $kNode
        let vNode = p.decodeBplistObject(valRefs[i])
        if result.hasKey(keyStr) and p.opts != nil and not p.opts.allowDuplicateKeys:
          bplistError("duplicate key " & keyStr)
        result[keyStr] = vNode
      else:
        let keyStr = kNode.getStr
        let vNode = p.decodeBplistObject(valRefs[i])
        if result.hasKey(keyStr) and p.opts != nil and not p.opts.allowDuplicateKeys:
          bplistError("duplicate key " & keyStr)
        result[keyStr] = vNode
    dec p.depth
    return result
  else:
    bplistError("unknown bplist marker " & $marker & " typ " & $typ)

proc decodeBplistObject(p: var BPlistParser, idx: int): JsonNode =
  if idx < 0 or idx >= p.numObjects: bplistError("object idx out of range")
  if p.cache[idx] != nil:
    return p.cache[idx]
  if idx in p.decodingStack:
    bplistError("bplist cycle detected")
  p.decodingStack.add(idx)
  let off = p.offsetTable[idx]
  var nextPos = 0
  let node = p.decodeBplistObjectByPos(off, nextPos)
  p.cache[idx] = node
  discard p.decodingStack.pop()
  node

proc parseBPlistData(data: seq[byte], opts: PlistOptions): JsonNode =
  if data.len < 8+32:
    bplistError("bplist too short")
  # header
  let header = cast[string](data[0..5])
  if header != "bplist":
    bplistError("invalid bplist header")
  let ver = cast[string](data[6..7])
  if ver != "00":
    # accept bplist0? permissive: allow any where starts with "0"
    if ver[0] != '0':
      bplistError("unsupported bplist version " & ver)
  let trailerStart = data.len - 32
  # trailer: 5 unused, sortVersion, offsetIntSize, objectRefSize, numObjects, topObject, offsetTableOffset
  let offsetIntSize = int(data[trailerStart+6])
  let objectRefSize = int(data[trailerStart+7])
  let numObjects = int(readUInt64BE(data, trailerStart+8))
  let topObject = int(readUInt64BE(data, trailerStart+16))
  let offsetTableOffset = int(readUInt64BE(data, trailerStart+24))
  if offsetIntSize notin [1,2,4,8]: bplistError("invalid offsetIntSize")
  if objectRefSize notin [1,2,4,8]: bplistError("invalid objectRefSize")
  if numObjects <= 0: bplistError("invalid numObjects")
  if topObject < 0 or topObject >= numObjects: bplistError("invalid topObject")
  if offsetTableOffset < 8 or offsetTableOffset > trailerStart: bplistError("invalid offsetTableOffset")
  let expectedOffsetTableSize = numObjects * offsetIntSize
  if offsetTableOffset + expectedOffsetTableSize > trailerStart:
    bplistError("offset table exceeds trailer")
  # read offset table
  var offsets = newSeq[int](numObjects)
  for i in 0..<numObjects:
    let pos = offsetTableOffset + i*offsetIntSize
    var v = 0
    for b in 0..<offsetIntSize:
      v = (v shl 8) or int(data[pos+b])
    if v < 8 or v >= offsetTableOffset:
      # offsets should be < offsetTableOffset but we already check < trailer, allow?
      discard
    offsets[i]=v
  var parser = BPlistParser(
    data: data,
    offsetTable: offsets,
    offsetIntSize: offsetIntSize,
    objectRefSize: objectRefSize,
    numObjects: numObjects,
    topObject: topObject,
    opts: opts,
    depth: 0,
    cache: newSeq[JsonNode](numObjects),
    decodingStack: @[]
  )
  result = parser.decodeBplistObject(topObject)

proc parseBPlist*(data: openArray[byte], opts: PlistOptions = nil): JsonNode =
  let o = if opts == nil: defaultPlistOptions() else: opts
  var seqData = newSeq[byte](data.len)
  for i, b in data: seqData[i]=b
  result = parseBPlistData(seqData, o)

proc parseBPlist*(data: seq[byte], opts: PlistOptions = nil): JsonNode =
  let o = if opts == nil: defaultPlistOptions() else: opts
  result = parseBPlistData(data, o)

proc parseBPlist*(data: string, opts: PlistOptions = nil): JsonNode =
  var seqData = newSeq[byte](data.len)
  for i, ch in data: seqData[i]=byte(ch)
  result = parseBPlistData(seqData, if opts == nil: defaultPlistOptions() else: opts)

# Encoder helpers
proc writeIntWithMarker(s: var seq[byte], v: int64) =
  if v >= 0 and v <= 0xFF:
    s.add(byte(0x10)); s.add(byte(v))
  elif v >= -0x80 and v <= 0x7F and v < 0:
    # negative 1-byte? Apple emits 8 bytes for negative small, but we emit 1-byte 0x10? Spec says 1/2/4 unsigned. For simplicity emit 8 for negatives < 0 but allow 1 byte for -128..127? Use 1 byte for compat
    s.add(byte(0x10)); s.add(byte(v and 0xFF))
  elif v >= 0 and v <= 0xFFFF:
    s.add(byte(0x11)); s.writeUInt16BE(uint16(v))
  elif v >= 0 and v <= 0xFFFFFFFF'i64:
    s.add(byte(0x12)); s.writeUInt32BE(uint32(v))
  else:
    s.add(byte(0x13)); s.writeUInt64BE(uint64(v))

proc writeCountMarker(s: var seq[byte], base: byte, count: int) =
  if count < 15:
    s.add(base or byte(count))
  else:
    s.add(base or 0x0F)
    s.writeIntWithMarker(int64(count))

proc writeBplistValue(s: var seq[byte], offsets: var seq[int], node: JsonNode, opts: PlistOptions, objIdx: var int, dedup: var Table[string,int]): int

proc getNodeKey(node: JsonNode): string =
  # for dedup: use json string
  $node

proc writeBplistValue(s: var seq[byte], offsets: var seq[int], node: JsonNode, opts: PlistOptions, objIdx: var int, dedup: var Table[string,int]): int =
  # returns object index, but we write sequentially; caller records offsets[objIdx]=s.len before writing
  # Simple non-dedup sequential: every value gets new index
  let idx = objIdx
  offsets.add(s.len)
  inc objIdx
  case node.kind
  of JNull:
    s.add(byte(0x00))
  of JBool:
    if node.getBool: s.add(byte(0x09)) else: s.add(byte(0x08))
  of JInt:
    s.writeIntWithMarker(node.getInt)
  of JFloat:
    let f = node.getFloat
    if f != f or f == Inf or f == NegInf:
      # keep as double
      s.add(byte(0x23)) # 0x20 | 3 -> 8 bytes
      var u: uint64
      var bytesBE: array[8, byte]
      # encode float64 BE
      var tmp: float64 = f
      when cpuEndian == littleEndian:
        var leBytes: array[8, byte]
        copyMem(addr leBytes[0], addr tmp, 8)
        for i in 0..<8: bytesBE[i]=leBytes[7-i]
      else:
        copyMem(addr bytesBE[0], addr tmp, 8)
      for b in bytesBE: s.add(b)
    else:
      # decide 4 vs 8: try 4 then check roundtrip? Simple use 8
      s.add(byte(0x23))
      var tmp: float64 = f
      var bytesBE: array[8, byte]
      when cpuEndian == littleEndian:
        var leBytes: array[8, byte]
        copyMem(addr leBytes[0], addr tmp, 8)
        for i in 0..<8: bytesBE[i]=leBytes[7-i]
      else:
        copyMem(addr bytesBE[0], addr tmp, 8)
      for b in bytesBE: s.add(b)
  of JString:
    # Detect if node is actually UID wrapper? caller handles dict case; string is ascii or utf16?
    var isAscii = true
    for ch in node.getStr:
      if ord(ch) > 127: isAscii=false; break
    if isAscii:
      let str = node.getStr
      s.writeCountMarker(0x50, str.len)
      for ch in str: s.add(byte(ord(ch)))
    else:
      let str = node.getStr
      var runes = toRunes(str)
      var units = 0
      for r in runes:
        if int(r) <= 0xFFFF: inc units else: inc units, 2
      s.writeCountMarker(0x60, units)
      for r in runes:
        let cp = int(r)
        if cp <= 0xFFFF:
          s.writeUInt16BE(uint16(cp))
        else:
          let u = cp - 0x10000
          let hi = 0xD800 + (u shr 10)
          let lo = 0xDC00 + (u and 0x3FF)
          s.writeUInt16BE(uint16(hi))
          s.writeUInt16BE(uint16(lo))
  of JArray:
    s.writeCountMarker(0xA0, node.len)
    # Need to write refs after flattening children. Simple approach: first flatten children then write refs.
    # But our offsets scheme expects sequential writes: we write array marker now, then children objects after.
    # Alternative two-pass: collect child indices first by recursively writing children, then backpatch.
    # Simpler: recursively write children first, collect indices, then write array object at idx (requires backpatch).
    # Instead we implement two-phase: write children first, then array.
    # For simplicity, we will handle JArray/JObject via pre-flattening using stack to avoid recursion issues.
    # Current simple sequential will produce refs that point forward (not yet written) -> invalid.
    # So we need to implement flatten before emitting.
    # For Phase 0, we implement naive fallback: serialize array elements first via recursion then backpatch s at idx pos.
    # To keep code simple, we will rebuild using full flatten helper instead of inline.
    discard # placeholder; real implementation in toBPlist flatten
  of JObject:
    # check UID wrapper
    if node.len == 1 and node.hasKey(plistCFUIDKey) and node[plistCFUIDKey].kind == JInt:
      let v = node[plistCFUIDKey].getInt
      if v < 0 or v > int64.high: bplistError("UID out of range")
      if v <= 0xFF:
        s.add(byte(0x80)); s.add(byte(v))
      elif v <= 0xFFFF:
        s.add(byte(0x81)); s.writeUInt16BE(uint16(v))
      elif v <= 0xFFFFFFFF:
        s.add(byte(0x83)); s.writeUInt32BE(uint32(v)) # 0x80|3? n+1=4 -> 0x83
      else:
        s.add(byte(0x84)); s.add(byte(v and 0xFF)) # shouldn't happen? Use 8 bytes
        # Actually UID 8 bytes -> marker 0x87 (0x80|7)
        discard
      # Correct UID sizes: n=1-> 0x80,2-> 0x81,4-> 0x83,8-> 0x87. We'll handle generically below outside
      discard
    else:
      s.writeCountMarker(0xD0, node.len)
      # similar backpatch needed for dict refs
      discard
  return idx

# Full flatten encoder: collect objects in order then write.
proc flattenBPlist(node: JsonNode, objects: var seq[JsonNode], idxMap: var Table[string,int]) =
  # post-order to ensure children before parents? For bplist, offsets table order defines object indices; parents reference child indices, so children can be before or after – no ordering constraint, refs are indices.
  # Simple: add node to objects list (assign idx) then recurse to add children; parent will reference children by later indices (forward refs) – that's allowed because offset table contains all offsets, any order.
  # We'll add parent first then children sequentially.
  let key = $node
  if key in idxMap and node.kind in {JInt,JString,JBool,JNull,JFloat}:
    # dedup primitives optionally – skip for now to keep code simple: allow duplicates as separate objects? Apple dedups.
    discard
  let idx = objects.len
  idxMap[key]=idx
  objects.add(node)
  case node.kind
  of JArray:
    for child in node.elems: flattenBPlist(child, objects, idxMap)
  of JObject:
    for k,v in node.fields:
      let kNode = newJString(k)
      flattenBPlist(kNode, objects, idxMap)
      flattenBPlist(v, objects, idxMap)
  else: discard

proc toBPlist*(node: JsonNode, opts: PlistOptions = nil): seq[byte] =
  let o = if opts == nil: defaultPlistOptions() else: opts
  # flatten
  var objects: seq[JsonNode] = @[]
  var idxMap = initTable[string,int]()
  flattenBPlist(node, objects, idxMap)
  # Map JsonNode object identity to index – but flatten added nodes in parent-first order, but children after parent.
  # For encoding we will write objects in order they appear in objects seq.
  # Need to compute ref size = byteCount(numObjects)
  let numObjects = objects.len
  let objectRefSize = byteCount(uint64(numObjects))
  # Write header + objects + offset table + trailer
  result = @[]
  result.add(cast[seq[byte]]("bplist00"))
  var offsets = newSeq[int](numObjects)
  # To write refs, we need index lookup for each child. Build map from node pointer? Our flatten with key string dedup is not stable for objects.
  # Simpler: re-encode by walking objects and for each array/dict lookup child index via linear search in objects seq (first occurrence).
  # Use proc findIdx(child: JsonNode): int -> linear search for first object that == child
  proc findIdx(child: JsonNode): int =
    for i, obj in objects:
      if obj == child: return i
    # For string keys, we created newJString(k) – must find that specific string node; == will match content
    for i, obj in objects:
      if obj.kind == child.kind and obj.kind == JString and obj.getStr == child.getStr: return i
    bplistError("child not found in objects")

  for i, obj in objects:
    offsets[i]=result.len
    case obj.kind
    of JNull: result.add(byte(0x00))
    of JBool:
      if obj.getBool: result.add(byte(0x09)) else: result.add(byte(0x08))
    of JInt:
      let v = obj.getInt
      if v >= 0 and v <= 0xFF:
        result.add(byte(0x10)); result.add(byte(v))
      elif v >= 0 and v <= 0xFFFF:
        result.add(byte(0x11)); result.writeUInt16BE(uint16(v))
      elif v >= 0 and v <= 0xFFFFFFFF:
        result.add(byte(0x12)); result.writeUInt32BE(uint32(v))
      else:
        result.add(byte(0x13)); result.writeUInt64BE(uint64(v))
    of JFloat:
      let f = obj.getFloat
      result.add(byte(0x23))
      var bytesBE: array[8, byte]
      var tmp = f
      when cpuEndian == littleEndian:
        var le: array[8, byte]
        copyMem(addr le[0], addr tmp, 8)
        for j in 0..<8: bytesBE[j]=le[7-j]
      else:
        copyMem(addr bytesBE[0], addr tmp, 8)
      for b in bytesBE: result.add(b)
    of JString:
      let s = obj.getStr
      if s.isPlistData:
        let b64 = s.extractPlistData
        let raw = base64.decode(b64)
        result.writeCountMarker(0x40, raw.len)
        for ch in raw: result.add(byte(ord(ch)))
      elif s.isPlistDate:
        let iso = s.extractPlistDate
        var dt: DateTime
        try:
          dt = parse(iso, "yyyy-MM-dd'T'HH:mm:ss'Z'", utc())
        except:
          dt = now().utc
        let unixSecs = dt.toTime.toUnix
        let cfSecs = float64(unixSecs - 978307200)
        result.add(byte(0x33))
        var tmp = cfSecs
        var bytesBE: array[8, byte]
        when cpuEndian == littleEndian:
          var le: array[8, byte]
          copyMem(addr le[0], addr tmp, 8)
          for j in 0..<8: bytesBE[j]=le[7-j]
        else:
          copyMem(addr bytesBE[0], addr tmp, 8)
        for b in bytesBE: result.add(b)
      else:
        var isAscii = true
        for ch in s:
          if ord(ch) > 127: isAscii=false; break
        if isAscii:
          result.writeCountMarker(0x50, s.len)
          for ch in s: result.add(byte(ord(ch)))
        else:
          let runes = toRunes(s)
          var units = 0
          for r in runes:
            if int(r) <= 0xFFFF: inc units else: inc units, 2
          result.writeCountMarker(0x60, units)
          for r in runes:
            let cp = int(r)
            if cp <= 0xFFFF:
              result.writeUInt16BE(uint16(cp))
            else:
              let u = cp - 0x10000
              result.writeUInt16BE(uint16(0xD800 + (u shr 10)))
              result.writeUInt16BE(uint16(0xDC00 + (u and 0x3FF)))
    of JArray:
      result.writeCountMarker(0xA0, obj.len)
      for child in obj.elems:
        let idx = findIdx(child)
        for b in 0..<objectRefSize:
          result.add(byte((idx shr ((objectRefSize-1-b)*8)) and 0xFF))
    of JObject:
      if obj.len == 1 and obj.hasKey(plistCFUIDKey) and obj[plistCFUIDKey].kind == JInt:
        let v = obj[plistCFUIDKey].getInt
        if v < 0: bplistError("UID negative")
        if v <= 0xFF:
          result.add(byte(0x80)); result.add(byte(v))
        elif v <= 0xFFFF:
          result.add(byte(0x81)); result.writeUInt16BE(uint16(v))
        elif v <= 0xFFFFFFFF:
          result.add(byte(0x83)); result.writeUInt32BE(uint32(v)) # 0x80|3 (n=4)
        else:
          result.add(byte(0x87)); result.writeUInt64BE(uint64(v))
      else:
        result.writeCountMarker(0xD0, obj.len)
        # keys
        var keys: seq[string] = @[]
        for k in obj.fields.keys: keys.add(k)
        if o != nil and o.binarySortKeys: keys.sort()
        for k in keys:
          let kNode = newJString(k)
          let idx = findIdx(kNode)
          for b in 0..<objectRefSize:
            result.add(byte((idx shr ((objectRefSize-1-b)*8)) and 0xFF))
        for k in keys:
          let child = obj[k]
          let idx = findIdx(child)
          # For duplicate primitive values, findIdx returns first idx; but if there are distinct nodes with same value we dedup via first occurrence – spec allows sharing
          # Need to handle case where child has multiple identical values but objects contains multiple copies; findIdx returns first duplicate, which is dedup sharing – okay.
          for b in 0..<objectRefSize:
            result.add(byte((idx shr ((objectRefSize-1-b)*8)) and 0xFF))

  let offsetTableOffset = result.len
  # offset table
  let maxOffset = offsetTableOffset
  let offsetIntSize = byteCount(uint64(maxOffset))
  for off in offsets:
    for b in 0..<offsetIntSize:
      result.add(byte((off shr ((offsetIntSize-1-b)*8)) and 0xFF))
  # trailer
  for i in 0..<5: result.add(byte(0))
  result.add(byte(0)) # sortVersion
  result.add(byte(offsetIntSize))
  result.add(byte(objectRefSize))
  result.writeUInt64BE(uint64(numObjects))
  # topObject is index of root node (0)
  result.writeUInt64BE(0)
  result.writeUInt64BE(uint64(offsetTableOffset))

proc toBPlist*[T](v: T, opts: PlistOptions = nil): seq[byte] =
  when T is JsonNode:
    toBPlist(v, opts)
  else:
    let node = %* v
    toBPlist(node, opts)
