import std/[json, strutils, sequtils, base64, options, times, tables, unicode, algorithm]
import ./common

type
  PlistXmlParser = object
    input: string
    pos: int
    line: int
    col: int
    opts: PlistOptions
    depth: int

proc plistXmlError(p: PlistXmlParser, msg: string) =
  raise newException(PlistError, msg & " at line " & $p.line & " col " & $p.col)

proc atEnd(p: PlistXmlParser): bool = p.pos >= p.input.len

proc peek(p: PlistXmlParser, s: string): bool =
  if p.pos + s.len > p.input.len: return false
  p.input[p.pos ..< p.pos + s.len] == s

proc advance(p: var PlistXmlParser, n: int = 1) =
  for i in 0..<n:
    if p.pos >= p.input.len: return
    if p.input[p.pos] == '\n':
      inc p.line; p.col = 1
    else:
      inc p.col
    inc p.pos

proc skipWhitespace(p: var PlistXmlParser) =
  while p.pos < p.input.len and p.input[p.pos] in {' ', '\t', '\r', '\n'}:
    p.advance()

proc skipComment(p: var PlistXmlParser): bool =
  if p.peek("<!--"):
    let e = p.input.find("-->", p.pos+4)
    if e < 0:
      p.plistXmlError("unterminated comment")
    # count lines inside
    for i in p.pos..<e+3:
      if p.input[i] == '\n':
        inc p.line; p.col = 1
      else:
        inc p.col
    p.pos = e+3
    return true
  false

proc skipWsAndComments(p: var PlistXmlParser) =
  while true:
    let before = p.pos
    p.skipWhitespace()
    discard p.skipComment()
    if p.pos == before: break

proc skipProlog(p: var PlistXmlParser) =
  p.skipWsAndComments()
  if p.peek("<?xml"):
    let e = p.input.find("?>", p.pos)
    if e < 0: p.plistXmlError("unterminated xml decl")
    # advance counting lines
    for i in p.pos..<e+2:
      if p.input[i] == '\n':
        inc p.line; p.col=1
      else: inc p.col
    p.pos = e+2
    p.skipWsAndComments()
  if p.peek("<!DOCTYPE"):
    let e = p.input.find(">", p.pos)
    if e < 0: p.plistXmlError("unterminated DOCTYPE")
    for i in p.pos..e:
      if p.input[i] == '\n': inc p.line; p.col=1
      else: inc p.col
    p.pos = e+1
    p.skipWsAndComments()
  # skip comments before plist
  while p.peek("<!--"):
    discard p.skipComment()
    p.skipWsAndComments()

proc decodeXmlEntities(s: string): string =
  result = newStringOfCap(s.len)
  var i = 0
  while i < s.len:
    if s[i] != '&':
      result.add(s[i]); inc i
    else:
      # find ;
      let semi = s.find(';', i)
      if semi < 0:
        result.add(s[i]); inc i; continue
      let ent = s[i+1 ..< semi]
      if ent == "lt": result.add('<')
      elif ent == "gt": result.add('>')
      elif ent == "amp": result.add('&')
      elif ent == "quot": result.add('"')
      elif ent == "apos": result.add('\'')
      elif ent.len > 0 and ent[0] == '#':
        # numeric
        var code = 0
        try:
          if ent.len > 1 and (ent[1] == 'x' or ent[1] == 'X'):
            code = fromHex[int](ent[2..^1])
          else:
            code = parseInt(ent[1..^1])
          result.add(Rune(code).toUTF8)
        except:
          # keep as is if invalid
          result.add(s[i..semi])
      else:
        result.add(s[i..semi])
      i = semi+1

proc findCloseTag(p: PlistXmlParser, tag: string, startPos: int): int =
  let needle = "</" & tag & ">"
  result = p.input.find(needle, startPos)
  if result < 0:
    raise newException(PlistError, "missing closing </" & tag & ">")

proc checkDepth(p: var PlistXmlParser) =
  if p.opts != nil and p.opts.maxDepth > 0:
    if p.depth > p.opts.maxDepth:
      raise newException(PlistError, "Plist maxDepth exceeded")

proc parsePlistValue(p: var PlistXmlParser): JsonNode

proc parseStringContent(p: var PlistXmlParser, tag: string): string =
  let contentStart = p.pos
  let closePos = p.findCloseTag(tag, contentStart)
  let raw = p.input[contentStart ..< closePos]
  p.pos = closePos + ("</" & tag & ">").len
  # adjust line/col roughly
  for ch in raw:
    if ch == '\n': inc p.line; p.col=1
    else: inc p.col
  raw

proc parseArray(p: var PlistXmlParser): JsonNode =
  result = newJArray()
  inc p.depth; p.checkDepth()
  while true:
    p.skipWsAndComments()
    if p.atEnd: p.plistXmlError("unterminated <array>")
    if p.peek("</array>"):
      p.pos += "</array>".len
      break
    let child = p.parsePlistValue()
    if child != nil:
      result.add(child)
    else:
      # unknown tag skipped
      continue
  dec p.depth

proc parseDict(p: var PlistXmlParser): JsonNode =
  result = newJObject()
  inc p.depth; p.checkDepth()
  while true:
    p.skipWsAndComments()
    if p.atEnd: p.plistXmlError("unterminated <dict>")
    if p.peek("</dict>"):
      p.pos += "</dict>".len
      break
    # expect <key>
    if not p.peek("<key"):
      if p.opts != nil and p.opts.strictDTD:
        p.plistXmlError("expected <key> in dict")
      else:
        # skip unknown value? Try parse value to resync
        discard p.parsePlistValue()
        continue
    # parse key
    # find '>' end of <key ...>
    let gt = p.input.find('>', p.pos)
    if gt < 0: p.plistXmlError("unterminated <key>")
    p.pos = gt+1
    let keyClose = p.findCloseTag("key", p.pos)
    let rawKey = p.input[p.pos ..< keyClose]
    let key = decodeXmlEntities(rawKey)
    # advance past </key>
    # count lines in rawKey? simple
    p.pos = keyClose + "</key>".len
    p.skipWsAndComments()
    # now value
    if p.peek("</dict>"):
      # dict ends after key without value -> spec says key must have value but permissive -> set null
      result[key] = newJNull()
      # will exit loop next iteration
      continue
    let val = p.parsePlistValue()
    if result.hasKey(key):
      if p.opts != nil and not p.opts.allowDuplicateKeys:
        p.plistXmlError("duplicate key '" & key & "'")
    result[key] = if val == nil: newJNull() else: val
  dec p.depth

proc parsePlistValue(p: var PlistXmlParser): JsonNode =
  p.skipWsAndComments()
  if p.atEnd:
    p.plistXmlError("unexpected EOF")
  if p.input[p.pos] != '<':
    p.plistXmlError("expected '<'")
  # peek closing tags for parent handling, should not be called on closing
  if p.peek("</"):
    # caller should have handled
    p.plistXmlError("unexpected closing tag")
  # extract tag inside <...>
  let gt = p.input.find('>', p.pos)
  if gt < 0: p.plistXmlError("unterminated tag")
  var inside = p.input[p.pos+1 ..< gt].strip()
  let selfClosing = inside.endsWith("/")
  if selfClosing:
    inside = inside[0..^2].strip()
  let spaceIdx = inside.find(' ')
  let tagName = if spaceIdx >= 0: inside[0..<spaceIdx] else: inside

  # self-closing
  if selfClosing:
    p.pos = gt+1
    if tagName == "true": return newJBool(true)
    elif tagName == "false": return newJBool(false)
    elif tagName == "array": return newJArray()
    elif tagName == "dict": return newJObject()
    elif tagName == "string": return newJString("")
    elif tagName == "data": return newJString("")
    else:
      if p.opts != nil and p.opts.strictDTD:
        p.plistXmlError("unknown self-closing tag <" & tagName & "/>")
      else:
        return nil
  # normal opening
  p.pos = gt+1
  case tagName
  of "string":
    let raw = p.parseStringContent("string")
    return newJString(decodeXmlEntities(raw))
  of "integer":
    let raw = p.parseStringContent("integer").strip()
    if raw.len == 0:
      return newJInt(0)
    try:
      if raw.startsWith("0x") or raw.startsWith("0X"):
        # hex
        let v = fromHex[int64](raw[2..^1])
        return newJInt(v)
      else:
        let v = parseBiggestInt(raw)
        return newJInt(v)
    except:
      p.plistXmlError("invalid integer '" & raw & "'")
  of "real":
    let raw = p.parseStringContent("real").strip()
    let lower = raw.toLowerAscii()
    if lower == "nan" or lower == "+nan" or lower == "-nan":
      return newJFloat(NaN)
    elif lower == "inf" or lower == "+inf" or lower == "infinity" or lower == "+infinity":
      return newJFloat(Inf)
    elif lower == "-inf" or lower == "-infinity":
      return newJFloat(NegInf)
    else:
      try:
        let f = parseFloat(raw)
        return newJFloat(f)
      except:
        p.plistXmlError("invalid real '" & raw & "'")
  of "data":
    let raw = p.parseStringContent("data")
    # strip whitespace for storage; keep base64 without ws
    let stripped = raw.strip().replace("\n","").replace("\r","").replace(" ","").replace("\t","")
    # optionally validate base64? permissive: keep stripped
    return newJString(stripped)
  of "date":
    let raw = p.parseStringContent("date").strip()
    # keep as string ISO8601
    return newJString(raw)
  of "array":
    # content already consumed opening, now parse children until </array>
    # our pos is after <array>, so call helper that expects to find children then closing
    # we already consumed opening, so need to handle children inline
    # reuse parseArray logic but without re-consuming opening
    result = newJArray()
    inc p.depth; p.checkDepth()
    while true:
      p.skipWsAndComments()
      if p.atEnd: p.plistXmlError("unterminated <array>")
      if p.peek("</array>"):
        p.pos += "</array>".len
        break
      let child = p.parsePlistValue()
      if child != nil: result.add(child)
    dec p.depth
    return result
  of "dict":
    result = newJObject()
    inc p.depth; p.checkDepth()
    while true:
      p.skipWsAndComments()
      if p.atEnd: p.plistXmlError("unterminated <dict>")
      if p.peek("</dict>"):
        p.pos += "</dict>".len
        break
      if not p.peek("<key"):
        if p.opts != nil and p.opts.strictDTD:
          p.plistXmlError("expected <key> in dict")
        else:
          discard p.parsePlistValue()
          continue
        # parse key
      # parse key
      let kgt = p.input.find('>', p.pos)
      if kgt < 0: p.plistXmlError("unterminated <key>")
      p.pos = kgt+1
      let kClose = p.findCloseTag("key", p.pos)
      let rawKey = p.input[p.pos ..< kClose]
      let key = decodeXmlEntities(rawKey)
      p.pos = kClose + "</key>".len
      p.skipWsAndComments()
      if p.peek("</dict>"):
        result[key] = newJNull()
        continue
      let val = p.parsePlistValue()
      if result.hasKey(key) and p.opts != nil and not p.opts.allowDuplicateKeys:
        p.plistXmlError("duplicate key '" & key & "'")
      result[key] = if val == nil: newJNull() else: val
    dec p.depth
    return result
  of "key":
    # should be handled by dict, but if appears at top level treat as string
    let raw = p.parseStringContent("key")
    return newJString(decodeXmlEntities(raw))
  of "plist":
    # nested plist shouldn't happen but handle: expect one object inside then </plist>
    p.skipWsAndComments()
    let inner = p.parsePlistValue()
    p.skipWsAndComments()
    if not p.peek("</plist>"):
      # find and consume
      let c = p.input.find("</plist>", p.pos)
      if c >= 0: p.pos = c + "</plist>".len
    else:
      p.pos += "</plist>".len
    return inner
  else:
    # unknown tag
    if p.opts != nil and p.opts.strictDTD:
      p.plistXmlError("unknown tag <" & tagName & ">")
    else:
      # skip content: find closing tag and skip
      let close = p.input.find("</" & tagName & ">", p.pos)
      if close >= 0:
        p.pos = close + ("</" & tagName & ">").len
      else:
        # self closing already handled, else skip to next '>'
        discard
      return nil

proc parseXmlPlistInternal(s: string, opts: PlistOptions): JsonNode =
  var p = PlistXmlParser(input: s, pos: 0, line: 1, col: 1, opts: opts, depth: 0)
  p.skipProlog()
  p.skipWsAndComments()
  if p.atEnd:
    raise newException(PlistError, "empty plist")
  # expect <plist
  if not p.peek("<plist"):
    # if no plist wrapper, try parse single value (permissive)
    if opts != nil and opts.strictDTD:
      p.plistXmlError("expected <plist>")
    result = p.parsePlistValue()
    return
  # consume <plist ...>
  let gt = p.input.find('>', p.pos)
  if gt < 0: p.plistXmlError("unterminated <plist>")
  # optional version check
  let plistTag = p.input[p.pos .. gt]
  if opts != nil and opts.strictDTD:
    if "version=\"1.0\"" notin plistTag and "version='1.0'" notin plistTag:
      # allow but warn? strict requires version 1.0
      discard
  p.pos = gt+1
  p.skipWsAndComments()
  # empty plist?
  if p.peek("</plist>"):
    p.pos += "</plist>".len
    return newJNull()
  result = p.parsePlistValue()
  p.skipWsAndComments()
  if p.peek("</plist>"):
    p.pos += "</plist>".len
  else:
    let c = p.input.find("</plist>", p.pos)
    if c >= 0: p.pos = c + "</plist>".len
    elif opts != nil and opts.strictDTD:
      p.plistXmlError("missing </plist>")

proc parseXmlPlist*(s: string, opts: PlistOptions = nil): JsonNode =
  let o = if opts == nil: defaultPlistOptions() else: opts
  result = parseXmlPlistInternal(s, o)

# Encoder helpers
proc escapeXml(s: string): string =
  result = newStringOfCap(s.len*2)
  for ch in s:
    case ch
    of '<': result.add("&lt;")
    of '>': result.add("&gt;")
    of '&': result.add("&amp;")
    of '"': result.add("&quot;")
    of '\'': result.add("&apos;")
    else: result.add(ch)

proc writeXmlValue(s: var string, node: JsonNode, opts: PlistOptions, indent: int) =
  let ind = "  ".repeat(indent)
  case node.kind
  of JNull:
    # no null in xml plist – encode as empty string? Use <string></string> as placeholder
    s.add(ind & "<string></string>\n")
  of JBool:
    if node.getBool: s.add(ind & "<true/>\n")
    else: s.add(ind & "<false/>\n")
  of JInt:
    s.add(ind & "<integer>" & $node.getInt & "</integer>\n")
  of JFloat:
    let f = node.getFloat
    var txt: string
    if f != f: txt = "nan"
    elif f == Inf: txt = "inf"
    elif f == NegInf: txt = "-inf"
    else: txt = $f
    s.add(ind & "<real>" & txt & "</real>\n")
  of JString:
    let str = node.getStr
    if str.isPlistData:
      s.add(ind & "<data>" & extractPlistData(str) & "</data>\n")
    elif str.isPlistDate:
      s.add(ind & "<date>" & extractPlistDate(str) & "</date>\n")
    else:
      s.add(ind & "<string>" & escapeXml(str) & "</string>\n")
  of JArray:
    s.add(ind & "<array>\n")
    for item in node.elems:
      s.writeXmlValue(item, opts, indent+1)
    s.add(ind & "</array>\n")
  of JObject:
    # Check if this is a UID wrapper {"CF$UID": int} – keep as dict with inner dict
    # Actually UID is dict with single key CF$UID -> encode as dict with that key and integer
    s.add(ind & "<dict>\n")
    var keys = toSeq(node.fields.keys)
    if opts != nil and opts.xmlSortKeys:
      keys.sort()
    for k in keys:
      s.add(ind & "  <key>" & escapeXml(k) & "</key>\n")
      s.writeXmlValue(node[k], opts, indent+1)
    s.add(ind & "</dict>\n")

proc toXmlPlist*(node: JsonNode, opts: PlistOptions = nil): string =
  let o = if opts == nil: defaultPlistOptions() else: opts
  result = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
  result.add("<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n")
  result.add("<plist version=\"1.0\">\n")
  if node != nil and node.kind != JNull:
    result.writeXmlValue(node, o, 0)
  result.add("</plist>\n")

# Overload for typed – uses JsonNode intermediate for Phase 0/1 (Phase 3 will add macro direct)
proc toXmlPlist*[T](v: T, opts: PlistOptions = nil): string =
  when T is JsonNode:
    toXmlPlist(v, opts)
  else:
    let node = %* v
    toXmlPlist(node, opts)