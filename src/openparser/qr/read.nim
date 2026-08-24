# A collection of tiny parsers and dumpers
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/openparser

## Image-side helpers shared by the QR readers: adaptive binarization of
## grayscale pixels and finder-style pattern location with affine grid
## sampling. Family agnostic; the symbology modules supply their own
## finder geometry.
##
## Unstable API. Prefer importing `openparser/qr` instead of this module.

import std/[math, algorithm]
import ./common

export common

type
  Point2* = tuple[x, y: float64]
    ## Sub-pixel image coordinate.

  FinderCandidate* = object
    ## A located finder-like ring with its estimated module pitch.
    center*: Point2
    moduleSize*: float64

proc otsuThreshold*(img: GrayImage): int =
  ## Global Otsu threshold over the pixel histogram.
  var hist: array[256, int]
  for p in img.pixels:
    inc hist[p]
  let total = img.pixels.len
  var sumAll = 0
  for i in 0 ..< 256:
    sumAll += i * hist[i]
  var sumB = 0
  var wB = 0
  var best = 0
  var bestVar = -1.0
  var bestLo = 0
  var bestHi = 0
  for t in 0 ..< 256:
    wB += hist[t]
    if wB == 0: continue
    let wF = total - wB
    if wF == 0: break
    sumB += t * hist[t]
    let mB = sumB.float / wB.float
    let mF = (sumAll - sumB).float / wF.float
    let between = wB.float * wF.float * (mB - mF) * (mB - mF)
    if between > bestVar:
      bestVar = between
      bestLo = t
      bestHi = t
    elif between == bestVar and t == bestHi + 1:
      # extend the plateau of maximal variance (empty histogram gap)
      bestHi = t
  # callers test `pixel < threshold`; sit in the middle of the winning
  # plateau so clean bimodal renders get a sane split point
  result = min((bestLo + bestHi) div 2 + 1, 255)

func integralImage(img: GrayImage): seq[int] =
  ## Row-major integral image with a leading zero row/column,
  ## size (width+1)*(height+1).
  let w = img.width
  let h = img.height
  result = newSeq[int]((w + 1) * (h + 1))
  for y in 0 ..< h:
    var rowSum = 0
    for x in 0 ..< w:
      rowSum += img.pixels[y * w + x].int
      result[(y + 1) * (w + 1) + (x + 1)] =
        result[y * (w + 1) + (x + 1)] + rowSum

proc binarizeAdaptive*(img: GrayImage, windowDiv = 16, bias = 4): QrMatrix =
  ## Hybrid binarization: a pixel is dark when it sits below the local
  ## mean (handles uneven lighting) or below the global Otsu threshold
  ## (keeps large solid areas from collapsing onto their own mean).
  let w = img.width
  let h = img.height
  let ii = integralImage(img)
  let otsu = uint8(otsuThreshold(img))
  var win = max(w, h) div windowDiv
  win = max(win or 1, 9)
  let half = win div 2
  result = initQrMatrix(w, h)
  for y in 0 ..< h:
    let y0 = max(0, y - half)
    let y1 = min(h - 1, y + half)
    for x in 0 ..< w:
      let x0 = max(0, x - half)
      let x1 = min(w - 1, x + half)
      let area = (x1 - x0 + 1) * (y1 - y0 + 1)
      let s = ii[(y1 + 1) * (w + 1) + (x1 + 1)] -
              ii[y0 * (w + 1) + (x1 + 1)] -
              ii[(y1 + 1) * (w + 1) + x0] +
              ii[y0 * (w + 1) + x0]
      let mean = s.float / area.float
      let p = img.pixels[y * w + x].float
      result[x, y] = p < mean - bias.float or p < otsu.float

proc binarizeOtsu*(img: GrayImage): QrMatrix =
  ## Global Otsu binarization; fast and ideal for clean renders.
  let t = otsuThreshold(img)
  result = initQrMatrix(img.width, img.height)
  for i, p in img.pixels:
    result.modules[i] = p < uint8(t)

# Finder run-length detection -----------------------------------------------

func checkRatio(runs: array[5, int]): bool =
  ## True when the last five runs look like the 1:1:3:1:1 finder rings.
  let total = runs[0] + runs[1] + runs[2] + runs[3] + runs[4]
  if total < 7:
    return false
  let unit = total.float / 7.0
  let tolerance = unit / 1.75
  for i in 0 ..< 5:
    let want = (if i == 2: 3.0 else: 1.0) * unit
    if abs(runs[i].float - want) > tolerance:
      return false
  true

proc horizontalCandidates*(m: QrMatrix): seq[FinderCandidate] =
  ## Scans every row for light-dark-light-dark-light run sequences whose
  ## lengths match the 1:1:3:1:1 finder profile.
  result = @[]
  for y in 0 ..< m.height:
    var runs: array[5, int]
    var filled = 0
    var curDark = m[0, y]
    var curLen = 1
    template closeRun(endX: int) =
      for k in 0 ..< 4:
        runs[k] = runs[k + 1]
      runs[4] = curLen
      if filled < 5: inc filled
      # a centre-row crossing ends on the dark outer ring of the finder
      if filled == 5 and curDark and checkRatio(runs):
        let total = runs[0] + runs[1] + runs[2] + runs[3] + runs[4]
        # centre of the wide dark middle run
        let cx = endX.float - runs[4].float - runs[3].float -
                 runs[2].float / 2.0 + 0.5
        result.add FinderCandidate(
          center: (cx, y.float),
          moduleSize: total.float / 7.0)
    for x in 1 ..< m.width:
      let d = m[x, y]
      if d != curDark:
        closeRun(x - 1)
        curDark = d
        curLen = 1
      else:
        inc curLen
    closeRun(m.width - 1)

proc verticalVerify*(m: QrMatrix, c: FinderCandidate): FinderCandidate =
  ## Walks the full vertical 1:1:3:1:1 profile through the candidate
  ## centre and returns the refined candidate, or a zeroed one when the
  ## column does not match.
  let cx = c.center.x.int.clamp(0, m.width - 1)
  let cy = c.center.y.int.clamp(0, m.height - 1)
  let darkHere = m[cx, cy]
  let maxRun = int(c.moduleSize * 4.0)
  # dark centre band fragment around cy
  var upFrag = 0
  while cy - upFrag - 1 >= 0 and m[cx, cy - upFrag - 1] == darkHere:
    inc upFrag
  var downFrag = 0
  while cy + downFrag + 1 < m.height and m[cx, cy + downFrag + 1] == darkHere:
    inc downFrag
  let centerRun = upFrag + downFrag + 1
  if abs(centerRun.float - 3.0 * c.moduleSize) > c.moduleSize * 1.5:
    return FinderCandidate(center: (0.0, 0.0), moduleSize: 0.0)
  # light bands adjacent to the centre
  var lightUp = 0
  while lightUp < maxRun and cy - upFrag - 1 - lightUp >= 0 and
        m[cx, cy - upFrag - 1 - lightUp] != darkHere:
    inc lightUp
  var lightDown = 0
  while lightDown < maxRun and cy + downFrag + 1 + lightDown < m.height and
        m[cx, cy + downFrag + 1 + lightDown] != darkHere:
    inc lightDown
  # outer dark rings
  var darkTop = 0
  let topLightEnd = cy - upFrag - 1 - lightUp
  while darkTop < maxRun and topLightEnd - 1 - darkTop >= 0 and
        m[cx, topLightEnd - 1 - darkTop] == darkHere:
    inc darkTop
  var darkBottom = 0
  let botLightStart = cy + downFrag + 1 + lightDown
  while darkBottom < maxRun and botLightStart + 1 + darkBottom < m.height and
        m[cx, botLightStart + 1 + darkBottom] == darkHere:
    inc darkBottom
  let runs = [darkTop, lightUp, centerRun, lightDown, darkBottom]
  if not checkRatio(runs):
    return FinderCandidate(center: (0.0, 0.0), moduleSize: 0.0)
  let total = runs[0] + runs[1] + runs[2] + runs[3] + runs[4]
  let centerY = cy.float - upFrag.float + centerRun.float / 2.0
  result = FinderCandidate(
    center: (c.center.x, centerY),
    moduleSize: total.float / 7.0)

proc dedupe*(cands: seq[FinderCandidate]): seq[FinderCandidate] =
  ## Merges candidates closer than two module pitches into the largest.
  result = @[]
  for c in cands.sortedByIt(-it.moduleSize):
    var merged = false
    for r in result.mitems:
      let dx = r.center.x - c.center.x
      let dy = r.center.y - c.center.y
      if dx * dx + dy * dy < (2.0 * c.moduleSize) * (2.0 * c.moduleSize):
        merged = true
        break
    if not merged:
      result.add c

type AffineMap = object
  ## Maps symbol-space module coordinates to image coordinates.
  ax, bx, cx: float64
  ay, by, cy: float64

proc applyAffine(a: AffineMap, u, v: float64): Point2 =
  (a.ax * u + a.bx * v + a.cx, a.ay * u + a.by * v + a.cy)

proc affineFromFinders*(topLeft: Point2; topRight: Point2; bottomLeft: Point2;
                       size: int): AffineMap =
  ## Solves the exact affine transform mapping the three finder centres
  ## (3.5, 3.5), (size-3.5, 3.5), (3.5, size-3.5) to their image points.
  let u1 = 3.5
  let u2 = size.float - 3.5
  # x' = ax*u + bx*v + cx ; solve from three point pairs
  let du = u2 - u1
  result.ax = (topRight.x - topLeft.x) / du
  result.ay = (topRight.y - topLeft.y) / du
  result.bx = (bottomLeft.x - topLeft.x) / du
  result.by = (bottomLeft.y - topLeft.y) / du
  result.cx = topLeft.x - result.ax * u1 - result.bx * u1
  result.cy = topLeft.y - result.ay * u1 - result.by * u1

proc sampleSymbol*(img: GrayImage, a: AffineMap, size: int,
                   threshold: float): QrMatrix =
  ## Samples every module centre through the affine map using bilinear
  ## interpolation against `threshold`.
  result = initSquareQrMatrix(size)
  for v in 0 ..< size:
    for u in 0 ..< size:
      let p = applyAffine(a, u.float + 0.5, v.float + 0.5)
      let x0 = floor(p.x).int
      let y0 = floor(p.y).int
      let fx = p.x - x0.float
      let fy = p.y - y0.float
      proc px(xx, yy: int): float =
        if xx < 0 or yy < 0 or xx >= img.width or yy >= img.height:
          return 255.0
        img.pixels[yy * img.width + xx].float
      let top = px(x0, y0) * (1 - fx) + px(x0 + 1, y0) * fx
      let bot = px(x0, y0 + 1) * (1 - fx) + px(x0 + 1, y0 + 1) * fx
      result[u, v] = top * (1 - fy) + bot * fy < threshold
