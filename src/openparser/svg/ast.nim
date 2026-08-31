# A collection of tiny parsers and dumpers
#
# (c) 2026 George Lemon | MIT License

import std/[tables, options, strutils]
import ./types
import ../colors

type
  SvgTag* = enum
    svgUnknown
    svgSvg = "svg"
    svgG = "g"
    svgDefs = "defs"
    svgSymbol = "symbol"
    svgUse = "use"
    svgSwitch = "switch"
    svgPath = "path"
    svgRect = "rect"
    svgCircle = "circle"
    svgEllipse = "ellipse"
    svgLine = "line"
    svgPolyline = "polyline"
    svgPolygon = "polygon"
    svgText = "text"
    svgTspan = "tspan"
    svgTref = "tref"
    svgTextPath = "textPath"
    svgAltGlyph = "altGlyph"
    svgAltGlyphDef = "altGlyphDef"
    svgAltGlyphItem = "altGlyphItem"
    svgGlyph = "glyph"
    svgGlyphRef = "glyphRef"
    svgMissingGlyph = "missing-glyph"
    svgFont = "font"
    svgFontFace = "font-face"
    svgFontFaceSrc = "font-face-src"
    svgFontFaceUri = "font-face-uri"
    svgFontFaceFormat = "font-face-format"
    svgFontFaceName = "font-face-name"
    svgHkern = "hkern"
    svgVkern = "vkern"
    svgA = "a"
    svgImage = "image"
    svgLinearGradient = "linearGradient"
    svgRadialGradient = "radialGradient"
    svgStop = "stop"
    svgPattern = "pattern"
    svgClipPath = "clipPath"
    svgMask = "mask"
    svgFilter = "filter"
    svgFeBlend = "feBlend"
    svgFeColorMatrix = "feColorMatrix"
    svgFeComponentTransfer = "feComponentTransfer"
    svgFeComposite = "feComposite"
    svgFeConvolveMatrix = "feConvolveMatrix"
    svgFeDiffuseLighting = "feDiffuseLighting"
    svgFeDisplacementMap = "feDisplacementMap"
    svgFeDistantLight = "feDistantLight"
    svgFeDropShadow = "feDropShadow"
    svgFeFlood = "feFlood"
    svgFeFuncA = "feFuncA"
    svgFeFuncB = "feFuncB"
    svgFeFuncG = "feFuncG"
    svgFeFuncR = "feFuncR"
    svgFeGaussianBlur = "feGaussianBlur"
    svgFeImage = "feImage"
    svgFeMerge = "feMerge"
    svgFeMergeNode = "feMergeNode"
    svgFeMorphology = "feMorphology"
    svgFeOffset = "feOffset"
    svgFePointLight = "fePointLight"
    svgFeSpecularLighting = "feSpecularLighting"
    svgFeSpotLight = "feSpotLight"
    svgFeTile = "feTile"
    svgFeTurbulence = "feTurbulence"
    svgView = "view"
    svgCursor = "cursor"
    svgStyle = "style"
    svgScript = "script"
    svgTitle = "title"
    svgDesc = "desc"
    svgMetadata = "metadata"
    svgForeignObject = "foreignObject"
    svgMarker = "marker"
    svgAnimate = "animate"
    svgAnimateMotion = "animateMotion"
    svgAnimateTransform = "animateTransform"
    svgSet = "set"
    svgMpath = "mpath"

  SvgNodeKind* = enum
    svgElement
    svgTextNode
    svgCommentNode
    svgCdataNode

  SvgPathSeg* = object
    cmd*: char
    args*: seq[float]

  SvgCommonAttrs* = object
    id*: Option[string]
    className*: Option[string]
    styleRaw*: Option[string]
    styleDecls*: seq[tuple[property, value: string]] # parsed via css_bridge
    transform*: Option[seq[SvgTransform]]
    opacity*: Option[float]
    fill*: Option[Color]
    fillRaw*: Option[string]
    stroke*: Option[Color]
    strokeRaw*: Option[string]
    strokeWidth*: Option[SvgLength]
    strokeOpacity*: Option[float]
    fillOpacity*: Option[float]
    display*: Option[string]
    visibility*: Option[string]

  SvgNode* {.acyclic.} = ref object
    case kind*: SvgNodeKind
    of svgElement:
      tag*: SvgTag
      rawTag*: string
      attrsRaw*: OrderedTable[string, string]
      common*: SvgCommonAttrs
      # geometry / specific typed attrs — all optional so single type covers all tags
      # svg root
      width*, height*: Option[SvgLength]
      viewBox*: Option[SvgViewBox]
      preserveAspectRatio*: Option[SvgPreserveAspect]
      xmlns*: Option[string]
      # rect
      x*, y*, rx*, ry*: Option[SvgLength]
      # circle
      cx*, cy*, r*: Option[SvgLength]
      # ellipse
      # uses cx,cy,rx,ry already
      # line
      x1*, y1*, x2*, y2*: Option[SvgLength]
      # polyline/polygon points raw
      points*: Option[string]
      pointsParsed*: seq[tuple[x,y: float]]
      # path
      d*: Option[string]
      dSegs*: seq[SvgPathSeg]
      # text
      dx*, dy*: Option[SvgLength]
      # image
      href*: Option[string]
      # gradient
      gradientUnits*: Option[string]
      stopColor*: Option[Color]
      stopOpacity*: Option[float]
      offset*: Option[string]
      # generic catch
      children*: seq[SvgNode]
    of svgTextNode:
      text*: string
    of svgCommentNode:
      comment*: string
    of svgCdataNode:
      cdata*: string

  SvgDocument* = object
    root*: SvgNode
    prolog*: Option[string]
    comments*: seq[SvgNode]

proc getSvgTag*(name: string): SvgTag =
  let n = name.toLowerAscii().strip()
  try:
    result = parseEnum[SvgTag](n)
  except ValueError:
    result = svgUnknown

proc newSvgElement*(tag: SvgTag, rawTag: string = ""): SvgNode =
  SvgNode(kind: svgElement, tag: tag, rawTag: if rawTag.len>0: rawTag else: $tag, attrsRaw: initOrderedTable[string,string](), children: @[])

proc newSvgText*(t: string): SvgNode = SvgNode(kind: svgTextNode, text: t)
proc newSvgComment*(c: string): SvgNode = SvgNode(kind: svgCommentNode, comment: c)
proc newSvgCdata*(c: string): SvgNode = SvgNode(kind: svgCdataNode, cdata: c)

proc tagName*(node: SvgNode): string =
  if node.kind != svgElement: return ""
  if node.tag == svgUnknown: node.rawTag else: $node.tag

proc `[]`*(node: SvgNode, idx: int): SvgNode =
  node.children[idx]
proc len*(node: SvgNode): int =
  if node.kind == svgElement: node.children.len else: 0
proc addChild*(parent, child: SvgNode) =
  if parent.kind == svgElement:
    parent.children.add(child)

proc findChild*(parent: SvgNode, tag: SvgTag): SvgNode =
  if parent.kind != svgElement: return nil
  for c in parent.children:
    if c.kind == svgElement and c.tag == tag: return c
  nil

proc findAll*(parent: SvgNode, tag: SvgTag): seq[SvgNode] =
  result = @[]
  if parent.kind != svgElement: return
  for c in parent.children:
    if c.kind == svgElement and c.tag == tag:
      result.add(c)
