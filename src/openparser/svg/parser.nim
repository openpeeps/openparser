# A collection of tiny parsers and dumpers
#
# (c) 2026 George Lemon | MIT License

import std/[tables, options, strutils, memfiles]
import ../xml
import ./ast
import ./types
import ./attributes
import ./path
import ./css_bridge

type
  SVGParserPolicy* = object
    requireXmlns*: bool = false
    allowUnknownTags*: bool = true
    allowUnknownAttrs*: bool = true
    preserveComments*: bool = true
    strictColors*: bool = false
    strictLengths*: bool = false
    allowEntities*: bool = true

  SvgParseError* = object of CatchableError

proc defaultSVGParserPolicy*(): SVGParserPolicy =
  SVGParserPolicy(
    requireXmlns: false,
    allowUnknownTags: true,
    allowUnknownAttrs: true,
    preserveComments: true,
    strictColors: false,
    strictLengths: false,
    allowEntities: true
  )

proc svgError(msg: string) =
  raise newException(SvgParseError, msg)

proc xmlNodeToSvgNode(xmlNode: XmlNode, policy: SVGParserPolicy): SvgNode =
  case xmlNode.kind
  of xnText:
    # preserve whitespace text? for svg text content we keep non-empty
    # but keep all text nodes as is; serializer will handle whitespace
    return newSvgText(xmlNode.text)
  of xnComment:
    if policy.preserveComments:
      return newSvgComment(xmlNode.comment)
    else:
      return nil
  of xnCdata:
    return newSvgCdata(xmlNode.cdata)
  of xnElement:
    let tag = getSvgTag(xmlNode.tag)
    if tag == svgUnknown and not policy.allowUnknownTags:
      svgError("unknown SVG tag: " & xmlNode.tag)
    let node = newSvgElement(tag, xmlNode.tag)
    node.attrsRaw = xmlNode.attrs
    # fill typed attrs
    fillCommonAttrs(node, policy.strictColors)
    # parse style decls
    if node.common.styleRaw.isSome:
      node.common.styleDecls = parseStyleAttribute(node.common.styleRaw.get())
    fillGeometryAttrs(node)
    # path d parsing
    if node.tag == svgPath and node.d.isSome:
      try:
        node.dSegs = parsePathData(node.d.get())
      except Exception as e:
        if policy.strictLengths: svgError("invalid path d: " & e.msg)
    # children
    for child in xmlNode.children:
      let c = xmlNodeToSvgNode(child, policy)
      if c != nil:
        node.children.add(c)
    return node
  else:
    return nil

proc parseSvgInternal(xmlRoot: XmlNode, policy: SVGParserPolicy, prolog: Option[string]): SvgDocument =
  if xmlRoot == nil:
    svgError("empty SVG document")
  if xmlRoot.tag.toLowerAscii() != "svg":
    svgError("root element must be <svg>, got <" & xmlRoot.tag & ">")
  if policy.requireXmlns:
    let xmlns = xmlRoot.attrs.getOrDefault("xmlns", "")
    if xmlns != "http://www.w3.org/2000/svg":
      svgError("requireXmlns: expected xmlns=\"http://www.w3.org/2000/svg\"")
  let svgRoot = xmlNodeToSvgNode(xmlRoot, policy)
  result = SvgDocument(root: svgRoot, prolog: prolog, comments: @[])

proc parseSvg*(input: string, policy: SVGParserPolicy = defaultSVGParserPolicy()): SvgDocument =
  var prologOpt: Option[string] = none(string)
  var xmlStr = input.strip()
  # detect prolog
  var body = xmlStr
  if body.startsWith("<?xml"):
    let endIdx = body.find("?>")
    if endIdx >= 0:
      prologOpt = some(body[0..endIdx+1])
      body = body[endIdx+2..^1].strip()
  let xmlNode =
    try:
      fromXml(body)
    except OpenParserXmlError as e:
      raise newException(SvgParseError, e.msg)
  parseSvgInternal(xmlNode, policy, prologOpt)

proc parseSvg*(mf: MemFile, policy: SVGParserPolicy = defaultSVGParserPolicy()): SvgDocument =
  let xmlNode =
    try:
      fromXml(mf)
    except OpenParserXmlError as e:
      raise newException(SvgParseError, e.msg)
  parseSvgInternal(xmlNode, policy, none(string))

proc parseSvgFile*(path: string, policy: SVGParserPolicy = defaultSVGParserPolicy()): SvgDocument =
  var mf = memfiles.open(path, fmRead)
  defer: mf.close()
  let xmlNode =
    try:
      fromXml(mf)
    except OpenParserXmlError as e:
      raise newException(SvgParseError, e.msg)
  parseSvgInternal(xmlNode, policy, none(string))

proc parseSvgElement*(input: string, policy: SVGParserPolicy = defaultSVGParserPolicy()): SvgNode =
  let xmlNode =
    try:
      fromXml(input)
    except OpenParserXmlError as e:
      raise newException(SvgParseError, e.msg)
  xmlNodeToSvgNode(xmlNode, policy)
