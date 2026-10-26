# A collection of tiny parsers and dumpers
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/openparser

## Spec-compliant MIME parser and creator.
##
## Covers RFC 5322 (Internet message format), RFC 2045 (MIME part one),
## RFC 2046 (media types), RFC 2047 (encoded words), RFC 2048
## (registration procedures) and RFC 2049 (conformance and examples),
## plus minimal RFC 2183 / RFC 2231 support for `Content-Disposition`
## filenames.
##
## ```nim
## import openparser/mime
## let msg = parseMime(readFile("mail.eml"))
## echo msg.subject.get("")
## writeFile("out.eml", toMime(msg))
## ```

import std/[strutils, options, base64, encodings, memfiles, os, unicode, times]

type
  OpenParserMimeError* = object of CatchableError

  MimePolicy* = enum
    ## Parsing/creation policy. Lenient recovers where safe and preserves
    ## unknown tokens; strict turns those recoveries into errors.
    mpLenient
    mpStrict

  MimeOptions* = object
    policy*: MimePolicy = mpLenient
      ## Default policy is lenient-first; strict opts into RFC enforcement.
    allowLf*: bool = true
      ## Accept lone LF (and CR) line endings on input. Output is CRLF.
    maxDepth*: int = 8
      ## Maximum nesting depth for multipart and message/rfc822 bodies.
    maxParts*: int = 100
      ## Maximum total MIME parts in one message.
    maxHeaderBytes*: int = 1_000_000
      ## Maximum bytes of a header block (headers only, not body).
    maxBodyBytes*: int = 50_000_000
      ## Maximum bytes of transfer-decoded body content collected.
    decodeCharsets*: bool = true
      ## Convert text bodies to UTF-8 using the declared charset.
    foldAt*: int = 78
      ## Preferred header folding column on output (never exceeds 998).
    lineEnding*: string = "\r\n"
      ## Line ending used when creating messages.

  MimeHeader* = object
    ## A single unfolded raw header field.
    name*: string
    value*: string

  MimeParam* = object
    ## A `Content-Type` / `Content-Disposition` parameter. RFC 2231
    ## continuations (`filename*0*`, `filename*1*`) are reassembled into a
    ## single param with `charset` / `language` preserved.
    name*: string
    value*: string
    charset*: Option[string]
    language*: Option[string]

  MimeContentType* = object
    mainType*: string
    subType*: string
    params*: seq[MimeParam]

  MimeDisposition* = object
    ## Minimal RFC 2183 content disposition (e.g. attachment filenames).
    kind*: string
    params*: seq[MimeParam]

  MimeTransferEncoding* = enum
    te7bit
    te8bit
    teBinary
    teQuotedPrintable
    teBase64
    teUnknown

  MimeAddressKind* = enum
    maMailbox
    maGroup

  MimeMailbox* = object
    displayName*: Option[string]
    localPart*: string
    domain*: string

  MimeAddress* = object
    case kind*: MimeAddressKind
    of maMailbox:
      mailbox*: MimeMailbox
    of maGroup:
      groupName*: string
      members*: seq[MimeMailbox]

  MimeDate* = object
    ## RFC 5322 date-time. `raw` preserves the original field body,
    ## `zone` preserves named zones, `offsetMinutes` holds the numeric
    ## offset when known.
    raw*: string
    year*, month*, day*: int
    hour*, minute*, second*: int
    offsetMinutes*: Option[int]
    zone*: string

  MimeBodyKind* = enum
    mbEmpty
    mbText
    mbData
    mbMultipart
    mbMessage

  MimeBody* = object
    case kind*: MimeBodyKind
    of mbEmpty:
      discard
    of mbText:
      text*: string
      charset*: string
      raw*: seq[byte]
    of mbData:
      data*: seq[byte]
    of mbMultipart:
      subtype*: string
      boundary*: string
      preamble*: string
      parts*: seq[MimePart]
      epilogue*: string
    of mbMessage:
      message*: MimeMessage

  MimePart* = ref object
    ## A single MIME entity: content headers plus a decoded body.
    contentType*: MimeContentType
    contentTypePresent*: bool
    transferEncoding*: MimeTransferEncoding
    transferEncodingRaw*: string
    transferEncodingPresent*: bool
    contentId*: Option[string]
    contentDescription*: Option[string]
    disposition*: Option[MimeDisposition]
    contentLanguage*: seq[string]
    contentLocation*: Option[string]
    body*: MimeBody
    extraHeaders*: seq[MimeHeader]

  MimeMessage* = ref object
    ## A top-level RFC 5322 message: originator/recipient headers plus
    ## the MIME body entity.
    date*: Option[MimeDate]
    fromAddrs*: seq[MimeMailbox]
    sender*: Option[MimeMailbox]
    replyTo*: seq[MimeMailbox]
    toAddrs*: seq[MimeAddress]
    cc*: seq[MimeAddress]
    bcc*: seq[MimeAddress]
    subject*: Option[string]
    messageId*: Option[string]
    inReplyTo*: seq[string]
    references*: seq[string]
    comments*: Option[string]
    keywords*: seq[string]
    received*: seq[string]
    returnPath*: Option[string]
    mimeVersion*: Option[string]
    body*: MimePart
    extraHeaders*: seq[MimeHeader]

proc defaultMimeOptions*(): MimeOptions {.inline.} =
  ## Default options: lenient policy, LF accepted, CRLF output.
  MimeOptions()

proc mimeError*(msg: string) {.noreturn.} =
  raise newException(OpenParserMimeError, msg)

# ---------------------------------------------------------------------------
# Byte / string helpers
# ---------------------------------------------------------------------------

proc bytesToString*(data: openArray[byte]): string =
  ## Copy raw bytes into a Nim string without any charset conversion.
  result = newString(data.len)
  if data.len > 0:
    copyMem(addr result[0], unsafeAddr data[0], data.len)

proc stringToBytes*(s: string): seq[byte] =
  ## Copy a string's bytes into a byte sequence.
  result = newSeq[byte](s.len)
  if s.len > 0:
    copyMem(addr result[0], unsafeAddr s[0], s.len)

proc isTokenChar(c: char): bool {.inline.} =
  ## RFC 2045 token characters (everything printable except tspecials).
  if c <= ' ' or c == '\x7f': return false
  case c
  of '(', ')', '<', '>', '@', ',', ';', ':', '\\', '"', '/', '[', ']', '?', '=':
    false
  else: true

proc isValidFieldName(name: string): bool =
  ## RFC 5322 field-name: printable ASCII except colon, non-empty.
  if name.len == 0: return false
  for c in name:
    if c < '!' or c > '~' or c == ':': return false
  true

# ---------------------------------------------------------------------------
# Header block splitting and unfolding (RFC 5322 section 2.2)
# ---------------------------------------------------------------------------

proc splitHeadersBody*(s: string; opts: MimeOptions = defaultMimeOptions()):
    tuple[head, body: string] =
  ## Split a message or entity into its raw header block and body at the
  ## first blank line. Lenient mode accepts LF-only and mixed separators.
  if opts.policy == mpStrict:
    let idx = s.find("\r\n\r\n")
    if idx < 0:
      mimeError("missing CRLF CRLF header/body separator")
    return (s[0 ..< idx], s[idx + 4 .. ^1])
  if s.startsWith("\r\n"):
    return ("", s[2 .. ^1]) # empty headers, body follows
  if s.len > 0 and (s[0] == '\n' or s[0] == '\r'):
    return ("", s[1 .. ^1])
  const seps = ["\r\n\r\n", "\n\n", "\r\r", "\r\n\n", "\n\r\n"]
  for sep in seps:
    let idx = s.find(sep)
    if idx >= 0:
      return (s[0 ..< idx], s[idx + sep.len .. ^1])
  # No blank line: treat the whole input as headers with an empty body.
  (s, "")

proc parseHeaderBlock*(head: string; opts: MimeOptions = defaultMimeOptions()):
    seq[MimeHeader] =
  ## Unfold (RFC 5322 obs-fold) and split a raw header block into fields.
  if head.len > opts.maxHeaderBytes:
    mimeError("header block exceeds maxHeaderBytes")
  result = @[]
  var cur = ""
  var hasCur = false
  template flushCur() =
    if hasCur:
      hasCur = false
      let c = cur.find(':')
      if c < 0:
        if opts.policy == mpStrict:
          mimeError("header line without colon: " & cur)
        # lenient: skip malformed header line
      else:
        let name = cur[0 ..< c].strip()
        if not isValidFieldName(name):
          if opts.policy == mpStrict:
            mimeError("invalid header field name: " & name)
          # lenient: skip malformed header line
        else:
          let value = cur[c + 1 .. ^1].strip()
          if opts.policy == mpStrict and cur.len > 998:
            mimeError("header line exceeds 998 characters: " & name)
          result.add(MimeHeader(name: name, value: value))
  for line in head.splitLines():
    if line.len == 0:
      flushCur()
      continue
    if line[0] == ' ' or line[0] == '\t':
      if not hasCur:
        if opts.policy == mpStrict:
          mimeError("continuation line without a header field")
        cur = line.strip()
        hasCur = true
      else:
        cur.add(line) # unfolding removes CRLF, keeps the WSP
    else:
      flushCur()
      cur = line
      hasCur = true
  flushCur()

# ---------------------------------------------------------------------------
# Comments (CFWS) and quoted-string helpers
# ---------------------------------------------------------------------------

proc removeComments*(s: string; opts: MimeOptions = defaultMimeOptions()): string =
  ## Remove `(comments)` outside quoted strings, honoring nesting and
  ## quoted pairs. Unbalanced comments raise in strict mode.
  result = newStringOfCap(s.len)
  var i = 0
  var inQ = false
  var esc = false
  while i < s.len:
    let c = s[i]
    if esc:
      result.add(c)
      esc = false
      inc i
      continue
    if inQ and c == '\\':
      result.add(c)
      esc = true
      inc i
      continue
    if c == '"':
      inQ = not inQ
      result.add(c)
      inc i
      continue
    if not inQ and c == '(':
      var depth = 1
      var j = i + 1
      while j < s.len and depth > 0:
        if s[j] == '\\':
          j += 2
          continue
        elif s[j] == '(':
          inc depth
        elif s[j] == ')':
          dec depth
        inc j
      if depth != 0:
        if opts.policy == mpStrict:
          mimeError("unbalanced comment in: " & s)
        break # lenient: drop the rest
      i = j
      continue
    result.add(c)
    inc i

proc splitOutsideQuotes*(s: string; sep: char): seq[string] =
  ## Split on `sep` characters that appear outside quoted strings,
  ## keeping backslash escapes intact for later unquoting.
  result = @[]
  var cur = newStringOfCap(s.len)
  var inQ = false
  var esc = false
  for c in s:
    if esc:
      cur.add(c)
      esc = false
    elif inQ and c == '\\':
      cur.add(c)
      esc = true
    elif c == '"':
      inQ = not inQ
      cur.add(c)
    elif c == sep and not inQ:
      result.add(cur)
      cur = newStringOfCap(s.len)
    else:
      cur.add(c)
  result.add(cur)

proc unquoteParamValue*(s: string): string =
  ## Remove surrounding quotes and resolve backslash quoted pairs.
  var t = s.strip()
  if t.len >= 2 and t[0] == '"' and t[^1] == '"':
    result = newStringOfCap(t.len)
    var i = 1
    while i < t.len - 1:
      if t[i] == '\\' and i + 1 < t.len - 1:
        result.add(t[i + 1])
        i += 2
      else:
        result.add(t[i])
        inc i
  else:
    result = t

# ---------------------------------------------------------------------------
# Content-Type and parameters (RFC 2045 section 5)
# ---------------------------------------------------------------------------

proc parseParams*(s: string; opts: MimeOptions = defaultMimeOptions()):
    seq[MimeParam] =
  ## Parse `; attr=value` parameter lists. Quoted values and comments are
  ## honored; RFC 2231 `name*` forms are kept verbatim here and decoded
  ## by `decodeRfc2231Params`.
  result = @[]
  if s.strip().len == 0: return
  for chunk in splitOutsideQuotes(s, ';'):
    let part = chunk.strip()
    if part.len == 0: continue
    let eqParts = splitOutsideQuotes(part, '=')
    if eqParts.len < 2:
      if opts.policy == mpStrict:
        mimeError("parameter without value: " & part)
      continue # lenient: skip bare attributes
    let name = eqParts[0].strip().toLowerAscii()
    if name.len == 0:
      if opts.policy == mpStrict:
        mimeError("empty parameter name in: " & part)
      continue
    var value = unquoteParamValue(eqParts[1 .. ^1].join("="))
    result.add(MimeParam(name: name, value: value,
      charset: none(string), language: none(string)))

proc parseContentType*(s: string; opts: MimeOptions = defaultMimeOptions()):
    MimeContentType =
  ## Parse a Content-Type field body into type, subtype and parameters.
  ## Type, subtype and attribute names are lowercased; values keep case.
  let clean = removeComments(s, opts)
  let chunks = splitOutsideQuotes(clean, ';')
  if chunks.len == 0 or chunks[0].strip().len == 0:
    mimeError("empty Content-Type value")
  let typeToken = chunks[0].strip()
  let slash = typeToken.find('/')
  if slash < 0:
    mimeError("Content-Type without subtype: " & typeToken)
  let mainType = typeToken[0 ..< slash].strip().toLowerAscii()
  let subType = typeToken[slash + 1 .. ^1].strip().toLowerAscii()
  if mainType.len == 0 or subType.len == 0:
    mimeError("invalid Content-Type: " & typeToken)
  if opts.policy == mpStrict:
    for c in mainType & subType:
      if not isTokenChar(c):
        mimeError("invalid Content-Type token: " & typeToken)
  var rest = ""
  if chunks.len > 1:
    rest = chunks[1 .. ^1].join(";")
  MimeContentType(mainType: mainType, subType: subType,
    params: parseParams(rest, opts))

proc defaultContentType*(): MimeContentType {.inline.} =
  ## RFC 2045 default: text/plain with charset us-ascii.
  MimeContentType(mainType: "text", subType: "plain",
    params: @[MimeParam(name: "charset", value: "us-ascii",
      charset: none(string), language: none(string))])

proc mediaType*(ct: MimeContentType): string {.inline.} =
  ct.mainType.toLowerAscii() & "/" & ct.subType.toLowerAscii()

proc contentTypeParam*(ct: MimeContentType; name: string): Option[string] =
  ## Case-insensitive parameter lookup.
  let key = name.toLowerAscii()
  for p in ct.params:
    if p.name == key:
      return some(p.value)
  none(string)

proc charsetOf*(ct: MimeContentType): string =
  ## Charset parameter, defaulting to us-ascii for text types.
  let c = ct.contentTypeParam("charset")
  if c.isSome: c.get
  else: "us-ascii"

proc boundaryOf*(ct: MimeContentType): Option[string] =
  ct.contentTypeParam("boundary")

proc isMultipart*(ct: MimeContentType): bool {.inline.} =
  ct.mainType.toLowerAscii() == "multipart"

proc isText*(ct: MimeContentType): bool {.inline.} =
  ct.mainType.toLowerAscii() == "text"

proc isMessage*(ct: MimeContentType): bool {.inline.} =
  ct.mainType.toLowerAscii() == "message"

proc parseTransferEncoding*(s: string): tuple[enc: MimeTransferEncoding, raw: string] =
  ## Parse a Content-Transfer-Encoding value, preserving unknown tokens.
  let raw = s.strip()
  case raw.toLowerAscii()
  of "7bit": (te7bit, raw)
  of "8bit": (te8bit, raw)
  of "binary": (teBinary, raw)
  of "quoted-printable": (teQuotedPrintable, raw)
  of "base64": (teBase64, raw)
  else: (teUnknown, raw)

# ---------------------------------------------------------------------------
# Content-Transfer-Encoding codecs (RFC 2045 section 6)
# ---------------------------------------------------------------------------

proc decodeBase64Body*(data: string; opts: MimeOptions = defaultMimeOptions()):
    seq[byte] =
  ## Decode base64 body data, ignoring folding whitespace. Invalid input
  ## raises in both policies since the bytes are unrecoverable; strict
  ## mode additionally enforces padding and alphabet rules.
  var clean = newStringOfCap(data.len)
  for c in data:
    if c notin {' ', '\t', '\r', '\n'}:
      clean.add(c)
  if opts.policy == mpStrict and clean.len > 0:
    if clean.len mod 4 != 0:
      mimeError("base64 body length is not a multiple of 4")
    var pads = 0
    while pads < clean.len and clean[clean.len - 1 - pads] == '=':
      inc pads
    if pads > 2:
      mimeError("invalid base64 padding")
    for c in clean:
      if c notin {'A' .. 'Z', 'a' .. 'z', '0' .. '9', '+', '/', '='}:
        mimeError("invalid base64 alphabet character")
    if '=' in clean[0 ..< clean.len - pads]:
      mimeError("misplaced base64 padding")
  try:
    result = stringToBytes(base64.decode(clean))
  except ValueError as e:
    mimeError("invalid base64 body: " & e.msg)
  except CatchableError as e:
    mimeError("invalid base64 body: " & e.msg)

proc isHexDigit(c: char): bool {.inline.} =
  c in {'0' .. '9', 'a' .. 'f', 'A' .. 'F'}

proc hexVal(c: char): int {.inline.} =
  case c
  of '0' .. '9': ord(c) - ord('0')
  of 'a' .. 'f': ord(c) - ord('a') + 10
  else: ord(c) - ord('A') + 10

proc decodeQuotedPrintable*(data: string; opts: MimeOptions = defaultMimeOptions()):
    seq[byte] =
  ## Decode a quoted-printable body. Soft breaks (`=` at end of line) are
  ## removed; malformed escapes raise in strict mode and pass through
  ## literally in lenient mode.
  result = newSeqOfCap[byte](data.len)
  var i = 0
  while i < data.len:
    let c = data[i]
    if c != '=':
      result.add(byte(ord(c)))
      inc i
      continue
    # Soft line break: "=" CRLF or (lenient) "=" LF.
    if i + 1 < data.len and data[i + 1] == '\n':
      i += 2
      continue
    if i + 2 < data.len and data[i + 1] == '\r' and data[i + 2] == '\n':
      i += 3
      continue
    if i + 2 < data.len and isHexDigit(data[i + 1]) and isHexDigit(data[i + 2]):
      result.add(byte(hexVal(data[i + 1]) * 16 + hexVal(data[i + 2])))
      i += 3
      continue
    if opts.policy == mpStrict:
      mimeError("invalid quoted-printable escape at offset " & $i)
    result.add(byte(ord('=')))
    inc i

proc encodeQuotedPrintable*(data: openArray[byte]): string =
  ## Encode bytes as quoted-printable, wrapping at 76 columns with soft
  ## breaks. Existing CRLF breaks are preserved; trailing spaces and
  ## tabs are encoded.
  result = newStringOfCap(data.len + data.len div 4 + 16)
  var lineLen = 0
  proc emitChunk(s: string; lineLen: var int; res: var string) =
    if lineLen + s.len > 76:
      res.add("=\r\n")
      lineLen = 0
    res.add(s)
    lineLen += s.len
  var i = 0
  while i < data.len:
    let b = data[i]
    if b == byte(ord('\r')) and i + 1 < data.len and data[i + 1] == byte(ord('\n')):
      result.add("\r\n")
      lineLen = 0
      i += 2
      continue
    if b == byte(ord('\n')):
      result.add("\r\n")
      lineLen = 0
      inc i
      continue
    var rep: string
    if b == byte(ord('=')):
      rep = "=3D"
    elif b >= 33 and b <= 60 or b >= 62 and b <= 126:
      rep = $chr(b)
    elif b == byte(ord(' ')) or b == byte(ord('\t')):
      # Encode whitespace at end of line or end of input.
      var atEnd = i + 1 >= data.len
      if not atEnd:
        let n = data[i + 1]
        atEnd = n == byte(ord('\r')) or n == byte(ord('\n'))
      if atEnd:
        rep = if b == byte(ord(' ')): "=20" else: "=09"
      else:
        rep = $chr(b)
    else:
      const hexd = "0123456789ABCDEF"
      rep = "=" & $hexd[b shr 4] & $hexd[b and 0x0F]
    emitChunk(rep, lineLen, result)
    inc i

proc encodeBase64Body*(data: openArray[byte]): string =
  ## Encode bytes as base64 wrapped at 76 columns with CRLF breaks.
  let raw = base64.encode(data)
  result = newStringOfCap(raw.len + raw.len div 76 * 2 + 2)
  var i = 0
  while i < raw.len:
    if i > 0:
      result.add("\r\n")
    result.add(raw[i ..< min(i + 76, raw.len)])
    i += 76

# ---------------------------------------------------------------------------
# Charset conversion (text bodies to UTF-8)
# ---------------------------------------------------------------------------

proc normalizeCharsetLabel*(s: string): string =
  ## Normalize common charset aliases to iconv-friendly labels.
  var t = s.strip().toLowerAscii().replace("_", "-")
  case t
  of "", "ascii", "us-ascii", "ansi-x3.4-1968": "US-ASCII"
  of "utf-8", "utf8": "UTF-8"
  of "latin-1", "latin1", "iso-8859-1", "iso8859-1": "ISO-8859-1"
  of "iso-8859-2", "iso8859-2", "latin-2": "ISO-8859-2"
  of "iso-8859-15", "iso8859-15", "latin-9": "ISO-8859-15"
  of "windows-1252", "cp1252", "windows1252": "WINDOWS-1252"
  of "windows-1250", "cp1250": "WINDOWS-1250"
  of "shift-jis", "shift_jis", "sjis", "windows-31j": "SHIFT_JIS"
  of "euc-jp", "eucjp": "EUC-JP"
  of "iso-2022-jp": "ISO-2022-JP"
  of "gb2312", "gbk", "gb18030": t.toUpperAscii()
  of "big5", "big5-hkscs": t.toUpperAscii()
  of "koi8-r", "koi8-u": t.toUpperAscii()
  else: s.strip()

proc latin1ToUtf8*(data: openArray[byte]): string =
  ## Lossless single-byte fallback: map bytes 0x00-0xFF to U+0000-U+00FF.
  result = newStringOfCap(data.len + 8)
  for b in data:
    if b < 0x80:
      result.add(chr(b))
    else:
      result.add(chr(0xC0 or (b shr 6)))
      result.add(chr(0x80 or (b and 0x3F)))

proc isAsciiBytes(data: openArray[byte]): bool =
  for b in data:
    if b >= 0x80: return false
  true

proc decodeTextBytes*(data: openArray[byte]; charset: string;
    opts: MimeOptions = defaultMimeOptions()): string =
  ## Convert transfer-decoded bytes to a UTF-8 string using `charset`.
  ## Unknown charsets raise in strict mode and fall back to a lossless
  ## single-byte mapping in lenient mode.
  if not opts.decodeCharsets:
    return latin1ToUtf8(data)
  let label = normalizeCharsetLabel(charset)
  if label == "UTF-8":
    let s = bytesToString(data)
    if opts.policy == mpStrict and unicode.validateUtf8(s) >= 0:
      mimeError("invalid UTF-8 in text body")
    return s
  if label == "US-ASCII":
    if opts.policy == mpStrict and not isAsciiBytes(data):
      mimeError("non-ASCII byte in us-ascii text body")
    return latin1ToUtf8(data)
  try:
    return encodings.convert(bytesToString(data), "UTF-8", label)
  except CatchableError:
    if opts.policy == mpStrict:
      mimeError("unsupported or invalid charset: " & charset)
    return latin1ToUtf8(data)

proc normalizeTextLineEndings*(data: openArray[byte]): seq[byte] =
  ## Canonicalize text line endings to CRLF (`\n` -> CRLF, lone
  ## `\r` -> CRLF, existing CRLF untouched).
  result = newSeqOfCap[byte](data.len + 8)
  var i = 0
  while i < data.len:
    if data[i] == byte(ord('\r')):
      result.add(byte(ord('\r')))
      result.add(byte(ord('\n')))
      if i + 1 < data.len and data[i + 1] == byte(ord('\n')):
        i += 2
      else:
        inc i
    elif data[i] == byte(ord('\n')):
      result.add(byte(ord('\r')))
      result.add(byte(ord('\n')))
      inc i
    else:
      result.add(data[i])
      inc i

# ---------------------------------------------------------------------------
# RFC 5322 lexical scanner (atoms, quoted strings, comments, domain
# literals) shared by addresses, dates and message IDs
# ---------------------------------------------------------------------------

proc decodeEncodedWords*(s: string;
    opts: MimeOptions = defaultMimeOptions()): string

type
  MimeTokenKind = enum
    tkAtom
    tkQuoted
    tkDomain
    tkSpecial
    tkEnd

  MimeToken = object
    kind: MimeTokenKind
    text: string

  MimeLexer = object
    s: string
    pos: int
    opts: MimeOptions

proc skipCfws(lx: var MimeLexer) =
  ## Skip folding whitespace and comments (nested, with quoted pairs).
  while lx.pos < lx.s.len:
    let c = lx.s[lx.pos]
    if c == ' ' or c == '\t' or c == '\r' or c == '\n':
      inc lx.pos
    elif c == '(':
      var depth = 1
      inc lx.pos
      while lx.pos < lx.s.len and depth > 0:
        if lx.s[lx.pos] == '\\':
          lx.pos += 2
        elif lx.s[lx.pos] == '(':
          inc depth
          inc lx.pos
        elif lx.s[lx.pos] == ')':
          dec depth
          inc lx.pos
        else:
          inc lx.pos
      if depth != 0 and lx.opts.policy == mpStrict:
        mimeError("unbalanced comment in address/date field")
    else:
      break

proc nextToken(lx: var MimeLexer): MimeToken =
  lx.skipCfws()
  if lx.pos >= lx.s.len:
    return MimeToken(kind: tkEnd)
  let c = lx.s[lx.pos]
  if c == '=' and lx.pos + 1 < lx.s.len and lx.s[lx.pos + 1] == '?':
    # Possible RFC 2047 encoded word: keep it as one atom so phrases
    # and display names survive tokenizing intact.
    let qe = lx.s.find("?=", lx.pos + 2)
    if qe >= 0:
      let word = lx.s[lx.pos ..< qe + 2]
      lx.pos = qe + 2
      return MimeToken(kind: tkAtom, text: word)
  if c == '"':
    var buf = newStringOfCap(16)
    inc lx.pos
    var closed = false
    while lx.pos < lx.s.len:
      let d = lx.s[lx.pos]
      if d == '\\' and lx.pos + 1 < lx.s.len:
        buf.add(lx.s[lx.pos + 1])
        lx.pos += 2
      elif d == '"':
        closed = true
        inc lx.pos
        break
      elif d == '\r' or d == '\n':
        if lx.opts.policy == mpStrict:
          mimeError("bare line break in quoted string")
        buf.add(d)
        inc lx.pos
      else:
        buf.add(d)
        inc lx.pos
    if not closed and lx.opts.policy == mpStrict:
      mimeError("unterminated quoted string")
    return MimeToken(kind: tkQuoted, text: buf)
  if c == '[':
    var buf = newStringOfCap(16)
    inc lx.pos
    var closed = false
    while lx.pos < lx.s.len:
      let d = lx.s[lx.pos]
      if d == '\\' and lx.pos + 1 < lx.s.len:
        buf.add(d)
        buf.add(lx.s[lx.pos + 1])
        lx.pos += 2
      elif d == ']':
        closed = true
        inc lx.pos
        break
      elif d == '\r' or d == '\n':
        if lx.opts.policy == mpStrict:
          mimeError("bare line break in domain literal")
        buf.add(d)
        inc lx.pos
      else:
        buf.add(d)
        inc lx.pos
    if not closed and lx.opts.policy == mpStrict:
      mimeError("unterminated domain literal")
    return MimeToken(kind: tkDomain, text: buf)
  if isTokenChar(c):
    let start = lx.pos
    while lx.pos < lx.s.len and isTokenChar(lx.s[lx.pos]):
      inc lx.pos
    return MimeToken(kind: tkAtom, text: lx.s[start ..< lx.pos])
  inc lx.pos
  MimeToken(kind: tkSpecial, text: $c)

proc peekToken(lx: MimeLexer): MimeToken =
  var cp = lx
  cp.nextToken()

# ---------------------------------------------------------------------------
# Addresses (RFC 5322 section 3.4)
# ---------------------------------------------------------------------------

proc addrSpecOf*(m: MimeMailbox): string {.inline.} =
  m.localPart & "@" & m.domain

proc `$`*(m: MimeMailbox): string =
  if m.displayName.isSome and m.displayName.get.len > 0:
    "\"" & m.displayName.get.replace("\\", "\\\\").replace("\"", "\\\"") &
      "\" <" & m.addrSpecOf() & ">"
  else:
    m.addrSpecOf()

proc parseMailboxRest(lx: var MimeLexer; first: MimeToken): MimeMailbox =
  ## Parse the remainder of a mailbox given its first token. Handles
  ## `display-name <addr>`, bare `addr-spec`, and obsolete route syntax.
  var toks: seq[MimeToken] = @[]
  var t = first
  # Collect phrase tokens up to `<`, `@`, or end.
  while true:
    if t.kind == tkEnd:
      break
    if t.kind == tkSpecial and (t.text == "<" or t.text == "@"):
      break
    toks.add(t)
    t = lx.nextToken()
  if t.kind == tkSpecial and t.text == "<":
    # name-addr: display name is toks, now parse angle-addr.
    var displayName = ""
    for tk in toks:
      if displayName.len > 0 and tk.text notin [",", ".", ";", ":", ")",
          "@", ">", "]"] and not displayName.endsWith("("):
        displayName.add(" ")
      displayName.add(tk.text)
    displayName = decodeEncodedWords(displayName.strip(), lx.opts)
    # Optional obsolete route: <@a,@b:local@domain>
    var inner = lx.nextToken()
    if inner.kind == tkSpecial and inner.text == "@":
      # Skip route to ':'.
      var depth = 0
      while true:
        let r = lx.nextToken()
        if r.kind == tkEnd:
          if lx.opts.policy == mpStrict:
            mimeError("unterminated route in angle-addr")
          break
        if r.kind == tkSpecial and r.text == ":" and depth == 0:
          break
        if r.kind == tkSpecial and r.text == "<": inc depth
        if r.kind == tkSpecial and r.text == ">":
          if depth == 0: break
          dec depth
      inner = lx.nextToken()
    # local-part (dot-atom or quoted).
    var local = ""
    if inner.kind == tkQuoted:
      local = "\"" & inner.text.replace("\\", "\\\\").replace("\"", "\\\"") & "\""
      inner = lx.nextToken()
    elif inner.kind == tkAtom:
      local = inner.text
      while true:
        let p = lx.peekToken()
        if p.kind == tkSpecial and p.text == ".":
          discard lx.nextToken()
          let nxt = lx.nextToken()
          if nxt.kind == tkAtom:
            local.add("." & nxt.text)
          elif nxt.kind == tkQuoted:
            local.add(".\"" & nxt.text.replace("\\", "\\\\").replace("\"", "\\\"") & "\"")
          else:
            if lx.opts.policy == mpStrict:
              mimeError("expected atom after dot in local-part")
            break
        else:
          break
      inner = lx.nextToken()
    else:
      if lx.opts.policy == mpStrict:
        mimeError("expected local-part in angle-addr")
      local = inner.text
    if not (inner.kind == tkSpecial and inner.text == "@"):
      if lx.opts.policy == mpStrict:
        mimeError("expected @ in angle-addr")
    let dom = lx.nextToken()
    var domain = ""
    if dom.kind == tkAtom:
      domain = dom.text
      while true:
        let p = lx.peekToken()
        if p.kind == tkSpecial and p.text == ".":
          discard lx.nextToken()
          let nxt = lx.nextToken()
          if nxt.kind == tkAtom:
            domain.add("." & nxt.text)
          else:
            if lx.opts.policy == mpStrict:
              mimeError("expected atom after dot in domain")
            break
        else:
          break
    elif dom.kind == tkDomain:
      domain = "[" & dom.text & "]"
    elif dom.kind == tkQuoted:
      domain = dom.text
    else:
      if lx.opts.policy == mpStrict:
        mimeError("expected domain in angle-addr")
      domain = dom.text
    let closing = lx.nextToken()
    if not (closing.kind == tkSpecial and closing.text == ">"):
      if lx.opts.policy == mpStrict:
        mimeError("expected > to close angle-addr")
    result = MimeMailbox(
      displayName: if displayName.len > 0: some(displayName) else: none(string),
      localPart: local, domain: domain)
  elif t.kind == tkSpecial and t.text == "@":
    # Bare addr-spec: toks form the local part.
    var local = ""
    for i, tk in toks:
      if i > 0 and tk.kind == tkAtom and toks[i - 1].kind == tkAtom:
        local.add(" ")
      if tk.kind == tkQuoted:
        local.add("\"" & tk.text.replace("\\", "\\\\").replace("\"", "\\\"") & "\"")
      else:
        local.add(tk.text)
      # Re-insert dots consumed as specials? Dots arrive as tkSpecial "."
      # only when between atoms, handled below via peek loop instead.
    # The toks loop above misses separators; rebuild properly:
    local = ""
    var firstTok = true
    # Re-scan: local part tokens were atoms/quoted separated by dots or
    # spaces. Spaces between atoms without dots are invalid; keep lenient.
    for tk in toks:
      if tk.kind == tkSpecial and tk.text == ".":
        local.add(".")
        firstTok = true
      else:
        if not firstTok and tk.kind == tkAtom:
          local.add(" ")
        if tk.kind == tkQuoted:
          local.add("\"" & tk.text.replace("\\", "\\\\").replace("\"", "\\\"") & "\"")
        else:
          local.add(tk.text)
        firstTok = false
    let dom = lx.nextToken()
    var domain = ""
    if dom.kind == tkAtom:
      domain = dom.text
      while true:
        let p = lx.peekToken()
        if p.kind == tkSpecial and p.text == ".":
          discard lx.nextToken()
          let nxt = lx.nextToken()
          if nxt.kind == tkAtom:
            domain.add("." & nxt.text)
          else:
            if lx.opts.policy == mpStrict:
              mimeError("expected atom after dot in domain")
            break
        else:
          break
    elif dom.kind == tkDomain:
      domain = "[" & dom.text & "]"
    else:
      if lx.opts.policy == mpStrict:
        mimeError("expected domain in addr-spec")
      domain = dom.text
    result = MimeMailbox(displayName: none(string), localPart: local,
      domain: domain)
  else:
    if lx.opts.policy == mpStrict:
      mimeError("expected < or @ in mailbox")
    var local = ""
    for tk in toks:
      local.add(tk.text)
    result = MimeMailbox(displayName: none(string), localPart: local,
      domain: "")

proc parseAddressList*(s: string; opts: MimeOptions = defaultMimeOptions()):
    seq[MimeAddress] =
  ## Parse an address-list (To, Cc) or mailbox-list (From). Groups
  ## (`name: mbox, ...;`) become `maGroup` entries.
  result = @[]
  var lx = MimeLexer(s: s, pos: 0, opts: opts)
  while true:
    lx.skipCfws()
    if lx.pos >= lx.s.len: break
    var t = lx.nextToken()
    if t.kind == tkEnd: break
    if t.kind == tkSpecial and t.text == ",":
      continue
    if t.kind == tkSpecial and t.text == ";":
      if opts.policy == mpStrict:
        mimeError("stray ; in address list")
      continue
    # Look ahead for group syntax: display-name ":".
    if t.kind == tkAtom or t.kind == tkQuoted:
      let p = lx.peekToken()
      if p.kind == tkSpecial and p.text == ":":
        discard lx.nextToken() # consume ':'
        var members: seq[MimeMailbox] = @[]
        while true:
          lx.skipCfws()
          if lx.pos >= lx.s.len: break
          let q = lx.peekToken()
          if q.kind == tkSpecial and q.text == ";":
            discard lx.nextToken()
            break
          if q.kind == tkEnd:
            if opts.policy == mpStrict:
              mimeError("unterminated group")
            break
          if q.kind == tkSpecial and q.text == ",":
            discard lx.nextToken()
            continue
          let m0 = lx.nextToken()
          members.add(parseMailboxRest(lx, m0))
        result.add(MimeAddress(kind: maGroup,
          groupName: decodeEncodedWords(t.text, opts), members: members))
        continue
    result.add(MimeAddress(kind: maMailbox,
      mailbox: parseMailboxRest(lx, t)))
    lx.skipCfws()
    if lx.pos < lx.s.len and lx.s[lx.pos] == ',':
      inc lx.pos
      continue
    elif lx.pos < lx.s.len and lx.s[lx.pos] == ';':
      if opts.policy == mpStrict:
        mimeError("stray ; in address list")
      inc lx.pos

proc parseMailboxList*(s: string; opts: MimeOptions = defaultMimeOptions()):
    seq[MimeMailbox] =
  ## Parse a mailbox-list (From, Sender, Reply-To), flattening groups.
  result = @[]
  for a in parseAddressList(s, opts):
    case a.kind
    of maMailbox:
      result.add(a.mailbox)
    of maGroup:
      for m in a.members:
        result.add(m)

proc formatAddress*(a: MimeAddress): string =
  case a.kind
  of maMailbox: $a.mailbox
  of maGroup:
    var inner = ""
    for i, m in a.members:
      if i > 0: inner.add(", ")
      inner.add($m)
    a.groupName & ": " & inner & ";"

# ---------------------------------------------------------------------------
# Date-time (RFC 5322 section 3.3)
# ---------------------------------------------------------------------------

const mimeMonths = ["jan", "feb", "mar", "apr", "may", "jun",
  "jul", "aug", "sep", "oct", "nov", "dec"]

const mimeObsZones = [
  ("ut", 0), ("gmt", 0), ("z", 0),
  ("est", -300), ("edt", -240),
  ("cst", -360), ("cdt", -300),
  ("mst", -420), ("mdt", -360),
  ("pst", -480), ("pdt", -420)]

proc parseMimeDate*(s: string; opts: MimeOptions = defaultMimeOptions()):
    MimeDate =
  ## Parse a Date field body. Accepts obsolete day names, 2-digit years
  ## and obsolete zone names; preserves the raw text and zone label.
  let raw = s.strip()
  var lx = MimeLexer(s: removeComments(raw, opts), pos: 0, opts: opts)
  var toks: seq[string] = @[]
  while true:
    let t = lx.nextToken()
    if t.kind == tkEnd: break
    if t.kind == tkSpecial and (t.text == "," or t.text == ":"):
      toks.add(t.text)
    else:
      toks.add(t.text)
  # Drop optional day-of-week prefix ("Mon,").
  var i = 0
  if toks.len >= 2 and toks[1] == ",":
    i = 2
  if toks.len - i < 5:
    mimeError("invalid date-time: " & raw)
  let day = try: parseInt(toks[i]) except ValueError: -1
  let mon = toks[i + 1].toLowerAscii()
  var month = mimeMonths.find(mon) + 1
  var year = try: parseInt(toks[i + 2]) except ValueError: -1
  if day < 1 or day > 31 or month < 1 or year < 0:
    mimeError("invalid date-time: " & raw)
  if year < 100:
    # RFC 822 obsolete 2-digit year: 00-49 -> 2000s, 50-99 -> 1900s.
    year += (if year < 50: 2000 else: 1900)
  var hour = try: parseInt(toks[i + 3]) except ValueError: -1
  var minute = 0
  var second = 0
  var j = i + 4
  if j < toks.len and toks[j] == ":":
    if j + 1 >= toks.len:
      mimeError("invalid date-time: " & raw)
    minute = try: parseInt(toks[j + 1]) except ValueError: -1
    j += 2
    if j < toks.len and toks[j] == ":":
      if j + 1 >= toks.len:
        mimeError("invalid date-time: " & raw)
      second = try: parseInt(toks[j + 1]) except ValueError: -1
      j += 2
  else:
    # Obsolete HHMM without colon.
    if toks[i + 3].len == 4:
      hour = try: parseInt(toks[i + 3][0 .. 1]) except ValueError: -1
      minute = try: parseInt(toks[i + 3][2 .. 3]) except ValueError: -1
    else:
      mimeError("invalid date-time: " & raw)
  if hour < 0 or hour > 23 or minute < 0 or minute > 59 or
      second < 0 or second > 60:
    mimeError("invalid date-time: " & raw)
  var zone = ""
  var offset: Option[int] = none(int)
  if j < toks.len:
    zone = toks[j]
    if zone.len == 5 and (zone[0] == '+' or zone[0] == '-'):
      try:
        let zh = parseInt(zone[1 .. 2])
        let zm = parseInt(zone[3 .. 4])
        if zh > 23 or zm > 59:
          raise newException(ValueError, "bad zone")
        offset = some((if zone[0] == '-': -1 else: 1) * (zh * 60 + zm))
      except ValueError:
        if opts.policy == mpStrict:
          mimeError("invalid zone in date-time: " & raw)
    else:
      let zl = zone.toLowerAscii()
      var found = false
      for (nm, off) in mimeObsZones:
        if zl == nm:
          offset = some(off)
          found = true
          break
      if not found and zl.len == 1:
        # Obsolete military single-letter zone: unknown offset, keep raw.
        offset = none(int)
      elif not found and opts.policy == mpStrict:
        mimeError("unknown zone in date-time: " & raw)
  MimeDate(raw: raw, year: year, month: month, day: day, hour: hour,
    minute: minute, second: second, offsetMinutes: offset, zone: zone)

proc formatMimeDate*(d: MimeDate): string =
  ## Format a date-time with numeric zone (offset or +0000).
  const mons = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
  var zone = "+0000"
  if d.offsetMinutes.isSome:
    let off = d.offsetMinutes.get
    let sign = if off < 0: "-" else: "+"
    let a = abs(off)
    zone = sign & align($ (a div 60), 2, '0') & align($ (a mod 60), 2, '0')
  elif d.zone.len > 0:
    zone = d.zone
  $d.day & " " & mons[d.month - 1] & " " & $d.year & " " &
    align($d.hour, 2, '0') & ":" & align($d.minute, 2, '0') & ":" &
    align($d.second, 2, '0') & " " & zone

# ---------------------------------------------------------------------------
# Message IDs (RFC 5322 section 3.6.4)
# ---------------------------------------------------------------------------

proc parseMessageIds*(s: string; opts: MimeOptions = defaultMimeOptions()):
    seq[string] =
  ## Parse In-Reply-To / References bodies into a list of msg-ids
  ## (angle brackets stripped). Bare tokens are kept leniently.
  result = @[]
  var lx = MimeLexer(s: s, pos: 0, opts: opts)
  while true:
    let t = lx.nextToken()
    if t.kind == tkEnd: break
    if t.kind == tkSpecial and t.text == "<":
      var inner = ""
      while true:
        let u = lx.nextToken()
        if u.kind == tkEnd:
          if opts.policy == mpStrict:
            mimeError("unterminated msg-id")
          break
        if u.kind == tkSpecial and u.text == ">":
          break
        inner.add(u.text)
      if inner.len > 0:
        result.add(inner)
    elif t.kind == tkAtom and '@' in t.text:
      result.add(t.text) # lenient: id without brackets
    elif opts.policy == mpStrict and t.kind != tkSpecial:
      mimeError("invalid msg-id: " & t.text)

proc formatMessageId*(id: string): string {.inline.} =
  "<" & id & ">"

# ---------------------------------------------------------------------------
# Encoded words (RFC 2047)
# ---------------------------------------------------------------------------

proc decodeBWord*(text, charset: string; opts: MimeOptions): string =
  var clean = newStringOfCap(text.len)
  for c in text:
    if c notin {' ', '\t', '\r', '\n'}:
      clean.add(c)
  var raw: string
  try:
    raw = base64.decode(clean)
  except CatchableError:
    if opts.policy == mpStrict:
      mimeError("invalid B encoded-word")
    return "=?" & charset & "?B?" & text & "?="
  decodeTextBytes(stringToBytes(raw), charset, opts)

proc decodeQWord*(text, charset: string; opts: MimeOptions): string =
  var raw = newSeqOfCap[byte](text.len)
  var i = 0
  while i < text.len:
    if text[i] == '_':
      raw.add(byte(ord(' ')))
      inc i
    elif text[i] == '=' and i + 2 < text.len and
        isHexDigit(text[i + 1]) and isHexDigit(text[i + 2]):
      raw.add(byte(hexVal(text[i + 1]) * 16 + hexVal(text[i + 2])))
      i += 3
    else:
      if opts.policy == mpStrict:
        mimeError("invalid Q encoded-word")
      raw.add(byte(ord(text[i])))
      inc i
  decodeTextBytes(raw, charset, opts)

proc matchEncodedWord(s: string; at: int):
    tuple[ok: bool, charset, enc, text: string, next: int] =
  ## Match `=?charset?enc?text?=` at position `at`.
  if at + 1 >= s.len or s[at] != '=' or s[at + 1] != '?':
    return (false, "", "", "", at)
  let q1 = s.find('?', at + 2)
  if q1 < 0: return (false, "", "", "", at)
  let q2 = s.find('?', q1 + 1)
  if q2 < 0: return (false, "", "", "", at)
  let q3 = s.find("?=", q2 + 1)
  if q3 < 0: return (false, "", "", "", at)
  let charset = s[at + 2 ..< q1]
  let enc = s[q1 + 1 ..< q2]
  let text = s[q2 + 1 ..< q3]
  if charset.len == 0 or text.len == 0 or
      not (enc == "B" or enc == "b" or enc == "Q" or enc == "q"):
    return (false, "", "", "", at)
  (true, charset, enc, text, q3 + 2)

proc unfoldEncodedInput(s: string): string =
  ## Remove folding breaks (CR/LF followed by WSP) so folded encoded
  ## words decode like their unfolded form.
  result = newStringOfCap(s.len)
  var i = 0
  while i < s.len:
    if s[i] == '\r' and i + 1 < s.len and s[i + 1] == '\n' and
        i + 2 < s.len and (s[i + 2] == ' ' or s[i + 2] == '\t'):
      i += 2
    elif s[i] == '\n' and i + 1 < s.len and
        (s[i + 1] == ' ' or s[i + 1] == '\t'):
      inc i
    else:
      result.add(s[i])
      inc i

proc decodeEncodedWords*(s: string; opts: MimeOptions = defaultMimeOptions()):
    string =
  ## Decode RFC 2047 encoded words in unstructured text. Whitespace
  ## between adjacent encoded words is ignored per section 6.2.
  let src = unfoldEncodedInput(s)
  result = newStringOfCap(src.len)
  var i = 0
  var justDecoded = false
  while i < src.len:
    let m = matchEncodedWord(src, i)
    if m.ok:
      if m.enc == "B" or m.enc == "b":
        result.add(decodeBWord(m.text, m.charset, opts))
      else:
        result.add(decodeQWord(m.text, m.charset, opts))
      justDecoded = true
      i = m.next
      continue
    elif src[i] == ' ' or src[i] == '\t':
      # Skip whitespace only when it separates adjacent encoded words.
      var j = i
      while j < src.len and (src[j] == ' ' or src[j] == '\t'):
        inc j
      let n = matchEncodedWord(src, j)
      if justDecoded and n.ok:
        i = j
        continue
      result.add(src[i ..< j])
      justDecoded = false
      i = j
      continue
    else:
      result.add(src[i])
      justDecoded = false
      inc i

proc needsEncoding*(s: string): bool =
  ## True when text contains non-ASCII bytes or overlong runs needing
  ## RFC 2047 encoding on output.
  for c in s:
    if ord(c) >= 127 or ord(c) < 32 and c notin {'\t'}:
      return true
  false

proc encodeWord*(s: string; charset = "UTF-8"): string =
  ## Encode text as a single RFC 2047 B encoded-word (UTF-8 default).
  "=?" & charset & "?B?" & base64.encode(s) & "?="

proc foldHeaderValue*(value: string; foldAt = 78): string

proc emptyPart*(): MimePart =
  ## An empty body entity with no emitted content headers.
  MimePart(contentType: defaultContentType(), contentTypePresent: false,
    transferEncoding: te7bit, transferEncodingRaw: "7bit",
    transferEncodingPresent: false, body: MimeBody(kind: mbEmpty))

proc chunkEncodedWords*(s: string; charset = "UTF-8"): seq[string] =
  ## Split non-ASCII text into encoded words, each at most 75
  ## characters, never splitting a UTF-8 sequence between words.
  let overhead = charset.len + 6 # "=?" + "?B?" + "?="
  var maxBytes = (75 - overhead) div 4 * 3
  if maxBytes < 12:
    maxBytes = 12
  result = @[]
  var i = 0
  while i < s.len:
    var j = min(i + maxBytes, s.len)
    # Back to a UTF-8 character boundary: first over continuation bytes,
    # then past a lead byte whose continuation was cut off.
    while j > i and (ord(s[j - 1]) and 0xC0) == 0x80:
      dec j
    if j > i and j < s.len and (ord(s[j - 1]) and 0xC0) == 0xC0 and
        (ord(s[j]) and 0xC0) == 0x80:
      dec j
    if j <= i:
      # Degenerate: advance one full character to guarantee progress.
      j = i + 1
      while j < s.len and (ord(s[j]) and 0xC0) == 0x80:
        inc j
    result.add("=?" & charset & "?B?" & base64.encode(s[i ..< j]) & "?=")
    i = j

proc encodeUnstructured*(s: string; opts: MimeOptions = defaultMimeOptions()):
    string =
  ## Fold unstructured header text, encoding non-ASCII runs as encoded
  ## words. Runs are concatenated without added spaces; lines break at
  ## spaces inside ASCII text or between adjacent encoded words (where
  ## the folding whitespace is ignored on decode). Output lines never
  ## exceed 998 characters.
  if s.len == 0: return ""
  if not needsEncoding(s):
    return foldHeaderValue(s, opts.foldAt)
  # Tokenize into ASCII runs and encoded words.
  var toks: seq[tuple[word: bool, text: string]] = @[]
  var i = 0
  while i < s.len:
    if ord(s[i]) < 128:
      var j = i
      while j < s.len and ord(s[j]) < 128:
        inc j
      toks.add((false, s[i ..< j]))
      i = j
    else:
      var j = i
      while j < s.len and ord(s[j]) >= 128:
        inc j
      for w in chunkEncodedWords(s[i ..< j]):
        toks.add((true, w))
      i = j
  var res = newStringOfCap(s.len + 32)
  var col = 0
  var prevWord = false
  template emitBreak() =
    res.add("\r\n ")
    col = 1
  for tok in toks:
    if not tok.word:
      var rest = tok.text
      while rest.len > 0:
        if col + rest.len <= opts.foldAt:
          res.add(rest)
          col += rest.len
          rest = ""
        else:
          let room = opts.foldAt - col
          var sp = -1
          var k = 0
          while k < rest.len and k < room:
            if rest[k] == ' ' or rest[k] == '\t':
              sp = k
            inc k
          if sp < 0:
            if col <= 1:
              res.add(rest) # overlong but unfoldable; keep text intact
              col += rest.len
              rest = ""
            else:
              emitBreak()
          else:
            res.add(rest[0 ..< sp])
            col += sp
            if sp + 1 < rest.len:
              rest = rest[sp + 1 .. ^1]
            else:
              rest = ""
            emitBreak()
      prevWord = false
    else:
      if col == 0:
        res.add(tok.text)
        col += tok.text.len
      elif prevWord and col + tok.text.len + 1 > opts.foldAt:
        # Whitespace between adjacent encoded words is ignored.
        emitBreak()
        res.add(tok.text)
        col += tok.text.len
      else:
        # After ASCII text only concatenation is faithful; overflow if
        # it does not fit rather than insert a spurious space.
        res.add(tok.text)
        col += tok.text.len
      prevWord = true
  res

# ---------------------------------------------------------------------------
# RFC 2231 parameter continuations and encoding
# ---------------------------------------------------------------------------

proc percentDecodeRfc2231*(s: string; opts: MimeOptions = defaultMimeOptions()):
    seq[byte] =
  ## Percent-decode an RFC 2231 encoded parameter section.
  result = newSeqOfCap[byte](s.len)
  var i = 0
  while i < s.len:
    if s[i] == '%':
      if i + 2 < s.len and isHexDigit(s[i + 1]) and isHexDigit(s[i + 2]):
        result.add(byte(hexVal(s[i + 1]) * 16 + hexVal(s[i + 2])))
        i += 3
      else:
        if opts.policy == mpStrict:
          mimeError("invalid percent escape in RFC 2231 parameter")
        result.add(byte(ord('%')))
        inc i
    else:
      result.add(byte(ord(s[i])))
      inc i

proc decodeRfc2231Params*(params: seq[MimeParam];
    opts: MimeOptions = defaultMimeOptions()): seq[MimeParam] =
  ## Reassemble RFC 2231 continuations (`name*0*`, `name*1`, `name*`)
  ## into single decoded params. Plain params pass through untouched.
  result = @[]
  var i = 0
  while i < params.len:
    let nm = params[i].name
    # Find the base name and segment info for extended params.
    var base = ""
    var segIdx = -2 # -2 = not extended
    var segEnc = false
    if nm.len > 0 and nm[^1] == '*':
      let inner = nm[0 ..< ^1]
      let star = inner.rfind('*')
      if star >= 0:
        let numPart = inner[star + 1 .. ^1]
        var allDigits = numPart.len > 0
        for c in numPart:
          if c notin {'0' .. '9'}:
            allDigits = false
            break
        if allDigits:
          base = inner[0 ..< star]
          segIdx = parseInt(numPart)
          segEnc = true
        else:
          base = inner
          segIdx = -1
          segEnc = true
      else:
        base = inner
        segIdx = -1
        segEnc = true
    if segIdx == -2:
      result.add(params[i])
      inc i
      continue
    # Collect every segment sharing this base name.
    type Seg = tuple[idx: int, enc: bool, value: string, at: int]
    var segs: seq[Seg] = @[]
    var j = i
    while j < params.len:
      let m = params[j].name
      if m == base & "*":
        segs.add((-1, true, params[j].value, j))
      elif m.len > base.len + 1 and m.startsWith(base & "*"):
        let rest = m[base.len + 1 .. ^1]
        var num = ""
        var enc = false
        if rest.len > 0 and rest[^1] == '*':
          enc = true
          num = rest[0 ..< ^1]
        else:
          num = rest
        var allDigits = num.len > 0
        for c in num:
          if c notin {'0' .. '9'}:
            allDigits = false
            break
        if allDigits:
          segs.add((parseInt(num), enc, params[j].value, j))
        else:
          break
      elif m == base:
        discard # plain duplicate; extended form wins
      else:
        break
      inc j
    # Order segments; `name*` alone counts as segment 0.
    var ordered: seq[Seg] = @[]
    for sg in segs:
      let normIdx = if sg.idx < 0: 0 else: sg.idx
      ordered.add((normIdx, sg.enc, sg.value, sg.at))
    # Insertion sort by index (segment counts are tiny).
    for a in 1 ..< ordered.len:
      var b = a
      while b > 0 and ordered[b].idx < ordered[b - 1].idx:
        swap(ordered[b], ordered[b - 1])
        dec b
    var charset = "us-ascii"
    var lang = ""
    var combined = ""
    for k, sg in ordered:
      var piece = sg.value
      if k == 0 and sg.enc:
        let q1 = piece.find('\'')
        if q1 >= 0:
          let q2 = piece.find('\'', q1 + 1)
          if q2 >= 0:
            charset = piece[0 ..< q1]
            lang = piece[q1 + 1 ..< q2]
            piece = piece[q2 + 1 .. ^1]
      combined.add(bytesToString(percentDecodeRfc2231(piece, opts)))
    let decoded = decodeTextBytes(stringToBytes(combined), charset, opts)
    result.add(MimeParam(name: base, value: decoded,
      charset: some(charset), language: some(lang)))
    i = j

proc parseDisposition*(s: string; opts: MimeOptions = defaultMimeOptions()):
    MimeDisposition =
  ## Parse a Content-Disposition field body (RFC 2183).
  let chunks = splitOutsideQuotes(removeComments(s, opts), ';')
  let kind = if chunks.len > 0: chunks[0].strip().toLowerAscii() else: ""
  var rest = ""
  if chunks.len > 1:
    rest = chunks[1 .. ^1].join(";")
  MimeDisposition(kind: kind,
    params: decodeRfc2231Params(parseParams(rest, opts), opts))

proc filenameOf*(part: MimePart): Option[string] =
  ## Attachment filename: disposition `filename` wins, then the
  ## content-type `name` parameter.
  if part.disposition.isSome:
    for p in part.disposition.get.params:
      if p.name == "filename":
        return some(p.value)
  for p in part.contentType.params:
    if p.name == "name":
      return some(p.value)
  none(string)

# ---------------------------------------------------------------------------
# Entity and message parsing
# ---------------------------------------------------------------------------

proc headerValues(headers: seq[MimeHeader]; name: string): seq[string] =
  let key = name.toLowerAscii()
  for h in headers:
    if h.name.toLowerAscii() == key:
      result.add(h.value)

proc headerFirst(headers: seq[MimeHeader]; name: string): Option[string] =
  let vals = headerValues(headers, name)
  if vals.len > 0: some(vals[0]) else: none(string)

proc decodeBodyCte(body: string; enc: MimeTransferEncoding;
    raw: string; opts: MimeOptions): seq[byte] =
  ## Apply Content-Transfer-Encoding decoding to a raw body.
  case enc
  of te7bit:
    if opts.policy == mpStrict:
      for c in body:
        if ord(c) > 127:
          mimeError("non-ASCII byte in 7bit body")
    stringToBytes(body)
  of te8bit, teBinary:
    stringToBytes(body)
  of teQuotedPrintable:
    decodeQuotedPrintable(body, opts)
  of teBase64:
    decodeBase64Body(body, opts)
  of teUnknown:
    if opts.policy == mpStrict:
      mimeError("unknown Content-Transfer-Encoding: " & raw)
    stringToBytes(body)

proc checkCteConstraints(ct: MimeContentType; enc: MimeTransferEncoding;
    raw: string; opts: MimeOptions) =
  ## RFC 2046 CTE restrictions for composite types (strict only).
  if opts.policy != mpStrict: return
  if ct.isMultipart() and
      (enc == teQuotedPrintable or enc == teBase64):
    mimeError("multipart entity must not use " & raw & " transfer encoding")
  if ct.isMessage() and ct.subType.toLowerAscii() == "rfc822" and
      (enc == teQuotedPrintable or enc == teBase64):
    mimeError("message/rfc822 entity must not use " & raw &
      " transfer encoding")

type MimeLine = tuple[text: string, start, next: int]

proc nextLine(s: string; pos: int): MimeLine =
  ## Return a line without its break plus byte offsets. Handles CRLF,
  ## lone LF and lone CR.
  var i = pos
  while i < s.len and s[i] != '\r' and s[i] != '\n':
    inc i
  let text = s[pos ..< i]
  var nxt = i
  if nxt < s.len and s[nxt] == '\r':
    inc nxt
    if nxt < s.len and s[nxt] == '\n':
      inc nxt
  elif nxt < s.len and s[nxt] == '\n':
    inc nxt
  (text, pos, nxt)

proc isDelimiterLine(line, boundary: string; closing: var bool): bool =
  ## Match `--boundary` or `--boundary--` with optional transport
  ## padding (spaces/tabs) and nothing else.
  closing = false
  let marker = "--" & boundary
  if not line.startsWith(marker):
    return false
  var rest = line[marker.len .. ^1]
  if rest.startsWith("--"):
    closing = true
    rest = rest[2 .. ^1]
  for c in rest:
    if c != ' ' and c != '\t':
      return false
  true

proc stripOneBreak(s: string): string =
  ## Remove a single trailing CRLF / LF / CR (the break belonging to a
  ## boundary delimiter, not to the part body).
  if s.endsWith("\r\n"): s[0 ..< ^2]
  elif s.endsWith("\n") or s.endsWith("\r"): s[0 ..< ^1]
  else: s

proc splitMultipartBody*(body, boundary: string;
    opts: MimeOptions = defaultMimeOptions()):
    tuple[preamble: string, parts: seq[string], epilogue: string,
      closed: bool] =
  ## Split a multipart body on its boundary. Preamble and epilogue are
  ## preserved verbatim; each part keeps its raw headers-plus-body text.
  result = ("", @[], "", false)
  if boundary.len == 0 or boundary.len > 70:
    if opts.policy == mpStrict:
      mimeError("invalid multipart boundary")
    return result
  var pos = 0
  # Find the first delimiter line.
  var firstStart = -1
  var firstNext = 0
  while pos <= body.len:
    let ln = nextLine(body, pos)
    var closing = false
    if isDelimiterLine(ln.text, boundary, closing):
      firstStart = ln.start
      firstNext = ln.next
      if closing:
        # Degenerate: closing delimiter with no parts.
        result.epilogue = body[ln.next .. ^1]
        result.closed = true
        return result
      break
    if ln.next <= pos:
      break
    pos = ln.next
  if firstStart < 0:
    if opts.policy == mpStrict:
      mimeError("multipart body without boundary delimiter")
    return result # lenient: no parts; caller falls back to raw data
  result.preamble = stripOneBreak(body[0 ..< firstStart])
  pos = firstNext
  var partStart = pos
  while pos <= body.len:
    let ln = nextLine(body, pos)
    var closing = false
    if isDelimiterLine(ln.text, boundary, closing):
      result.parts.add(stripOneBreak(body[partStart ..< ln.start]))
      if closing:
        result.epilogue = body[ln.next .. ^1]
        result.closed = true
        return result
      partStart = ln.next
    if ln.next <= pos:
      break
    pos = ln.next
  # Ran out without a closing delimiter.
  if opts.policy == mpStrict:
    mimeError("multipart body without closing boundary")
  # lenient: keep parts found so far as-is
  result.closed = false

proc parseEntity*(headers: seq[MimeHeader]; body: string;
    opts: MimeOptions = defaultMimeOptions(); depth = 0;
    partCount: var int): MimePart

proc buildMessage*(headers: seq[MimeHeader]; body: string;
    opts: MimeOptions = defaultMimeOptions(); depth = 0;
    partCount: var int): MimeMessage

proc parseEntity*(headers: seq[MimeHeader]; body: string;
    opts: MimeOptions = defaultMimeOptions(); depth = 0;
    partCount: var int): MimePart =
  ## Parse one MIME entity (content headers plus raw body) into a typed
  ## part with a transfer- and charset-decoded body.
  if depth > opts.maxDepth:
    mimeError("MIME nesting exceeds maxDepth")
  inc partCount
  if partCount > opts.maxParts:
    mimeError("MIME message exceeds maxParts")
  if body.len > opts.maxBodyBytes and opts.policy == mpStrict:
    mimeError("MIME body exceeds maxBodyBytes")
  result = MimePart(body: MimeBody(kind: mbEmpty))
  # Content-Type.
  let ctRaw = headerFirst(headers, "content-type")
  if ctRaw.isSome:
    result.contentTypePresent = true
    try:
      result.contentType = parseContentType(ctRaw.get, opts)
    except OpenParserMimeError:
      if opts.policy == mpStrict:
        raise
      result.contentType = MimeContentType(mainType: "application",
        subType: "octet-stream", params: @[])
    result.contentType.params =
      decodeRfc2231Params(result.contentType.params, opts)
  else:
    result.contentTypePresent = false
    result.contentType = defaultContentType()
  # Content-Transfer-Encoding.
  let cteRaw = headerFirst(headers, "content-transfer-encoding")
  if cteRaw.isSome:
    result.transferEncodingPresent = true
    let (enc, raw) = parseTransferEncoding(cteRaw.get)
    result.transferEncoding = enc
    result.transferEncodingRaw = raw
  else:
    result.transferEncodingPresent = false
    result.transferEncoding = te7bit
    result.transferEncodingRaw = "7bit"
  checkCteConstraints(result.contentType, result.transferEncoding,
    result.transferEncodingRaw, opts)
  # Other content headers.
  let cid = headerFirst(headers, "content-id")
  if cid.isSome: result.contentId = cid
  let cdesc = headerFirst(headers, "content-description")
  if cdesc.isSome:
    result.contentDescription = some(decodeEncodedWords(cdesc.get, opts))
  let cdisp = headerFirst(headers, "content-disposition")
  if cdisp.isSome:
    try:
      result.disposition = some(parseDisposition(cdisp.get, opts))
    except OpenParserMimeError:
      if opts.policy == mpStrict:
        raise
  let clang = headerFirst(headers, "content-language")
  if clang.isSome:
    for piece in splitOutsideQuotes(clang.get, ','):
      let t = piece.strip()
      if t.len > 0:
        result.contentLanguage.add(t)
  let cloc = headerFirst(headers, "content-location")
  if cloc.isSome: result.contentLocation = cloc
  # Unknown headers (including unknown content-*) are preserved.
  const knownPartHeaders = ["content-type", "content-transfer-encoding",
    "content-id", "content-description", "content-disposition",
    "content-language", "content-location"]
  for h in headers:
    if h.name.toLowerAscii() notin knownPartHeaders:
      result.extraHeaders.add(h)
  # Decode the transfer encoding, then dispatch on media type.
  let decoded = decodeBodyCte(body, result.transferEncoding,
    result.transferEncodingRaw, opts)
  if opts.policy == mpStrict and decoded.len > opts.maxBodyBytes:
    mimeError("MIME body exceeds maxBodyBytes")
  let ct = result.contentType
  if ct.isMultipart():
    let b = ct.boundaryOf()
    if b.isNone or b.get.len == 0:
      if opts.policy == mpStrict:
        mimeError("multipart entity without boundary parameter")
      result.body = MimeBody(kind: mbData, data: decoded)
      return result
    let split = splitMultipartBody(body, b.get, opts)
    if split.parts.len == 0 and not split.closed:
      # Lenient fallback: no usable delimiters, keep raw bytes.
      result.body = MimeBody(kind: mbData, data: decoded)
      return result
    var parts: seq[MimePart] = @[]
    for praw in split.parts:
      let (phead, pbody) = splitHeadersBody(praw, opts)
      parts.add(parseEntity(parseHeaderBlock(phead, opts), pbody, opts,
        depth + 1, partCount))
    result.body = MimeBody(kind: mbMultipart, subtype: ct.subType,
      boundary: b.get, preamble: split.preamble, parts: parts,
      epilogue: split.epilogue)
  elif ct.isMessage() and ct.subType.toLowerAscii() == "rfc822":
    let nested = bytesToString(decoded)
    let (nhead, nbody) = splitHeadersBody(nested, opts)
    result.body = MimeBody(kind: mbMessage,
      message: buildMessage(parseHeaderBlock(nhead, opts), nbody, opts,
        depth + 1, partCount))
  elif ct.isText():
    if decoded.len == 0:
      result.body = MimeBody(kind: mbEmpty)
    else:
      let norm = normalizeTextLineEndings(decoded)
      result.body = MimeBody(kind: mbText,
        text: decodeTextBytes(norm, ct.charsetOf(), opts),
        charset: ct.charsetOf(), raw: norm)
  else:
    if decoded.len == 0:
      result.body = MimeBody(kind: mbEmpty)
    else:
      result.body = MimeBody(kind: mbData, data: decoded)

proc tryParseDate(s: string; opts: MimeOptions): Option[MimeDate] =
  try:
    some(parseMimeDate(s, opts))
  except OpenParserMimeError:
    if opts.policy == mpStrict:
      raise
    none(MimeDate)

proc tryParseAddresses(s: string; opts: MimeOptions): seq[MimeAddress] =
  try:
    parseAddressList(s, opts)
  except OpenParserMimeError:
    if opts.policy == mpStrict:
      raise
    @[]

proc tryParseMailboxes(s: string; opts: MimeOptions): seq[MimeMailbox] =
  try:
    parseMailboxList(s, opts)
  except OpenParserMimeError:
    if opts.policy == mpStrict:
      raise
    @[]

proc tryParseIds(s: string; opts: MimeOptions): seq[string] =
  try:
    parseMessageIds(s, opts)
  except OpenParserMimeError:
    if opts.policy == mpStrict:
      raise
    @[]

proc stripMsgId(s: string; opts: MimeOptions): string =
  let t = s.strip()
  if t.len >= 2 and t[0] == '<' and t[^1] == '>':
    t[1 ..< ^1]
  elif opts.policy == mpStrict:
    mimeError("Message-ID without angle brackets: " & s)
  else:
    t

proc buildMessage*(headers: seq[MimeHeader]; body: string;
    opts: MimeOptions = defaultMimeOptions(); depth = 0;
    partCount: var int): MimeMessage =
  ## Assemble a top-level message from parsed headers and a raw body.
  result = MimeMessage()
  if opts.policy == mpStrict:
    # RFC 5322 section 3.6: origination Date and From are required.
    if headerFirst(headers, "date").isNone:
      mimeError("strict: message without Date")
    if headerFirst(headers, "from").isNone:
      mimeError("strict: message without From")
  # Partition headers: content-* describe the body entity.
  var contentHeaders: seq[MimeHeader] = @[]
  const messageFields = ["date", "from", "sender", "reply-to", "to", "cc",
    "bcc", "subject", "message-id", "in-reply-to", "references",
    "comments", "keywords", "received", "return-path", "mime-version"]
  for h in headers:
    let key = h.name.toLowerAscii()
    if key.startsWith("content-"):
      contentHeaders.add(h)
    elif key notin messageFields:
      result.extraHeaders.add(h)
  let first = proc(name: string): Option[string] =
    headerFirst(headers, name)
  let dv = first("date")
  if dv.isSome:
    result.date = tryParseDate(dv.get, opts)
  let fv = first("from")
  if fv.isSome:
    result.fromAddrs = tryParseMailboxes(fv.get, opts)
  let sv = first("sender")
  if sv.isSome:
    let mbs = tryParseMailboxes(sv.get, opts)
    if mbs.len > 0:
      result.sender = some(mbs[0])
  let rv = first("reply-to")
  if rv.isSome:
    result.replyTo = tryParseMailboxes(rv.get, opts)
  let tv = first("to")
  if tv.isSome:
    result.toAddrs = tryParseAddresses(tv.get, opts)
  let ccv = first("cc")
  if ccv.isSome:
    result.cc = tryParseAddresses(ccv.get, opts)
  let bccv = first("bcc")
  if bccv.isSome:
    result.bcc = tryParseAddresses(bccv.get, opts)
  let subj = first("subject")
  if subj.isSome:
    result.subject = some(decodeEncodedWords(subj.get, opts))
  let mid = first("message-id")
  if mid.isSome:
    try:
      result.messageId = some(stripMsgId(mid.get, opts))
    except OpenParserMimeError:
      if opts.policy == mpStrict:
        raise
  let irt = first("in-reply-to")
  if irt.isSome:
    result.inReplyTo = tryParseIds(irt.get, opts)
  let refs = first("references")
  if refs.isSome:
    result.references = tryParseIds(refs.get, opts)
  let cm = first("comments")
  if cm.isSome:
    result.comments = some(decodeEncodedWords(cm.get, opts))
  let kw = first("keywords")
  if kw.isSome:
    for piece in splitOutsideQuotes(decodeEncodedWords(kw.get, opts), ','):
      let t = piece.strip()
      if t.len > 0:
        result.keywords.add(t)
  result.received = headerValues(headers, "received")
  let rp = first("return-path")
  if rp.isSome:
    result.returnPath = rp
  let mv = first("mime-version")
  if mv.isSome:
    result.mimeVersion = mv
  result.body = parseEntity(contentHeaders, body, opts, depth, partCount)

proc parseMime*(s: string; opts: MimeOptions = defaultMimeOptions()):
    MimeMessage =
  ## Parse a full RFC 5322 / MIME message from a string.
  let (head, body) = splitHeadersBody(s, opts)
  var partCount = 0
  buildMessage(parseHeaderBlock(head, opts), body, opts, 0, partCount)

proc parseMimeFile*(path: string; opts: MimeOptions = defaultMimeOptions()):
    MimeMessage =
  ## Parse a message from a file using a memory-mapped read.
  if not fileExists(path):
    mimeError("MIME file not found: " & path)
  let size = getFileSize(path)
  if size <= 0:
    mimeError("MIME file is empty: " & path)
  if size > int.high:
    mimeError("MIME file too large to map: " & path)
  var mf = memfiles.open(path, mode = fmRead, mappedSize = int(size))
  defer: mf.close()
  var s = newString(mf.size)
  if mf.size > 0:
    copyMem(addr s[0], mf.mem, mf.size)
  parseMime(s, opts)

# ---------------------------------------------------------------------------
# Serialization
# ---------------------------------------------------------------------------

proc foldHeaderValue*(value: string; foldAt = 78): string =
  ## Greedy header folding at spaces: lines stay within `foldAt`
  ## columns (plus the CRLF WSP continuation marker).
  var res = newStringOfCap(value.len + 16)
  var lineStart = 0
  var lastSp = -1
  var i = 0
  while i < value.len:
    let c = value[i]
    if c == ' ' or c == '\t':
      lastSp = i
    if i - lineStart + 1 > foldAt and lastSp > lineStart:
      res.add(value[lineStart ..< lastSp])
      res.add("\r\n ")
      lineStart = lastSp + 1
      lastSp = -1
    inc i
  if lineStart < value.len:
    res.add(value[lineStart .. ^1])
  res

proc quoteParamValue*(s: string): string =
  ## Quote a parameter value when it is not a valid token.
  var needsQuotes = s.len == 0
  for c in s:
    if not isTokenChar(c):
      needsQuotes = true
      break
  if not needsQuotes:
    return s
  result = newStringOfCap(s.len + 2)
  result.add('"')
  for c in s:
    if c == '"' or c == '\\':
      result.add('\\')
    result.add(c)
  result.add('"')

proc formatParams*(params: seq[MimeParam]): string =
  for p in params:
    if p.charset.isSome:
      # RFC 2231 encoded form: name*=charset'lang'percent-encoded.
      var enc = newStringOfCap(p.value.len * 2)
      for b in stringToBytes(p.value):
        let c = chr(b)
        if isTokenChar(c) and c != '%' and c != '*':
          enc.add(c)
        else:
          enc.add('%')
          enc.add("0123456789ABCDEF"[b shr 4])
          enc.add("0123456789ABCDEF"[b and 0x0F])
      let lang = p.language.get("")
      result.add("; " & p.name & "*=" & p.charset.get("utf-8") & "'" &
        lang & "'" & enc)
    else:
      result.add("; " & p.name & "=" & quoteParamValue(p.value))

proc formatContentType*(ct: MimeContentType): string =
  ct.mediaType() & formatParams(ct.params)

proc formatDisposition*(d: MimeDisposition): string =
  d.kind & formatParams(d.params)

var mimeBoundaryCounter = 0

proc generateBoundary*(): string =
  ## Generate a boundary marker (70 chars max, plain ASCII).
  inc mimeBoundaryCounter
  "openparser-" & $toUnix(getTime()) & "-" & $mimeBoundaryCounter & "-mime"

# Forward declarations: part and message writers are mutually recursive.
proc writePart*(part: MimePart; opts: MimeOptions = defaultMimeOptions();
  depth = 0): string
proc writeMessage*(msg: MimeMessage; opts: MimeOptions = defaultMimeOptions();
  depth = 0): string
proc writePartHeadersOnly*(part: MimePart;
  opts: MimeOptions = defaultMimeOptions()): string
proc writePartBodyOnly*(part: MimePart;
  opts: MimeOptions = defaultMimeOptions(); depth = 0): string

proc emitBodyBytes(part: MimePart; opts: MimeOptions): string =
  ## Transfer-encode a decoded body back to transport form.
  case part.body.kind
  of mbEmpty:
    ""
  of mbText:
    let raw = bytesToString(normalizeTextLineEndings(part.body.raw))
    case part.transferEncoding
    of teBase64: encodeBase64Body(stringToBytes(raw))
    of teQuotedPrintable: encodeQuotedPrintable(stringToBytes(raw))
    of te7bit:
      if opts.policy == mpStrict:
        for c in raw:
          if ord(c) > 127:
            mimeError("non-ASCII byte in 7bit text body")
      raw
    else: raw
  of mbData:
    case part.transferEncoding
    of teBase64: encodeBase64Body(part.body.data)
    of teQuotedPrintable: encodeQuotedPrintable(part.body.data)
    else: bytesToString(part.body.data)
  of mbMultipart, mbMessage:
    "" # handled by writePart

proc writePart*(part: MimePart; opts: MimeOptions = defaultMimeOptions();
    depth = 0): string =
  ## Serialize one MIME entity: content headers, blank line, body.
  if part.isNil:
    return writePart(emptyPart(), opts, depth)
  if depth > opts.maxDepth:
    mimeError("MIME nesting exceeds maxDepth")
  if part.body.kind == mbMultipart and part.body.boundary.len == 0:
    # Hand-built part without a boundary: generate and attach one
    # before headers are emitted.
    let b = generateBoundary()
    part.body.boundary = b
    var hasBoundary = false
    for p in part.contentType.params.mitems:
      if p.name == "boundary":
        p.value = b
        hasBoundary = true
    if not hasBoundary:
      part.contentType.params.add(MimeParam(name: "boundary",
        value: b, charset: none(string), language: none(string)))
    part.contentTypePresent = true
  var res = newStringOfCap(512)
  res.add(writePartHeadersOnly(part, opts))
  res.add(opts.lineEnding)
  res.add(writePartBodyOnly(part, opts, depth))
  res

proc writeMessage*(msg: MimeMessage; opts: MimeOptions = defaultMimeOptions();
    depth = 0): string =
  ## Serialize a full message: message headers, body entity headers,
  ## blank line, body.
  if msg.isNil:
    return writeMessage(MimeMessage(body: emptyPart()), opts, depth)
  var head = newStringOfCap(1024)
  proc addHeader(name, value: string) =
    head.add(name & ": " &
      foldHeaderValue(value, opts.foldAt) & opts.lineEnding)
  proc addAddrs(name: string; addrs: seq[MimeAddress]) =
    if addrs.len == 0: return
    var parts: seq[string] = @[]
    for a in addrs:
      parts.add(formatAddress(a))
    addHeader(name, parts.join(", "))
  proc addMailboxes(name: string; mbs: seq[MimeMailbox]) =
    if mbs.len == 0: return
    var parts: seq[string] = @[]
    for m in mbs:
      parts.add($m)
    addHeader(name, parts.join(", "))
  if msg.returnPath.isSome:
    addHeader("Return-Path", msg.returnPath.get)
  for r in msg.received:
    addHeader("Received", r)
  if msg.date.isSome:
    addHeader("Date", formatMimeDate(msg.date.get))
  addMailboxes("From", msg.fromAddrs)
  if msg.sender.isSome:
    addHeader("Sender", $msg.sender.get)
  addMailboxes("Reply-To", msg.replyTo)
  addAddrs("To", msg.toAddrs)
  addAddrs("Cc", msg.cc)
  addAddrs("Bcc", msg.bcc)
  if msg.subject.isSome:
    addHeader("Subject", encodeUnstructured(msg.subject.get, opts))
  if msg.messageId.isSome:
    addHeader("Message-ID", formatMessageId(msg.messageId.get))
  if msg.inReplyTo.len > 0:
    var ids: seq[string] = @[]
    for id in msg.inReplyTo:
      ids.add(formatMessageId(id))
    addHeader("In-Reply-To", ids.join(" "))
  if msg.references.len > 0:
    var ids: seq[string] = @[]
    for id in msg.references:
      ids.add(formatMessageId(id))
    addHeader("References", ids.join(" "))
  if msg.comments.isSome:
    addHeader("Comments", encodeUnstructured(msg.comments.get, opts))
  if msg.keywords.len > 0:
    addHeader("Keywords", encodeUnstructured(msg.keywords.join(", "), opts))
  if msg.mimeVersion.isSome:
    addHeader("MIME-Version", msg.mimeVersion.get)
  for h in msg.extraHeaders:
    addHeader(h.name, h.value)
  # Body entity headers, then blank line, then body content.
  let body = if msg.body.isNil: emptyPart() else: msg.body
  let partHead = writePartHeadersOnly(body, opts)
  head.add(partHead)
  head.add(opts.lineEnding)
  head.add(writePartBodyOnly(body, opts, depth))
  head

proc writePartHeadersOnly*(part: MimePart;
    opts: MimeOptions = defaultMimeOptions()): string =
  ## Serialize just the content headers of a part (no blank line).
  var res = newStringOfCap(256)
  proc addHeader(name, value: string) =
    res.add(name & ": " &
      foldHeaderValue(value, opts.foldAt) & opts.lineEnding)
  if part.contentTypePresent:
    addHeader("Content-Type", formatContentType(part.contentType))
  if part.transferEncodingPresent:
    addHeader("Content-Transfer-Encoding", part.transferEncodingRaw)
  if part.contentId.isSome:
    addHeader("Content-ID", part.contentId.get)
  if part.contentDescription.isSome:
    addHeader("Content-Description",
      encodeUnstructured(part.contentDescription.get, opts))
  if part.disposition.isSome:
    addHeader("Content-Disposition",
      formatDisposition(part.disposition.get))
  if part.contentLanguage.len > 0:
    addHeader("Content-Language", part.contentLanguage.join(", "))
  if part.contentLocation.isSome:
    addHeader("Content-Location", part.contentLocation.get)
  for h in part.extraHeaders:
    addHeader(h.name, h.value)
  res

proc writePartBodyOnly*(part: MimePart;
    opts: MimeOptions = defaultMimeOptions(); depth = 0): string =
  ## Serialize just the body of a part (headers handled elsewhere).
  case part.body.kind
  of mbEmpty:
    ""
  of mbText, mbData:
    emitBodyBytes(part, opts)
  of mbMultipart:
    var res = newStringOfCap(1024)
    var b = part.body.boundary
    if b.len == 0:
      # Hand-built part without a boundary: generate and attach one.
      b = generateBoundary()
      part.body.boundary = b
      var hasBoundary = false
      for p in part.contentType.params.mitems:
        if p.name == "boundary":
          p.value = b
          hasBoundary = true
      if not hasBoundary:
        part.contentType.params.add(MimeParam(name: "boundary",
          value: b, charset: none(string), language: none(string)))
      part.contentTypePresent = true
    if part.body.preamble.len > 0:
      res.add(part.body.preamble)
      if not part.body.preamble.endsWith("\r\n") and
          not part.body.preamble.endsWith("\n"):
        res.add(opts.lineEnding)
    for p in part.body.parts:
      res.add("--" & b & opts.lineEnding)
      res.add(writePart(p, opts, depth + 1))
      res.add(opts.lineEnding)
    res.add("--" & b & "--")
    if part.body.epilogue.len > 0:
      res.add(opts.lineEnding & part.body.epilogue)
    res
  of mbMessage:
    writeMessage(part.body.message, opts, depth + 1)

proc toMime*(msg: MimeMessage; opts: MimeOptions = defaultMimeOptions()):
    string =
  ## Serialize a message to its wire format (CRLF by default).
  writeMessage(msg, opts, 0)

proc writeMimeFile*(path: string; msg: MimeMessage;
    opts: MimeOptions = defaultMimeOptions()) =
  ## Serialize a message and write it to a file.
  writeFile(path, toMime(msg, opts))

# ---------------------------------------------------------------------------
# Builders
# ---------------------------------------------------------------------------

proc newTextPart*(text: string; mediaSubtype = "plain";
    charset = "utf-8"; transferEncoding = teQuotedPrintable): MimePart =
  ## Build a text part. Pure ASCII with short lines uses 7bit unless a
  ## transfer encoding is given explicitly.
  var useEnc = transferEncoding
  if transferEncoding == teQuotedPrintable:
    var ascii = true
    for c in text:
      if ord(c) >= 127:
        ascii = false
        break
    if ascii:
      var longLine = false
      for line in text.splitLines():
        if line.len > 998:
          longLine = true
          break
      if not longLine:
        useEnc = te7bit
  let raw = stringToBytes(text)
  let encName = case useEnc
    of te7bit: "7bit"
    of te8bit: "8bit"
    of teBinary: "binary"
    of teQuotedPrintable: "quoted-printable"
    of teBase64: "base64"
    of teUnknown: "7bit"
  MimePart(
    contentType: MimeContentType(mainType: "text",
      subType: mediaSubtype.toLowerAscii(),
      params: @[MimeParam(name: "charset", value: charset.toLowerAscii(),
        charset: none(string), language: none(string))]),
    contentTypePresent: true,
    transferEncoding: (if useEnc == teUnknown: te7bit else: useEnc),
    transferEncodingRaw: encName,
    transferEncodingPresent: true,
    body: MimeBody(kind: mbText, text: text, charset: charset, raw: raw))

proc toParamValue*(name, value: string): MimeParam =
  ## Build a parameter, using RFC 2231 extended form for non-ASCII values.
  if needsEncoding(value):
    MimeParam(name: name, value: value, charset: some("utf-8"),
      language: some(""))
  else:
    MimeParam(name: name, value: value, charset: none(string),
      language: none(string))

proc newBinaryPart*(data: seq[byte];
    mediaType = "application/octet-stream";
    filename = ""): MimePart =
  ## Build a binary part with base64 transfer encoding and an optional
  ## attachment filename.
  let slash = mediaType.find('/')
  let mainType = if slash < 0: mediaType.toLowerAscii()
    else: mediaType[0 ..< slash].toLowerAscii()
  let subType = if slash < 0: "octet-stream"
    else: mediaType[slash + 1 .. ^1].toLowerAscii()
  var params: seq[MimeParam] = @[]
  var disp: Option[MimeDisposition] = none(MimeDisposition)
  if filename.len > 0:
    params.add(toParamValue("name", filename))
    disp = some(MimeDisposition(kind: "attachment",
      params: @[toParamValue("filename", filename)]))
  MimePart(
    contentType: MimeContentType(mainType: mainType, subType: subType,
      params: params),
    contentTypePresent: true,
    transferEncoding: teBase64,
    transferEncodingRaw: "base64",
    transferEncodingPresent: true,
    disposition: disp,
    body: MimeBody(kind: mbData, data: data))

proc ensureBoundary(part: MimePart; opts: MimeOptions): string =
  ## Return a boundary that does not occur in the serialized children.
  var boundary = ""
  let b = part.contentType.boundaryOf()
  if b.isSome and b.get.len > 0:
    boundary = b.get
  else:
    boundary = generateBoundary()
  # Point the content type at the boundary.
  var hasBoundary = false
  for p in part.contentType.params.mitems:
    if p.name == "boundary":
      p.value = boundary
      hasBoundary = true
  if not hasBoundary:
    part.contentType.params.add(MimeParam(name: "boundary",
      value: boundary, charset: none(string), language: none(string)))
  # Verify children do not contain the marker; regenerate if needed.
  var guard = 0
  while guard < 10:
    var probe = ""
    for p in part.body.parts:
      probe.add(writePart(p, opts))
    if ("--" & boundary) notin probe:
      break
    boundary = generateBoundary()
    for p in part.contentType.params.mitems:
      if p.name == "boundary":
        p.value = boundary
    inc guard
  boundary

proc newMultipart*(subtype = "mixed"; parts: seq[MimePart] = @[];
    opts: MimeOptions = defaultMimeOptions()): MimePart =
  ## Build a multipart entity, generating a collision-free boundary.
  result = MimePart(
    contentType: MimeContentType(mainType: "multipart",
      subType: subtype.toLowerAscii(), params: @[]),
    contentTypePresent: true,
    transferEncoding: te7bit,
    transferEncodingRaw: "7bit",
    transferEncodingPresent: false,
    body: MimeBody(kind: mbMultipart, subtype: subtype.toLowerAscii(),
      boundary: "", preamble:
        "This is a multi-part message in MIME format.",
      parts: parts, epilogue: ""))
  result.body.boundary = ensureBoundary(result, opts)

proc newForwardedMessage*(msg: MimeMessage): MimePart =
  ## Wrap a message as a message/rfc822 part.
  MimePart(
    contentType: MimeContentType(mainType: "message", subType: "rfc822",
      params: @[]),
    contentTypePresent: true,
    transferEncoding: te7bit,
    transferEncodingRaw: "7bit",
    transferEncodingPresent: true,
    body: MimeBody(kind: mbMessage, message: msg))
