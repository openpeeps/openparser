## Node.js addon surface for openparser (napibuild only).
##
## Included from `src/openparser.nim` after `napi_convert`. Every wrapper
## takes only NAPI-safe params (`string`, `bool`, `int`) and either
## returns a plain value via `%*` or a live JS object via the `jsParse`
## bridge. Structured Nim results cross as JSON; binary crosses as
## base64; floats cross as strings where they are inputs.
##
## Like above, std/json's `%*` is excluded on purpose — bare `%*`
## always means denim's napi-value macro here.

from ../yaml import dump
from ../toml import parseTOML, dumpTOML
from ../xml import fromXml, toXml
from ../csv import parseFile
from ../bson import toBson, fromBson
from ../plist import parsePlist, toXmlPlist, toBPlist
from ../rss import parseRss, toRssXml
from ../feed import parseAtom, toAtomXml
from ../dotenv import parseEnv
from ../ical import parseIcal, toIcal
from ../vcard import parseVCards, toVCards, toQrPayload
from ../sql import parseSql, renderSql
from ../gettext/po import openPoCatalog, compilePo, translate, close
from ../gettext/mo import openMoCatalog, translate, close
from ../qr import encodeQr, encodeMicro, encodeRmqr, encodeModel1,
  encodeSqrc, encodeAqr, buildSqrcPayload, decodeSqrcText, splitSqrcText,
  MicroVersion, QrEcLevel, defaultQrEncodeOptions, makeWifi, makeMecard, makeUrl, makeSms, makeEmail, toSvg
from ../svg import parseSvg, toSvg, parsePathData
from ../colors import parseColor, isValidColor, lighten, darken, complement,
  contrastRatio
from ../css import parseCss, toString
from ../uuid import Uuid, parseUuid, isValidUuid, newUuidV1, newUuidV2,
  newUuidV3, newUuidV4, newUuidV5, newUuidV6, newUuidV7, newUuidV8, nilUuid,
  UuidNamespace, version, variant, `$`
from ../path import parsePath
from ../fuzzy import FuzzyOptions, fuzzyScore, fuzzySearch

init proc(module: Module) =
  # ------------------------------------------------------------- yaml
  proc yamlParse(src: string) {.export_napi: false.} =
    ## Parse YAML to a JS object.
    return jsParse(yamlParseJson(args.get("src").getStr()))

  proc yamlDump(doc: string) {.export_napi: false.} =
    ## Serialize a JSON document (as string) to YAML.
    return %*dump(parseJson(args.get("doc").getStr()))

  module.register("yaml", [("parse", yamlParse), ("dump", yamlDump)])

  # ------------------------------------------------------------- toml
  proc tomlParse(src: string) {.export_napi: false.} =
    ## Parse TOML to a JS object (datetimes become ISO strings).
    return jsParse(tomlToJson(parseTOML(args.get("src").getStr())))

  proc tomlDump(doc: string) {.export_napi: false.} =
    ## Serialize a JSON document (as string) to TOML.
    return %*dumpTOML(tomlFromJson(parseJson(args.get("doc").getStr())))

  module.register("toml", [("parse", tomlParse), ("dump", tomlDump)])

  # -------------------------------------------------------------- xml
  proc xmlParse(src: string) {.export_napi: false.} =
    ## Parse XML to a JS DOM ({kind, tag, attrs, children}).
    return jsParse(xmlToJson(fromXml(args.get("src").getStr())))

  proc xmlNormalize(src: string) {.export_napi: false.} =
    ## Canonicalize XML via parse/serialize round-trip.
    return %*toXml(fromXml(args.get("src").getStr()))

  module.register("xml", [("parse", xmlParse), ("normalize", xmlNormalize)])

  # -------------------------------------------------------------- csv
  proc csvParse(src: string, delimiter: string,
                quote: string) {.export_napi: false.} =
    ## Parse CSV text to an array of rows (arrays of strings).
    return jsParse(csvRowsFromString(args.get("src").getStr(),
      args.get("delimiter").getStr(), args.get("quote").getStr()))

  proc csvParseFile(path: string, delimiter: string,
                    quote: string) {.export_napi: false.} =
    ## Parse a CSV file to an array of rows.
    return jsParse(csvRowsFromFile(args.get("path").getStr(),
      args.get("delimiter").getStr(), args.get("quote").getStr()))

  module.register("csv", [("parse", csvParse), ("parseFile", csvParseFile)])

  # ------------------------------------------------------------- bson
  proc bsonFromJson(doc: string) {.export_napi: false.} =
    ## Encode a JSON document (as string) to BSON, returned as base64.
    return %*base64FromBytes(toBson(parseJson(args.get("doc").getStr())))

  proc bsonToJson(data: string) {.export_napi: false.} =
    ## Decode base64 BSON to a JS object (extended JSON v2).
    return jsParse(fromBson(bytesFromBase64(args.get("data").getStr())))

  module.register("bson", [("fromJson", bsonFromJson),
                           ("toJson", bsonToJson)])

  # ------------------------------------------------------------ plist
  proc plistParse(src: string) {.export_napi: false.} =
    ## Parse an XML plist to a JS object.
    return jsParse(parsePlist(args.get("src").getStr()))

  proc plistParseBase64(data: string) {.export_napi: false.} =
    ## Parse a base64 plist (XML or binary bplist00) to a JS object.
    return jsParse(parsePlist(bytesFromBase64(args.get("data").getStr())))

  proc plistToXml(doc: string) {.export_napi: false.} =
    ## Serialize a JSON document (as string) to XML plist.
    return %*toXmlPlist(parseJson(args.get("doc").getStr()))

  proc plistToBplist(doc: string) {.export_napi: false.} =
    ## Serialize a JSON document (as string) to binary plist, as base64.
    return %*base64FromBytes(toBPlist(parseJson(args.get("doc").getStr())))

  module.register("plist", [("parse", plistParse),
                            ("parseBase64", plistParseBase64),
                            ("toXml", plistToXml),
                            ("toBplist", plistToBplist)])

  # -------------------------------------------------------------- rss
  proc rssParse(src: string) {.export_napi: false.} =
    ## Parse an RSS feed to a JS object.
    return jsParse(rssToJson(parseRss(args.get("src").getStr())))

  proc rssNormalize(src: string) {.export_napi: false.} =
    ## Canonicalize RSS via parse/serialize round-trip.
    return %*toRssXml(parseRss(args.get("src").getStr()))

  module.register("rss", [("parse", rssParse), ("normalize", rssNormalize)])

  # -------------------------------------------------------------- atom
  proc atomParse(src: string) {.export_napi: false.} =
    ## Parse an Atom feed to a JS object.
    return jsParse(atomToJson(parseAtom(args.get("src").getStr())))

  proc atomNormalize(src: string) {.export_napi: false.} =
    ## Canonicalize Atom via parse/serialize round-trip.
    return %*toAtomXml(parseAtom(args.get("src").getStr()))

  module.register("atom", [("parse", atomParse),
                           ("normalize", atomNormalize)])

  # ------------------------------------------------------------ dotenv
  proc dotenvParse(src: string) {.export_napi: false.} =
    ## Parse .env content to an array of {key, value, expand}.
    return jsParse(dotenvToJson(parseEnv(args.get("src").getStr())))

  module.register("dotenv", [("parse", dotenvParse)])

  # ------------------------------------------------------------- ical
  proc icalParse(src: string) {.export_napi: false.} =
    ## Parse iCalendar to a JS object (RFC 5545 typed model as JSON).
    return jsParse(icalToJson(parseIcal(args.get("src").getStr())))

  proc icalNormalize(src: string) {.export_napi: false.} =
    ## Canonicalize iCalendar via parse/serialize round-trip.
    return %*toIcal(parseIcal(args.get("src").getStr()))

  module.register("ical", [("parse", icalParse),
                           ("normalize", icalNormalize)])

  # ------------------------------------------------------------ vcard
  proc vcardParse(src: string) {.export_napi: false.} =
    ## Parse vCards (3.0/4.0) to a JS array of contacts.
    return jsParse(vcardsToJson(parseVCards(args.get("src").getStr())))

  proc vcardNormalize(src: string) {.export_napi: false.} =
    ## Canonicalize vCards to 4.0 via parse/serialize round-trip.
    return %*toVCards(parseVCards(args.get("src").getStr()))

  proc vcardQrPayload(src: string, index: int) {.export_napi: false.} =
    ## Minimal vCard 3.0 QR payload for the card at `index`.
    let cards = parseVCards(args.get("src").getStr())
    let i = args.get("index").getInt()
    if i < 0 or i >= cards.len:
      # NB: must be a CatchableError (not IndexDefect) so denim's
      # wrapper converts it to a JS error instead of crashing.
      raise newException(ValueError, "card index out of range")
    return %*toQrPayload(cards[i])

  module.register("vcard", [("parse", vcardParse),
                            ("normalize", vcardNormalize),
                            ("qrPayload", vcardQrPayload)])

  # -------------------------------------------------------------- sql
  proc sqlParse(src: string, driver: string) {.export_napi: false.} =
    ## Parse SQL to a JS AST ({kind, value?, children?}).
    ## driver: generic|pgsql|mysql|sqlite (prefixes accepted).
    return jsParse(sqlToJson(parseSql(args.get("src").getStr(),
      sqlDriverFromString(args.get("driver").getStr()))))

  proc sqlNormalize(src: string, driver: string) {.export_napi: false.} =
    ## Canonicalize SQL via parse/render round-trip.
    return %*renderSql(parseSql(args.get("src").getStr(),
      sqlDriverFromString(args.get("driver").getStr())))

  module.register("sql", [("parse", sqlParse), ("normalize", sqlNormalize)])

  # ---------------------------------------------------------- gettext
  proc poTranslate(path: string, msgid: string,
                   msgctxt: string) {.export_napi: false.} =
    ## Translate `msgid` using a .po file (empty msgctxt for none).
    var cat = openPoCatalog(args.get("path").getStr())
    defer: close(cat)
    let cc = compilePo(cat)
    return %*cc.translate(args.get("msgid").getStr(),
                          args.get("msgctxt").getStr())

  proc moTranslate(path: string, msgid: string,
                   msgctxt: string) {.export_napi: false.} =
    ## Translate `msgid` using a compiled .mo file.
    var cat = openMoCatalog(args.get("path").getStr())
    defer: close(cat)
    return %*cat.translate(args.get("msgid").getStr(),
                           args.get("msgctxt").getStr())

  module.register("gettext", [("poTranslate", poTranslate),
                              ("moTranslate", moTranslate)])

  # --------------------------------------------------------------- qr
  proc qrMakeWifi(ssid: string, password: string, encryption: string,
                  hidden: bool) {.export_napi: false.} =
    ## Build a WIFI: QR payload string.
    return %*makeWifi(args.get("ssid").getStr(),
      args.get("password").getStr(), args.get("encryption").getStr(),
      args.get("hidden").getBool())

  proc qrMakeMecard(name: string, phone: string, email: string,
                    url: string) {.export_napi: false.} =
    ## Build a MECARD contact payload string.
    return %*makeMecard(args.get("name").getStr(),
      args.get("phone").getStr(), args.get("email").getStr(),
      args.get("url").getStr())

  proc qrMakeUrl(url: string) {.export_napi: false.} =
    ## Normalize a URL payload string.
    return %*makeUrl(args.get("url").getStr())

  proc qrMakeSms(phone: string, message: string) {.export_napi: false.} =
    ## Build an SMSTO: payload string.
    return %*makeSms(args.get("phone").getStr(),
                     args.get("message").getStr())

  proc qrMakeEmail(to: string, subject: string,
                   body: string) {.export_napi: false.} =
    ## Build a mailto: payload string.
    return %*makeEmail(args.get("to").getStr(),
      args.get("subject").getStr(), args.get("body").getStr())

  proc qrEncodeSvg(text: string) {.export_napi: false.} =
    ## Encode text as a QR symbol, returned as an SVG string.
    return %*toSvg(encodeQr(args.get("text").getStr()))

  proc parseQrEc(s: string): QrEcLevel =
    ## Map "L/M/Q/H" to an EC level; raises ValueError (a JS error).
    case s.toUpperAscii():
    of "L": ecLow
    of "M": ecMedium
    of "Q": ecQuartile
    of "H": ecHigh
    else: raise newException(ValueError,
      "invalid EC level (expected L, M, Q or H): " & s)

  proc qrEncodeModel2(text: string, ec: string,
                      version: int) {.export_napi: false.} =
    ## Encode text as a Model 2 symbol (versions 1-40, 0 = auto).
    let v = args.get("version").getInt()
    if v < 0 or v > 40:
      raise newException(ValueError,
        "Model 2 version out of range (0 = auto, 1 .. 40)")
    var opts = defaultQrEncodeOptions()
    opts.ecLevel = parseQrEc(args.get("ec").getStr())
    if v > 0:
      opts.minVersion = v
      opts.maxVersion = v
    return %*toSvg(encodeQr(args.get("text").getStr(), opts))

  proc qrEncodeMicro(text: string, ec: string,
                     version: int) {.export_napi: false.} =
    ## Encode text as a Micro QR symbol (0 = auto, 1-4 = M1-M4).
    let v = args.get("version").getInt()
    if v < 0 or v > 4:
      raise newException(ValueError,
        "Micro version out of range (0 = auto, 1 .. 4)")
    return %*toSvg(encodeMicro(args.get("text").getStr(),
      parseQrEc(args.get("ec").getStr()), MicroVersion(v)))

  proc qrEncodeRmqr(text: string, ec: string,
                    version: string) {.export_napi: false.} =
    ## Encode text as an rMQR symbol ("" = auto, else e.g. "R7x43").
    return %*toSvg(encodeRmqr(args.get("text").getStr(),
      parseQrEc(args.get("ec").getStr()), args.get("version").getStr()))

  proc qrEncodeModel1(text: string, ec: string,
                      version: int) {.export_napi: false.} =
    ## Encode text as a legacy Model 1 symbol (0 = auto, 1-12).
    return %*toSvg(encodeModel1(args.get("text").getStr(),
      parseQrEc(args.get("ec").getStr()), args.get("version").getInt()))

  proc qrKeyBytes(s: string): seq[byte] =
    ## Copy a key string to bytes for the SQRC helpers.
    result = newSeq[byte](s.len)
    for i, c in s: result[i] = byte(c)

  proc qrEncodeSqrc(publicData: string, privateData: string,
                    key: string) {.export_napi: false.} =
    ## Encode an SQRC symbol (public + AES-sealed private area).
    return %*toSvg(encodeSqrc(args.get("publicData").getStr(),
      args.get("privateData").getStr(),
      qrKeyBytes(args.get("key").getStr())))

  proc qrMakeSqrc(publicData: string, privateData: string, key: string,
                  extended: bool) {.export_napi: false.} =
    ## Build an SQRC payload string without rendering a symbol.
    return %*buildSqrcPayload(args.get("publicData").getStr(),
      args.get("privateData").getStr(),
      qrKeyBytes(args.get("key").getStr()),
      args.get("extended").getBool())

  proc qrEncodeAqr(mainPayload: string, ringPayload: string, ec: string,
                   version: int) {.export_napi: false.} =
    ## Encode an AQR dual-payload symbol (core version 0 = auto).
    return %*toSvg(encodeAqr(args.get("mainPayload").getStr(),
      args.get("ringPayload").getStr(),
      parseQrEc(args.get("ec").getStr()), args.get("version").getInt()))

  proc qrDecodeSqrc(text: string, key: string) {.export_napi: false.} =
    ## Open an SQRC payload: {ok, publicText, privateText, scannedText}.
    let r = decodeSqrcText(args.get("text").getStr(),
                           qrKeyBytes(args.get("key").getStr()))
    var o = newJObject()
    o["ok"] = %r.ok
    o["publicText"] = %r.publicText
    o["privateText"] = %r.privateText
    o["scannedText"] = %r.scannedText
    return jsParse(o)

  proc qrSplitSqrc(text: string) {.export_napi: false.} =
    ## Split an SQRC payload: {extended, blobBase64, publicData}.
    let (extended, blob, publicData) =
      splitSqrcText(args.get("text").getStr())
    var o = newJObject()
    o["extended"] = %extended
    o["blobBase64"] = %base64.encode(blob)
    o["publicData"] = %publicData
    return jsParse(o)

  module.register("qr", [("makeWifi", qrMakeWifi),
                         ("makeMecard", qrMakeMecard),
                         ("makeUrl", qrMakeUrl),
                         ("makeSms", qrMakeSms),
                         ("makeEmail", qrMakeEmail),
                         ("encodeSvg", qrEncodeSvg),
                         ("encodeModel2", qrEncodeModel2),
                         ("encodeMicro", qrEncodeMicro),
                         ("encodeRmqr", qrEncodeRmqr),
                         ("encodeModel1", qrEncodeModel1),
                         ("encodeSqrc", qrEncodeSqrc),
                         ("encodeAqr", qrEncodeAqr),
                         ("makeSqrc", qrMakeSqrc),
                         ("decodeSqrc", qrDecodeSqrc),
                         ("splitSqrc", qrSplitSqrc)])

  # -------------------------------------------------------------- svg
  proc svgNormalize(src: string) {.export_napi: false.} =
    ## Canonicalize SVG via parse/serialize round-trip.
    return %*toSvg(parseSvg(args.get("src").getStr()))

  proc svgParsePathData(d: string) {.export_napi: false.} =
    ## Parse SVG path data to an array of {cmd, args}.
    return jsParse(svgPathToJson(parsePathData(args.get("d").getStr())))

  module.register("svg", [("normalize", svgNormalize),
                          ("parsePathData", svgParsePathData)])

  # ------------------------------------------------------------ colors
  proc colorsParse(src: string) {.export_napi: false.} =
    ## Parse any CSS color to {hex, hex8, rgb, hsl, hsv, cmyk, lab,
    ## oklch, name}.
    return jsParse(colorToJson(parseColor(args.get("src").getStr())))

  proc colorsIsValid(src: string) {.export_napi: false.} =
    ## Check whether a string is a parseable CSS color.
    return %*isValidColor(args.get("src").getStr())

  proc colorsLighten(src: string, amount: string) {.export_napi: false.} =
    ## Lighten a color by `amount`, returned as hex.
    return %*toHex(lighten(parseColor(args.get("src").getStr()),
                           parseFloat(args.get("amount").getStr())))

  proc colorsDarken(src: string, amount: string) {.export_napi: false.} =
    ## Darken a color by `amount`, returned as hex.
    return %*toHex(darken(parseColor(args.get("src").getStr()),
                          parseFloat(args.get("amount").getStr())))

  proc colorsComplement(src: string) {.export_napi: false.} =
    ## Complement of a color, returned as hex.
    return %*toHex(complement(parseColor(args.get("src").getStr())))

  proc colorsContrastRatio(a: string, b: string) {.export_napi: false.} =
    ## WCAG contrast ratio between two colors.
    return %*contrastRatio(parseColor(args.get("a").getStr()),
                           parseColor(args.get("b").getStr()))

  module.register("colors", [("parse", colorsParse),
                             ("isValid", colorsIsValid),
                             ("lighten", colorsLighten),
                             ("darken", colorsDarken),
                             ("complement", colorsComplement),
                             ("contrastRatio", colorsContrastRatio)])

  # -------------------------------------------------------------- css
  proc cssParse(src: string) {.export_napi: false.} =
    ## Parse a CSS stylesheet to a JS AST.
    return jsParse(cssToJson(parseCss(args.get("src").getStr())))

  proc cssNormalize(src: string) {.export_napi: false.} =
    ## Canonicalize CSS via parse/serialize round-trip.
    var outp = ""
    for n in parseCss(args.get("src").getStr()).nodes:
      outp.add(toString(n))
    return %*outp

  module.register("css", [("parse", cssParse), ("normalize", cssNormalize)])

  # ------------------------------------------------------------- uuid
  proc uuidIsValid(s: string) {.export_napi: false.} =
    ## Check whether a string is a valid UUID.
    return %*isValidUuid(args.get("s").getStr())

  proc uuidV1() {.export_napi: false.} =
    ## Generate a time-based v1 UUID string.
    return %*($newUuidV1())

  proc uuidV2(domain: int, id: int) {.export_napi: false.} =
    ## Generate a DCE Security v2 UUID (domain 0=person,1=group,2=org).
    let d = args.get("domain").getInt()
    let i = args.get("id").getInt()
    if d < 0 or d > 255:
      raise newException(ValueError, "v2 domain out of range (0 .. 255)")
    if i < 0 or i > 4294967295:
      raise newException(ValueError, "v2 id out of range (0 .. 2^32-1)")
    return %*($newUuidV2(byte(d), uint32(i)))

  proc parseUuidNamespace(s: string): Uuid =
    ## Map "dns/url/oid/x500" (or any UUID string) to a namespace UUID.
    case s.toLowerAscii():
    of "dns": parseUuid($nsDNS)
    of "url": parseUuid($nsURL)
    of "oid": parseUuid($nsOID)
    of "x500": parseUuid($nsX500)
    else: parseUuid(s)

  proc uuidV3(namespace: string, name: string) {.export_napi: false.} =
    ## Generate an MD5 name-based v3 UUID string.
    return %*($newUuidV3(parseUuidNamespace(args.get("namespace").getStr()),
                         args.get("name").getStr()))

  proc uuidV4() {.export_napi: false.} =
    ## Generate a random v4 UUID string.
    return %*($newUuidV4())

  proc uuidV5(namespace: string, name: string) {.export_napi: false.} =
    ## Generate a SHA-1 name-based v5 UUID string.
    return %*($newUuidV5(parseUuidNamespace(args.get("namespace").getStr()),
                         args.get("name").getStr()))

  proc uuidV6() {.export_napi: false.} =
    ## Generate a reordered time-based v6 UUID string.
    return %*($newUuidV6())

  proc uuidV7() {.export_napi: false.} =
    ## Generate a time-ordered v7 UUID string.
    return %*($newUuidV7())

  proc uuidV8(data: string) {.export_napi: false.} =
    ## Generate a custom v8 UUID from 128 bits of hex (32 hex digits).
    return %*($newUuidV8(parseUuid(args.get("data").getStr()).bytes))

  proc uuidNil() {.export_napi: false.} =
    ## The nil UUID (all zeros).
    return %*($nilUuid())

  proc uuidParse(s: string) {.export_napi: false.} =
    ## Parse a UUID to its canonical string form.
    return %*($parseUuid(args.get("s").getStr()))

  proc uuidVersion(s: string) {.export_napi: false.} =
    ## Extract the version number from a UUID string.
    return %*version(parseUuid(args.get("s").getStr()))

  proc uuidVariant(s: string) {.export_napi: false.} =
    ## Extract the variant name (NCS, RFC4122, Microsoft, Future).
    let v = $variant(parseUuid(args.get("s").getStr()))
    return %*v[len("variant") .. ^1]

  module.register("uuid", [("isValid", uuidIsValid), ("v1", uuidV1),
                           ("v2", uuidV2), ("v3", uuidV3),
                           ("v4", uuidV4), ("v5", uuidV5),
                           ("v6", uuidV6), ("v7", uuidV7),
                           ("v8", uuidV8), ("nil", uuidNil),
                           ("parse", uuidParse),
                           ("version", uuidVersion),
                           ("variant", uuidVariant)])

  # ------------------------------------------------------------- path
  proc pathParse(s: string) {.export_napi: false.} =
    ## Parse a filesystem path or URL to a JS object.
    return jsParse(pathToJson(parsePath(args.get("s").getStr())))

  proc pathNormalize(s: string) {.export_napi: false.} =
    ## Canonicalize a path/URL via parse/stringify round-trip.
    return %*($parsePath(args.get("s").getStr()))

  module.register("path", [("parse", pathParse),
                           ("normalize", pathNormalize)])

  # ------------------------------------------------------------ fuzzy
  proc fuzzyScoreSingle(query: string, candidate: string,
                        caseSensitive: bool) {.export_napi: false.} =
    ## Score one candidate: {matched, score, positions}.
    let r = fuzzyScore(args.get("query").getStr(),
                       args.get("candidate").getStr(),
                       FuzzyOptions(caseSensitive: args.get("caseSensitive").getBool()))
    var o = newJObject()
    o["matched"] = %r.matched
    o["score"] = %r.score
    var arr = newJArray()
    for p in r.positions: arr.add(%p)
    o["positions"] = arr
    return jsParse(o)

  proc fuzzySearchMulti(query: string, candidates: string,
                        caseSensitive: bool, limit: int,
                        minScore: string) {.export_napi: false.} =
    ## Rank candidates (JSON array string): [{text, score, positions}].
    ## Floats cross as strings per NAPI-safe params rule.
    var cands: seq[string] = @[]
    for n in parseJson(args.get("candidates").getStr()).elems:
      cands.add(n.getStr())
    let res = fuzzySearch(args.get("query").getStr(), cands,
                FuzzyOptions(caseSensitive: args.get("caseSensitive").getBool(),
                             limit: args.get("limit").getInt(),
                             minScore: parseFloat(args.get("minScore").getStr())))
    var arr = newJArray()
    for m in res: arr.add(fuzzyMatchToJson(m))
    return jsParse(arr)

  module.register("fuzzy", [("score", fuzzyScoreSingle),
                            ("search", fuzzySearchMulti)])
