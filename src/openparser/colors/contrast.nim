# A collection of tiny parsers and dumpers
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/openparser
import std/[math, strutils]
import ./types
import ./constants

proc luminance*(c: Color): float =
  proc lin(v: float): float =
    if v <= 0.03928: v / 12.92
    else: pow((v + 0.055)/1.055, 2.4)
  let r = lin(clamp01(c.r))
  let g = lin(clamp01(c.g))
  let b = lin(clamp01(c.b))
  0.2126*r + 0.7152*g + 0.0722*b

proc contrastRatio*(a, b: Color): float =
  let la = luminance(a)
  let lb = luminance(b)
  let l1 = max(la, lb)
  let l2 = min(la, lb)
  (l1 + 0.05) / (l2 + 0.05)

proc isReadable*(a, b: Color, level: string = "AA", size: string = "small"): bool =
  let ratio = contrastRatio(a,b)
  let lvl = level.toLowerAscii
  let sz = size.toLowerAscii
  if lvl == "aaa":
    if sz == "large": ratio >= 4.5
    else: ratio >= 7.0
  else: # AA
    if sz == "large": ratio >= 3.0
    else: ratio >= 4.5

proc readability*(a, b: Color): tuple[ratio: float, level: string] =
  let r = contrastRatio(a,b)
  var lvl = "fail"
  if r >= 7.0: lvl = "AAA"
  elif r >= 4.5: lvl = "AA"
  elif r >= 3.0: lvl = "AA large"
  (r, lvl)

proc isLight*(c: Color): bool =
  luminance(c) > 0.5

proc isDark*(c: Color): bool =
  not c.isLight()

proc mostReadable*(base: Color, candidates: seq[Color]): Color =
  if candidates.len == 0:
    return base
  var best = candidates[0]
  var bestRatio = contrastRatio(base, best)
  for i in 1..<candidates.len:
    let r = contrastRatio(base, candidates[i])
    if r > bestRatio:
      bestRatio = r
      best = candidates[i]
  best
