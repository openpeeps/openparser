# MIME parser and creator (RFC 822/2822/5322 + RFC 2045-2049) Plan

## Status: Implemented

Module: `src/openparser/mime.nim` | Tests: `tests/test_mime.nim`

---

## 1. Goal

Spec-compliant MIME parser and creator using Nim objects/data types, covering:

- RFC 822 / 2822 / 5322: Internet message format (headers, addresses, dates, message IDs, trace fields).
- RFC 2045: MIME format of Internet message bodies.
- RFC 2046: media types and multipart.
- RFC 2047: non-ASCII header extensions.
- RFC 2048: registration procedures (accept `x-` and future tokens).
- RFC 2049: conformance criteria and examples.

Plus pragmatic extensions: RFC 2183 `Content-Disposition` and RFC 2231 extended params/filename continuations.

---

## 2. Locked decisions

1. Module name: `mime` (`src/openparser/mime.nim`).
2. RFC 2183 / 2231 filename support in scope for v1.
3. Public binary payloads are owned `seq[byte]`. `std/memfiles` is used internally for file input and scanning; `UncheckedArray` stays out of public API.
4. Date representation: custom `MimeDate` preserving raw, calendar fields, offset, and zone. `toTime` helper when convertible.
5. Policy level added, lenient-first default (`MimePolicy.mpLenient`).

---

## 3. Data model

(See plan conversation for full type definitions.)

Key types: `MimeOptions`, `MimeHeader`, `MimeParam`, `MimeContentType`, `MimeDisposition`, `MimeTransferEncoding`, `MimeMailbox`, `MimeAddress`, `MimeDate`, `MimeBody`, `MimePart`, `MimeMessage`.

- `extraHeaders` fallback for unknown headers.
- Unknown media types, subtypes, CTE tokens, charsets, dispositions preserved.
- `preamble` / `epilogue` preserved for multipart.
- `raw` bytes preserved for text bodies.

---

## 4. API

```nim
proc defaultMimeOptions*(): MimeOptions
proc parseMime*(s: string; opts = defaultMimeOptions()): MimeMessage
proc parseMimeFile*(path: string; opts = defaultMimeOptions()): MimeMessage
proc toMime*(msg: MimeMessage; opts = defaultMimeOptions()): string
proc writeMimeFile*(path: string; msg: MimeMessage; opts = defaultMimeOptions())

proc newTextPart*(text, mediaSubtype = "plain"; charset = "utf-8"): MimePart
proc newBinaryPart*(data: seq[byte]; mediaType = "application/octet-stream"): MimePart
proc newMultipart*(subtype = "mixed"; parts: seq[MimePart] = @[]): MimePart
proc newForwardedMessage*(msg: MimeMessage): MimePart

proc decodeEncodedWords*(s: string; opts: MimeOptions = defaultMimeOptions()): string
proc parseMimeAddresses*(s: string): seq[MimeAddress]
proc parseMimeDate*(s: string): MimeDate
proc parseContentType*(s: string): MimeContentType
```

---

## 5. Architecture

Parsing pipeline:

1. Split headers/body at first blank line (CRLF canonical, LF/CR lenient).
2. Unfold headers.
3. Parse field names.
4. Parse structured headers with RFC 5322 lexer (atoms, quoted strings, quoted pairs, comments, domain literals).
5. Decode RFC 2047 words where allowed.
6. Multipart boundary scanning.
7. CTE decode (base64, quoted-printable, 7bit/8bit/binary validation).
8. Charset conversion to UTF-8 via `std/encodings`, preserving raw bytes.
9. Recurse into multipart and `message/rfc822`.

Creation:

- CRLF by default, configurable.
- Fold headers around 78 columns, max 998.
- Encode non-ASCII as RFC 2047 words.
- Quote/encode params (RFC 2231 for non-ASCII).
- Generate and verify boundaries.
- Normalize text bodies to CRLF.
- Wrap base64/QP at 76 columns.

---

## 6. Policy

`MimePolicy`: `mpLenient` (default) / `mpStrict`.

Lenient accepts LF, unfolding with LF, missing MIME-Version, missing Content-Type (default text/plain; charset=us-ascii), missing CTE (7bit), unknown types as application/octet-stream, overlong lines, and recoverable boundary issues.

Strict enforces required fields, valid dates/addresses/message IDs/boundaries, CTE constraints, line lengths, and limits.

---

## 7. Charset policy

Use `std/encodings`. Unknown charset: strict raises, lenient preserves bytes without conversion. Invalid UTF-8: strict raises, lenient uses replacement and preserves raw.

---

## 8. File input

`parseMimeFile` memory-maps input, scans zero-copy, copies only decoded payloads into owned `seq[byte]`/strings.

---

## 9. Milestones

1. RFC 5322 core: headers, unfolding, addresses, dates, IDs, unstructured.
2. RFC 2045/2046: content types, CTE codecs, multipart, nested messages.
3. RFC 2047 + creator: encoded words, folding, boundaries, builders.
4. RFC 2048/2049 conformance, limits, vectors, docs, examples.

---

## 10. Tests

`tests/test_mime.nim`: header unfolding, addresses, dates, message IDs, content types, CTE vectors, multipart, RFC 2231 filenames, encoded words, policy matrix, binary fidelity, RFC 2049 examples, round-trips, negative strict tests, SIMD fast-path equivalence (base64/QP/line-ending/multipart dash lines, large-binary round trip).

## 12. SIMD acceleration

`src/openparser/private/mime_simd.nim` (SSE2 + AVX2 with scalar fallback,
`-d:openparserMimeNoSimd` to force scalar): `findEol`, `findEq`,
`hasNonAscii`, `hasBase64Ws`, `findNonBase64`. Wired into `nextLine`,
`parseHeaderBlock`, base64 strip + strict validation, QP decode
(block copies) + encode (no per-byte allocs), `encodeBase64Body`
(copyMem lines), `latin1ToUtf8`/`normalizeTextLineEndings` ASCII fast
paths, 7bit strict checks, multipart marker hoisting + `--` fast reject.
Measured on a 2.4 MB mixed message (`-d:release`, x86_64 SSE2):
parse 22.1 ms -> 14.5 ms (1.5x), serialize 13.5 ms -> 5.1 ms (2.6x),
QP decode 6.1x, base64 decode 3.3x.

## 13. Message creation defaults and date helpers

`newMessage` constructor with `withDefaults` (Date now, generated
Message-ID with From-domain fallback, `MIME-Version: 1.0` for MIME
bodies via `ensureMimeDefaults`/`isMimeBody`); `MimeDate.toTime`
(offset-aware, unknown zones read as UTC), `nowMimeDate`,
`generateMessageId`, `daysInMonth` with strict calendar validation
(Feb 30 and non-leap Feb 29 rejected; lenient drops the date).
Bare addr-spec reconstruction collapsed from a double build to a
single pass (behavior identical). `newTextPart` ASCII scan and
long-line check use the SIMD scanners. 135 tests passing.

---

## 11. Integration

- Add to `builddocs` export list in `src/openparser.nim`.
- README coverage.
- Example `examples/mime_example.nim`.
- No NAPI addon changes.