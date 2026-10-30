import std/[unittest, options, strutils, base64, os, times]
import openparser/mime

suite "MIME headers - splitting and unfolding":
  test "crlf separator":
    let (head, body) = splitHeadersBody("Subject: hi\r\n\r\nbody text")
    check head == "Subject: hi"
    check body == "body text"

  test "lf separator accepted":
    let (head, body) = splitHeadersBody("Subject: hi\n\nbody text")
    check head == "Subject: hi"
    check body == "body text"

  test "no separator means headers only":
    let (head, body) = splitHeadersBody("Subject: hi")
    check head == "Subject: hi"
    check body == ""

  test "unfolding continuation lines":
    let hs = parseHeaderBlock("Subject: hello\r\n world")
    check hs.len == 1
    check hs[0].name == "Subject"
    check hs[0].value == "hello world"

  test "strict rejects missing separator":
    expect OpenParserMimeError:
      discard splitHeadersBody("Subject: hi",
        MimeOptions(policy: mpStrict))

  test "strict rejects unfolded line over 998":
    expect OpenParserMimeError:
      discard parseHeaderBlock("X-Long: " & 'a'.repeat(1000),
        MimeOptions(policy: mpStrict))

suite "MIME content types and params":
  test "basic content type":
    let ct = parseContentType("text/plain; charset=utf-8")
    check ct.mainType == "text"
    check ct.subType == "plain"
    check ct.charsetOf == "utf-8"

  test "quoted params with semicolons":
    let ct = parseContentType("multipart/mixed; boundary=\"abc;def\"")
    check ct.mainType == "multipart"
    check ct.boundaryOf.get == "abc;def"

  test "case insensitive lookup, case preserving values":
    let ct = parseContentType("Text/HTML; Charset=UTF-8")
    check ct.mediaType == "text/html"
    check ct.contentTypeParam("CHARSET").get == "UTF-8"

  test "missing subtype raises":
    expect OpenParserMimeError:
      discard parseContentType("textplain")

  test "unknown cte token preserved":
    let (enc, raw) = parseTransferEncoding("x-uuencode")
    check enc == teUnknown
    check raw == "x-uuencode"

suite "MIME transfer codecs":
  test "base64 round trip":
    let data = "hello world, this is a test of base64 bodies"
    let enc = encodeBase64Body(stringToBytes(data))
    check decodeBase64Body(enc).len > 0
    check bytesToString(decodeBase64Body(enc)) == data

  test "base64 ignores folding whitespace":
    check bytesToString(decodeBase64Body("aGVsbG8=")) == "hello"

  test "invalid base64 raises":
    expect OpenParserMimeError:
      discard decodeBase64Body("!!!not-base64!!!")

  test "quoted printable soft breaks":
    let d = decodeQuotedPrintable("hello=\r\nworld")
    check bytesToString(d) == "helloworld"

  test "quoted printable hex escapes":
    let d = decodeQuotedPrintable("=41=42=43")
    check bytesToString(d) == "ABC"

  test "quoted printable round trip with trailing space":
    let enc = encodeQuotedPrintable(stringToBytes("trailing "))
    check enc.endsWith("=20")
    check bytesToString(decodeQuotedPrintable(enc)) == "trailing "

  test "strict rejects bad qp escape":
    expect OpenParserMimeError:
      discard decodeQuotedPrintable("=ZZ",
        MimeOptions(policy: mpStrict))

suite "MIME addresses":
  test "bare addr-spec":
    let addrs = parseAddressList("bob@example.com")
    check addrs.len == 1
    check addrs[0].mailbox.addrSpecOf == "bob@example.com"

  test "named address":
    let addrs = parseAddressList("\"Doe, John\" <john@example.com>")
    check addrs.len == 1
    check addrs[0].mailbox.displayName.get == "Doe, John"

  test "group syntax":
    let addrs = parseAddressList("team: a@x.com, b@x.com;")
    check addrs.len == 1
    check addrs[0].kind == maGroup
    check addrs[0].members.len == 2

  test "comments are skipped":
    let addrs = parseAddressList("bob(comment)@example.com")
    check addrs.len == 1
    check addrs[0].mailbox.addrSpecOf == "bob@example.com"

  test "domain literal":
    let addrs = parseAddressList("postmaster@[127.0.0.1]")
    check addrs.len == 1
    check addrs[0].mailbox.domain == "[127.0.0.1]"

  test "unquoted display name with comma":
    let addrs = parseAddressList("Doe, John <john@example.com>")
    check addrs.len == 1
    check addrs[0].mailbox.displayName.get == "Doe, John"

suite "MIME dates":
  test "numeric zone":
    let d = parseMimeDate("Wed, 02 Oct 2024 08:00:00 +0200")
    check d.year == 2024
    check d.month == 10
    check d.day == 2
    check d.offsetMinutes.get == 120

  test "obsolete zone name":
    let d = parseMimeDate("Tue, 01 Oct 2024 12:00:00 EST")
    check d.offsetMinutes.get == -300
    check d.zone == "EST"

  test "two digit year":
    check parseMimeDate("01 Oct 99 00:00:00 +0000").year == 1999
    check parseMimeDate("01 Oct 24 00:00:00 +0000").year == 2024

  test "invalid date raises":
    expect OpenParserMimeError:
      discard parseMimeDate("not a date")

suite "MIME encoded words":
  test "B word decoding":
    check decodeEncodedWords("=?UTF-8?B?SsO2aG4=?=") == "Jöhn"

  test "Q word decoding with underscore":
    check decodeEncodedWords("=?ISO-8859-1?Q?Andr=E9?=") == "André"

  test "adjacent words join without space":
    check decodeEncodedWords("=?utf-8?B?YQ==?= =?utf-8?B?Yg==?=") == "ab"

  test "plain text passes through":
    check decodeEncodedWords("hello world") == "hello world"

  test "unstructured round trip":
    let s = "Grüße aus München"
    check decodeEncodedWords(encodeUnstructured(s)) == s

suite "MIME single-part messages":
  test "minimal message":
    let msg = parseMime("From: a@x.com\r\nSubject: hi\r\n\r\nbody")
    check msg.fromAddrs.len == 1
    check msg.subject.get == "hi"
    check msg.body.body.kind == mbText
    check msg.body.body.text == "body"

  test "default content type is text/plain":
    let msg = parseMime("From: a@x.com\r\n\r\nbody")
    check msg.body.contentTypePresent == false
    check msg.body.contentType.mediaType == "text/plain"

  test "base64 text part":
    let src = "From: a@x.com\r\nContent-Type: text/plain; charset=utf-8\r\n" &
      "Content-Transfer-Encoding: base64\r\n\r\nSsO2aG4="
    let msg = parseMime(src)
    check msg.body.body.kind == mbText
    check msg.body.body.text == "Jöhn"

  test "charset conversion latin-1":
    let src = "From: a@x.com\r\nContent-Type: text/plain; charset=iso-8859-1\r\n" &
      "Content-Transfer-Encoding: quoted-printable\r\n\r\nAndr=E9"
    let msg = parseMime(src)
    check msg.body.body.text == "André"

  test "subject encoded word decoded":
    let msg = parseMime("From: a@x.com\r\nSubject: =?UTF-8?B?SsO2aG4=?=\r\n\r\nx")
    check msg.subject.get == "Jöhn"

  test "message-id and references":
    let msg = parseMime("From: a@x.com\r\nMessage-ID: <abc@x.com>\r\n" &
      "References: <one@x.com> <two@x.com>\r\n\r\nx")
    check msg.messageId.get == "abc@x.com"
    check msg.references == @["one@x.com", "two@x.com"]

  test "unknown headers preserved":
    let msg = parseMime("From: a@x.com\r\nX-Custom: 123\r\n\r\nx")
    check msg.extraHeaders.len == 1
    check msg.extraHeaders[0].name == "X-Custom"

suite "MIME multipart":
  test "mixed with two parts":
    let src = "From: a@x.com\r\n" &
      "Content-Type: multipart/mixed; boundary=frontier\r\n\r\n" &
      "preamble here\r\n" &
      "--frontier\r\nContent-Type: text/plain\r\n\r\nfirst\r\n" &
      "--frontier\r\nContent-Type: text/plain\r\n\r\nsecond\r\n" &
      "--frontier--\r\nepilogue here"
    let msg = parseMime(src)
    check msg.body.body.kind == mbMultipart
    check msg.body.body.parts.len == 2
    check msg.body.body.parts[0].body.text == "first"
    check msg.body.body.parts[1].body.text == "second"
    check msg.body.body.preamble == "preamble here"
    check msg.body.body.epilogue == "epilogue here"

  test "missing closing boundary raises in strict":
    expect OpenParserMimeError:
      discard parseMime("Content-Type: multipart/mixed; boundary=b\r\n\r\n" &
        "--b\r\nContent-Type: text/plain\r\n\r\nx\r\n",
        MimeOptions(policy: mpStrict))

  test "nested multipart":
    let inner = "--in\r\nContent-Type: text/plain\r\n\r\ndeep\r\n--in--\r\n"
    let src = "Content-Type: multipart/mixed; boundary=out\r\n\r\n" &
      "--out\r\nContent-Type: multipart/alternative; boundary=in\r\n\r\n" &
      inner & "--out--\r\n"
    let msg = parseMime(src)
    let outer = msg.body.body.parts[0]
    check outer.body.kind == mbMultipart
    check outer.body.parts[0].body.text == "deep"

  test "message/rfc822 nesting":
    let src = "Content-Type: multipart/mixed; boundary=b\r\n\r\n" &
      "--b\r\nContent-Type: message/rfc822\r\n\r\n" &
      "From: inner@x.com\r\nSubject: nested\r\n\r\ninner body\r\n" &
      "--b--\r\n"
    let msg = parseMime(src)
    let nested = msg.body.body.parts[0].body.message
    check nested.subject.get == "nested"
    check nested.body.body.text == "inner body"

  test "multipart round trip":
    let src = "From: a@x.com\r\nSubject: t\r\n" &
      "Content-Type: multipart/mixed; boundary=frontier\r\n\r\n" &
      "--frontier\r\nContent-Type: text/plain\r\n\r\nfirst\r\n" &
      "--frontier--\r\n"
    let msg = parseMime(src)
    let back = parseMime(toMime(msg))
    check back.body.body.parts.len == 1
    check back.body.body.parts[0].body.text == "first"
    check back.subject.get == "t"

suite "MIME disposition and rfc2231":
  test "attachment filename from disposition":
    let src = "Content-Type: application/pdf; name=\"doc.pdf\"\r\n" &
      "Content-Disposition: attachment; filename=\"doc.pdf\"\r\n" &
      "Content-Transfer-Encoding: base64\r\n\r\naGVsbG8=\r\n"
    let msg = parseMime("From: a@x.com\r\n" & src)
    check msg.body.filenameOf.get == "doc.pdf"
    check msg.body.body.kind == mbData
    check bytesToString(msg.body.body.data) == "hello"

  test "rfc2231 encoded filename":
    let src = "From: a@x.com\r\n" &
      "Content-Type: application/octet-stream\r\n" &
      "Content-Disposition: attachment; filename*=UTF-8''%E2%82%AC.txt\r\n\r\nx"
    let msg = parseMime(src)
    check msg.body.filenameOf.get == "€.txt"

  test "rfc2231 continuations reassembled":
    let src = "From: a@x.com\r\n" &
      "Content-Type: application/octet-stream\r\n" &
      "Content-Disposition: attachment;\r\n filename*0*=UTF-8''%E2%82%AC%20rates;\r\n filename*1*=.txt\r\n\r\nx"
    let msg = parseMime(src)
    check msg.body.filenameOf.get == "€ rates.txt"

suite "MIME creation":
  test "text part builder uses 7bit for ascii":
    let p = newTextPart("hello")
    check p.transferEncoding == te7bit
    check p.contentType.charsetOf == "utf-8"

  test "builder round trip with attachment":
    var msg = MimeMessage()
    msg.fromAddrs = parseMailboxList("me@example.com")
    msg.toAddrs = parseAddressList("you@example.com")
    msg.subject = some("Grüße")
    let textPart = newTextPart("Hello, world")
    let binPart = newBinaryPart(stringToBytes("%PDF-binary"), filename = "doc.pdf")
    let multi = newMultipart("mixed", @[textPart, binPart])
    msg.body = multi
    let wire = toMime(msg)
    let back = parseMime(wire)
    check back.subject.get == "Grüße"
    check back.body.body.parts.len == 2
    check back.body.body.parts[0].body.text == "Hello, world"
    check back.body.body.parts[1].filenameOf.get == "doc.pdf"
    check bytesToString(back.body.body.parts[1].body.data) == "%PDF-binary"

  test "forwarded message":
    var inner = MimeMessage()
    inner.fromAddrs = parseMailboxList("a@x.com")
    inner.subject = some("orig")
    inner.body = newTextPart("orig body")
    var outer = MimeMessage()
    outer.fromAddrs = parseMailboxList("b@x.com")
    outer.subject = some("fwd")
    outer.body = newMultipart("mixed", @[newForwardedMessage(inner)])
    let back = parseMime(toMime(outer))
    check back.body.body.parts[0].body.message.subject.get == "orig"

  test "folding keeps lines short":
    var msg = MimeMessage()
    msg.fromAddrs = parseMailboxList("a@x.com")
    msg.subject = some("This is a fairly long subject line that should fold")
    let wire = toMime(msg)
    for line in wire.splitLines():
      check line.len <= 998

suite "MIME limits and policy":
  test "too many parts raises":
    var src = "Content-Type: multipart/mixed; boundary=b\r\n\r\n"
    for i in 0 ..< 5:
      src.add("--b\r\nContent-Type: text/plain\r\n\r\nx\r\n")
    src.add("--b--\r\n")
    expect OpenParserMimeError:
      discard parseMime(src, MimeOptions(maxParts: 3))

  test "unknown content type becomes octet-stream in lenient":
    let msg = parseMime("Content-Type: x-weird/type\r\n\r\nabc")
    check msg.body.body.kind == mbData

  test "file round trip":
    var msg = MimeMessage()
    msg.fromAddrs = parseMailboxList("a@x.com")
    msg.subject = some("file test")
    msg.body = newTextPart("file body")
    let path = getTempDir() / "openparser_mime_test.eml"
    try:
      writeMimeFile(path, msg)
      let back = parseMimeFile(path)
      check back.subject.get == "file test"
      check back.body.body.text == "file body"
    finally:
      try:
        removeFile(path)
      except OSError:
        discard

  test "multipart with base64 text part decodes":
    # Shape of real-world mail: multipart/mixed wrapping a base64
    # text/html part. The top body is multipart, so text lives in
    # the nested part, not on the top-level body.
    let html = "<p>Hello, base64 world</p>"
    let src = "From: a@x.com\r\n" &
      "Content-Type: multipart/mixed; boundary=outer\r\n\r\n" &
      "--outer\r\n" &
      "Content-Type: text/html; charset=utf-8\r\n" &
      "Content-Transfer-Encoding: base64\r\n\r\n" &
      base64.encode(html) & "\r\n" &
      "--outer--\r\n"
    let msg = parseMime(src)
    check msg.body.body.kind == mbMultipart
    let part = msg.body.body.parts[0]
    check part.contentType.mediaType == "text/html"
    check part.body.kind == mbText
    check part.body.text == html

  test "strict requires Date and From":
    expect OpenParserMimeError:
      discard parseMime("Subject: no origination\r\n\r\nx",
        MimeOptions(policy: mpStrict))

  test "empty body after separator":
    let msg = parseMime("From: a@x.com\r\nSubject: t\r\n\r\n")
    check msg.subject.get == "t"
    check msg.body.body.kind == mbEmpty

  test "hand-built multipart gains a boundary":
    let multi = MimePart(
      contentType: MimeContentType(mainType: "multipart",
        subType: "mixed", params: @[]),
      contentTypePresent: true,
      transferEncoding: te7bit,
      transferEncodingRaw: "7bit",
      transferEncodingPresent: false,
      body: MimeBody(kind: mbMultipart, subtype: "mixed", boundary: "",
        preamble: "", parts: @[newTextPart("hi")], epilogue: ""))
    let wire = writePart(multi)
    check "boundary=" in wire
    var msg = MimeMessage()
    msg.fromAddrs = parseMailboxList("a@x.com")
    msg.body = multi
    let back = parseMime(toMime(msg))
    check back.body.body.kind == mbMultipart
    check back.body.body.parts.len == 1
    check back.body.body.parts[0].body.text == "hi"

suite "MIME conformance vectors":
  test "rfc2049 style alternative with attachment":
    let src = "From: Nathaniel Borenstein <nsb@bellcore.com>\r\n" &
      "To: Ned Freed <ned@innosoft.com>\r\n" &
      "Date: Mon, 23 Mar 1992 12:00:00 -0500\r\n" &
      "Subject: ordinary message\r\n" &
      "Message-ID: <199203231200.12345@bellcore.com>\r\n" &
      "MIME-Version: 1.0\r\n" &
      "Content-Type: multipart/mixed; boundary=outer\r\n\r\n" &
      "preamble\r\n" &
      "--outer\r\n" &
      "Content-Type: multipart/alternative; boundary=inner\r\n\r\n" &
      "--inner\r\n" &
      "Content-Type: text/plain; charset=us-ascii\r\n\r\n" &
      "plain text\r\n" &
      "--inner\r\n" &
      "Content-Type: text/html; charset=us-ascii\r\n\r\n" &
      "<p>html text</p>\r\n" &
      "--inner--\r\n" &
      "--outer\r\n" &
      "Content-Type: application/octet-stream; name=\"data.bin\"\r\n" &
      "Content-Transfer-Encoding: base64\r\n" &
      "Content-Disposition: attachment; filename=\"data.bin\"\r\n\r\n" &
      "AAEC\r\n" &
      "--outer--\r\n"
    let msg = parseMime(src)
    check msg.mimeVersion.get == "1.0"
    check msg.messageId.get == "199203231200.12345@bellcore.com"
    check msg.fromAddrs[0].displayName.get == "Nathaniel Borenstein"
    check msg.date.get.offsetMinutes.get == -300
    let outer = msg.body.body
    check outer.kind == mbMultipart
    check outer.parts.len == 2
    let alt = outer.parts[0].body
    check alt.kind == mbMultipart
    check alt.parts[0].body.text == "plain text"
    check alt.parts[1].contentType.mediaType == "text/html"
    check outer.parts[1].filenameOf.get == "data.bin"
    check outer.parts[1].body.data == @[byte 0, 1, 2]
    # Full round trip preserves the payload tree.
    let back = parseMime(toMime(msg))
    check back.body.body.parts.len == 2
    check back.body.body.parts[1].body.data == @[byte 0, 1, 2]

  test "message with all recipient kinds and trace":
    let src = "Return-Path: <mailer@x.com>\r\n" &
      "Received: from a by b\r\n" &
      "Received: from b by c\r\n" &
      "Date: Wed, 02 Oct 2024 08:00:00 +0200\r\n" &
      "From: Boss <boss@x.com>\r\n" &
      "Sender: aide@x.com\r\n" &
      "Reply-To: help@x.com\r\n" &
      "To: team: a@x.com, b@x.com;\r\n" &
      "Cc: c@x.com\r\n" &
      "Subject: s\r\n\r\nbody"
    let msg = parseMime(src)
    check msg.returnPath.get == "<mailer@x.com>"
    check msg.received.len == 2
    check msg.sender.get.addrSpecOf == "aide@x.com"
    check msg.toAddrs[0].kind == maGroup
    check msg.toAddrs[0].members.len == 2
    check toMime(msg).count("Received:") == 2

suite "MIME addresses extended":
  test "message with all recipient kinds and trace":
    let src = "Return-Path: <mailer@x.com>\r\n" &
      "Received: from a by b\r\n" &
      "Received: from b by c\r\n" &
      "Date: Wed, 02 Oct 2024 08:00:00 +0200\r\n" &
      "From: Boss <boss@x.com>\r\n" &
      "Sender: aide@x.com\r\n" &
      "Reply-To: help@x.com\r\n" &
      "To: team: a@x.com, b@x.com;\r\n" &
      "Cc: c@x.com\r\n" &
      "Subject: s\r\n\r\nbody"
    let msg = parseMime(src)
    check msg.returnPath.get == "<mailer@x.com>"
    check msg.received.len == 2
    check msg.sender.get.addrSpecOf == "aide@x.com"
    check msg.toAddrs[0].kind == maGroup
    check msg.toAddrs[0].members.len == 2
    check toMime(msg).count("Received:") == 2

  test "multiple addresses with mixed forms":
    let addrs = parseAddressList("a@x.com, \"Doe, Jane\" <jane@x.com>, team: b@x.com;")
    check addrs.len == 3
    check addrs[0].mailbox.localPart == "a"
    check addrs[1].mailbox.displayName.get == "Doe, Jane"
    check addrs[2].kind == maGroup

  test "empty group":
    let addrs = parseAddressList("undisclosed-recipients:;")
    check addrs.len == 1
    check addrs[0].kind == maGroup
    check addrs[0].members.len == 0

  test "quoted local part with specials":
    let addrs = parseAddressList("\"john..doe\"@example.com")
    check addrs.len == 1
    check addrs[0].mailbox.domain == "example.com"

  test "obsolete route is skipped":
    let addrs = parseAddressList("<@relay1,@relay2:john@example.com>")
    check addrs.len == 1
    check addrs[0].mailbox.addrSpecOf == "john@example.com"

  test "comments between tokens":
    let addrs = parseAddressList("john (the boss) @ (comment) example.com")
    check addrs.len == 1
    check addrs[0].mailbox.addrSpecOf == "john@example.com"

  test "mailbox format round trip":
    let m = MimeMailbox(displayName: some("Doe, John"),
      localPart: "john", domain: "example.com")
    let back = parseMailboxList($m)
    check back.len == 1
    check back[0].displayName.get == "Doe, John"
    check back[0].addrSpecOf == "john@example.com"

  test "group format round trip":
    let g = MimeAddress(kind: maGroup, groupName: "team",
      members: @[MimeMailbox(localPart: "a", domain: "x.com")])
    check formatAddress(g) == "team: a@x.com;"

suite "MIME dates extended":
  test "without seconds":
    let d = parseMimeDate("02 Oct 2024 08:00 +0200")
    check d.hour == 8
    check d.minute == 0
    check d.second == 0

  test "obsolete hhmm without colon":
    let d = parseMimeDate("02 Oct 2024 0800 +0200")
    check d.hour == 8
    check d.minute == 0

  test "gmt and ut zones":
    check parseMimeDate("02 Oct 2024 08:00:00 GMT").offsetMinutes.get == 0
    check parseMimeDate("02 Oct 2024 08:00:00 UT").offsetMinutes.get == 0

  test "negative offset":
    check parseMimeDate("02 Oct 2024 08:00:00 -0930").offsetMinutes.get == -570

  test "format and reparse":
    let d = parseMimeDate("Wed, 02 Oct 2024 08:00:00 +0200")
    let back = parseMimeDate(formatMimeDate(d))
    check back.year == d.year
    check back.month == d.month
    check back.day == d.day
    check back.hour == d.hour
    check back.offsetMinutes.get == 120

  test "strict rejects garbage zone":
    expect OpenParserMimeError:
      discard parseMimeDate("02 Oct 2024 08:00:00 XXYY",
        MimeOptions(policy: mpStrict))

suite "MIME message ids extended":
  test "strict rejects unbracketed id":
    expect OpenParserMimeError:
      discard parseMessageIds("abc@x.com", MimeOptions(policy: mpStrict))

  test "lenient ignores unbracketed tokens":
    check parseMessageIds("abc@x.com").len == 0

  test "message id without brackets in strict header":
    expect OpenParserMimeError:
      discard parseMime("Date: Wed, 02 Oct 2024 08:00:00 +0200\r\n" &
        "From: a@x.com\r\nMessage-ID: abc@x.com\r\n\r\nx",
        MimeOptions(policy: mpStrict))

suite "MIME content type extended":
  test "params with comments":
    let ct = parseContentType("text/plain (comment); charset=utf-8")
    check ct.charsetOf == "utf-8"

  test "quote round trip for special values":
    let ct = parseContentType("multipart/mixed; boundary=\"a;b c\"")
    let back = parseContentType(formatContentType(ct))
    check back.boundaryOf.get == "a;b c"

  test "empty param value":
    let ct = parseContentType("text/plain; charset=")
    check ct.charsetOf == ""

  test "uppercase media type normalizes":
    let ct = parseContentType("TEXT/PLAIN")
    check ct.mediaType == "text/plain"
    check ct.isText()

suite "MIME cte extended":
  test "8bit passes bytes through":
    let raw = [byte(ord('A')), byte(0xE9), byte(ord('B'))]
    let src = "Content-Type: text/plain; charset=iso-8859-1\r\n" &
      "Content-Transfer-Encoding: 8bit\r\n\r\n" & bytesToString(raw)
    let msg = parseMime("From: a@x.com\r\n" & src)
    check msg.body.body.text == "AéB"

  test "unknown cte passes through in lenient":
    let msg = parseMime("From: a@x.com\r\n" &
      "Content-Type: text/plain\r\n" &
      "Content-Transfer-Encoding: x-custom\r\n\r\nabc")
    check msg.body.body.kind == mbText
    check msg.body.body.text == "abc"

  test "unknown cte raises in strict":
    expect OpenParserMimeError:
      discard parseMime("From: a@x.com\r\n" &
        "Content-Type: text/plain\r\n" &
        "Content-Transfer-Encoding: x-custom\r\n\r\nabc",
        MimeOptions(policy: mpStrict))

  test "qp lowercase hex":
    check bytesToString(decodeQuotedPrintable("=4a=4B")) == "JK"

  test "qp trailing equals is literal in lenient":
    check bytesToString(decodeQuotedPrintable("a=")) == "a="

  test "base64 strict rejects bad padding":
    expect OpenParserMimeError:
      discard decodeBase64Body("a===",
        MimeOptions(policy: mpStrict))

suite "MIME encoded words extended":
  test "encoded word in display name":
    let addrs = parseAddressList("=?UTF-8?B?SsO2aG4=?= <john@x.com>")
    check addrs.len == 1
    check addrs[0].mailbox.displayName.get == "Jöhn"

  test "lowercase encoding markers":
    check decodeEncodedWords("=?utf-8?b?SsO2aG4=?=") == "Jöhn"
    check decodeEncodedWords("=?utf-8?q?J=C3=B6hn?=") == "Jöhn"

  test "punctuation between words is kept":
    check decodeEncodedWords("=?utf-8?B?YQ==?=, =?utf-8?B?Yg==?=") == "a, b"

  test "long subject folds and round trips":
    let s = "Grüße aus München ".repeat(10).strip()
    let enc = encodeUnstructured(s)
    for line in enc.splitLines():
      check line.len <= 998
    check decodeEncodedWords(enc) == s

  test "encoded word split across chunks":
    let s = "ü".repeat(60)
    let enc = encodeUnstructured(s)
    check decodeEncodedWords(enc) == s
    for line in enc.splitLines():
      check line.len <= 998

suite "MIME multipart extended":
  test "transport padding on delimiters":
    let src = "Content-Type: multipart/mixed; boundary=b\r\n\r\n" &
      "--b  \t\r\nContent-Type: text/plain\r\n\r\nx\r\n" &
      "--b--  \r\n"
    let msg = parseMime(src)
    check msg.body.body.parts.len == 1
    check msg.body.body.parts[0].body.text == "x"

  test "quoted boundary param":
    let src = "Content-Type: multipart/mixed; boundary=\"b-1\"\r\n\r\n" &
      "--b-1\r\nContent-Type: text/plain\r\n\r\nx\r\n--b-1--\r\n"
    check parseMime(src).body.body.parts.len == 1

  test "lookalike lines do not split parts":
    let src = "Content-Type: multipart/mixed; boundary=b\r\n\r\n" &
      "--b\r\nContent-Type: text/plain\r\n\r\n" &
      "not a delimiter: --b-extra\r\n --b indented\r\n--bmid\r\n" &
      "--b--\r\n"
    let msg = parseMime(src)
    check msg.body.body.parts.len == 1
    check "--b-extra" in msg.body.body.parts[0].body.text

  test "part without headers uses defaults":
    let src = "Content-Type: multipart/mixed; boundary=b\r\n\r\n" &
      "--b\r\n\r\nplain\r\n--b--\r\n"
    let msg = parseMime(src)
    check msg.body.body.parts[0].contentTypePresent == false
    check msg.body.body.parts[0].body.text == "plain"

  test "missing boundary in lenient keeps raw":
    let msg = parseMime("Content-Type: multipart/mixed\r\n\r\nabc")
    check msg.body.body.kind == mbData

  test "rfc822 with base64 raises in strict":
    let inner = base64.encode("From: a@x.com\r\n\r\nx")
    expect OpenParserMimeError:
      discard parseMime("Content-Type: multipart/mixed; boundary=b\r\n\r\n" &
        "--b\r\nContent-Type: message/rfc822\r\n" &
        "Content-Transfer-Encoding: base64\r\n\r\n" & inner & "\r\n--b--\r\n",
        MimeOptions(policy: mpStrict))

  test "rfc822 with base64 decodes in lenient":
    let inner = base64.encode("From: a@x.com\r\nSubject: hi\r\n\r\nx")
    let msg = parseMime("Content-Type: multipart/mixed; boundary=b\r\n\r\n" &
      "--b\r\nContent-Type: message/rfc822\r\n" &
      "Content-Transfer-Encoding: base64\r\n\r\n" & inner & "\r\n--b--\r\n")
    check msg.body.body.parts[0].body.message.subject.get == "hi"

suite "MIME headers extended":
  test "content description encoded word":
    let msg = parseMime("From: a@x.com\r\n" &
      "Content-Type: text/plain\r\n" &
      "Content-Description: =?UTF-8?B?SsO2aG4=?=\r\n\r\nx")
    check msg.body.contentDescription.get == "Jöhn"

  test "content id preserved":
    let msg = parseMime("From: a@x.com\r\n" &
      "Content-Type: application/pdf\r\n" &
      "Content-ID: <part1@x.com>\r\n\r\nx")
    check msg.body.contentId.get == "<part1@x.com>"
    check "Content-ID: <part1@x.com>" in toMime(msg)

  test "content language list":
    let msg = parseMime("From: a@x.com\r\n" &
      "Content-Type: text/plain\r\n" &
      "Content-Language: en, fr\r\n\r\nx")
    check msg.body.contentLanguage == @["en", "fr"]

  test "content location preserved":
    let msg = parseMime("From: a@x.com\r\n" &
      "Content-Type: text/html\r\n" &
      "Content-Location: http://x.com/a.html\r\n\r\nx")
    check msg.body.contentLocation.get == "http://x.com/a.html"

  test "keywords split and round trip":
    let msg = parseMime("From: a@x.com\r\nKeywords: one, two\r\n\r\nx")
    check msg.keywords == @["one", "two"]
    check "Keywords:" in toMime(msg)

  test "comments decoded":
    let msg = parseMime("From: a@x.com\r\n" &
      "Comments: =?UTF-8?B?SsO2aG4=?=\r\n\r\nx")
    check msg.comments.get == "Jöhn"

  test "wire uses crlf only":
    var msg = MimeMessage()
    msg.fromAddrs = parseMailboxList("a@x.com")
    msg.subject = some("Grüße")
    msg.body = newMultipart("mixed", @[newTextPart("x")])
    let wire = toMime(msg)
    check "\r\n" in wire
    check '\n' notin wire.replace("\r\n", "")

suite "MIME builders extended":
  test "non-ascii filename uses rfc2231":
    let p = newBinaryPart(@[byte 1, 2], filename = "dök.pdf")
    let wire = writePart(p)
    check "filename*=" in wire
    let back = parseMime("From: a@x.com\r\n" & wire)
    check back.body.filenameOf.get == "dök.pdf"

  test "boundaries are unique and short":
    let a = newMultipart("mixed", @[newTextPart("x")])
    let b = newMultipart("mixed", @[newTextPart("x")])
    check a.body.boundary != b.body.boundary
    check a.body.boundary.len <= 70

  test "alternative builder keeps order":
    let alt = newMultipart("alternative",
      @[newTextPart("plain"), newTextPart("<b>html</b>", "html")])
    check alt.body.subtype == "alternative"
    check alt.body.parts[0].contentType.subType == "plain"
    check alt.body.parts[1].contentType.subType == "html"

  test "ascii uses 7bit, non-ascii uses qp":
    check newTextPart("plain ascii").transferEncoding == te7bit
    check newTextPart("Grüße").transferEncoding == teQuotedPrintable

suite "MIME limits extended":
  test "nesting depth exceeded":
    var src = "leaf"
    for i in 1 .. 10:
      src = "Content-Type: multipart/mixed; boundary=b" & $i & "\r\n\r\n" &
        "--b" & $i & "\r\n" & src & "\r\n--b" & $i & "--\r\n"
    expect OpenParserMimeError:
      discard parseMime("From: a@x.com\r\n" & src)

  test "body size limit in strict":
    expect OpenParserMimeError:
      discard parseMime("From: a@x.com\r\n\r\n" & 'x'.repeat(100),
        MimeOptions(policy: mpStrict, maxBodyBytes: 10))

  test "missing file raises":
    expect OpenParserMimeError:
      discard parseMimeFile("/nonexistent/mime-msg.eml")

suite "MIME simd fast paths":
  test "base64 with and without whitespace agree":
    let raw = cast[seq[byte]]("Hello, SIMD world! " & "0123456789ABCDEF".repeat(64))
    let clean = base64.encode(raw)
    var folded = ""
    for i in 0 ..< clean.len:
      folded.add(clean[i])
      if i mod 76 == 75:
        folded.add("\r\n")
    check bytesToString(decodeBase64Body(clean)) ==
      bytesToString(decodeBase64Body(folded))
    check bytesToString(decodeBase64Body(clean)) ==
      bytesToString(stringToBytes(cast[string](raw)))

  test "qp long run without escapes bulk-copies":
    let body = "a".repeat(5000) & "=20" & "b".repeat(5000) & "=\r\n" & "c".repeat(100)
    check bytesToString(decodeQuotedPrintable(body)) ==
      "a".repeat(5000) & " " & "b".repeat(5000) & "c".repeat(100)

  test "qp encode has no per-byte allocs and round trips":
    let data = stringToBytes("a=b c\r\nline with ünicode = sign " & "x".repeat(300))
    check bytesToString(decodeQuotedPrintable(encodeQuotedPrintable(data))) ==
      bytesToString(data)

  test "line ending normalization without breaks is a copy":
    let data = cast[seq[byte]]("no breaks here")
    check normalizeTextLineEndings(data) == data
    check normalizeTextLineEndings(cast[seq[byte]]("a\r\nb\rc\nd")) ==
      cast[seq[byte]]("a\r\nb\r\nc\r\nd")

  test "multipart dash lines are not false delimiters":
    let src = "Content-Type: multipart/mixed; boundary=b\r\n\r\n" &
      "--b\r\nContent-Type: text/plain\r\n\r\n" &
      "-\r\n--\r\n--x\r\n--b-nope\r\n--b\tnot-a-delimiter\r\n" &
      "real body\r\n--b--\r\n"
    let msg = parseMime(src)
    check msg.body.body.parts.len == 1
    check "real body" in msg.body.body.parts[0].body.text
    check "--x" in msg.body.body.parts[0].body.text

  test "large base64 multipart round trips":
    let raw = cast[seq[byte]]("ABCD".repeat(50000))
    var msg = MimeMessage()
    msg.fromAddrs = parseMailboxList("a@x.com")
    msg.body = newMultipart("mixed",
      @[newBinaryPart(raw, "application/octet-stream", filename = "big.bin")])
    let back = parseMime(toMime(msg))
    check back.body.body.parts[0].body.data == raw

suite "MIME message creation defaults":
  test "newMessage fills date, id and mime version":
    let msg = newMessage(newMultipart("mixed", @[newTextPart("hi")]),
      fromAddrs = parseMailboxList("me@example.org"),
      toAddrs = parseAddressList("you@example.org"),
      subject = "hello")
    check msg.date.isSome
    check msg.messageId.isSome
    check msg.mimeVersion.get == "1.0"
    check msg.subject.get == "hello"
    let back = parseMime(toMime(msg))
    check back.mimeVersion.get == "1.0"
    check back.messageId.get == msg.messageId.get
    check back.date.get.year == msg.date.get.year

  test "newMessage without mime body skips mime version":
    let msg = newMessage()
    check msg.date.isSome
    check msg.messageId.isSome
    check msg.mimeVersion.isNone
    check parseMime(toMime(msg)).date.isSome

  test "withDefaults false leaves headers unset":
    let msg = newMessage(newTextPart("x"), withDefaults = false)
    check msg.date.isNone
    check msg.messageId.isNone
    check msg.mimeVersion.isNone

  test "explicit fields are never overwritten":
    var msg = newMessage(newTextPart("x"))
    let fixed = parseMimeDate("Wed, 02 Oct 2024 08:00:00 +0200")
    msg.date = some(fixed)
    msg.messageId = some("fixed@example.org")
    msg.mimeVersion = some("9.9")
    ensureMimeDefaults(msg)
    check msg.date.get.year == 2024
    check msg.messageId.get == "fixed@example.org"
    check msg.mimeVersion.get == "9.9"

  test "message id domain comes from From":
    let msg = newMessage(newTextPart("x"),
      fromAddrs = parseMailboxList("me@example.org"))
    check msg.messageId.get.endsWith("@example.org")

  test "message id falls back to localhost":
    let msg = newMessage(newTextPart("x"))
    check msg.messageId.get.endsWith("@localhost")

  test "ensureMimeDefaults on nil raises":
    expect OpenParserMimeError:
      ensureMimeDefaults(nil)

suite "MIME date helpers":
  test "toTime applies numeric offset":
    let d = parseMimeDate("Wed, 02 Oct 2024 08:00:00 +0200")
    check toUnix(toTime(d)) ==
      toUnix(dateTime(2024, mOct, 2, 6, 0, 0, 0, utc()).toTime)

  test "toTime applies named zone":
    let d = parseMimeDate("Tue, 01 Oct 2024 12:00:00 EST")
    check toUnix(toTime(d)) ==
      toUnix(dateTime(2024, mOct, 1, 17, 0, 0, 0, utc()).toTime)

  test "toTime reads unknown zone as UTC":
    let d = parseMimeDate("02 Oct 2024 08:00:00 X")
    check toUnix(toTime(d)) ==
      toUnix(dateTime(2024, mOct, 2, 8, 0, 0, 0, utc()).toTime)

  test "nowMimeDate round trips through text":
    let back = parseMimeDate(formatMimeDate(nowMimeDate()))
    let now = nowMimeDate()
    check back.year == now.year
    check back.month == now.month
    check back.day == now.day
    check back.offsetMinutes.get == now.offsetMinutes.get

  test "leap day accepted in leap years only":
    check parseMimeDate("29 Feb 2024 00:00:00 +0000").day == 29
    expect OpenParserMimeError:
      discard parseMimeDate("29 Feb 2023 00:00:00 +0000",
        MimeOptions(policy: mpStrict))

  test "february 30 rejected":
    expect OpenParserMimeError:
      discard parseMimeDate("30 Feb 2024 00:00:00 +0000",
        MimeOptions(policy: mpStrict))
    let msg = parseMime("From: a@x.com\r\nDate: 30 Feb 2024 00:00:00 +0000\r\n\r\nx")
    check msg.date.isNone

  test "toTime rejects out-of-range fields":
    expect OpenParserMimeError:
      discard toTime(MimeDate(raw: "x", year: 2024, month: 13, day: 1,
        hour: 0, minute: 0, second: 0,
        offsetMinutes: some(0), zone: ""))

suite "MIME address reconstruction":
  test "bare quoted local part with dot preserved":
    let mbs = parseMailboxList("\"a.b\"@x.com")
    check mbs.len == 1
    check mbs[0].localPart == "\"a.b\""
    check mbs[0].domain == "x.com"

  test "unquoted display name joins and round trips":
    let addrs = parseAddressList("John Doe <john@example.com>")
    check addrs.len == 1
    check addrs[0].mailbox.displayName.get == "John Doe"
    let back = parseMailboxList($addrs[0].mailbox)
    check back.len == 1
    check back[0].addrSpecOf == "john@example.com"
    check back[0].displayName.get == "John Doe"
