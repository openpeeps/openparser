# A collection of tiny parsers and dumpers
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/openparser

## Secure QR Code (SQRC) style symbols carrying a public area everyone
## can scan plus an encrypted private area only key holders can read.
##
## This module implements the openparser SQRC profile inspired by DENSO
## WAVE's Secure QR Code: the private payload is encrypted with AES and
## embedded ahead of the public text inside an ordinary Model 2 symbol.
## Two flavours exist:
##
## - compat   (prefix "SQRC1"): AES-128-ECB over PKCS#7 padded private
##   data, mirroring the original SQRC construction.
## - extended (prefix "SQRC2"): AES-GCM with a fresh random 96-bit nonce;
##   the tag covers the ciphertext and the public data as associated
##   data, so tampering with either is detected.
##
## Note that DENSO WAVE's own wire format is proprietary; symbols
## produced here follow the documented profile above, not theirs.
##
## Unstable API. Prefer importing `openparser/qr` instead of this module.

import std/[base64, strutils, sequtils]
import nimcypher
import ./common, ./model2

const sqrcPrefixCompat* = "SQRC1:"
const sqrcPrefixExtended* = "SQRC2:"

func checkSqrcKey(key: openArray[byte]) {.raises: [ValueError].} =
  if key.len != 16:
    raise newException(ValueError,
      "SQRC requires an AES-128 key of exactly 16 bytes")

func bytes(s: string): seq[byte] {.inline.} =
  s.toOpenArrayByte(0, s.len - 1).toSeq

proc sealPrivate*(privateData: string, key: openArray[byte],
                  publicData = "",
                  extended = false): string
    {.raises: [ValueError, OSError].} =
  ## Returns the encoded middle section of a SQRC payload: the base64
  ## sealed form of `privateData`. In extended mode the public data is
  ## bound into the authentication tag.
  checkSqrcKey key
  if extended:
    let sealed = gcmSeal(bytes(privateData), @(key), ad = bytes(publicData))
    var blob: seq[byte] = @[]
    for b in sealed.nonce: blob.add b
    for b in sealed.tag: blob.add b
    for b in sealed.cipherText: blob.add b
    result = base64.encode(blob)
  else:
    result = base64.encode(aesEcbEncrypt(@(key), bytes(privateData)))

proc openPrivate*(blob: string, key: openArray[byte],
                  publicData = "",
                  extended = false): string
    {.raises: [ValueError, KeyError, OSError].} =
  ## Recovers the private payload from a `sealPrivate` blob. Raises
  ## ValueError when the key is wrong or the data was tampered with.
  checkSqrcKey key
  let raw = base64.decode(blob)
  if extended:
    if raw.len < 28:
      raise newException(ValueError, "SQRC blob too short")
    var nonce: array[12, uint8]
    var tag: array[16, uint8]
    for i in 0 ..< 12: nonce[i] = uint8(raw[i])
    for i in 0 ..< 16: tag[i] = uint8(raw[12 + i])
    var ct: seq[byte] = @[]
    for i in 28 ..< raw.len: ct.add uint8(raw[i])
    let plain = aesGcmDecrypt(@(key), nonce, ct, tag, ad = bytes(publicData))
    result = newString(plain.len)
    for i in 0 ..< plain.len: result[i] = char(plain[i])
  else:
    let plain = aesEcbDecrypt(@(key), bytes(raw))
    result = newString(plain.len)
    for i in 0 ..< plain.len: result[i] = char(plain[i])

proc buildSqrcPayload*(publicData, privateData: string,
                       key: openArray[byte],
                       extended = false): string
    {.raises: [ValueError, OSError].} =
  ## Assembles the full SQRC text: prefix, sealed private blob, colon,
  ## public data. Ordinary scanners see the prefix and the public text
  ## around an opaque base64 block.
  let blob = sealPrivate(privateData, key, publicData, extended)
  result = (if extended: sqrcPrefixExtended else: sqrcPrefixCompat) &
    blob & ":" & publicData

proc encodeSqrc*(publicData, privateData: string, key: openArray[byte],
                 options = defaultQrEncodeOptions(),
                 extended = false): QrMatrix
    {.raises: [QrError, ValueError, OSError].} =
  ## Renders a Model 2 symbol carrying both areas at the requested
  ## error correction level.
  let payload = buildSqrcPayload(publicData, privateData, key, extended)
  result = encodeQr(payload, options)

proc splitSqrcText*(text: string): tuple[extended: bool, blob: string,
                                         publicData: string] {.
    raises: [QrError].} =
  ## Splits a scanned SQRC payload without touching cryptography.
  if text.startsWith(sqrcPrefixExtended):
    result.extended = true
  elif not text.startsWith(sqrcPrefixCompat):
    raise newException(QrError, "not a SQRC payload")
  let rest = text[(if result.extended: sqrcPrefixExtended.len
                   else: sqrcPrefixCompat.len) .. ^1]
  let sep = rest.find(':')
  if sep < 0:
    raise newException(QrError, "SQRC payload missing public section")
  result.blob = rest[0 ..< sep]
  result.publicData = rest[sep + 1 .. ^1]

type SqrcOpenResult* = object
    ## Outcome of opening a SQRC payload.
    ok*: bool
    publicText*: string
      ## The public area, readable without any key.
    privateText*: string
      ## The decrypted private area; empty when decryption failed.
    scannedText*: string
      ## The complete raw payload as it appeared on the symbol.

proc decodeSqrcText*(text: string, key: openArray[byte]): SqrcOpenResult =
  ## Opens a SQRC payload obtained from any scanner or decoder.
  ## On success `text` holds the public data and `privateText` the
  ## decrypted private data.
  try:
    let parts = splitSqrcText(text)
    result.ok = true
    result.publicText = parts.publicData
    result.scannedText = text
    result.privateText = openPrivate(parts.blob, key,
                                     parts.publicData, parts.extended)
  except ValueError, KeyError, OSError, QrError:
    result.ok = false

proc decodeSqrcMatrix*(m: QrMatrix, key: openArray[byte]): SqrcOpenResult =
  ## Decodes a Model 2 grid and opens its SQRC payload in one step.
  let plain = decodeQrMatrix(m)
  if not plain.ok:
    result.ok = false
    return
  try:
    let parts = splitSqrcText(plain.text)
    result = decodeSqrcText(plain.text, key)
    result.scannedText = plain.text
  except QrError:
    result.ok = false