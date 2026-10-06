# A collection of tiny parsers and dumpers
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/openparser

## End to end tour of the openparser fuzzy module: rank a word list,
## highlight match positions, then benchmark the SIMD lanes against
## the scalar fallback.

import std/[monotimes, strutils, times]
import ../src/openparser/fuzzy

const words = @["application", "apple", "pineapple", "app", "append",
  "banana", "grape", "Apply", "happy", "snapple", "captcha", "dapple"]

proc highlight(text: string, positions: seq[int]): string =
  ## Uppercase matched bytes so the alignment is visible.
  result = text
  for p in positions:
    result[p] = result[p].toUpperAscii()

block demo:
  echo "query: app"
  for m in fuzzySearch("app", words, FuzzyOptions(limit: 5)):
    echo "  ", highlight(m.text, m.positions),
      "  score=", m.score.formatFloat(ffDecimal, 2)
  echo "query: apl (top 3)"
  for m in fuzzySearch("apl", words, FuzzyOptions(limit: 3)):
    echo "  ", highlight(m.text, m.positions),
      "  score=", m.score.formatFloat(ffDecimal, 2)

block bench:
  # Long haystack entry so the vector lanes have room to run.
  var long = newStringOfCap(4096)
  for i in 0 ..< 256: long.add("the quick brown fox jumps over the lazy dog. ")
  let query = "qbf"
  const iters = 2_000
  template timed(label: string, body: untyped) =
    let t0 = getMonoTime()
    for _ in 0 ..< iters: body
    let dt = (getMonoTime() - t0).inNanoseconds
    echo "  ", label, ": ", dt div iters, " ns/iter"
  timed "fuzzyScore (best lane)":
    discard fuzzyScore(query, long)
  # 'Z' never occurs: forces a full 11 KiB scan, where lanes shine.
  timed "findCharScalar":
    discard findCharScalar(long, 0, 'Z', 'Z', false)
  when hasSse2:
    timed "findCharSse2 ":
      discard findCharSse2(long, 0, 'Z', 'Z', false)
  when hasAvx2:
    timed "findCharAvx2 ":
      discard findCharAvx2(long, 0, 'Z', 'Z', false)
  when hasNeon:
    timed "findCharNeon ":
      discard findCharNeon(long, 0, 'Z', 'Z', false)
