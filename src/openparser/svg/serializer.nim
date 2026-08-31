# A collection of tiny parsers and dumpers
#
# (c) 2026 George Lemon | MIT License

import std/[strutils, tables, options, algorithm]
import ./ast
import ./types
import ./path
import ./attributes
import ./css_bridge

type
  SvgSerializeOptions* = object
    pretty*: bool = false
    minify*: bool = false
    indentSize*: int = 2
    newLine*: string = "\n"
    xmlDecl*: bool = false
    preserveComments*: bool = true
    sortAttrs*: bool = false

proc defaultSvgSerializeOptions*(): SvgSerializeOptions =
  SvgSerializeOptions(pretty: false, minify: false, indentSize: 2, newLine: "\n", xmlDecl: false, preserveComments: true, sortAttrs: false)

proc svgAttrEscape(s: string): string =
  result = ""
  for c in s:
    case c
    of '&': result.add("&amp;")
    of '"': result.add("&quot;")
    of '<': result.add("&lt;")
    of '>': result.add("&gt;")
    else: result.add(c)

proc svgTextEscape(s: string): string =
  result = ""
  for c in s:
    case c
    of '&': result.add("&amp;")
    of '<': result.add("&lt;")
    of '>': result.add("&gt;")
    else: result.add(c)

proc serializeNode(node: SvgNode, opts: SvgSerializeOptions, depth: int, outStr: var string) =
  case node.kind
  of svgTextNode:
    # preserve text as is, but escape
    outStr.add(svgTextEscape(node.text))
  of svgCommentNode:
    if opts.preserveComments:
      if opts.pretty:
        outStr.add(repeat(' ', depth*opts.indentSize))
      outStr.add("<!--" & node.comment & "-->")
      if opts.pretty: outStr.add(opts.newLine)
  of svgCdataNode:
    outStr.add("<![CDATA[" & node.cdata & "]]>")
  of svgElement:
    let tag = tagName(node)
    let indent = if opts.pretty and not opts.minify: repeat(' ', depth*opts.indentSize) else: ""
    if opts.pretty and not opts.minify and depth>0:
      # caller handles newline before, but we add indent here
      discard
    # build attrs
    var attrs: seq[string] = @[]
    # sort if requested
    var keys: seq[string] = @[]
    for k in node.attrsRaw.keys:
      keys.add(k)
    if opts.sortAttrs:
      keys.sort()
    for k in keys:
      let v = node.attrsRaw[k]
      attrs.add(k & "=\"" & svgAttrEscape(v) & "\"")
    let attrStr = if attrs.len>0: " " & attrs.join(" ") else: ""
    let hasChildren = node.children.len > 0
    # handle self-closing for empty elements
    let isRawTextParent = tag in ["style", "script"]
    if not hasChildren:
      # self-close
      if opts.pretty and not opts.minify:
        outStr.add(indent)
      outStr.add("<" & tag & attrStr & "/>")
      if opts.pretty and not opts.minify:
        outStr.add(opts.newLine)
    else:
      if opts.pretty and not opts.minify:
        outStr.add(indent)
      outStr.add("<" & tag & attrStr & ">")
      if opts.pretty and not opts.minify:
        # if children are single text node, keep inline
        if node.children.len == 1 and node.children[0].kind == svgTextNode:
          # inline
          outStr.add(svgTextEscape(node.children[0].text))
          outStr.add("</" & tag & ">")
          outStr.add(opts.newLine)
          return
        outStr.add(opts.newLine)
      for child in node.children:
        if child.kind == svgTextNode and isRawTextParent:
          # raw text inside style/script not escaped
          if opts.pretty and not opts.minify:
            outStr.add(repeat(' ', (depth+1)*opts.indentSize))
          outStr.add(child.text)
          if opts.pretty and not opts.minify: outStr.add(opts.newLine)
        elif child.kind == svgTextNode:
          # for mixed content, if text is whitespace only and pretty, skip?
          let txt = child.text
          let isWs = txt.strip().len == 0
          if opts.pretty and not opts.minify and isWs:
            continue
          if opts.pretty and not opts.minify:
            outStr.add(repeat(' ', (depth+1)*opts.indentSize))
            outStr.add(svgTextEscape(txt.strip()))
            outStr.add(opts.newLine)
          else:
            outStr.add(svgTextEscape(txt))
        else:
          serializeNode(child, opts, depth+1, outStr)
      if opts.pretty and not opts.minify:
        outStr.add(indent)
      outStr.add("</" & tag & ">")
      if opts.pretty and not opts.minify:
        outStr.add(opts.newLine)

proc toSvg*(doc: SvgDocument, opts: SvgSerializeOptions = defaultSvgSerializeOptions()): string =
  var actualOpts = opts
  if actualOpts.minify:
    actualOpts.pretty = false
  result = ""
  if actualOpts.xmlDecl or doc.prolog.isSome:
    if doc.prolog.isSome:
      result.add(doc.prolog.get() & actualOpts.newLine)
    elif actualOpts.xmlDecl:
      result.add("""<?xml version="1.0" encoding="UTF-8"?>""" & actualOpts.newLine)
  serializeNode(doc.root, actualOpts, 0, result)
  # trim trailing newline for minified? keep as is for pretty
  if actualOpts.minify:
    result = result.strip()

proc toSvg*(node: SvgNode, opts: SvgSerializeOptions = defaultSvgSerializeOptions()): string =
  var actualOpts = opts
  if actualOpts.minify: actualOpts.pretty = false
  result = ""
  serializeNode(node, actualOpts, 0, result)
  if actualOpts.minify:
    result = result.strip()

proc `$`*(doc: SvgDocument): string =
  doc.toSvg(defaultSvgSerializeOptions())

proc `$`*(node: SvgNode): string =
  node.toSvg(defaultSvgSerializeOptions())
