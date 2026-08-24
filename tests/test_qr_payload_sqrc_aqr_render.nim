# A collection of tiny parsers and dumpers
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/openparser

import std/[unittest, strutils, os, sequtils]
import ../src/openparser/qr/common
import ../src/openparser/qr/model2
import ../src/openparser/qr/payload
import ../src/openparser/qr/sqrc
import ../src/openparser/qr/aqr
import ../src/openparser/qr/render

suite "payload builders":
  test "wifi payload escapes special characters":
    check makeWifi("home", "pass;word") ==
      "WIFI:T:WPA;S:home;P:pass\\;word;;"
    check makeWifi("open") == "WIFI:T:nopass;S:open;;"
    check makeWifi("corp", "pw", "wep", hidden = true) ==
      "WIFI:T:WEP;S:corp;P:pw;H:true;;"

  test "mecard payload":
    check makeMecard("Doe;John", "+1555000111") ==
      "MECARD:N:Doe\\;John;TEL:+1555000111;;"

  test "vcard payload structure":
    let v = makeVCard(VCard(fullName: "Ada Lovelace",
                            org: "OpenPeeps", email: "ada@example.org"))
    check v.startsWith("BEGIN:VCARD\r\nVERSION:3.0\r\n")
    check "FN:Ada Lovelace" in v
    check "N:Lovelace;Ada;;;" in v
    check "ORG:OpenPeeps" in v
    check v.endsWith("END:VCARD")

  test "url normalisation":
    check makeUrl("example.org/path") == "https://example.org/path"
    check makeUrl("http://insecure.example") == "http://insecure.example"

  test "sms and mailto payloads":
    check makeSms("+1555000111", "hi") == "SMSTO:+1555000111:hi"
    check makeEmail("a@b.org", "Hello") == "mailto:a@b.org?subject=Hello"
    check makeEmail("a@b.org", "Hi", "Body") ==
      "mailto:a@b.org?subject=Hi&body=Body"

  test "payloads feed the encoder":
    let m = encodeQr(makeWifi("net", "secret1234"))
    check decodeQrMatrix(m).text == "WIFI:T:WPA;S:net;P:secret1234;;"

suite "sqrc":
  func testKey(): array[16, uint8] =
    for i in 0 ..< 16: result[i] = uint8(i * 13 + 7)

  test "compat mode round trip":
    let key = testKey()
    let m = encodeSqrc("serial 4711", "code 99-FOO", key)
    let opened = decodeSqrcMatrix(m, key)
    check opened.ok
    check opened.publicText == "serial 4711"
    check opened.privateText == "code 99-FOO"

  test "extended mode round trip binds the public area":
    let key = testKey()
    let m = encodeSqrc("public text", "top secret", key, extended = true)
    let opened = decodeSqrcMatrix(m, key)
    check opened.ok
    check opened.privateText == "top secret"
    # flipping one bit of the public text must invalidate the tag
    var tampered = opened.scannedText
    let i = tampered.rfind('t')
    tampered[i] = 'T'
    check not decodeSqrcText(tampered, key).ok

  test "wrong key fails cleanly":
    let key = testKey()
    let m = encodeSqrc("pub", "priv", key)
    var wrong: array[16, uint8]
    for i in 0 ..< 16: wrong[i] = uint8(i)
    check not decodeSqrcMatrix(m, wrong).ok

  test "plain payloads are rejected":
    let key = testKey()
    let plain = encodeQr("just a normal qr code")
    check not decodeSqrcMatrix(plain, key).ok

suite "aqr":
  test "ring round trip":
    let m = encodeAqr("https://example.org", "RING-42")
    check readAqrRing(m) == "RING-42"

  test "core stays decodable":
    let m = encodeAqr("https://example.org/main", "X1")
    check decodeAqrCore(m).text == "https://example.org/main"
    check readAqrRing(m) == "X1"

  test "oversized ring payload is rejected":
    expect QrError:
      discard encodeAqr("main", repeat('z', 64))

suite "render":
  test "svg contains every dark module exactly once":
    let m = encodeQr("svg render check")
    let svg = m.toSvg(scale = 4, border = 2)
    check svg.startsWith("<svg xmlns=")
    check svg.endsWith("</svg>\n")
    check "width=\"" & $((m.width + 4) * 4) & "\"" in svg
    # one M command per dark module plus a single fill directive
    check svg.count('M') == m.modules.countIt(it)

  test "terminal half blocks pair two rows per line":
    var m = initSquareQrMatrix(1)
    m.modules[0] = true
    let term = m.toTerminal(border = 1)
    let lines = term.split('\n')
    # three module rows compress into two character lines; the lone
    # dark module shows as an upper half block between full blocks
    check lines == @["█▀█", "███"]

  test "invalid arguments raise":
    let m = initSquareQrMatrix(21)
    expect ValueError:
      discard m.toSvg(scale = 0)
    expect ValueError:
      discard m.toTerminal(border = -1)

when isMainModule and fileExists("/dev/null"):
  discard
