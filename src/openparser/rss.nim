# A collection of tiny parsers and dumpers
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/openparsers

import std/[xmltree, xmlparser, strutils, httpclient, options]

## This module provides functionality to parse and generate RSS feeds in Nim. It defines data structures to
## represent RSS feeds, items, images, and media content, as well as functions to read RSS
## feeds from files or URLs, parse them from XML strings, and convert them back to XML format.

type
  RssImage* = object
    ## Represents the image associated with an RSS feed.
    url*: string
      # The URL of the image, if available.
    title*: string
      # The title of the image, if available.
    link*: string
      # The URL that the image links to, if available.

  RssMediaContent* = object
    ## Represents media content associated with an RSS item.
    url*: Option[string]
      # The URL of the media content, if available.
    mediaType*: Option[string]
      # The type of media (e.g., "image/jpeg", "video/mp4"), if available.
    medium*: Option[string]
      # The medium of the media content (e.g., "image", "video"), if available.
    height*: Option[int]
      # The height of the media content in pixels, if available.
    width*: Option[int]
      # The width of the media content in pixels, if available.

  RssItem* = object
    ## Represents an individual item in an RSS feed.
    title*: Option[string]
      # The title of the item, if available.
    link*: Option[string]
      # The URL of the item, if available.
    description*: Option[string]
      # A brief description of the item, if available.
    pubDate*: Option[string]
      # The date and time when the item was published.
      # TODO - parse this into a DateTime object
    category*: Option[string]
      # The category of the item, if available.
    guid*: Option[string]
      # A unique identifier for the item, if available.
    source*: Option[string]
      # The source of the item, if available.
    mediaContent*: Option[RssMediaContent]
      # The media content associated with the item, if any.

  RssFeed* = object
    ## Represents an RSS feed with its metadata and items.
    title*: string
      # The title of the feed, if available.
    link*: string
      # The URL of the feed, if available.
    description*: string
      # A brief description of the feed, if available.
    language: string
      # The language of the feed, if available.
    copyright*: string
      # The copyright information for the feed, if available.
    pubDate*: string
      # The date and time when the feed was last updated.
    lastBuildDate*: string
      # The date and time when the feed was last built.
    atomSelfLink*: Option[string]
      # The URL of the feed itself, if available (from Atom self link).
    image*: RssImage
      # The image associated with the feed, if any.
    items*: seq[RssItem]
      # A sequence of items contained in the feed.
    ttl*: int
      # The time to live (TTL) for the feed, in minutes.

  RSSParsingError* = object of CatchableError

proc firstChild(node: XmlNode; tag: string): XmlNode =
  if node.isNil: return nil
  for child in node:
    if child.kind == xnElement and child.tag == tag:
      return child
  nil

proc childTextOpt(node: XmlNode; tag: string): Option[string] =
  let n = firstChild(node, tag)
  if n != nil:
    let v = n.innerText.strip
    if v.len > 0:
      return some(v)
  none(string)

proc childText(node: XmlNode; tag: string): string =
  childTextOpt(node, tag).get("")

proc parseRssImage(node: XmlNode): RssImage =
  result.url = childText(node, "url")
  result.title = childText(node, "title")
  result.link = childText(node, "link")

proc parseRssMediaContent(node: XmlNode): RssMediaContent =
  let mediaUrl = node.attr("url")
  let mediaType = node.attr("type")
  let medium = node.attr("medium")
  let height = node.attr("height")
  let width = node.attr("width")

  if mediaUrl.len > 0: result.url = some(mediaUrl)
  if mediaType.len > 0: result.mediaType = some(mediaType)
  if medium.len > 0: result.medium = some(medium)
  if height.len > 0:
    try: result.height = some(parseInt(height))
    except ValueError: discard
  if width.len > 0:
    try: result.width = some(parseInt(width))
    except ValueError: discard

proc parseRssItem(node: XmlNode): RssItem =
  result.title = childTextOpt(node, "title")
  result.link = childTextOpt(node, "link")
  result.description = childTextOpt(node, "description")
  result.pubDate = childTextOpt(node, "pubDate")
  result.category = childTextOpt(node, "category")
  result.guid = childTextOpt(node, "guid")
  result.source = childTextOpt(node, "source")

  let mediaNode = firstChild(node, "media:content")
  if mediaNode != nil:
    result.mediaContent = some(parseRssMediaContent(mediaNode))

proc parseRss*(xml: string): RssFeed =
  ## Parses the given XML string as an RSS feed and returns an RssFeed object.
  let doc = parseXml(xml)

  var channel = firstChild(doc, "channel")
  if channel == nil and doc.kind == xnElement and doc.tag == "channel":
    channel = doc
  if channel == nil:
    raise newException(RSSParsingError, "RSS channel element not found")

  result.title = childText(channel, "title")
  result.link = childText(channel, "link")
  result.description = childText(channel, "description")
  result.language = childText(channel, "language")
  result.copyright = childText(channel, "copyright")
  result.pubDate = childText(channel, "pubDate")
  result.lastBuildDate = childText(channel, "lastBuildDate")

  let atomLink = firstChild(channel, "atom:link")
  if atomLink != nil:
    let href = atomLink.attr("href")
    if href.len > 0: result.atomSelfLink = some(href)

  let ttlText = childText(channel, "ttl")
  if ttlText.len > 0:
    try: result.ttl = parseInt(ttlText)
    except ValueError: discard

  let imageNode = firstChild(channel, "image")
  if imageNode != nil:
    result.image = parseRssImage(imageNode)

  for item in channel:
    if item.kind == xnElement and item.tag == "item":
      result.items.add(parseRssItem(item))

proc readRss*(filePath: string): RssFeed =
  ## Reads an RSS feed from the specified file path and parses it into an RssFeed object.
  let xml = readFile(filePath)
  result = parseRss(xml)

proc fetchRss*(url: string): RssFeed =
  ## Fetches an RSS feed from the specified URL and parses it into an RssFeed object.
  let client = newHttpClient()
  let body = client.getContent(url)
  result = parseRss(body)

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

proc addOptTag(sb: var string; tag: string; value: Option[string]) =
  if value.isSome:
    addTag(sb, tag, value.get)

proc mediaContentToXml(media: RssMediaContent): string =
  var attrs: seq[string] = @[]
  if media.url.isSome: attrs.add("url=\"" & xmlEscape(media.url.get) & "\"")
  if media.mediaType.isSome: attrs.add("type=\"" & xmlEscape(media.mediaType.get) & "\"")
  if media.medium.isSome: attrs.add("medium=\"" & xmlEscape(media.medium.get) & "\"")
  if media.height.isSome: attrs.add("height=\"" & $media.height.get & "\"")
  if media.width.isSome: attrs.add("width=\"" & $media.width.get & "\"")
  if attrs.len > 0:
    result = "<media:content " & attrs.join(" ") & "/>"

proc itemToXml(item: RssItem): string =
  result.add("<item>")
  addOptTag(result, "title", item.title)
  addOptTag(result, "link", item.link)
  addOptTag(result, "description", item.description)
  addOptTag(result, "pubDate", item.pubDate)
  addOptTag(result, "category", item.category)
  addOptTag(result, "guid", item.guid)
  addOptTag(result, "source", item.source)
  if item.mediaContent.isSome:
    let m = mediaContentToXml(item.mediaContent.get)
    if m.len > 0: result.add(m)
  result.add("</item>")

proc toRssXml*(feed: RssFeed): string =
  ## Converts an RssFeed object back into an XML string representation of the RSS feed.
  result.add("""<?xml version="1.0" encoding="UTF-8"?>""")
  result.add("""<rss version="2.0" xmlns:media="http://search.yahoo.com/mrss/" xmlns:atom="http://www.w3.org/2005/Atom">""")
  result.add("<channel>")

  addTag(result, "title", feed.title)
  addTag(result, "link", feed.link)
  addTag(result, "description", feed.description)
  addTag(result, "language", feed.language)
  addTag(result, "copyright", feed.copyright)
  addTag(result, "pubDate", feed.pubDate)
  addTag(result, "lastBuildDate", feed.lastBuildDate)

  if feed.atomSelfLink.isSome:
    result.add("""<atom:link href="""" & xmlEscape(feed.atomSelfLink.get) & """" rel="self" type="application/rss+xml"/>""")

  if feed.ttl > 0:
    addTag(result, "ttl", $feed.ttl)

  if feed.image.url.len > 0 or feed.image.title.len > 0 or feed.image.link.len > 0:
    result.add("<image>")
    addTag(result, "url", feed.image.url)
    addTag(result, "title", feed.image.title)
    addTag(result, "link", feed.image.link)
    result.add("</image>")

  for item in feed.items:
    result.add(itemToXml(item))

  result.add("</channel></rss>")
