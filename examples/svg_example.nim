# A collection of tiny parsers and dumpers
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/openparser

## SVG end to end tour: parse, inspect typed DOM, mutate, and serialize.

import std/[options, strutils, tables, sequtils]
import ../src/openparser/svg
import ../src/openparser/colors

proc sep(title: string) =
  echo "\n=== ", title, " ==="

block parse_string:
  sep("parse from string")
  let src = """
    <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24">
      <rect x="2" y="2" width="20" height="20" rx="4" fill="oklch(0.7 0.15 180)" stroke="none"/>
      <path d="M12 2 L22 22 L2 22 Z" fill="red"/>
      <g transform="translate(10) rotate(45)">
        <circle cx="12" cy="12" r="10" fill="none" stroke="currentColor" stroke-width="2px"/>
      </g>
    </svg>
  """
  let doc = parseSvg(src)
  echo "root tag   ", doc.root.tag, " (", tagName(doc.root), ")"
  echo "width      ", $doc.root.width.get().value, " ", $doc.root.width.get().unit
  echo "viewBox    ", viewBoxToString(doc.root.viewBox.get())
  # children includes whitespace text nodes; filter to elements
  let elems = doc.root.children.filterIt(it.kind == svgElement)
  echo "children   ", doc.root.children.len, " (elements ", elems.len, ")"

  let rect = doc.root.findChild(svgRect)
  echo "rect fill raw ", rect.attrsRaw.getOrDefault("fill")
  echo "rect fill Color ", rect.common.fill.get().toHex(), " ", rect.common.fill.get().toOklchString()
  echo "rect rx      ", rect.rx.get().value

  let path = doc.root.findChild(svgPath)
  echo "path d     ", path.d.get()
  echo "path segs  ", path.dSegs.len, " ", path.dSegs.mapIt($it.cmd & $it.args)
  echo "svgLength  ", parseSvgLength("50%").unit, " 50% -> ", svgLengthToString(parseSvgLength("50%"))

block typed_lengths_viewbox_transform:
  sep("typed helpers")
  echo parseSvgLength("100").value, " luNumber"
  echo parseSvgLength("24px").unit
  echo parseSvgLength("1.5em").unit
  let vb = parseSvgViewBox("0 0 100 100")
  echo "viewBox w ", vb.width, " h ", vb.height
  let pa = parsePreserveAspectRatio("xMidYMid meet")
  echo "preserveAspect ", pa.align, " ", pa.meetOrSlice
  let ts = parseSvgTransform("translate(10,10) scale(2) rotate(45)")
  echo "transforms ", ts.len, " -> ", transformsToString(ts)
  echo "points poly ", pointsToString(@[(x:0.0,y:0.0),(x:10.0,y:0.0),(x:5.0,y:10.0)])

block dom_traversal:
  sep("DOM traversal")
  let src = """<svg><g id="layer1"><circle cx="12" cy="12" r="10"/><rect x="0" y="0" width="5" height="5" fill="blue"/></g></svg>"""
  let doc = parseSvg(src)
  let g = doc.root.findChild(svgG)
  echo "g id ", g.common.id.get()
  for c in g.findAll(svgCircle):
    echo "circle r ", c.r.get().value
  # raw attrs preserved
  echo "rect fill raw ", g.children[1].attrsRaw.getOrDefault("fill")

block mutate_and_serialize:
  sep("mutate + serialize")
  let doc = parseSvg("""<svg width="24" height="24"><rect width="10" height="10" fill="red"/></svg>""")
  let rect = doc.root.findChild(svgRect)
  # change fill via Colors (keep raw in sync for serializer which uses attrsRaw)
  let newColor = parseColor("rebeccapurple")
  rect.common.fill = some(newColor)
  rect.attrsRaw["fill"] = "rebeccapurple"
  # add a new node
  let circle = newSvgElement(svgCircle, "circle")
  circle.attrsRaw["cx"] = "12"
  circle.attrsRaw["cy"] = "12"
  circle.attrsRaw["r"] = "8"
  circle.cx = some(parseSvgLength("12"))
  circle.cy = some(parseSvgLength("12"))
  circle.r = some(parseSvgLength("8"))
  doc.root.addChild(circle)

  let minified = doc.toSvg() # compact
  echo "minified ", minified[0..80], "..."
  let pretty = doc.toSvg(SvgSerializeOptions(pretty: true, indentSize: 2, xmlDecl: true))
  echo "pretty:\n", pretty
  let sorted = doc.toSvg(SvgSerializeOptions(sortAttrs: true))
  echo "sorted attrs -> ", sorted

block style_and_colors_integration:
  sep("style + CSS bridge + colors")
  let src = """<svg><rect style="fill: hsl(0 100% 50%); stroke: oklch(0.7 0.15 180); stroke-width: 2px; opacity: 0.5"/></svg>"""
  let doc = parseSvg(src)
  let rect = doc.root.findChild(svgRect)
  echo "styleRaw ", rect.common.styleRaw.get()
  for d in rect.common.styleDecls:
    echo "  decl ", d.property, " = ", d.value
  # fill via style is not auto-resolved to common.fill; inline fill is
  let doc2 = parseSvg("""<svg><rect fill="lab(53.2 80.1 67.2)"/></svg>""")
  echo "lab fill -> ", doc2.root.findChild(svgRect).common.fill.get().toHex()

block policies_and_files:
  sep("policies, entities, files")
  # entities
  let t = parseSvg("""<svg><text>&amp; &lt;hello&gt;</text></svg>""")
  let txtElem = t.root.findChild(svgText)
  echo "entity decoded ", txtElem.children[0].text

  # requireXmlns
  try:
    discard parseSvg("""<svg><rect width="10"/></svg>""", SVGParserPolicy(requireXmlns: true))
  except SvgParseError as e:
    echo "requireXmlns correctly rejected: ", e.msg

  # allowUnknownTags
  echo "unknown tag allowed: ", parseSvg("""<svg><myTag foo="1"/></svg>""").root.children[0].rawTag
  try:
    discard parseSvg("""<svg><myTag/></svg>""", SVGParserPolicy(allowUnknownTags: false))
  except SvgParseError as e:
    echo "unknown tag correctly rejected: ", e.msg

  # parse element fragment
  let el = parseSvgElement("""<rect x="5" y="5" width="10" height="10"/>""")
  echo "fragment tag ", el.tag, " x ", el.x.get().value

  # path data api directly
  let segs = parsePathData("M10 10 L20 20 Z")
  echo "path segs ", segs.len, " ", segs[0].cmd, segs[1].cmd, segs[2].cmd
  echo "path to string ", pathDataToString(segs)
