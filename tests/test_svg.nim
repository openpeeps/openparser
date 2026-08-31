import unittest, options, strutils, os, tables, sequtils
import ../src/openparser/svg
import ../src/openparser/colors

suite "SVG Parsing - Basic DOM":
  test "simple svg root":
    let src = """<svg xmlns="http://www.w3.org/2000/svg" width="100" height="100"><rect width="10" height="10"/></svg>"""
    let doc = parseSvg(src)
    check doc.root.tag == svgSvg
    check doc.root.children.len == 1
    check doc.root.children[0].tag == svgRect
    check doc.root.width.get().value == 100
    check doc.root.height.get().value == 100

  test "nested g and circle":
    let src = """<svg><g id="layer1"><circle cx="12" cy="12" r="10"/></g></svg>"""
    let doc = parseSvg(src)
    check doc.root.children.len == 1
    let g = doc.root.children[0]
    check g.tag == svgG
    check g.common.id.get() == "layer1"
    check g.children.len == 1
    check g.children[0].tag == svgCircle
    check g.children[0].cx.get().value == 12
    check g.children[0].cy.get().value == 12
    check g.children[0].r.get().value == 10

  test "text and tspan":
    let src = """<svg><text x="10" y="20">Hello <tspan>World</tspan></text></svg>"""
    let doc = parseSvg(src)
    let textNode = doc.root.children[0]
    check textNode.tag == svgText
    check textNode.children.len == 2
    check textNode.children[0].kind == svgTextNode
    check textNode.children[0].text == "Hello "
    check textNode.children[1].tag == svgTspan

  test "attributes raw preserved":
    let src = """<svg><rect x="5" y="5" width="10" height="10" fill="red" data-custom="123"/></svg>"""
    let doc = parseSvg(src)
    let rect = doc.root.children[0]
    check rect.attrsRaw["data-custom"] == "123"
    check rect.attrsRaw["fill"] == "red"

  test "self-closing":
    let src = """<svg><path d="M0 0 L10 10"/><br/></svg>"""
    # br is unknown but allowed
    let doc = parseSvg(src)
    check doc.root.children.len == 2
    check doc.root.children[0].tag == svgPath
    check doc.root.children[1].rawTag == "br"

suite "SVG Typed Attributes":
  test "SvgLength normalization":
    let l1 = parseSvgLength("100")
    check l1.value == 100 and l1.unit == luNumber
    check l1.raw == "100"
    let l2 = parseSvgLength("50%")
    check l2.value == 50 and l2.unit == luPercent
    check svgLengthToString(l2) == "50%"
    let l3 = parseSvgLength("1.5em")
    check l3.unit == luEm
    let l4 = parseSvgLength("24px")
    check l4.unit == luPx
    check svgLengthToString(l4) == "24px"

  test "viewBox":
    let vb = parseSvgViewBox("0 0 24 24")
    check vb.minX == 0 and vb.minY == 0 and vb.width == 24 and vb.height == 24
    check viewBoxToString(vb) == "0 0 24 24"
    let doc = parseSvg("""<svg viewBox="0 0 100 100"><rect width="10" height="10"/></svg>""")
    check doc.root.viewBox.get().width == 100
    check doc.root.viewBox.get().height == 100
    let vb2 = parseSvgViewBox("10, 20, 30, 40")
    check vb2.minX == 10

  test "preserveAspectRatio":
    let p = parsePreserveAspectRatio("xMidYMid meet")
    check p.align == "xMidYMid" and p.meetOrSlice == "meet"
    check preserveAspectToString(p) == "xMidYMid"
    let p2 = parsePreserveAspectRatio("none")
    check p2.align == "none"
    let doc = parseSvg("""<svg preserveAspectRatio="xMinYMin slice"><rect width="10" height="10"/></svg>""")
    check doc.root.preserveAspectRatio.get().align == "xMinYMin"

  test "transform":
    let ts = parseSvgTransform("translate(10) rotate(45) scale(2)")
    check ts.len == 3
    check ts[0].kind == trTranslate and ts[0].values[0] == 10
    check ts[1].kind == trRotate
    check ts[2].kind == trScale
    check transformsToString(ts) == "translate(10) rotate(45) scale(2)"
    let doc = parseSvg("""<svg><g transform="translate(5,10) scale(2)"><rect width="10" height="10"/></g></svg>""")
    check doc.root.children[0].common.transform.get().len == 2

  test "fill via colors":
    let doc = parseSvg("""<svg><rect fill="red" stroke="oklch(0.7 0.15 180)" stroke-width="2px"/></svg>""")
    let rect = doc.root.children[0]
    check rect.common.fill.isSome
    check rect.common.fill.get().toHex() == "#ff0000"
    check rect.common.stroke.isSome
    check rect.common.strokeWidth.get().value == 2

  test "fill none and currentColor":
    let doc = parseSvg("""<svg><rect fill="none" stroke="currentColor"/></svg>""")
    check doc.root.children[0].common.fillRaw.get() == "none"
    check doc.root.children[0].common.strokeRaw.get() == "currentColor"
    check doc.root.children[0].common.fill.isNone

  test "points polygon polyline":
    let doc = parseSvg("""<svg><polygon points="0,0 10,0 5,10"/><polyline points="0 0 10 10 20 0"/></svg>""")
    check doc.root.children[0].pointsParsed.len == 3
    check doc.root.children[1].pointsParsed.len == 3
    check pointsToString(doc.root.children[0].pointsParsed) == "0,0 10,0 5,10"

  test "image href":
    let doc = parseSvg("""<svg><image href="test.png" x="0" y="0" width="10" height="10"/></svg>""")
    check doc.root.children[0].href.get() == "test.png"
    let doc2 = parseSvg("""<svg><image xlink:href="old.png"/></svg>""")
    check doc2.root.children[0].href.get() == "old.png"

  test "style attribute via CSS":
    let doc = parseSvg("""<svg><rect style="fill: red; stroke: blue; opacity: 0.5"/></svg>""")
    check doc.root.children[0].common.styleRaw.get().contains("fill")
    check doc.root.children[0].common.styleDecls.len == 3
    check doc.root.children[0].common.styleDecls[0].property == "fill"

suite "SVG Path Data":
  test "simple commands":
    let segs = parsePathData("M10 10 L20 20 Z")
    check segs.len == 3
    check segs[0].cmd == 'M' and segs[0].args[0] == 10
    check segs[2].cmd == 'Z'
  test "relative and horiz vert":
    let segs = parsePathData("m10 10 l5 5 h10 v10 z")
    check segs.len == 5
    check segs[2].cmd == 'h'
    check segs[3].cmd == 'v'
  test "cubic and arc":
    let segs = parsePathData("M0 0 C10 10 20 20 30 30 S40 40 50 50")
    check segs.len == 3
    let arc = parsePathData("M10 10 A 5 5 0 0 1 20 20")
    check arc.len == 2
    check arc[1].cmd == 'A' and arc[1].args.len == 7
  test "implicit lineto after moveto":
    let segs = parsePathData("M10 10 20 20 30 30")
    check segs.len == 3
    check segs[0].cmd == 'M'
    check segs[1].cmd == 'L'
    check segs[2].cmd == 'L'
  test "path on node":
    let doc = parseSvg("""<svg><path d="M12 2 L22 22 L2 22 Z"/></svg>""")
    check doc.root.children[0].dSegs.len == 4
    check doc.root.children[0].d.get() == "M12 2 L22 22 L2 22 Z"

suite "SVG Parser Policy":
  test "requireXmlns":
    let good = """<svg xmlns="http://www.w3.org/2000/svg"><rect width="10" height="10"/></svg>"""
    check parseSvg(good, SVGParserPolicy(requireXmlns: true)).root.tag == svgSvg
    expect SvgParseError:
      discard parseSvg("""<svg><rect width="10" height="10"/></svg>""", SVGParserPolicy(requireXmlns: true))
  test "allowUnknownTags true vs false":
    let src = """<svg><myCustom foo="bar"/></svg>"""
    check parseSvg(src).root.children[0].rawTag == "myCustom"
    expect SvgParseError:
      discard parseSvg(src, SVGParserPolicy(allowUnknownTags: false))
  test "preserveComments":
    let src = """<svg><!-- comment --><rect width="10" height="10"/></svg>"""
    check parseSvg(src, SVGParserPolicy(preserveComments: true)).root.children[0].kind == svgCommentNode
    check parseSvg(src, SVGParserPolicy(preserveComments: false)).root.children[0].tag == svgRect
  test "entity decoding":
    let src = """<svg><text>&amp; &lt;hello&gt;</text></svg>"""
    let doc = parseSvg(src)
    check doc.root.children[0].children[0].text == "& <hello>"

suite "SVG Serializer - Minified vs Beautified":
  test "minified no whitespace":
    let src = """<svg width="24" height="24"><path d="M0 0 L10 10"/></svg>"""
    let doc = parseSvg(src)
    let minified = doc.toSvg(SvgSerializeOptions(pretty: false))
    check not minified.contains("\n")
    check minified.contains("<path")
    check minified.contains("/>")
  test "beautified 2 spaces indent":
    let src = """<svg width="24" height="24"><g><rect width="10" height="10"/></g></svg>"""
    let doc = parseSvg(src)
    let pretty = doc.toSvg(SvgSerializeOptions(pretty: true, indentSize: 2))
    check pretty.contains("\n")
    check pretty.contains("  <g>")
    check pretty.contains("    <rect")
    check pretty.contains("</g>")
    check pretty.contains("</svg>")
  test "xmlDecl":
    let doc = parseSvg("""<svg><rect width="10" height="10"/></svg>""")
    check doc.toSvg(SvgSerializeOptions(xmlDecl: true)).startsWith("<?xml")
    check doc.toSvg(SvgSerializeOptions(pretty: true, xmlDecl: true)).contains("<?xml")
  test "round-trip":
    let src = """<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24"><path d="M12 2 L22 22 Z" fill="red"/><g><circle cx="12" cy="12" r="10"/></g></svg>"""
    let doc = parseSvg(src)
    let minified = doc.toSvg(SvgSerializeOptions(pretty: false))
    let doc2 = parseSvg(minified)
    check doc2.root.children.len == 2
    check doc2.root.children[0].tag == svgPath
  test "style script raw not escaped":
    let src = """<svg><style>.cls { fill: red; }</style><script>console.log("hi")</script></svg>"""
    let doc = parseSvg(src)
    let minified = doc.toSvg(SvgSerializeOptions(pretty: false))
    check minified.contains(".cls { fill: red; }")
    check minified.contains("console.log")
  test "sortAttrs":
    let doc = parseSvg("""<svg><rect y="0" x="0" width="10" height="10"/></svg>""")
    let sorted = doc.toSvg(SvgSerializeOptions(sortAttrs: true))
    # x should come before y when sorted
    check sorted.find("x=") < sorted.find("y=")

suite "SVG File and Error Handling":
  test "parseSvgFile memfile":
    let tmp = getTempDir() / "openparser_svg_test.svg"
    writeFile(tmp, """<svg><rect width="10" height="10"/></svg>""")
    defer: removeFile(tmp)
    let doc = parseSvgFile(tmp)
    check doc.root.children[0].tag == svgRect
  test "mismatched tags error":
    expect SvgParseError:
      discard parseSvg("""<svg><g><rect></g></svg>""")
  test "empty and no svg root":
    expect SvgParseError:
      discard parseSvg("")
    expect SvgParseError:
      discard parseSvg("""<html><body></body></html>""")

suite "SVG Integration - Colors and CSS":
  test "oklch fill via colors":
    let doc = parseSvg("""<svg><rect fill="oklch(0.7 0.15 180)"/></svg>""")
    check doc.root.children[0].common.fill.isSome
    check doc.root.children[0].common.fill.get().toHex().len == 7
  test "style with css declarations":
    let doc = parseSvg("""<svg><rect style="fill: hsl(0 100% 50%); stroke: none; stroke-width: 2px"/></svg>""")
    check doc.root.children[0].common.styleDecls.len == 3
    let decl = doc.root.children[0].common.styleDecls[0]
    check decl.property == "fill"
    check decl.value == "hsl(0 100% 50%)"
  test "transform and style together":
    let doc = parseSvg("""<svg><g transform="translate(10) rotate(45)" style="opacity: 0.5"><rect width="10" height="10"/></g></svg>""")
    check doc.root.children[0].common.transform.get().len == 2
    check doc.root.children[0].common.styleDecls.len == 1
