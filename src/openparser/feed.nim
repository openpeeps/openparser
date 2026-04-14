# A collection of tiny parsers and dumpers
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/openparser

import std/[xmltree, xmlparser, strutils, httpclient, options]

## This module provides functionality to parse and generate Atom feeds in Nim. It defines data structures to
## represent Atom feeds, entries, authors, links, categories, and content, as well as functions to read Atom
## feeds from files or URLs, parse them from XML strings, and convert them back to XML format.
## 
## The module also includes error handling for parsing and validation errors.

const AtomNs* = "http://www.w3.org/2005/Atom"

type
  AtomParsingError* = object of CatchableError
  AtomValidationError* = object of CatchableError

  AtomText* = object
    ## Atom text construct: text|html|xhtml (stored as string payload)
    kind*: string      # text, html, xhtml
    value*: string

  AtomPerson* = object
    ## Represents a person construct in Atom, which can be an author or contributor.
    name*: string
    uri*: Option[string]
    email*: Option[string]

  AtomLink* = object
    ## Represents a link construct in Atom, which can be associated with feeds or entries.
    href*: string
    rel*: Option[string]
    mimeType*: Option[string]   # maps to @type
    hreflang*: Option[string]
    title*: Option[string]
    length*: Option[int]

  AtomCategory* = object
    ## Represents a category construct in Atom, which can be used to categorize feeds or entries.
    term*: string
    scheme*: Option[string]
    label*: Option[string]

  AtomGenerator* = object
    ## Represents the generator construct in Atom, which
    ## identifies the software used to generate the feed.
    value*: string
    uri*: Option[string]
    version*: Option[string]

  AtomContent* = object
    ## Represents the content construct in Atom, which can be
    ## used to include the main content of an entry.
    kind*: Option[string]       # maps to @type
    src*: Option[string]
    value*: Option[string]      # inline payload (text/html/xhtml or opaque string)

  AtomEntry* = object
    ## Represents an individual entry in an Atom feed, containing metadata and content about the entry.
    id*: string
    title*: AtomText
    updated*: string
    authors*: seq[AtomPerson]
    contributors*: seq[AtomPerson]
    links*: seq[AtomLink]
    categories*: seq[AtomCategory]
    summary*: Option[AtomText]
    content*: Option[AtomContent]
    rights*: Option[AtomText]
    published*: Option[string]

  AtomFeed* = object
    ## Represents an Atom feed, containing metadata about the feed and a sequence of entries.
    id*: string
    title*: AtomText
    updated*: string
    authors*: seq[AtomPerson]
    contributors*: seq[AtomPerson]
    links*: seq[AtomLink]
    categories*: seq[AtomCategory]
    subtitle*: Option[AtomText]
    rights*: Option[AtomText]
    generator*: Option[AtomGenerator]
    icon*: Option[string]
    logo*: Option[string]
    entries*: seq[AtomEntry]
    lang*: Option[string]       # xml:lang
    base*: Option[string]       # xml:base

proc localName(tag: string): string =
  let i = tag.rfind(':')
  if i >= 0 and i + 1 < tag.len: tag[i + 1 .. ^1] else: tag

proc isElem(n: XmlNode; name: string): bool =
  n != nil and n.kind == xnElement and localName(n.tag) == name

proc firstChild(node: XmlNode; name: string): XmlNode =
  if node == nil: return
  for c in node:
    if isElem(c, name): return c

iterator children(node: XmlNode; name: string): XmlNode =
  if node != nil:
    for c in node:
      if isElem(c, name): yield c

proc attrOpt(node: XmlNode; key: string): Option[string] =
  if node == nil: return none(string)
  let v = node.attr(key)
  if v.len > 0: some(v) else: none(string)

proc textOf(node: XmlNode): string =
  if node == nil: "" else: node.innerText.strip

proc parseText(node: XmlNode): AtomText =
  result.kind = node.attr("type")
  if result.kind.len == 0: result.kind = "text"
  result.value = textOf(node)

proc parsePerson(node: XmlNode): AtomPerson =
  let n = firstChild(node, "name")
  if n == nil:
    raise newException(AtomParsingError, "Person construct missing <name>")
  result.name = textOf(n)
  result.uri = attrOpt(firstChild(node, "uri"), "value")
  if result.uri.isNone:
    let uriNode = firstChild(node, "uri")
    if uriNode != nil:
      let v = textOf(uriNode)
      if v.len > 0: result.uri = some(v)

  let emailNode = firstChild(node, "email")
  if emailNode != nil:
    let v = textOf(emailNode)
    if v.len > 0: result.email = some(v)

proc parseLink(node: XmlNode): AtomLink =
  result.href = node.attr("href")
  if result.href.len == 0:
    raise newException(AtomParsingError, "Link missing required @href")
  result.rel = attrOpt(node, "rel")
  result.mimeType = attrOpt(node, "type")
  result.hreflang = attrOpt(node, "hreflang")
  result.title = attrOpt(node, "title")

  let l = node.attr("length")
  if l.len > 0:
    try: result.length = some(parseInt(l))
    except ValueError: discard

proc parseCategory(node: XmlNode): AtomCategory =
  result.term = node.attr("term")
  if result.term.len == 0:
    raise newException(AtomParsingError, "Category missing required @term")
  result.scheme = attrOpt(node, "scheme")
  result.label = attrOpt(node, "label")

proc parseGenerator(node: XmlNode): AtomGenerator =
  result.value = textOf(node)
  result.uri = attrOpt(node, "uri")
  result.version = attrOpt(node, "version")

proc parseContent(node: XmlNode): AtomContent =
  result.kind = attrOpt(node, "type")
  result.src = attrOpt(node, "src")
  let v = textOf(node)
  if v.len > 0: result.value = some(v)

proc parseEntry(node: XmlNode): AtomEntry =
  for c in node:
    if c.kind != xnElement: continue
    case localName(c.tag)
    of "id": result.id = textOf(c)
    of "title": result.title = parseText(c)
    of "updated": result.updated = textOf(c)
    of "author": result.authors.add(parsePerson(c))
    of "contributor": result.contributors.add(parsePerson(c))
    of "link": result.links.add(parseLink(c))
    of "category": result.categories.add(parseCategory(c))
    of "summary": result.summary = some(parseText(c))
    of "content": result.content = some(parseContent(c))
    of "rights": result.rights = some(parseText(c))
    of "published":
      let v = textOf(c)
      if v.len > 0: result.published = some(v)
    else: discard

proc validateFeed(feed: AtomFeed) =
  if feed.id.len == 0:
    raise newException(AtomValidationError, "feed.id is required")
  if feed.title.value.len == 0:
    raise newException(AtomValidationError, "feed.title is required")
  if feed.updated.len == 0:
    raise newException(AtomValidationError, "feed.updated is required")

  for e in feed.entries:
    if e.id.len == 0:
      raise newException(AtomValidationError, "entry.id is required")
    if e.title.value.len == 0:
      raise newException(AtomValidationError, "entry.title is required")
    if e.updated.len == 0:
      raise newException(AtomValidationError, "entry.updated is required")
    if e.authors.len == 0 and feed.authors.len == 0:
      raise newException(AtomValidationError, "entry.author required when feed has no author")

proc xmlEscape(s: string): string =
  result = s
  result = result.replace("&", "&amp;")
  result = result.replace("<", "&lt;")
  result = result.replace(">", "&gt;")
  result = result.replace("\"", "&quot;")
  result = result.replace("'", "&apos;")

proc addTag(sb: var string; tag, value: string) =
  if value.len > 0:
    sb.add("<" & tag & ">" & xmlEscape(value) & "</" & tag & ">")

proc addText(sb: var string; tag: string; t: AtomText) =
  if t.value.len == 0: return
  if t.kind.len > 0 and t.kind != "text":
    sb.add("<" & tag & " type=\"" & xmlEscape(t.kind) & "\">" &
      xmlEscape(t.value) & "</" & tag & ">")
  else:
    addTag(sb, tag, t.value)

proc addPerson(sb: var string; tag: string; p: AtomPerson) =
  sb.add("<" & tag & ">")
  addTag(sb, "name", p.name)
  if p.uri.isSome: addTag(sb, "uri", p.uri.get)
  if p.email.isSome: addTag(sb, "email", p.email.get)
  sb.add("</" & tag & ">")

proc addLink(sb: var string; l: AtomLink) =
  sb.add("<link href=\"" & xmlEscape(l.href) & "\"")
  if l.rel.isSome: sb.add(" rel=\"" & xmlEscape(l.rel.get) & "\"")
  if l.mimeType.isSome: sb.add(" type=\"" & xmlEscape(l.mimeType.get) & "\"")
  if l.hreflang.isSome: sb.add(" hreflang=\"" & xmlEscape(l.hreflang.get) & "\"")
  if l.title.isSome: sb.add(" title=\"" & xmlEscape(l.title.get) & "\"")
  if l.length.isSome: sb.add(" length=\"" & $l.length.get & "\"")
  sb.add("/>")

proc addCategory(sb: var string; c: AtomCategory) =
  sb.add("<category term=\"" & xmlEscape(c.term) & "\"")
  if c.scheme.isSome: sb.add(" scheme=\"" & xmlEscape(c.scheme.get) & "\"")
  if c.label.isSome: sb.add(" label=\"" & xmlEscape(c.label.get) & "\"")
  sb.add("/>")

proc addContent(sb: var string; c: AtomContent) =
  sb.add("<content")
  if c.kind.isSome: sb.add(" type=\"" & xmlEscape(c.kind.get) & "\"")
  if c.src.isSome: sb.add(" src=\"" & xmlEscape(c.src.get) & "\"")
  if c.value.isSome and c.src.isNone:
    sb.add(">" & xmlEscape(c.value.get) & "</content>")
  else:
    sb.add("/>")

proc addEntry(sb: var string; e: AtomEntry) =
  sb.add("<entry>")
  addTag(sb, "id", e.id)
  addText(sb, "title", e.title)
  addTag(sb, "updated", e.updated)

  for a in e.authors: addPerson(sb, "author", a)
  for c in e.contributors: addPerson(sb, "contributor", c)
  for l in e.links: addLink(sb, l)
  for c in e.categories: addCategory(sb, c)

  if e.summary.isSome: addText(sb, "summary", e.summary.get)
  if e.content.isSome: addContent(sb, e.content.get)
  if e.rights.isSome: addText(sb, "rights", e.rights.get)
  if e.published.isSome: addTag(sb, "published", e.published.get)

  sb.add("</entry>")

#
# Public API
#
proc parseAtom*(xml: string): AtomFeed =
  ## Parses an Atom feed from the given XML string and returns an AtomFeed object.
  let doc = parseXml(xml)
  var root = doc
  if not isElem(root, "feed"):
    root = firstChild(doc, "feed")
  if root == nil:
    raise newException(AtomParsingError, "Atom <feed> not found")

  let xmlns = root.attr("xmlns")
  if xmlns.len > 0 and xmlns != AtomNs:
    raise newException(AtomParsingError, "Unsupported Atom namespace: " & xmlns)

  result.lang = attrOpt(root, "xml:lang")
  result.base = attrOpt(root, "xml:base")

  for c in root:
    if c.kind != xnElement: continue
    case localName(c.tag)
    of "id": result.id = textOf(c)
    of "title": result.title = parseText(c)
    of "updated": result.updated = textOf(c)
    of "author": result.authors.add(parsePerson(c))
    of "contributor": result.contributors.add(parsePerson(c))
    of "link": result.links.add(parseLink(c))
    of "category": result.categories.add(parseCategory(c))
    of "subtitle": result.subtitle = some(parseText(c))
    of "rights": result.rights = some(parseText(c))
    of "generator": result.generator = some(parseGenerator(c))
    of "icon":
      let v = textOf(c)
      if v.len > 0: result.icon = some(v)
    of "logo":
      let v = textOf(c)
      if v.len > 0: result.logo = some(v)
    of "entry": result.entries.add(parseEntry(c))
    else: discard

  validateFeed(result)

proc readAtom*(filePath: string): AtomFeed =
  ## Reads an Atom feed from the specified file path and parses it into an AtomFeed object.
  parseAtom(readFile(filePath))

proc fetchAtom*(url: string): AtomFeed =
  ## Fetches an Atom feed from the specified URL and parses it into an AtomFeed object.
  let client = newHttpClient()
  parseAtom(client.getContent(url))

proc toAtomXml*(feed: AtomFeed): string =
  ## Converts an AtomFeed object back to XML string
  validateFeed(feed)
  result.add("<?xml version=\"1.0\" encoding=\"UTF-8\"?>")
  result.add("<feed xmlns=\"" & AtomNs & "\"")
  if feed.lang.isSome: result.add(" xml:lang=\"" & xmlEscape(feed.lang.get) & "\"")
  if feed.base.isSome: result.add(" xml:base=\"" & xmlEscape(feed.base.get) & "\"")
  result.add(">")

  addTag(result, "id", feed.id)
  addText(result, "title", feed.title)
  addTag(result, "updated", feed.updated)

  for a in feed.authors: addPerson(result, "author", a)
  for c in feed.contributors: addPerson(result, "contributor", c)
  for l in feed.links: addLink(result, l)
  for c in feed.categories: addCategory(result, c)

  if feed.subtitle.isSome: addText(result, "subtitle", feed.subtitle.get)
  if feed.rights.isSome: addText(result, "rights", feed.rights.get)
  if feed.generator.isSome:
    let g = feed.generator.get
    result.add("<generator")
    if g.uri.isSome: result.add(" uri=\"" & xmlEscape(g.uri.get) & "\"")
    if g.version.isSome: result.add(" version=\"" & xmlEscape(g.version.get) & "\"")
    result.add(">" & xmlEscape(g.value) & "</generator>")
  if feed.icon.isSome: addTag(result, "icon", feed.icon.get)
  if feed.logo.isSome: addTag(result, "logo", feed.logo.get)

  for e in feed.entries: addEntry(result, e)
  result.add("</feed>")
