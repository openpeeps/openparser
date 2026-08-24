# A collection of tiny parsers and dumpers
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/openparser

## Minimal SVG renderer for any QR family matrix in this package.
## Dark modules become one merged path so the output stays small even
## for high versions.
##
## Unstable API. Prefer importing `openparser/qr` instead of this module.

import ./common

proc toSvg*(m: QrMatrix, scale = 8, border = 4, dark = "#000000",
            light = "#ffffff"): string =
  ## Renders `m` as a standalone SVG image. `scale` is the pixel size of
  ## one module and `border` the quiet zone in modules.
  if scale < 1:
    raise newException(ValueError, "scale must be positive")
  if border < 0:
    raise newException(ValueError, "border must not be negative")
  let side = (m.width + 2 * border) * scale
  result = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"" &
    $side & "\" height=\"" & $side &
    "\" viewBox=\"0 0 " & $side & " " & $side & "\">\n"
  result.add "<rect width=\"100%\" height=\"100%\" fill=\"" & light & "\"/>\n"
  result.add "<path d=\""
  for y in 0 ..< m.height:
    for x in 0 ..< m.width:
      if m[x, y]:
        let px = (x + border) * scale
        let py = (y + border) * scale
        result.add "M" & $px & " " & $py & "h" & $scale & "v" & $scale &
          "h-" & $scale & "z"
  result.add "\" fill=\"" & dark & "\"/>\n</svg>\n"

proc toTerminal*(m: QrMatrix, border = 2): string =
  ## Half block rendering: two module rows share one character line
  ## (`█`, upper half `▀`, lower half `▄` or a blank), which keeps the
  ## symbol square in a terminal where cells are twice as tall as wide.
  ## Dark modules print as blanks and light ones as blocks, which reads
  ## correctly on the dark background most terminals use. `border`
  ## widens the quiet zone in modules; two is a good minimum for
  ## scanning straight off the screen.
  if border < 0:
    raise newException(ValueError, "border must not be negative")
  let w = m.width + border * 2
  let h = m.height + border * 2
  template cell(x, y: int): bool =
    let mx = x - border
    let my = y - border
    mx >= 0 and my >= 0 and mx < m.width and my < m.height and
      m.modules[my * m.width + mx]
  result = newStringOfCap((h div 2 + 1) * (w + 1))
  var y = 0
  while y < h:
    if y > 0:
      result.add '\n'
    for x in 0 ..< w:
      let top = cell(x, y)
      let bottom = y + 1 < h and cell(x, y + 1)
      # dark halves print as blanks so the code reads correctly on the
      # dark background terminals usually have
      result.add case (top.int shl 1) or bottom.int
        of 0b11: " "
        of 0b10: "▄"
        of 0b01: "▀"
        else: "█"

    inc y, 2
