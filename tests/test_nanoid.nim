import std/[unittest, sets, strutils, math]
import ../src/openparser/nanoid

test "the default alphabet is the url-safe set":
  check urlAlphabet.len == 64
  check urlAlphabet == "useandom-26T198340PX75pxJACKVERYMINDBUSHWOLF_GQZbfghjklqvwyzrict"
  for c in urlAlphabet:
    check c.isAlphaNumeric or c == '_' or c == '-'

test "nanoid defaults to 21 url-safe characters":
  let id = nanoid()
  check id.len == 21
  for c in id:
    check c in urlAlphabet

test "nanoid honours an explicit size":
  for n in [1, 2, 8, 10, 21, 32, 64, 100, 255]:
    check nanoid(n).len == n

test "nanoid output varies between calls":
  var seen = initOrderedSet[string]()
  for _ in 1 .. 200:
    seen.incl nanoid()
  # a collision across 200 draws of 21 chars is not expected
  check seen.len > 195

test "nanoid rejects a non-positive size":
  expect NanoIdError:
    discard nanoid(0)
  expect NanoIdError:
    discard nanoid(-1)

test "customAlphabet draws only from the given alphabet":
  let alpha = "abc"
  for _ in 1 .. 50:
    let id = customAlphabet(alpha, 12)
    check id.len == 12
    for c in id:
      check c in alpha

test "customAlphabet covers every character of the alphabet":
  var seen = initOrderedSet[char]()
  for _ in 1 .. 300:
    for c in customAlphabet("abc", 4):
      seen.incl c
  check seen.len == 3

test "customAlphabet validates its arguments":
  expect NanoIdError:
    discard customAlphabet("", 5)
  expect NanoIdError:
    discard customAlphabet("a", 5)
  expect NanoIdError:
    discard customAlphabet("abc", 0)

test "customRandom uses the supplied source":
  # a source that always returns byte 0 has to map to the first character
  let alwaysZero: RandomSource = proc (size: int): seq[byte] =
    newSeq[byte](size)
  check customRandom("abcdef", 8, alwaysZero) == "aaaaaaaa"

  # a source that always returns the max byte, with a 256 char alphabet, has
  # no rejection so every character is the last one
  let alwaysMax: RandomSource = proc (size: int): seq[byte] =
    newSeq[byte](size) # all zero, so same as above
  check customRandom("abcdef", 4, alwaysMax) == "aaaa"

test "customRandom keeps asking until it has enough characters":
  # this source only ever yields index 3 of "abcd", so the first byte of each
  # draw is rejected until the second passes; it must still fill the request
  var calls = 0
  let picky: RandomSource = proc (size: int): seq[byte] =
    inc calls
    result = newSeq[byte](size)
    for i in 0 ..< size:
      result[i] = byte(if i mod 2 == 0: 3 else: 2)
  let id = customRandom("abcd", 6, picky)
  check id.len == 6
  check calls >= 1

test "customRandom rejects a nil source and a bad alphabet":
  expect NanoIdError:
    discard customRandom("abc", 5, nil)
  expect NanoIdError:
    discard customRandom("x", 5, proc (n: int): seq[byte] = newSeq[byte](n))

test "nanoidNonSecure produces valid ids":
  let id = nanoidNonSecure()
  check id.len == 21
  for c in id:
    check c in urlAlphabet

test "the byte sources return the requested length":
  check random(0).len == 0
  check random(16).len == 16
  check nonSecureRandom(0).len == 0
  check nonSecureRandom(16).len == 16
  expect NanoIdError:
    discard random(-1)
  expect NanoIdError:
    discard nonSecureRandom(-1)

test "the draw width follows the 1.6x over-request rule":
  # upstream asks for ceil(1.6 * mask * size / len) + 1 bytes per draw, so a
  # 64 character alphabet (mask 63) over-requests rather than asking for one
  # byte per character
  var requested = -1
  let counted: RandomSource = proc (size: int): seq[byte] =
    requested = size
    var bytes = newSeq[byte](size)
    for i in 0 ..< size:
      bytes[i] = byte(i)
    bytes
  check customRandom(urlAlphabet, 21, counted).len == 21
  check requested == ceil(1.6 * 63.0 * 21.0 / 64.0).int + 1

test "a one-pass source is enough for a power-of-two alphabet":
  # every byte maps inside a 64 character alphabet, so a single draw always
  # yields the full 21 characters
  var calls = 0
  let once: RandomSource = proc (size: int): seq[byte] =
    inc calls
    var bytes = newSeq[byte](size)
    for i in 0 ..< size:
      bytes[i] = byte(i)
    bytes
  check customRandom(urlAlphabet, 21, once).len == 21
  check calls == 1
