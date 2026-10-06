# A collection of tiny parsers and dumpers
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/openparser

## Byte scanning primitives. Nothing here allocates: callers pass around a
## `ByteView` that is already in hand.
##
## The byte *searches* go to libc `memchr` rather than a hand-written loop.
## That is a measured decision, not an oversight. Profiling the pipeline showed
## the newline scan to be the only stage where vectorisation could help at all,
## and libc's `memchr` is already SSE2/AVX2-vectorised on every platform this
## package targets. A hand-rolled `nimsimd` lane would have to beat an existing
## optimised library to justify its parity-test surface, and the numbers said it
## would not. See `plans/diff-module.md`.
##
## The scalar loops are kept deliberately, under `*Scalar` names, as the
## reference implementation: a parity test compares every libc result against
## them, so a wrong `memchr` bound or a bad offset conversion fails loudly here
## rather than producing a corrupt diff somewhere downstream. They are also the
## fallback for a target where `c_memchr` is unavailable, and the same shape
## `fuzzy.nim` uses for its lanes.
##
## Line *comparison* was already vectorised: `equalRange` calls `equalMem`,
## which is `memcmp`. There was never anything to win there.

from system/ansi_c import c_memchr

import ./types

const
  nlByte* = byte(10) ## `\n`, the only line terminator this module splits on
  crByte* = byte(13) ## `\r`, counted as content rather than as terminator
  nulByte* = byte(0) ## the binary sniff marker

proc findNewlineScalar*(v: ByteView, start, stop: int): int =
  ## First index in `[start, stop)` holding a newline, or -1.
  ##
  ## The reference implementation, and what `findNewline` is parity-tested
  ## against. Not dead code: it is the fallback for any target where
  ## `c_memchr` is not available.
  ##
  ## The range is clamped to the view's own length. Without that clamp a caller
  ## asking about `[0, 1)` of an *empty* view reads index 0 of a nil pointer,
  ## which is a crash rather than a wrong answer. Internally the callers always
  ## pass `stop <= v.len`, but this proc is public, so it defends itself.
  let lo = max(0, start)
  let hi = min(stop, v.len)
  if lo >= hi or v.data == nil: return -1
  var i = lo
  # Bound by the clamped `hi`, not the caller's `stop`: that is the whole point
  # of the clamp.
  while i < hi:
    if v[i] == nlByte: return i
    inc i
  -1

proc findByteScalar*(v: ByteView, start, stop: int, needle: byte): int =
  ## First index in `[start, stop)` equal to `needle`, or -1.
  ## Reference implementation for `findByte`, clamped for the same reason.
  let lo = max(0, start)
  let hi = min(stop, v.len)
  if lo >= hi or v.data == nil: return -1
  var i = lo
  while i < hi:
    if v[i] == needle: return i
    inc i
  -1

proc findNewline*(v: ByteView, start, stop: int): int =
  ## First index in `[start, stop)` holding a newline, or -1.
  ##
  ## Delegates to libc `memchr`, so the whole line scan runs at the speed of
  ## libc's vectorised implementation rather than one byte per iteration.
  ##
  ## The bounds are clamped here rather than trusted to `memchr`, which takes an
  ## unsigned count and would happily read out of bounds given either a negative
  ## length or one that runs past the buffer. Converting the returned pointer
  ## back to an index is done on the integers' own terms: `cast[int]` on a
  ## pointer sign-extends on some targets, and the standard library's own
  ## `strimpl.find` guards the same subtraction with `-%` for that reason.
  let lo = max(0, start)
  let hi = min(stop, v.len)
  if lo >= hi or v.data == nil: return -1
  let found = c_memchr(v.at(lo), nlByte.cint, csize_t(hi - lo))
  if found.isNil: return -1
  lo + (cast[int](found) -% cast[int](v.at(lo)))

proc findByte*(v: ByteView, start, stop: int, needle: byte): int =
  ## First index in `[start, stop)` equal to `needle`, or -1. libc `memchr`.
  ##
  ## Used by the binary sniff, which is bounded to the first `DiffBinarySniff`
  ## bytes and so matters far less than the newline scan, but costs nothing to
  ## give it the same treatment. Clamped exactly as `findNewline` is.
  let lo = max(0, start)
  let hi = min(stop, v.len)
  if lo >= hi or v.data == nil: return -1
  let found = c_memchr(v.at(lo), needle.cint, csize_t(hi - lo))
  if found.isNil: return -1
  lo + (cast[int](found) -% cast[int](v.at(lo)))

proc equalPrefixScalar*(a, b: ByteView, aStart, bStart, limit: int): int =
  ## Length of the common prefix of the two regions, capped at `limit`.
  ##
  ## `limit` is the caller's guarantee that both regions are at least that
  ## long, which is why no per-byte bounds check is needed here. A zero
  ## `limit` returns 0, and an empty region matches any other empty region.
  var i = 0
  while i < limit and a[aStart + i] == b[bStart + i]:
    inc i
  i

proc equalSuffixScalar*(a, b: ByteView, aStart, bStart, limit: int): int =
  ## Length of the common suffix of the two regions, capped at `limit`.
  ##
  ## The caller passes the bytes still available after the prefix it already
  ## trimmed, which is what keeps the two trimmed regions from overlapping.
  ## Walking backwards from that shared limit makes the result independent of
  ## where each region starts.
  var i = 0
  while i < limit and a[aStart + limit - 1 - i] == b[bStart + limit - 1 - i]:
    inc i
  i

proc equalRange*(a: ByteView, aStart: int, b: ByteView, bStart: int,
                 length: int): bool =
  ## Whether two equal-length byte regions are identical.
  ##
  ## A zero length is a match. A negative length, or a region reaching past
  ## its view, is a non-match rather than a crash: the line index is trusted
  ## internally, but this proc is also public, so it defends itself.
  if length == 0: return true
  if length < 0: return false
  if aStart < 0 or bStart < 0: return false
  if a.len - aStart < length or b.len - bStart < length: return false
  equalMem(a.at(aStart), b.at(bStart), length)

proc endsWithNewline*(v: ByteView): bool =
  ## Whether the buffer's last byte is a line terminator. An empty buffer
  ## holds no line and therefore has no terminator.
  v.len > 0 and v[v.len - 1] == nlByte

proc lineContent*(v: ByteView, byteStart, contentLen: int): string =
  ## Copy one line's content out of a view as a `string`.
  ##
  ## Only for keys that must outlive the borrow, namely the patience and
  ## histogram anchor tables. Comparing lines never goes through here, since
  ## that is the one allocation this design is built to avoid.
  if contentLen <= 0: return ""
  result = newString(contentLen)
  copyMem(addr result[0], v.at(byteStart), contentLen)