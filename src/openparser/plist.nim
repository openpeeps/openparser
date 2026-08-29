import std/[json, strutils, base64, tables, options, times, os, sequtils, algorithm, macros]
import ./plist/common
import ./plist/xml as xmlImpl
import ./plist/bplist as bplistImpl

export common
export json

# Typed encoders via toPlistNode (from common)
proc toXmlPlist*[T: object](v: T, opts: PlistOptions = nil): string =
  xmlImpl.toXmlPlist(toPlistNode(v), opts)

proc toBPlist*[T: object](v: T, opts: PlistOptions = nil): seq[byte] =
  bplistImpl.toBPlist(toPlistNode(v), opts)

# For JsonNode, just forward to xml/bplist impls
proc toXmlPlist*(node: JsonNode, opts: PlistOptions = nil): string =
  xmlImpl.toXmlPlist(node, opts)

proc toBPlist*(node: JsonNode, opts: PlistOptions = nil): seq[byte] =
  bplistImpl.toBPlist(node, opts)

# ----------------------------------------------------------------------
# Unarchiver helper – shared for XML & BPlist
# ----------------------------------------------------------------------
proc isArchivedPlist(node: JsonNode): bool =
  node.kind == JObject and node.hasKey("$archiver") and node.hasKey("$objects") and node.hasKey("$top")

proc resolveArchivedNode(objects: JsonNode, idx: int, seen: var seq[int]): JsonNode =
  if idx < 0 or idx >= objects.len:
    return newJNull()
  if idx in seen:
    return newJNull() # cycle
  seen.add(idx)
  let obj = objects[idx]
  if obj.isPlistUIDObject:
    let uid = obj[plistCFUIDKey].getInt
    result = resolveArchivedNode(objects, uid, seen)
  elif obj.kind == JObject:
    result = newJObject()
    for k,v in obj.fields:
      if v.isPlistUIDObject:
        result[k] = resolveArchivedNode(objects, v[plistCFUIDKey].getInt, seen)
      elif v.kind == JArray:
        var arr = newJArray()
        for elem in v.elems:
          if elem.isPlistUIDObject:
            arr.add(resolveArchivedNode(objects, elem[plistCFUIDKey].getInt, seen))
          else:
            arr.add(elem)
        result[k]=arr
      else:
        result[k]=v
  elif obj.kind == JArray:
    result = newJArray()
    for elem in obj.elems:
      if elem.isPlistUIDObject:
        result.add(resolveArchivedNode(objects, elem[plistCFUIDKey].getInt, seen))
      else:
        result.add(elem)
  else:
    result = obj
  discard seen.pop()

proc unarchiveIfNeeded*(node: JsonNode): JsonNode =
  if not isArchivedPlist(node):
    return node
  let objects = node["$objects"]
  let top = node["$top"]
  if objects.kind != JArray:
    return node
  var topIdx = -1
  if top.kind == JObject:
    for k,v in top.fields:
      if v.isPlistUIDObject:
        topIdx = v[plistCFUIDKey].getInt
        break
      elif v.kind == JInt:
        topIdx = v.getInt
        break
    if topIdx < 0:
      return node
  elif top.isPlistUIDObject:
    topIdx = top[plistCFUIDKey].getInt
  elif top.kind == JInt:
    topIdx = top.getInt
  else:
    return node
  var seen: seq[int]= @[]
  result = resolveArchivedNode(objects, topIdx, seen)

# ----------------------------------------------------------------------
# Autodetect dispatcher for JsonNode
# ----------------------------------------------------------------------

proc parseXmlPlist*(s: string, opts: PlistOptions = nil): JsonNode =
  let node = xmlImpl.parseXmlPlist(s, opts)
  let o = if opts == nil: defaultPlistOptions() else: opts
  if o.unarchive: unarchiveIfNeeded(node) else: node

proc parseBPlist*(data: openArray[byte], opts: PlistOptions = nil): JsonNode =
  let node = bplistImpl.parseBPlist(data, opts)
  let o = if opts == nil: defaultPlistOptions() else: opts
  if o.unarchive: unarchiveIfNeeded(node) else: node

proc parseBPlist*(data: seq[byte], opts: PlistOptions = nil): JsonNode =
  let node = bplistImpl.parseBPlist(data, opts)
  let o = if opts == nil: defaultPlistOptions() else: opts
  if o.unarchive: unarchiveIfNeeded(node) else: node

proc parseBPlist*(data: string, opts: PlistOptions = nil): JsonNode =
  var seqData = newSeq[byte](data.len)
  for i,ch in data: seqData[i]=byte(ch)
  parseBPlist(seqData, opts)

proc parsePlist*(s: string, opts: PlistOptions = nil): JsonNode =
  let o = if opts == nil: defaultPlistOptions() else: opts
  let fmt = detectPlistFormat(s)
  if fmt == pfBinary:
    var seqData = newSeq[byte](s.len)
    for i,ch in s: seqData[i]=byte(ch)
    let raw = bplistImpl.parseBPlist(seqData, o)
    result = if o.unarchive: unarchiveIfNeeded(raw) else: raw
  else:
    let raw = xmlImpl.parseXmlPlist(s, o)
    result = if o.unarchive: unarchiveIfNeeded(raw) else: raw

proc parsePlist*(data: seq[byte], opts: PlistOptions = nil): JsonNode =
  let o = if opts == nil: defaultPlistOptions() else: opts
  let fmt = detectPlistFormat(data)
  if fmt == pfBinary:
    let raw = bplistImpl.parseBPlist(data, o)
    result = if o.unarchive: unarchiveIfNeeded(raw) else: raw
  else:
    var s = newString(data.len)
    for i,b in data: s[i]=char(b)
    let raw = xmlImpl.parseXmlPlist(s, o)
    result = if o.unarchive: unarchiveIfNeeded(raw) else: raw

proc parsePlist*(data: openArray[byte], opts: PlistOptions = nil): JsonNode =
  var seqData = newSeq[byte](data.len)
  for i,b in data: seqData[i]=b
  result = parsePlist(seqData, opts)

proc parseXmlPlistFile*(path: string, opts: PlistOptions = nil): JsonNode =
  let s = readFile(path)
  parseXmlPlist(s, opts)

proc parseBPlistFile*(path: string, opts: PlistOptions = nil): JsonNode =
  let data = readFile(path)
  var seqData = newSeq[byte](data.len)
  for i,ch in data: seqData[i]=byte(ch)
  parseBPlist(seqData, opts)

proc parsePlistFile*(path: string, opts: PlistOptions = nil): JsonNode =
  let s = readFile(path)
  parsePlist(s, opts)

# ----------------------------------------------------------------------
# Typed decoders – via jsonNodeTo (from common) – mirrors json.fromJson(T)
# ----------------------------------------------------------------------

proc parsePlist*[T](s: string, _: typedesc[T], opts: PlistOptions = nil): T =
  let node = parsePlist(s, opts)
  jsonNodeTo(node, T)

proc parsePlist*[T](data: seq[byte], _: typedesc[T], opts: PlistOptions = nil): T =
  let node = parsePlist(data, opts)
  jsonNodeTo(node, T)

proc parsePlist*[T](data: openArray[byte], _: typedesc[T], opts: PlistOptions = nil): T =
  let node = parsePlist(data, opts)
  jsonNodeTo(node, T)

proc parseXmlPlist*[T](s: string, _: typedesc[T], opts: PlistOptions = nil): T =
  let node = xmlImpl.parseXmlPlist(s, opts)
  let o = if opts == nil: defaultPlistOptions() else: opts
  let un = if o.unarchive: unarchiveIfNeeded(node) else: node
  jsonNodeTo(un, T)

proc parseBPlist*[T](data: openArray[byte], _: typedesc[T], opts: PlistOptions = nil): T =
  let node = bplistImpl.parseBPlist(data, opts)
  let o = if opts == nil: defaultPlistOptions() else: opts
  let un = if o.unarchive: unarchiveIfNeeded(node) else: node
  jsonNodeTo(un, T)

proc parseBPlist*[T](data: seq[byte], _: typedesc[T], opts: PlistOptions = nil): T =
  let node = bplistImpl.parseBPlist(data, opts)
  let o = if opts == nil: defaultPlistOptions() else: opts
  let un = if o.unarchive: unarchiveIfNeeded(node) else: node
  jsonNodeTo(un, T)

proc parsePlistFile*[T](path: string, _: typedesc[T], opts: PlistOptions = nil): T =
  let node = parsePlistFile(path, opts)
  jsonNodeTo(node, T)

proc parseXmlPlistFile*[T](path: string, _: typedesc[T], opts: PlistOptions = nil): T =
  let node = parseXmlPlistFile(path, opts)
  jsonNodeTo(node, T)

proc parseBPlistFile*[T](path: string, _: typedesc[T], opts: PlistOptions = nil): T =
  let node = parseBPlistFile(path, opts)
  jsonNodeTo(node, T)
