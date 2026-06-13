# A collection of tiny parsers and dumpers
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/openparser
import std/[tables, strutils]

## This module implements the AST structure for OpenParser's built-in HTML parser

type
  HtmlTag* = enum
    tagUnknown
    tagA        = "a"
    tagAbbr     = "abbr"
    tagAddress  = "address"
    tagArea     = "area"
    tagArticle  = "article"
    tagAside    = "aside"
    tagAudio    = "audio"
    tagB        = "b"
    tagBase     = "base"
    tagBdi      = "bdi"
    tagBdo      = "bdo"
    tagBlockquote = "blockquote"
    tagBody     = "body"
    tagBr       = "br"
    tagButton   = "button"
    tagCanvas   = "canvas"
    tagCaption  = "caption"
    tagCite     = "cite"
    tagCode     = "code"
    tagCol      = "col"
    tagColgroup = "colgroup"
    tagData     = "data"
    tagDatalist = "datalist"
    tagDd       = "dd"
    tagDel      = "del"
    tagDetails  = "details"
    tagDfn      = "dfn"
    tagDialog   = "dialog"
    tagDiv      = "div"
    tagDl       = "dl"
    tagDt       = "dt"
    tagEm       = "em"
    tagEmbed    = "embed"
    tagFieldset = "fieldset"
    tagFigcaption = "figcaption"
    tagFigure   = "figure"
    tagFooter   = "footer"
    tagForm     = "form"
    tagH1       = "h1"
    tagH2       = "h2"
    tagH3       = "h3"
    tagH4       = "h4"
    tagH5       = "h5"
    tagH6       = "h6"
    tagHead     = "head"
    tagHeader   = "header"
    tagHr       = "hr"
    tagHtml     = "html"
    tagI        = "i"
    tagIframe   = "iframe"
    tagImg      = "img"
    tagInput    = "input"
    tagIns      = "ins"
    tagKbd      = "kbd"
    tagLabel    = "label"
    tagLegend   = "legend"
    tagLi       = "li"
    tagLink     = "link"
    tagMain     = "main"
    tagMap      = "map"
    tagMark     = "mark"
    tagMeta     = "meta"
    tagMeter    = "meter"
    tagNav      = "nav"
    tagNoscript = "noscript"
    tagObject   = "object"
    tagOl       = "ol"
    tagOptgroup = "optgroup"
    tagOption   = "option"
    tagOutput   = "output"
    tagP        = "p"
    tagParam    = "param"
    tagPicture  = "picture"
    tagPre      = "pre"
    tagProgress = "progress"
    tagQ        = "q"
    tagRp       = "rp"
    tagRt       = "rt"
    tagRuby     = "ruby"
    tagS        = "s"
    tagSamp     = "samp"
    tagScript   = "script"
    tagSection  = "section"
    tagSelect   = "select"
    tagSmall    = "small"
    tagSource   = "source"
    tagSpan     = "span"
    tagStrong   = "strong"
    tagStyle    = "style"
    tagSub      = "sub"
    tagSummary  = "summary"
    tagSup      = "sup"
    tagTable    = "table"
    tagTbody    = "tbody"
    tagTd       = "td"
    tagTemplate = "template"
    tagTextarea = "textarea"
    tagTfoot    = "tfoot"
    tagTh       = "th"
    tagThead    = "thead"
    tagTime     = "time"
    tagTitle    = "title"
    tagTr       = "tr"
    tagTrack    = "track"
    tagU        = "u"
    tagUl       = "ul"
    tagVar      = "var"
    tagVideo    = "video"
    tagWbr      = "wbr"
    tagSlot     = "slot"

const
  htmlTagsSelfClosing* = {tagArea, tagBase, tagBr, tagCol, tagEmbed, tagHr, tagImg, tagInput,
              tagLink, tagMeta, tagParam, tagSource, tagTrack, tagWbr}
    ## The set of HTML tags that are self-closing (void elements) and do not have closing tags or children.
  htmlTagsInlineElements* = {tagA, tagAbbr, tagB, tagBdi, tagBdo, tagBr, tagCite, tagCode, tagData,
              tagDfn, tagEm, tagI, tagImg, tagKbd, tagLabel, tagMark, tagQ,
              tagRp, tagRt, tagS, tagSamp, tagSmall, tagSpan, tagStrong,
              tagSub, tagSup, tagU, tagVar}
    ## The set of HTML tags that are considered inline elements and typically do not start on a new line.
  htmlTagsBlockElements* = {tagAddress, tagArticle, tagAside, tagAudio, tagBlockquote, tagBody, tagButton,
              tagCanvas, tagCaption, tagCite, tagColgroup, tagData, tagDatalist, tagDd, tagDel, tagDetails,
              tagDfn, tagDialog, tagDiv, tagDl, tagDt, tagFieldset, tagFigcaption, tagFigure,
              tagFooter, tagForm, tagH1, tagH2, tagH3, tagH4, tagH5, tagH6, tagHead, tagHeader, tagHtml,
              tagIframe, tagIns, tagLabel, tagLegend, tagLi, tagMain, tagMap, tagMeta, tagMeter, tagNav,
              tagNoscript, tagObject, tagOl, tagOptgroup, tagOption, tagOutput, tagP, tagPicture, tagPre, tagProgress, tagQ,
              tagRp, tagRt, tagRuby, tagS, tagSamp, tagScript, tagSection, tagSelect, tagSmall, tagSource, tagSpan,
              tagStrong, tagStyle, tagSub, tagSummary, tagSup, tagTable, tagTbody, tagTd, tagTemplate, tagTextarea,
              tagTfoot, tagTh, tagThead, tagTime, tagTitle, tagTr, tagTrack, tagU, tagUl, tagVar, tagVideo, tagWbr, tagSlot}
    ## The set of HTML tags that are considered block-level elements and typically start on a new line and take up the full width available.

type
  HtmlInnerText* = object
    ## Represents the text content of an HTML node, including whitespace
    ## and special characters.
    text*: string
      ## The raw text content of the node, including all
      ## whitespace and special characters exactly as they
  
  HtmlNodeKind* = enum
    ## Represents the type of an HTML node in the parse tree
    htmlTag, htmlInnerText, htmlComment
  
  HtmlNode* {.acyclic.} = ref object
    ## Represents a node in the HTML parse tree
    case kind*: HtmlNodeKind
    of htmlTag:
      tag*: HtmlTag
        ## the specific HTML tag this node represents
      attributes*: TableRef[string, string]
        ## map of attribute names to values
      children*: seq[HtmlNode]
    of htmlInnerText:
      value*: HtmlInnerText
    else:
      comment*: string

  HtmlDocument* = object
    ## Represents the root of the HTML parse tree, containing all top-level nodes.
    nodes*: seq[HtmlNode]

proc isInline*(node: HtmlNode): bool =
  ## Returns true if the given HTML node is an inline element.
  result = node.tag in htmlTagsInlineElements

proc isInline*(tag: HtmlTag): bool =
  ## Returns true if the given HTML tag is an inline element.
  result = tag in htmlTagsInlineElements

proc isBlock*(node: HtmlNode): bool =
  ## Returns true if the given HTML node is a block-level element.
  result = node.tag in htmlTagsBlockElements

proc isBlock*(tag: HtmlTag): bool =
  ## Returns true if the given HTML tag is a block-level element.
  result = tag in htmlTagsBlockElements

proc isSelfClosing*(node: HtmlNode): bool =
  ## Returns true if the given HTML node is a self-closing (void) element.
  result = node.tag in htmlTagsSelfClosing

proc isSelfClosing*(tag: HtmlTag): bool =
  ## Returns true if the given HTML tag is a self-closing (void) element.
  result = tag in htmlTagsSelfClosing

proc toString*(tag: HtmlTag, closing: static bool = false): string =
  ## Converts an HtmlTag enum value to HTML tag string (e.g., tagA -> "<a>" or "</a>" if `closing` is true)
  result.add('<')
  when closing == true:
    result = "</"
  result.add($tag & ">")

proc getHtmlTag*(tagName: string): HtmlTag =
  ## Converts a tag name string to the corresponding `HtmlTag`.
  ## If the tag name is not recognized, returns `tagUnknown`.
  parseEnum[HtmlTag](tagName, tagUnknown)

proc innerText*(node: HtmlNode): string =
  ## Gets the inner text of `node`
  case node.kind
  of htmlTag:
    if not node.isSelfClosing:
      for child in node.children:
        let text = child.innerText()
        if text.len == 0: continue
        if result.len > 0 and result[^1] != ' ' and text[0] != ' ':
          result.add(' ')
        result.add(text)
  of htmlInnerText:
    return node.value.text
  else: discard

proc innerText*(doc: HtmlDocument): string =
  ## Gets the inner text of the entire document by concatenating the inner text of all top-level nodes
  for node in doc.nodes:
    let text = node.innerText()
    if text.len == 0: continue
    if result.len > 0 and result[^1] != ' ' and text[0] != ' ':
      result.add(' ')
    result.add(text)
