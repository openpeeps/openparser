# Plist common types
import std/[json, options, times, strutils, base64, macros, tables, sequtils, algorithm]

type
  PlistFormat* = enum
    pfXml, pfBinary

  PlistError* = object of CatchableError

  PlistOptions* = ref object
    maxDepth*: int
    allowDuplicateKeys*: bool
    strictDTD*: bool
    xmlSortKeys*: bool
    binarySortKeys*: bool
    dataAsBase64*: bool
    dateAsString*: bool
    unarchive*: bool

  PlistUID* = distinct int

template plist*(name: static[string]) {.pragma.}
  ## Plist field mapping pragma. Maps Nim field name to plist key.
  ## `name {.plist: "wireName".}: string`  `renameHook` supersedes this.
template json*(name: static[string]) {.pragma.}
  ## Compat alias for json pragma when using plist module (so {.json:} works)

proc defaultPlistOptions*(): PlistOptions =
  result = PlistOptions(
    maxDepth: 512,
    allowDuplicateKeys: true,
    strictDTD: false,
    xmlSortKeys: false,
    binarySortKeys: false,
    dataAsBase64: true,
    dateAsString: true,
    unarchive: true
  )

proc `==`*(a, b: PlistUID): bool {.borrow.}
proc `$`*(u: PlistUID): string =
  $int(u)

const plistCFUIDKey* = "CF$UID"
const plistDataMarker* = "\x1F__PLIST_DATA__:"
proc isPlistData*(s: string): bool = s.startsWith(plistDataMarker)
proc extractPlistData*(s: string): string = s[plistDataMarker.len .. ^1]
proc makePlistDataNode*(b64: string): JsonNode = newJString(plistDataMarker & b64)
const plistDateMarker* = "\x1F__PLIST_DATE__:"
proc isPlistDate*(s: string): bool = s.startsWith(plistDateMarker)
proc extractPlistDate*(s: string): string = s[plistDateMarker.len .. ^1]
proc makePlistDateNode*(iso: string): JsonNode = newJString(plistDateMarker & iso)

proc isPlistUIDObject*(node: JsonNode): bool =
  node.kind == JObject and node.len == 1 and node.hasKey(plistCFUIDKey) and node[plistCFUIDKey].kind == JInt

proc toPlistUID*(node: JsonNode): PlistUID =
  if not node.isPlistUIDObject:
    raise newException(PlistError, "not a CF$UID object")
  PlistUID(node[plistCFUIDKey].getInt)

proc fromPlistUID*(uid: PlistUID): JsonNode =
  result = newJObject()
  result[plistCFUIDKey] = newJInt(uid.int)

proc detectPlistFormat*(data: openArray[byte]): PlistFormat =
  if data.len >= 6 and data[0] == byte('b') and data[1] == byte('p') and
     data[2] == byte('l') and data[3] == byte('i') and data[4] == byte('s') and data[5] == byte('t'):
    pfBinary
  else:
    pfXml

proc detectPlistFormat*(data: string): PlistFormat =
  if data.len >= 6 and data[0] == 'b' and data[1] == 'p' and data[2] == 'l' and data[3] == 'i' and data[4] == 's' and data[5] == 't':
    pfBinary
  else:
    pfXml

# BE helpers for bplist
proc readUInt16BE*(data: openArray[byte], pos: int): uint16 {.inline.} =
  (uint16(data[pos]) shl 8) or uint16(data[pos+1])

proc readUInt32BE*(data: openArray[byte], pos: int): uint32 {.inline.} =
  (uint32(data[pos]) shl 24) or (uint32(data[pos+1]) shl 16) or (uint32(data[pos+2]) shl 8) or uint32(data[pos+3])

proc readUInt64BE*(data: openArray[byte], pos: int): uint64 {.inline.} =
  (uint64(data[pos]) shl 56) or (uint64(data[pos+1]) shl 48) or (uint64(data[pos+2]) shl 40) or
  (uint64(data[pos+3]) shl 32) or (uint64(data[pos+4]) shl 24) or (uint64(data[pos+5]) shl 16) or
  (uint64(data[pos+6]) shl 8) or uint64(data[pos+7])

proc writeUInt16BE*(s: var seq[byte], v: uint16) =
  s.add(byte(v shr 8))
  s.add(byte(v and 0xFF))

proc writeUInt32BE*(s: var seq[byte], v: uint32) =
  s.add(byte(v shr 24)); s.add(byte((v shr 16) and 0xFF)); s.add(byte((v shr 8) and 0xFF)); s.add(byte(v and 0xFF))

proc writeUInt64BE*(s: var seq[byte], v: uint64) =
  s.add(byte(v shr 56)); s.add(byte((v shr 48) and 0xFF)); s.add(byte((v shr 40) and 0xFF)); s.add(byte((v shr 32) and 0xFF))
  s.add(byte((v shr 24) and 0xFF)); s.add(byte((v shr 16) and 0xFF)); s.add(byte((v shr 8) and 0xFF)); s.add(byte(v and 0xFF))

proc byteCount*(v: uint64): int =
  if v <= 0xFF'u64: 1
  elif v <= 0xFFFF'u64: 2
  elif v <= 0xFFFFFFFF'u64: 4
  else: 8

proc ensure*(dataLen, pos, needed: int) =
  if pos + needed > dataLen:
    raise newException(PlistError, "bplist truncated: need " & $needed & " at " & $pos)

proc plistError*(msg: string) =
  raise newException(PlistError, msg)
# Wire mapping macros and toPlistNode (shared for xml/bplist/plist)
macro plistFromNodeMacro(T: typedesc): untyped =
  let valSym = ident"node"
  let tInst = T.getTypeInst
  let t = if tInst.kind == nnkBracketExpr: tInst[1] else: tInst
  if t.kind != nnkSym:
    return quote do:
      json.to(`valSym`, `T`)
  let typeSym = t
  var valImpl = typeSym.getImpl
  if valImpl.kind != nnkTypeDef:
    return quote do:
      json.to(`valSym`, `T`)
  var isRef = false
  var tObj: NimNode
  case valImpl.kind
  of nnkTypeDef:
    let objBody = valImpl[2]
    if objBody.kind == nnkRefTy:
      isRef = true
      tObj = objBody[0]
      if tObj.kind == nnkSym:
        tObj = tObj.getTypeImpl
    elif objBody.kind == nnkObjectTy:
      tObj = objBody
    else:
      return quote do:
        json.to(`valSym`, `T`)
  of nnkObjectTy:
    tObj = valImpl
  else:
    return quote do:
      json.to(`valSym`, `T`)
  if tObj == nil or tObj.kind != nnkObjectTy:
    return quote do:
      json.to(`valSym`, `T`)
  let recList = tObj[2]
  var stmts = newStmtList()
  let resSym = genSym(nskVar, "res")
  stmts.add quote do:
    var `resSym`: `T`
  proc processRecList(list: NimNode) =
    for def in list:
      if def.kind == nnkIdentDefs:
        let fieldPragmaExpr = def[0]
        var fieldNameNode: NimNode
        var wireName = ""
        var hasWire = false
        if fieldPragmaExpr.kind == nnkPragmaExpr:
          fieldNameNode = fieldPragmaExpr[0]
          let pragmas = fieldPragmaExpr[1]
          for p in pragmas:
            if p.kind == nnkExprColonExpr and $p[0] == "plist":
              wireName = p[1].strVal
              hasWire = true
              break
            elif p.kind == nnkCall and $p[0] == "plist":
              if p.len >= 2:
                wireName = p[1].strVal
                hasWire = true
                break
          if not hasWire:
            for p in pragmas:
              if p.kind == nnkExprColonExpr and $p[0] == "json":
                wireName = p[1].strVal
                hasWire = true
                break
              elif p.kind == nnkCall and $p[0] == "json":
                if p.len >= 2:
                  wireName = p[1].strVal
                  hasWire = true
                  break
          if not hasWire:
            wireName = $fieldNameNode
        else:
          fieldNameNode = fieldPragmaExpr
          wireName = $fieldNameNode
        let fieldSym = fieldNameNode
        let wireLit = newLit(wireName)
        stmts.add quote do:
          if `valSym`.hasKey(`wireLit`):
            `resSym`.`fieldSym` = jsonNodeTo(`valSym`[`wireLit`], typeof(`resSym`.`fieldSym`))
      elif def.kind == nnkRecList:
        processRecList(def)
      elif def.kind == nnkRecCase:
        discard
  if not recList.isNil:
    processRecList(recList)
  stmts.add quote do:
    `resSym`
  result = stmts

macro plistToNodeMacro(T: typedesc): untyped =
  let valSym = ident"v"
  let tInst = T.getTypeInst
  let t = if tInst.kind == nnkBracketExpr: tInst[1] else: tInst
  if t.kind != nnkSym:
    return quote do:
      %* `valSym`
  let typeSym = t
  var valImpl = typeSym.getImpl
  if valImpl.kind != nnkTypeDef:
    return quote do:
      %* `valSym`
  var tObj: NimNode
  case valImpl.kind
  of nnkTypeDef:
    let objBody = valImpl[2]
    if objBody.kind == nnkRefTy:
      tObj = objBody[0]
      if tObj.kind == nnkSym:
        tObj = tObj.getTypeImpl
    elif objBody.kind == nnkObjectTy:
      tObj = objBody
    else:
      return quote do:
        %* `valSym`
  of nnkObjectTy:
    tObj = valImpl
  else:
    return quote do:
      %* `valSym`
  if tObj == nil or tObj.kind != nnkObjectTy:
    return quote do:
      %* `valSym`
  let recList = tObj[2]
  var stmts2 = newStmtList()
  let objSym = genSym(nskVar, "obj")
  stmts2.add quote do:
    var `objSym` = newJObject()
  proc processRecList2(list: NimNode) =
    for def in list:
      if def.kind == nnkIdentDefs:
        let fieldPragmaExpr = def[0]
        var fieldNameNode: NimNode
        var wireName = ""
        var hasWire = false
        if fieldPragmaExpr.kind == nnkPragmaExpr:
          fieldNameNode = fieldPragmaExpr[0]
          let pragmas = fieldPragmaExpr[1]
          for p in pragmas:
            if p.kind == nnkExprColonExpr and $p[0] == "plist":
              wireName = p[1].strVal
              hasWire = true
              break
            elif p.kind == nnkCall and $p[0] == "plist":
              if p.len >= 2:
                wireName = p[1].strVal
                hasWire = true
                break
          if not hasWire:
            for p in pragmas:
              if p.kind == nnkExprColonExpr and $p[0] == "json":
                wireName = p[1].strVal
                hasWire = true
                break
              elif p.kind == nnkCall and $p[0] == "json":
                if p.len >= 2:
                  wireName = p[1].strVal
                  hasWire = true
                  break
          if not hasWire:
            wireName = $fieldNameNode
        else:
          fieldNameNode = fieldPragmaExpr
          wireName = $fieldNameNode
        let fieldSym = fieldNameNode
        let wireLit = newLit(wireName)
        stmts2.add quote do:
          `objSym`[`wireLit`] = toPlistNode(`valSym`.`fieldSym`)
      elif def.kind == nnkRecList:
        processRecList2(def)
      elif def.kind == nnkRecCase:
        discard
  if not recList.isNil:
    processRecList2(recList)
  stmts2.add quote do:
    `objSym`
  result = stmts2

proc toPlistNode*[T](v: T): JsonNode =
  when T is JsonNode:
    v
  elif T is string:
    newJString(v)
  elif T is int:
    newJInt(v)
  elif T is int64:
    newJInt(int(v))
  elif T is int32:
    newJInt(int(v))
  elif T is bool:
    newJBool(v)
  elif T is float:
    newJFloat(float(v))
  elif T is float64:
    newJFloat(v)
  elif T is seq[byte]:
    makePlistDataNode(base64.encode(cast[string](v)))
  elif T is DateTime:
    makePlistDateNode(v.format("yyyy-MM-dd'T'HH:mm:ss'Z'"))
  elif T is PlistUID:
    fromPlistUID(v)
  elif T is object:
    plistToNodeMacro(T)
  elif T is seq:
    var arr = newJArray()
    for e in v:
      arr.add(toPlistNode(e))
    arr
  elif T is array:
    var arr = newJArray()
    for e in v:
      arr.add(toPlistNode(e))
    arr
  elif T is Option:
    if v.isNone: newJNull() else: toPlistNode(v.get())
  else:
    %* v

proc jsonNodeTo*[T](node: JsonNode, _: typedesc[T]): T =
  when T is JsonNode:
    node
  elif T is string:
    if node.kind == JString: node.getStr else: $node
  elif T is int:
    if node.kind == JInt: node.getInt elif node.kind == JFloat: int(node.getFloat) else: 0
  elif T is int64:
    if node.kind == JInt: node.getInt.int64 elif node.kind == JFloat: int64(node.getFloat) else: 0
  elif T is float:
    if node.kind == JFloat: node.getFloat elif node.kind == JInt: float(node.getInt) else: 0.0
  elif T is float64:
    if node.kind == JFloat: node.getFloat elif node.kind == JInt: float(node.getInt) else: 0.0
  elif T is bool:
    if node.kind == JBool: node.getBool elif node.kind == JInt: node.getInt != 0 else: false
  elif T is seq[byte]:
    if node.kind == JString:
      let s = node.getStr
      let b64 = if s.isPlistData: s.extractPlistData else: s
      try: cast[seq[byte]](base64.decode(b64))
      except: @[]
    elif node.kind == JArray:
      var s: seq[byte] = @[]
      for e in node.elems:
        if e.kind == JInt: s.add(byte(e.getInt))
      s
    else: @[]
  elif T is DateTime:
    if node.kind == JString:
      let s = node.getStr
      let iso = if s.isPlistDate: s.extractPlistDate else: s
      try: parse(iso, "yyyy-MM-dd'T'HH:mm:ss'Z'", utc())
      except:
        try: parse(iso, "yyyy-MM-dd", utc())
        except: now().utc
    else: now().utc
  elif T is PlistUID:
    if node.isPlistUIDObject: PlistUID(node[plistCFUIDKey].getInt)
    elif node.kind == JInt: PlistUID(node.getInt)
    else: PlistUID(0)
  elif T is object:
    result = plistFromNodeMacro(T)
  else:
    json.to(node, T)
