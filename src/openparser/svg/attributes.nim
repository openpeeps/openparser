# A collection of tiny parsers and dumpers
#
# (c) 2026 George Lemon | MIT License

import std/[tables, options, strutils, math]
import ./types
import ./ast
import ../colors

proc parsePoints*(s: string): seq[tuple[x,y: float]] =
  result = @[]
  let t = s.strip()
  if t.len == 0: return
  # split by whitespace and commas
  var nums: seq[float] = @[]
  var cur = ""
  for ch in t:
    if ch in {' ', '\t', '\n', '\r', ','}:
      if cur.strip().len > 0:
        try: nums.add(parseFloat(cur.strip())) except: discard
        cur = ""
    else:
      cur.add(ch)
  if cur.strip().len > 0:
    try: nums.add(parseFloat(cur.strip())) except: discard
  var i = 0
  while i+1 < nums.len:
    result.add((nums[i], nums[i+1]))
    i += 2

proc pointsToString*(pts: seq[tuple[x,y: float]], minify: bool=false): string =
  var parts: seq[string] = @[]
  for p in pts:
    let sx = if abs(p.x - round(p.x)) < 1e-9: $int(round(p.x)) else: formatFloat(p.x, ffDecimal, 6).strip(chars={'0'}, trailing=true).strip(chars={'.'}, trailing=true)
    let sy = if abs(p.y - round(p.y)) < 1e-9: $int(round(p.y)) else: formatFloat(p.y, ffDecimal, 6).strip(chars={'0'}, trailing=true).strip(chars={'.'}, trailing=true)
    parts.add(sx & "," & sy)
  if minify: parts.join(" ") else: parts.join(" ")

proc fillCommonAttrs*(node: SvgNode, policyStrict: bool = false) =
  # parse common presentation attrs from attrsRaw
  template getOpt(name: string): Option[string] =
    if node.attrsRaw.hasKey(name): some(node.attrsRaw[name]) else: none(string)
  # id
  node.common.id = getOpt("id")
  node.common.className = getOpt("class")
  if node.attrsRaw.hasKey("style"):
    node.common.styleRaw = some(node.attrsRaw["style"])
    # parsed in parser via css_bridge to fill styleDecls
  if node.attrsRaw.hasKey("transform"):
    let t = node.attrsRaw["transform"]
    try:
      node.common.transform = some(parseSvgTransform(t))
    except:
      if policyStrict: raise
  if node.attrsRaw.hasKey("opacity"):
    try: node.common.opacity = some(parseFloat(node.attrsRaw["opacity"])) except: discard
  if node.attrsRaw.hasKey("fill"):
    let raw = node.attrsRaw["fill"]
    node.common.fillRaw = some(raw)
    if raw.toLowerAscii() notin ["none", "currentcolor"]:
      try:
        node.common.fill = some(parseColor(raw))
      except:
        if policyStrict: raise
  if node.attrsRaw.hasKey("stroke"):
    let raw = node.attrsRaw["stroke"]
    node.common.strokeRaw = some(raw)
    if raw.toLowerAscii() notin ["none", "currentcolor"]:
      try:
        node.common.stroke = some(parseColor(raw))
      except:
        if policyStrict: raise
  if node.attrsRaw.hasKey("stroke-width"):
    try: node.common.strokeWidth = some(parseSvgLength(node.attrsRaw["stroke-width"])) except: discard
  if node.attrsRaw.hasKey("stroke-opacity"):
    try: node.common.strokeOpacity = some(parseFloat(node.attrsRaw["stroke-opacity"])) except: discard
  if node.attrsRaw.hasKey("fill-opacity"):
    try: node.common.fillOpacity = some(parseFloat(node.attrsRaw["fill-opacity"])) except: discard
  if node.attrsRaw.hasKey("display"):
    node.common.display = some(node.attrsRaw["display"])
  if node.attrsRaw.hasKey("visibility"):
    node.common.visibility = some(node.attrsRaw["visibility"])

proc fillGeometryAttrs*(node: SvgNode) =
  template getLen(name: string, field: untyped) =
    if node.attrsRaw.hasKey(name):
      try: field = some(parseSvgLength(node.attrsRaw[name])) except: discard
  template getStr(name: string, field: untyped) =
    if node.attrsRaw.hasKey(name):
      field = some(node.attrsRaw[name])
  # svg root
  if node.tag == svgSvg:
    getLen("width", node.width)
    getLen("height", node.height)
    if node.attrsRaw.hasKey("viewBox"):
      try: node.viewBox = some(parseSvgViewBox(node.attrsRaw["viewBox"])) except: discard
    if node.attrsRaw.hasKey("preserveAspectRatio"):
      try: node.preserveAspectRatio = some(parsePreserveAspectRatio(node.attrsRaw["preserveAspectRatio"])) except: discard
    getStr("xmlns", node.xmlns)
  # rect
  if node.tag in {svgRect, svgImage, svgForeignObject}:
    getLen("x", node.x)
    getLen("y", node.y)
    getLen("width", node.width)
    getLen("height", node.height)
  if node.tag == svgRect:
    getLen("rx", node.rx)
    getLen("ry", node.ry)
  if node.tag in {svgCircle, svgEllipse, svgRadialGradient}:
    getLen("cx", node.cx)
    getLen("cy", node.cy)
  if node.tag == svgCircle:
    getLen("r", node.r)
  if node.tag == svgEllipse:
    getLen("rx", node.rx)
    getLen("ry", node.ry)
  if node.tag == svgLine:
    getLen("x1", node.x1)
    getLen("y1", node.y1)
    getLen("x2", node.x2)
    getLen("y2", node.y2)
  if node.tag in {svgPolyline, svgPolygon}:
    getStr("points", node.points)
    if node.points.isSome:
      node.pointsParsed = parsePoints(node.points.get())
  if node.tag == svgPath:
    getStr("d", node.d)
    if node.d.isSome:
      # will be parsed in parser via path
      discard
  if node.tag in {svgText, svgTspan, svgTextPath}:
    getLen("dx", node.dx)
    getLen("dy", node.dy)
    getLen("x", node.x)
    getLen("y", node.y)
  if node.tag in {svgImage, svgUse}:
    # href can be href or xlink:href
    if node.attrsRaw.hasKey("href"):
      node.href = some(node.attrsRaw["href"])
    elif node.attrsRaw.hasKey("xlink:href"):
      node.href = some(node.attrsRaw["xlink:href"])
  # gradient
  if node.tag in {svgLinearGradient, svgRadialGradient, svgPattern}:
    getStr("gradientUnits", node.gradientUnits)
  if node.tag == svgStop:
    getStr("offset", node.offset)
    if node.attrsRaw.hasKey("stop-color"):
      try: node.stopColor = some(parseColor(node.attrsRaw["stop-color"])) except: discard
    if node.attrsRaw.hasKey("stop-opacity"):
      try: node.stopOpacity = some(parseFloat(node.attrsRaw["stop-opacity"])) except: discard
