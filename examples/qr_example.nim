# A collection of tiny parsers and dumpers
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/openparser

## End to end tour of the openparser QR family: generate every supported
## symbology, render it as SVG and decode it back.

import std/[os]
import ../src/openparser/qr

proc preview(m: QrMatrix) =
  ## Terminal fallback: half blocks keep the symbol square and scannable.
  stdout.write m.toTerminal()
  echo ""

block model2:
  let m = encodeQr("https://openparser.dev/qr")
  echo "Model 2 v", (m.width - 17) div 4, ": ", decodeQrMatrix(m).text
  writeFile("/tmp/openparser_model2.svg", m.toSvg())

block micro:
  let m = encodeMicro("HELLO MICRO")
  let dec = decodeMicroMatrix(m)
  echo "Micro ", microDesignator(dec.version), ": ", dec.text

block rmqr:
  let m = encodeRmqr("rectangular micro qr", ecMedium, "R11x139")
  let dec = decodeRmqrMatrix(m)
  echo "rMQR ", rmqrSizeName(dec.version - 1), "-M: ", dec.text
  writeFile("/tmp/openparser_rmqr.svg", m.toSvg(border = 4))

block sqrc:
  var key: array[16, uint8]
  for i in 0 ..< 16: key[i] = uint8(i * 17 + 3)
  let m = encodeSqrc(publicData = "serial 4711",
                     privateData = "warranty code 99-FOO",
                     key)
  let opened = decodeSqrcMatrix(m, key)
  echo "SQRC public: ", opened.publicText,
    " private: ", opened.privateText
  # a wrong key must not decrypt anything
  var wrong: array[16, uint8]
  doAssert not decodeSqrcMatrix(m, wrong).ok
  key[0] = 0

block payload:
  let card = VCard(fullName: "Ada Lovelace", org: "OpenPeeps",
                   phone: "+1555000111", email: "ada@example.org",
                   url: "https://example.org")
  let m = encodeQr(makeVCard(card))
  writeFile("/tmp/openparser_payload_qr_vcard.svg", m.toSvg(border = 4))
  echo "vCard symbol decodes: ", decodeQrMatrix(m).ok

block aqr:
  let m = encodeAqr("https://example.org", "RING42")
  echo "AQR ring: ", readAqrRing(m),
    " core: ", decodeAqrCore(m).text

if paramCount() > 0 and paramStr(1) == "--ascii":
  preview(encodeQr("openparser"))
