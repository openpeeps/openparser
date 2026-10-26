import std/[options, strutils]
import openparser/mime

# Parse an existing message.
let msg = parseMime(readFile("mail.eml"))
echo "Subject: ", msg.subject.get("(none)")
if msg.fromAddrs.len > 0:
  echo "From: ", msg.fromAddrs[0].addrSpecOf()
if msg.date.isSome:
  echo "Date: ", msg.date.get.raw

proc showPart(part: MimePart; indent: string) =
  echo indent & part.contentType.mediaType(),
    " [", part.transferEncodingRaw, "]"
  case part.body.kind
  of mbText:
    echo indent & "  text: ", part.body.text[0 ..< min(60, part.body.text.len)]
  of mbData:
    echo indent & "  bytes: ", part.body.data.len,
      " filename: ", part.filenameOf.get("(none)")
  of mbMultipart:
    for p in part.body.parts:
      showPart(p, indent & "  ")
  of mbMessage:
    echo indent & "  nested: ",
      part.body.message.subject.get("(none)")
  of mbEmpty:
    echo indent & "  (empty)"

showPart(msg.body, "")

# Build a new multipart message with an attachment.
var outMsg = MimeMessage()
outMsg.fromAddrs = parseMailboxList("Ada Lovelace <ada@example.org>")
outMsg.toAddrs = parseAddressList("team@example.org")
outMsg.subject = some("Grüße aus München")
outMsg.body = newMultipart("mixed", @[
  newMultipart("alternative", @[
    newTextPart("Hello, plain world"),
    newTextPart("<p>Hello, <b>html</b> world</p>", "html")
  ]),
  newBinaryPart(cast[seq[byte]]("fake-pdf-bytes"), "application/pdf",
    filename = "doc.pdf")
])
let wire = toMime(outMsg)
echo "---"
echo "bytes: ", wire.len
echo "lines over 998: ",
  block:
    var n = 0
    for line in wire.splitLines():
      if line.len > 998: inc n
    n
writeFile("out.eml", wire)

# Round trip through a memory-mapped file read.
let back = parseMimeFile("out.eml")
echo "round trip subject: ", back.subject.get("")
echo "round trip parts: ", back.body.body.parts.len
