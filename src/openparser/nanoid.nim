# A collection of tiny parsers and dumpers
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/openparser

## A tiny, URL-friendly, collision-resistant id generator.
##
## Port of https://github.com/ai/nanoid. The default alphabet is the same
## 64 character URL-safe set and the default size is 21, so `nanoid` output
## matches upstream byte for byte in distribution.
##
## The drawing scheme is also the same, which is what keeps the output
## unbiased: a byte is masked down to the smallest power-of-two-minus-one that
## covers the alphabet, and a value past the end of the alphabet is rejected
## rather than folded back in.
##
## The output is only as random as the source. `nanoid` and `customAlphabet`
## draw from the OS CSPRNG; `customRandom` takes the generator as a callback,
## and `nanoidNonSecure` swaps in a non-cryptographic PRNG for callers who do
## not need unguessable ids.

import std/[sysrand, math]
import std/random as stdrandom

type
  NanoIdError* = object of ValueError

  RandomSource* = proc (size: int): seq[byte]
    ## Produces `size` random bytes for `customRandom` to draw from.

const
  ## The default alphabet, `A-Za-z0-9_-`. 64 characters, so its size is a
  ## power of two and the mask rejects nothing.
  urlAlphabet* = "useandom-26T198340PX75pxJACKVERYMINDBUSHWOLF_GQZbfghjklqvwyzrict"

  ## The size used when a caller does not ask for one.
  defaultSize* = 21

# Helpers ──

proc alphabetMask(size: int): int =
  ## The smallest power-of-two-minus-one that covers `size`, which is what
  ## makes `byte and idxMask` uniform over the whole mask.
  var p = 1
  while p < size:
    p = p shl 1
  result = p - 1

proc checkAlphabet(alphabet: string, size: int) =
  if alphabet.len < 2 or alphabet.len > 255:
    raise newException(NanoIdError,
      "alphabet must contain between 2 and 255 characters, got " &
      $alphabet.len)
  if size <= 0:
    raise newException(NanoIdError,
      "size must be greater than zero, got " & $size)

proc drawFrom(alphabet: string, size: int, bytes: seq[byte]): string =
  ## Walk `bytes`, keeping every index that falls inside the alphabet. The
  ## caller decides how many bytes to ask for, so a short draw may return short.
  let idxMask = alphabetMask(alphabet.len)
  var chars = newString(size)
  var written = 0
  for b in bytes:
    if written >= size: break
    let idx = int(b) and idxMask
    if idx < alphabet.len:
      chars[written] = alphabet[idx]
      inc written
  result = chars[0 ..< written]

# Public API ──

proc random*(size: int): seq[byte] =
  ## `size` random bytes from the system CSPRNG.
  if size < 0:
    raise newException(NanoIdError, "size must not be negative")
  result = newSeq[byte](size)
  if size > 0:
    if not urandom(result.toOpenArray(0, result.high)):
      raise newException(NanoIdError, "could not read random bytes")

proc nonSecureRandom*(size: int): seq[byte] =
  ## `size` random bytes from the non-cryptographic PRNG. Not safe for ids that
  ## must be unguessable.
  if size < 0:
    raise newException(NanoIdError, "size must not be negative")
  result = newSeq[byte](size)
  if size > 0:
    # the global PRNG, seeded from the clock by std/random at startup
    for i in 0 ..< size:
      result[i] = byte(stdrandom.rand(256))

proc customRandom*(alphabet: string, size = defaultSize,
                   getRandom: RandomSource): string =
  ## Generate an id of `size` characters from `alphabet`, taking bytes from
  ## `getRandom`. Rejection sampling means the number of bytes drawn is not
  ## fixed, so this keeps asking until it has enough characters.
  checkAlphabet(alphabet, size)
  if getRandom == nil:
    raise newException(NanoIdError, "getRandom must not be nil")

  let
    idxMask = alphabetMask(alphabet.len)
    # 1.6x the expected need, plus one, as upstream does
    step = int(ceil(1.6 * float(idxMask) * float(size) /
                    float(alphabet.len))) + 1
  var chars = ""
  while chars.len < size:
    chars.add drawFrom(alphabet, size, getRandom(step))
  result = chars[0 ..< size]

proc customAlphabet*(alphabet: string, size = defaultSize): string =
  ## Generate an id of `size` characters drawn from `alphabet`, using the
  ## system CSPRNG.
  customRandom(alphabet, size, random)

proc nanoid*(size = defaultSize): string =
  ## Generate a URL-friendly id of `size` characters.
  customRandom(urlAlphabet, size, random)

proc nanoidNonSecure*(size = defaultSize): string =
  ## As `nanoid`, but drawing from the non-cryptographic PRNG. Suitable for
  ## throwaway ids such as DOM keys or log correlation ids.
  customRandom(urlAlphabet, size, nonSecureRandom)
