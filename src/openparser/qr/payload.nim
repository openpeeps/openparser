# A collection of tiny parsers and dumpers
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/openparser

## Payload builders for common QR use cases: WiFi network credentials,
## MECARD contact cards and vCard 3.0 business cards. Every builder
## returns a string that can be handed straight to any encoder in this
## package.
##
## Unstable API. Prefer importing `openparser/qr` instead of this module.

import std/[strutils]

func escapeMecard(s: string): string =
  ## MECARD escapes backslashes, semicolons, commas and colons.
  for c in s:
    case c
    of '\\', ';', ',', ':': result.add '\\' & c
    else: result.add c

proc makeWifi*(ssid: string, password = "", encryption = "WPA",
               hidden = false): string =
  ## WIFI: payload per the Android/Wi-Fi Alliance QR convention.
  ## `encryption` is WPA, WEP or nopass; an empty password implies nopass.
  var enc = encryption.toUpperAscii
  if password.len == 0:
    enc = "nopass"
  result = "WIFI:T:" & enc & ";S:" & escapeMecard(ssid) & ";"
  if enc != "nopass":
    result.add "P:" & escapeMecard(password) & ";"
  if hidden:
    result.add "H:true;"
  result.add ";"

proc makeMecard*(name: string, phone = "", email = "", url = ""): string =
  ## Compact MECARD contact card as read by Japanese feature phones and
  ## most camera apps.
  result = "MECARD:N:" & escapeMecard(name) & ";"
  if phone.len > 0:
    result.add "TEL:" & escapeMecard(phone) & ";"
  if email.len > 0:
    result.add "EMAIL:" & escapeMecard(email) & ";"
  if url.len > 0:
    result.add "URL:" & escapeMecard(url) & ";"
  result.add ";"

type VCard* = object
  ## Fields of a minimal vCard 3.0 business card. Empty fields are
  ## omitted from the payload.
  fullName*: string
  org*: string
  title*: string
  phone*: string
  email*: string
  url*: string
  address*: string
    ## Free form, semicolon separated street;city;region;zip;country.
  note*: string

proc makeVCard*(card: VCard): string =
  ## vCard 3.0 payload widely used for business card QR codes.
  result = "BEGIN:VCARD\r\nVERSION:3.0\r\n"
  if card.fullName.len > 0:
    result.add "FN:" & card.fullName & "\r\n"
    # N is reversed: family;given;middle;prefix;suffix - we only split the
    # last token off as the family name when possible
    let parts = card.fullName.split(' ')
    var family = ""
    var given = card.fullName
    if parts.len > 1:
      family = parts[^1]
      given = card.fullName[0 ..< card.fullName.len - family.len - 1]
    result.add "N:" & family & ";" & given & ";;;\r\n"
  if card.org.len > 0:
    result.add "ORG:" & card.org & "\r\n"
  if card.title.len > 0:
    result.add "TITLE:" & card.title & "\r\n"
  if card.phone.len > 0:
    result.add "TEL;TYPE=CELL:" & card.phone & "\r\n"
  if card.email.len > 0:
    result.add "EMAIL:" & card.email & "\r\n"
  if card.url.len > 0:
    result.add "URL:" & card.url & "\r\n"
  if card.address.len > 0:
    result.add "ADR:;;" & card.address & "\r\n"
  if card.note.len > 0:
    result.add "NOTE:" & card.note & "\r\n"
  result.add "END:VCARD"

proc makeUrl*(url: string): string =
  ## Normalises a bare domain into an https URL; absolute URLs with any
  ## scheme pass through unchanged.
  if "://" in url:
    url
  else:
    "https://" & url

proc makeSms*(phone: string, message = ""): string =
  ## SMSTO: payload which prompts the scanner to send an SMS.
  if message.len > 0:
    "SMSTO:" & phone & ":" & message
  else:
    "SMSTO:" & phone

proc makeEmail*(to: string, subject = "", body = ""): string =
  ## mailto: payload with optional query parameters.
  result = "mailto:" & to
  var params: seq[string] = @[]
  if subject.len > 0:
    params.add "subject=" & subject
  if body.len > 0:
    params.add "body=" & body
  if params.len > 0:
    result.add "?" & params.join("&")
