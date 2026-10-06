import std/[unittest, strutils]
import ../src/openparser/fuzzy

# Score formula (pinned here, mirrors fuzzy.nim consts):
# exact hit 16, folded hit 8, consecutive +12, word start +10,
# gap -3/byte, leading -1/byte, total / span of the match (the
# distance from the first matched byte to the last).

suite "Fuzzy: scoring":
  test "exact consecutive match":
    # a@0: 16 + 10 (word start) = 26
    # b@1: 16 + 12 (consecutive) = 28
    # c@2: 16 + 12 = 28  → 82 over a 3-byte span
    let r = fuzzyScore("abc", "abc")
    check r.matched
    check r.positions == @[0, 1, 2]
    check abs(r.score - 82.0 / 3.0) < 0.001

  test "consecutive beats gapped":
    let tight = fuzzyScore("abc", "abc")
    let loose = fuzzyScore("abc", "axbyc")
    check loose.matched
    check loose.positions == @[0, 2, 4]
    check tight.score > loose.score

  test "word start beats mid-word":
    let atStart = fuzzyScore("w", "x w")   # 16 - 2 + 10 = 24, span 1 → 24
    let midWord = fuzzyScore("w", "xw")    # 16 - 1 + 0 = 15, span 1 → 15
    check atStart.score > midWord.score

  test "case-exact beats folded":
    let exact = fuzzyScore("A", "A")       # 16 + 10 = 26
    let folded = fuzzyScore("A", "a")      # 8 + 10 = 18
    check exact.score > folded.score

  test "case-insensitive by default":
    check fuzzyScore("abc", "ABC").matched
    check fuzzyScore("ABC", "abc").matched

  test "caseSensitive rejects folded hits":
    let opts = FuzzyOptions(caseSensitive: true)
    check not fuzzyScore("A", "a", opts).matched
    check fuzzyScore("A", "A", opts).matched

  test "camel hump counts as word start":
    # 'U' in "parseURL" at pos 5: 16 - 5 + 10 = 21, span 1 → 21
    # 'U' in "parsexurl" at pos 5: 16 - 5 + 0 = 11, span 1 → 11
    let camel = fuzzyScore("U", "parseURL")
    let flat = fuzzyScore("U", "parsexurl")
    check camel.score > flat.score

  test "a tight match beats a scattered one in a longer candidate":
    ## Both candidates hold the query four times over. Normalizing by
    ## `candidate.len` let the short one's scattered match outrank the long
    ## one's contiguous run, which is the regression the span divisor fixes.
    let scattered = fuzzyScore("real", "Stream and listen to music online for free with SoundCloud")
    let contiguous = fuzzyScore("real", "Is \"man flu\" real, or am I just weak?")
    check scattered.matched
    check contiguous.matched
    # The tight match is four adjacent characters; the scattered one spans ten.
    check contiguous.positions[3] - contiguous.positions[0] == 3
    check scattered.positions[3] - scattered.positions[0] > 3
    check contiguous.score > scattered.score

  test "match position still counts, so an earlier hit wins":
    ## Span normalization removed length as a factor but must not flatten
    ## position: `FuzzyPenaltyLeading` is absolute, so identical matches
    ## compete on where they sit.
    let early = fuzzyScore("real", "real and other words here")
    let late = fuzzyScore("real", "quite a few other words before real")
    check early.score > late.score

  test "finds the tight match, not an earlier scattered one":
    ## The reported failure: `the heart` in `Reddit - The heart of the internet`
    ## used to take its `t` from `Reddit` and highlight nine scattered bytes,
    ## because a leftmost walk never revisits the byte it took first. The query
    ## sits there verbatim, so that is the alignment that has to win.
    let r = fuzzyScore("the heart", "Reddit - The heart of the internet")
    check r.matched
    check r.positions == @[9, 10, 11, 12, 13, 14, 15, 16, 17]
    # One contiguous run, which is what the caller merges into a single range.
    for i in 1 ..< r.positions.len:
      check r.positions[i] == r.positions[i - 1] + 1

  test "no match reported":
    check not fuzzyScore("z", "abc").matched
    check not fuzzyScore("", "abc").matched
    check not fuzzyScore("abc", "").matched
    check not fuzzyScore("abcd", "abc").matched

suite "Fuzzy: search and ranking":
  const words = @["application", "apple", "pineapple", "app", "append",
                  "banana", "grape"]

  test "best first, ties by text":
    let res = fuzzySearch("app", words)
    check res.len > 0
    check res[0].text == "app"
    for i in 1 ..< res.len:
      check res[i - 1].score >= res[i].score

  test "limit keeps top-N":
    let res = fuzzySearch("app", words, FuzzyOptions(limit: 2))
    check res.len == 2
    check res[0].text == "app"
    let full = fuzzySearch("app", words)
    check res[0].score == full[0].score
    check res[1].score == full[1].score

  test "minScore filters weak matches":
    let all = fuzzySearch("app", words)
    check all.len > 1
    # Thresholded between the weakest and the strongest match rather than at a
    # literal: this test is about ranking and about minScore being honoured, not
    # about where the current formula happens to put its scores.
    let midpoint = (all[all.len - 1].score + all[0].score) / 2.0'f32
    let strict = fuzzySearch("app", words, FuzzyOptions(minScore: midpoint))
    check strict.len > 0
    check strict.len < all.len
    for m in strict:
      check m.score >= midpoint

  test "empty query or haystack":
    check fuzzySearch("", words).len == 0
    check fuzzySearch("app", newSeq[string]()).len == 0

  test "positions reproduce the subsequence":
    let res = fuzzySearch("apl", @["pineapple"])
    check res.len == 1
    var rebuilt = ""
    for p in res[0].positions:
      rebuilt.add(res[0].text[p])
    check rebuilt.toLowerAscii() == "apl"

suite "Fuzzy: kernel parity scalar vs SIMD":
  const pairs = [
    ("a", "a"), ("a", "A"), ("z", "abcxyz"), ("q", "nope"),
    ("ab", "0123456789abcdefab"),          # 16-byte boundary cross
    ("ab", "0123456789abcdef_ab"),         # gap across lanes
    ("hello", "well, hello there, hello again and hello once more!"),
    ("Aa", "aAaAaA"), ("x", ""), ("longquerystring", "short"),
  ]

  test "findChar kernels agree":
    for (q, t) in pairs:
      for start in [0, 1, 3, 7, 15, 16, 17, 31, 33]:
        let want = findCharScalar(t, start, q[0], q[0], false)
        when hasSse2:
          check findCharSse2(t, start, q[0], q[0], false) == want
        when hasAvx2:
          check findCharAvx2(t, start, q[0], q[0], false) == want
        when hasNeon:
          check findCharNeon(t, start, q[0], q[0], false) == want

  test "folded findChar kernels agree":
    for (q, t) in [("a", "AbC"), ("Z", "xyz"), ("m", "aMmAmM exhibitions")]:
      let lo = if q[0] in 'A'..'Z': chr(ord(q[0]) + 32) else: q[0]
      let hi = if lo in 'a'..'z': chr(ord(lo) - 32) else: lo
      let want = findCharScalar(t, 0, lo, hi, true)
      when hasSse2:
        check findCharSse2(t, 0, lo, hi, true) == want
      when hasAvx2:
        check findCharAvx2(t, 0, lo, hi, true) == want
      when hasNeon:
        check findCharNeon(t, 0, lo, hi, true) == want
