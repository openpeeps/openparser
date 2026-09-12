import std/[unittest, options, os, strutils]
import openparser/vcard

suite "vCard parsing - minimal":
  test "minimal v4 card":
    let src = "BEGIN:VCARD\r\nVERSION:4.0\r\nFN:Ada Lovelace\r\nN:Lovelace;Ada;;;\r\nEND:VCARD\r\n"
    let c = parseVCard(src)
    check c.version == vv40
    check c.fn == "Ada Lovelace"
    check c.n.get.family == "Lovelace"
    check c.n.get.given == "Ada"

  test "v3 card parsed":
    let src = "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:Bob\r\nN:Bob;;;;\r\nTEL;TYPE=CELL:+100\r\nEND:VCARD\r\n"
    let c = parseVCard(src)
    check c.version == vv30
    check c.tels.len == 1
    check c.tels[0].value == "+100"

  test "LF endings accepted (lenient)":
    let src = "BEGIN:VCARD\nVERSION:4.0\nFN:LF Test\nEND:VCARD\n"
    check parseVCard(src).fn == "LF Test"

  test "multiple cards":
    let src = "BEGIN:VCARD\r\nVERSION:4.0\r\nFN:A\r\nEND:VCARD\r\nBEGIN:VCARD\r\nVERSION:4.0\r\nFN:B\r\nEND:VCARD\r\n"
    let cards = parseVCards(src)
    check cards.len == 2
    check cards[0].fn == "A"
    check cards[1].fn == "B"

  test "escaping TEXT ; , newline backslash":
    let src = "BEGIN:VCARD\r\nVERSION:4.0\r\nFN:Test\r\nNOTE:Comma\\, semi\\; nl\\n bs\\\\\r\nEND:VCARD\r\n"
    check parseVCard(src).note.get == "Comma, semi; nl\n bs\\"

  test "N structured 5 parts":
    let src = "BEGIN:VCARD\r\nVERSION:4.0\r\nFN:John Doe\r\nN:Doe;John;Middle;Dr.;Jr.\r\nEND:VCARD\r\n"
    let n = parseVCard(src).n.get
    check n.family == "Doe"
    check n.given == "John"
    check n.additional == "Middle"
    check n.prefix == "Dr."
    check n.suffix == "Jr."

  test "ADR structured 7 parts + LABEL caret":
    let src = "BEGIN:VCARD\r\nVERSION:4.0\r\nFN:T\r\nADR;LABEL=123^nMain^'St:;;123 Main St;Springfield;IL;62701;USA\r\nEND:VCARD\r\n"
    let a = parseVCard(src).adrs[0]
    check a.street == "123 Main St"
    check a.locality == "Springfield"
    check a.country == "USA"
    check a.label.get == "123\nMain'St"

  test "TEL PREF v4 vs TYPE=PREF v3":
    let v4 = parseVCard("BEGIN:VCARD\r\nVERSION:4.0\r\nFN:T\r\nTEL;PREF=1;TYPE=voice:+111\r\nEND:VCARD\r\n")
    check v4.tels[0].pref.get == 1
    let v3 = parseVCard("BEGIN:VCARD\r\nVERSION:3.0\r\nFN:T\r\nTEL;TYPE=HOME,PREF:+222\r\nEND:VCARD\r\n")
    check v3.tels[0].pref.get == 1

  test "groups item1.TEL":
    let src = "BEGIN:VCARD\r\nVERSION:4.0\r\nFN:T\r\nitem1.TEL;TYPE=HOME:+100\r\nitem1.X-ABLABEL:Home\r\nEND:VCARD\r\n"
    let c = parseVCard(src)
    check c.tels.len == 1
    check c.tels[0].value == "+100"
    var found = false
    for p in c.extraProps:
      if norm(p.name) == "X-ABLABEL": found = true
    check found

  test "PHOTO v3 ENCODING=b upgrades to data URI":
    let src = "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:T\r\nPHOTO;ENCODING=b;TYPE=JPEG:aGVsbG8=\r\nEND:VCARD\r\n"
    let c = parseVCard(src)
    check c.photos.len == 1
    check c.photos[0].value.startsWith("data:image/jpeg;base64,")

  test "BDAY date + anniversary + gender":
    let src = "BEGIN:VCARD\r\nVERSION:4.0\r\nFN:T\r\nBDAY:19900101\r\nANNIVERSARY;VALUE=text:around 2010\r\nGENDER:M;Boy\r\nEND:VCARD\r\n"
    let c = parseVCard(src)
    check c.bday.get.value == "19900101"
    check c.anniversary.get.value == "around 2010"
    check c.gender.get.sex == "M"
    check c.gender.get.identity == "Boy"

  test "repeated TYPE params merge (Apple style)":
    let src = "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:John Doe\r\nTEL;type=CELL;type=VOICE;type=pref:+1555000111\r\nEMAIL;type=INTERNET;type=WORK:john@example.com\r\nEND:VCARD\r\n"
    let c = parseVCard(src)
    check c.tels[0].pref.get == 1
    check "CELL" in c.tels[0].types
    check "VOICE" in c.tels[0].types

  test "X-props go to extraProps":
    let src = "BEGIN:VCARD\r\nVERSION:4.0\r\nFN:T\r\nX-CUSTOM:hello\r\nX-EVOLUTION-FILE-AS:Test\r\nEND:VCARD\r\n"
    check parseVCard(src).extraProps.len >= 2

  test "KIND typed enum":
    let c = parseVCard("BEGIN:VCARD\r\nVERSION:4.0\r\nFN:Team\r\nKIND:group\r\nMEMBER:urn:uuid:1\r\nEND:VCARD\r\n")
    check c.kind.get.kind == vkGroup
    check vcardKindStr(c.kind.get) == "group"
    check c.members.len == 1

  test "KIND all registered tokens, case-insensitive":
    for (wire, expected) in [("individual", vkIndividual), ("GROUP", vkGroup),
        ("Org", vkOrg), ("LOCATION", vkLocation), ("application", vkApplication)]:
      let c = parseVCard("BEGIN:VCARD\r\nVERSION:4.0\r\nFN:T\r\nKIND:" & wire & "\r\nEND:VCARD\r\n")
      check c.kind.get.kind == expected

  test "KIND x-custom preserved and round-trips":
    let c = parseVCard("BEGIN:VCARD\r\nVERSION:4.0\r\nFN:T\r\nKIND:x-device\r\nEND:VCARD\r\n")
    check c.kind.get.kind == vkCustom
    check c.kind.get.custom == "x-device"
    let c2 = parseVCard(toVCard(c))
    check c2.kind.get.kind == vkCustom
    check vcardKindStr(c2.kind.get) == "x-device"

  test "KIND from objects emits canonical form":
    var c = VCard(version: vv40, fn: "T")
    c.kind = some(VCardKindValue(kind: vkOrg))
    check "KIND:org" in toVCard(c)

suite "vCard writing":
  test "round-trip identity":
    let src = "BEGIN:VCARD\r\nVERSION:4.0\r\nFN:Ada Lovelace\r\nN:Lovelace;Ada;;;\r\nORG:OpenPeeps\r\nTITLE:Dev\r\nTEL;PREF=1;TYPE=cell:+100\r\nEMAIL;PREF=1:ada@example.org\r\nADR:;;street;city;reg;zip;ctry\r\nNOTE:hi\\, there\r\nCATEGORIES:a,b\r\nURL:https://ex.org\r\nEND:VCARD\r\n"
    let c = parseVCard(src)
    let outStr = toVCard(c)
    let c2 = parseVCard(outStr)
    check c2.fn == c.fn
    check c2.tels[0].value == "+100"
    check c2.emails[0].value == "ada@example.org"
    check c2.note.get == "hi, there"
    check c2.categories == @["a", "b"]

  test "folding long NOTE (75 octets)":
    var c = VCard(version: vv40, fn: "Long")
    c.note = some("A".repeat(300))
    let txt = toVCard(c)
    for line in txt.split("\r\n"):
      if line.len == 0: continue
      check line.len <= 75
    check parseVCard(txt).note.get == "A".repeat(300)

  test "UTF-8 not split inside fold":
    let emoji = "🎉".repeat(80)
    var c = VCard(version: vv40, fn: "E")
    c.note = some(emoji)
    let txt = toVCard(c)
    check parseVCard(txt).note.get == emoji

  test "unfolding continuation":
    let src = "BEGIN:VCARD\r\nVERSION:4.0\r\nFN:T\r\nNOTE:This is a very long note that definitely exceeds seventy five characters\r\n and continues here.\r\nEND:VCARD\r\n"
    check parseVCard(src).note.get ==
      "This is a very long note that definitely exceeds seventy five charactersand continues here."

  test "downgrade to 3.0 maps PREF and data URI":
    var c = VCard(version: vv40, fn: "D")
    c.tels.add(VCardTel(value: "+1", types: @["voice"], pref: some(1)))
    c.photos.add(VCardPhoto(value: "data:image/jpeg;base64,aGVsbG8=",
      mediaType: some("image/jpeg")))
    var opts = defaultVCardOptions()
    opts.targetVersion = vv30
    let txt = toVCard(c, opts)
    check "VERSION:3.0" in txt
    check "TYPE=voice,PREF" in txt or "TYPE=PREF" in txt or "PREF" in txt
    check "ENCODING=b" in txt

  test "parseVCardsFile round-trip":
    let tmp = getTempDir() / "openparser_vcard_test.vcf"
    writeFile(tmp, "BEGIN:VCARD\r\nVERSION:4.0\r\nFN:File Test\r\nEND:VCARD\r\n")
    check parseVCardFile(tmp).fn == "File Test"
    removeFile(tmp)

  test "QR bridge compatible with qr/payload":
    var c = VCard(version: vv40, fn: "Ada Lovelace")
    c.n = some(VCardName(family: "Lovelace", given: "Ada"))
    c.org = some(VCardOrg(name: "OpenPeeps"))
    c.emails.add(VCardEmail(value: "ada@example.org"))
    let q = toQrPayload(c)
    check q.startsWith("BEGIN:VCARD\r\nVERSION:3.0\r\n")
    check "FN:Ada Lovelace" in q
    check "N:Lovelace;Ada" in q
    check q.endsWith("END:VCARD")
    # payload itself must re-parse
    check parseVCard(q).fn == "Ada Lovelace"

suite "vCard errors":
  test "missing FN raises":
    expect(OpenParserVCardError):
      discard parseVCard("BEGIN:VCARD\r\nVERSION:4.0\r\nEND:VCARD\r\n")

  test "missing VERSION raises":
    expect(OpenParserVCardError):
      discard parseVCard("BEGIN:VCARD\r\nFN:T\r\nEND:VCARD\r\n")

  test "mismatched END raises":
    expect(OpenParserVCardError):
      discard parseVCards("BEGIN:VCARD\r\nVERSION:4.0\r\nFN:T\r\nEND:VCALENDAR\r\n")

  test "unclosed card raises":
    expect(OpenParserVCardError):
      discard parseVCards("BEGIN:VCARD\r\nVERSION:4.0\r\nFN:T\r\n")

  test "invalid GENDER raises":
    expect(OpenParserVCardError):
      discard parseVCard("BEGIN:VCARD\r\nVERSION:4.0\r\nFN:T\r\nGENDER:X\r\nEND:VCARD\r\n")

  test "invalid BDAY DATE raises":
    expect(OpenParserVCardError):
      discard parseVCard("BEGIN:VCARD\r\nVERSION:4.0\r\nFN:T\r\nBDAY;VALUE=date:not-a-date\r\nEND:VCARD\r\n")

  test "empty KIND raises":
    expect(OpenParserVCardError):
      discard parseVCard("BEGIN:VCARD\r\nVERSION:4.0\r\nFN:T\r\nKIND:\r\nEND:VCARD\r\n")
