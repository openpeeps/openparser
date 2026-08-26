# A collection of tiny parsers and dumpers
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/openparser

## This module implements a HTML5 parser that can handle typical HTML documents
## and produces a parse tree of `HtmlNode` objects.
## 
## The parser can tokenize and parse long HTML documents efficiently by using memory-mapped files
## and pointer-based string access, avoiding unnecessary copying of the input string.
## 
## It also supports a flexible parsing policy that allows users to control how the parser handles
## various HTML constructs and errors, making it suitable for both strict and lenient parsing scenarios,
## such as validating HTML or parsing real-world HTML (Markdown, web scraping, etc.)

import std/[strutils, tables, options, memfiles]
import ./json

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

#
# Parser
#
type
  HtmlTokenKind* = enum
    tkText
    tkTagOpen
    tkTagClose
    tkSelfClosingTag
    tkAttributeName
    tkAttributeValue
    tkComment
    tkDoctype
    tkProcessingInstruction
    tkCdata
    tkEntity
    tkRawText
    tkEOF

  HtmlLexer* = object
    ## The lexer is responsible for tokenizing the input HTML string
    input: string
    data: ptr UncheckedArray[char]
    len: int
    pos: int
    line, col: int
    current: char
    inTag: bool

  HtmlToken* = object
    ## Represents a single token produced by the lexer, with its kind,
    ## value and position for error reporting.
    kind: HtmlTokenKind
    value: string
    line, col, pos: int

  HtmlParserPolicy* = object
    ## The parsing policy controls how the parser handles various HTML
    ## constructs and errors.
    allowSelfClosingTags*: bool
      ## Whether to allow self-closing tags like `<br/>` or `<img />`. If false, these will be treated as syntax errors.
    allowUnclosedTags*: bool
      ## Whether to allow unclosed tags (e.g., `<div><p>Text</div>`). If false, the parser will raise an error on mismatched tags.
    allowComments*: bool
      ## Whether to allow HTML comments (`<!-- comment -->`). If false, comments will be treated as syntax errors.
    allowDoctype*: bool
      ## Whether to allow DOCTYPE declarations (e.g., `<!DOCTYPE html>`). If false, these will be treated as syntax errors.
    allowProcessingInstructions*: bool # e.g., <?xml version="1.0"?>
      ## Whether to allow processing instructions (e.g., `<?xml version="1.0"?>`). If false, these will be treated as syntax errors.
    allowCdata*: bool
      ## Whether to allow CDATA sections (e.g., `<![CDATA[ ... ]]>`). If false, these will be treated as syntax errors.
    allowScriptAndStyleContent*: bool
      ## Whether to allow raw text content inside `<script>` and `<style>` tags without parsing it as HTML. If false, the parser will attempt to parse the content of these tags as normal HTML, which may lead to errors if it contains characters that are not valid in HTML.
    allowEntities*: bool
      ## Whether to allow HTML entities (e.g., `&amp;`, `&lt;`, `&gt;`). If false, entities will be treated as syntax errors.
    allowRawText*: bool
      ## Whether to allow raw text content (e.g., text that is not inside any tags). If false, the parser will raise an error if it encounters text outside of tags.
    allowHtmlInAttributes*: bool
      ## Whether to allow HTML tags inside attribute values (e.g., `<div title="<b>bold</b>">`). If false, the parser will treat `<` and `>` characters inside attribute values as syntax errors.
    allowUnquotedAttributes*: bool
      ## Whether to allow unquoted attribute values (e.g., `<input type=text>`). If false, the parser will require all attribute values to be quoted and will raise an error if it encounters an unquoted attribute value.
    allowDuplicateAttributes*: bool
      ## Whether to allow duplicate attributes on the same tag (e.g., `<input type="text" type="password">`). If false, the parser will raise an error if it encounters duplicate attribute names within the same tag.
    allowInvalidTags*: bool
      ## Whether to allow invalid tag names (e.g., `<123>`, `<div!>`, `<div class="foo" id=bar>`). If false, the parser will raise an error if it encounters a tag name that does not conform to standard HTML tag naming rules.
    allowInvalidAttributeNames*: bool
      ## Whether to allow invalid attribute names (e.g., `<div 123="value">`, `<div class!>`, `<div class="foo" id=bar>`). If false, the parser will raise an error if it encounters an attribute name that does not conform to standard HTML attribute naming rules.
    allowInvalidAttributeValues*: bool
      ## Whether to allow invalid attribute values (e.g., unquoted values, values with illegal characters, etc.). If false, the parser will raise an error if it encounters an attribute value that does not conform to standard HTML attribute value rules.
    allowInvalidNesting*: bool
      ## Whether to allow invalid nesting of tags (e.g., `<div><p></div></p>`). If false, the parser will raise an error if it encounters tags that are not properly nested according to HTML rules.
    allowInvalidSyntax*: bool
      ## Whether to allow other forms of invalid syntax that don't fit into the above categories. If false, the parser will raise an error on any syntax that it considers invalid according to standard HTML parsing rules.

  HtmlParser* = object
    ## The parser maintains the current state of parsing, including the lexer,
    ## current and lookahead tokens, the document being built, and the parsing policy
    lexer: HtmlLexer
      # the lexer instance responsible for tokenizing the input HTML string
    prev, curr, next: HtmlToken
      # prev, curr, and next tokens for lookahead and error reporting
    document: HtmlDocument
      # the current document being built during parsing (root node containing all parsed nodes)
    policy: HtmlParserPolicy
      # parsing policy that controls how the parser handles various HTML constructs and errors

  HtmlParserError* = object of CatchableError
    ## Represents an error that occurs during HTML parsing

const
  invalidToken* = "Invalid token `$1`"
  errorEndOfFile* = "Unexpected EOF while parsing `$1`"
  unexpectedToken* = "Unexpected token `$1`"
  unexpectedTokenExpected* = "Got `$1`, expected $2"
  unexpectedChar* = "Unexpected character `$1`"

proc charAt(l: HtmlLexer, idx: int): char {.inline.} =
  # Safely get the character at the specified index, returning '\0' if out of bounds.
  if idx < 0 or idx >= l.len: return '\0'
  if l.data != nil: l.data[idx] else: l.input[idx]

proc slice(l: HtmlLexer, start, `end`: int): string =
  # Build a string from lexer positions, works for both string and memfile input.
  result = newString(max(0, `end` - start))
  for i in 0 ..< result.len:
    result[i] = l.charAt(start + i)

proc getContext(l: HtmlLexer, posOverride: int = -1): string =
  # Show the full current line and place caret at exact token position.
  let rawPos = if posOverride >= 0: posOverride else: l.pos
  let atPos = max(0, min(rawPos, l.len))

  var lineStart = atPos
  while lineStart > 0 and l.charAt(lineStart - 1) != '\n':
    dec lineStart

  var lineEnd = atPos
  while lineEnd < l.len and l.charAt(lineEnd) notin {'\n', '\r'}:
    inc lineEnd

  var snippet: string
  if l.input.len > 0:
    snippet = l.input[lineStart ..< lineEnd]
  else:
    snippet = newStringOfCap(max(0, lineEnd - lineStart))
    for i in lineStart ..< lineEnd:
      snippet.add(l.charAt(i))

  let markerPos = max(0, min(snippet.len, atPos - lineStart))
  result = snippet & "\n" & " ".repeat(markerPos) & "^"

proc advance(l: var HtmlLexer) =
  if l.pos < l.len - 1:
    inc l.pos
    l.current = l.charAt(l.pos)
    inc l.col
  else:
    l.pos = l.len
    l.current = '\0'

proc skipWhitespace(l: var HtmlLexer) =
  while true:
    case l.current
    of {' ', '\t', '\n', '\r'}:
      if l.current == '\n':
        inc l.line
        l.col = 0
      advance(l)
    else: break

proc error*(l: var HtmlLexer, msg: string) =
  # Raise a lexer error
  let context = getContext(l)
  raise newException(HtmlParserError, ("\n" & context & "\n" & "Error ($1:$2) " % [$l.line, $l.col]) & msg)

proc error*(p: var HtmlParser, msg: string) =
  # Prefer current token coordinates over lexer cursor (lookahead-safe).
  var atPos = p.lexer.pos
  var atLine = p.lexer.line
  var atCol = p.lexer.col

  atPos = p.curr.pos
  atLine = p.curr.line
  atCol = p.curr.col

  let context = getContext(p.lexer, atPos)
  raise newException(
    HtmlParserError,
    ("\n" & context & "\n" & "Error ($1:$2) " % [$atLine, $atCol]) & msg
  )

proc isMapped*(m: MemFile): bool {.inline.} =
  ## True when this MemFile currently has a valid mapped region.
  m.mem != nil and m.size > 0

proc nextToken(l: var HtmlLexer): HtmlToken =
  # Lex the next token from the input and return it
  skipWhitespace(l)
  result = HtmlToken(line: l.line, col: l.col, pos: l.pos)
  case l.current:
  of '\0':
    result.kind = tkEOF
  of '<':
    if l.charAt(l.pos + 1) == '/':
      advance(l)
      advance(l)
      result.kind = tkTagClose
      l.inTag = true
    elif l.charAt(l.pos + 1) == '!' and l.charAt(l.pos + 2) == '-' and l.charAt(l.pos + 3) == '-':
      advance(l); advance(l); advance(l); advance(l)
      var commentStart = l.pos
      while not (l.charAt(l.pos) == '-' and l.charAt(l.pos + 1) == '-' and l.charAt(l.pos + 2) == '>'):
        if l.current == '\0':
          # Unterminated comment – treat rest of input as comment body.
          result.kind = tkComment
          result.value = l.slice(commentStart, l.pos)
          return result
        advance(l)
      result.kind = tkComment
      result.value = l.slice(commentStart, l.pos)
      advance(l); advance(l); advance(l)
    else:
      advance(l)
      result.kind = tkTagOpen
      l.inTag = true

    if result.kind in {tkTagOpen, tkTagClose}:
      var start = l.pos
      while l.charAt(l.pos) notin {' ', '\t', '\n', '\r', '/', '>', '\0'}:
        advance(l)
      result.pos = start
      result.value = l.slice(start, l.pos)
  of '>':
    result.kind = tkTagClose
    l.inTag = false   # leaving the tag
    advance(l)
  of '/':
    if l.charAt(l.pos + 1) == '>':
      result.kind = tkSelfClosingTag
      l.inTag = false
      advance(l)
    else:
      result.kind = tkText
      result.value = "/"
      advance(l)
  of '"', '\'':
    if l.inTag:
      # inside a tag — treat as a quoted attribute value
      let quote = l.current
      result.kind = tkAttributeValue
      var valueStart = l.pos + 1
      var valueEnd = valueStart
      while l.charAt(valueEnd) != quote:
        if l.charAt(valueEnd) in {'\0', '<', '>'}:
          # Unterminated attribute value – emit partial value and stop.
          result.value = l.slice(valueStart, valueEnd)
          l.pos = valueEnd
          l.current = l.charAt(l.pos)
          l.inTag = false
          return result
        inc valueEnd
      result.value = l.slice(valueStart, valueEnd)
      l.pos = valueEnd + 1
      l.col += (valueEnd - valueStart) + 2
      l.current = l.charAt(l.pos)
    else:
      # outside a tag — just plain text content
      var start = l.pos
      while l.charAt(l.pos) notin {'<', '>', '\0'}:
        advance(l)
      result.kind = tkText
      result.value = l.slice(start, l.pos)
  of '=':
    # Emit '=' as its own token so attribute names don't include the '=' char.
    result.kind = tkText
    result.value = "="
    advance(l)
  else:
    # Text or unquoted attribute name
    var start = l.pos
    while l.charAt(l.pos) notin {'<', '>', '/', '"', '\'', '=', ' ', '\t', '\n', '\r'} and l.charAt(l.pos) != '\0':
      advance(l)
    result.value = l.slice(start, l.pos)
    if result.kind == tkTagOpen and result.value.len > 0:
      # The first token after a tag open is the tag name
      result.kind = tkTagOpen
    elif result.kind == tkTagClose and result.value.len > 0:
      # The first token after a tag close is the tag name
      result.kind = tkTagClose
    elif result.value.len > 0:
      result.kind = tkText
    else:
      result.kind = tkText
#
# Parsing
#
proc advance*(p: var HtmlParser): HtmlToken {.discardable.} =
  # Advance to the next token and return it
  p.prev = p.curr
  p.curr = p.next
  p.next = p.lexer.nextToken()
  result = p.curr

proc expectWalk*(p: var HtmlParser, expectedKind: HtmlTokenKind) =
  # Expect the current token to be of a specific kind, then advance
  if p.curr.kind != expectedKind:
    p.error("Expected token of kind $1 but got $2" % [$expectedKind, $p.curr.kind])
  p.advance()

proc parseInnerText(p: var HtmlParser): HtmlNode =
  # Parse a text node and return it as a single HtmlNode that
  # combines consecutive tkText tokens into one string.
  var buf = newStringOfCap(64)
  var first = true
  while p.curr.kind == tkText:
    if not first:
      # lexer strips whitespace, so insert a single space between tokens
      buf.add(' ')
    buf.add(p.curr.value)
    first = false
    discard p.advance()
  result = HtmlNode(kind: htmlInnerText,
                    value: HtmlInnerText(text: buf))

proc parseAttributes(p: var HtmlParser, node: var HtmlNode) =
  ## Parse attribute name/value pairs after the tag name.
  ## Stops when we hit `>` , `/>` or EOF.
  if p.curr.kind notin {tkTagClose, tkSelfClosingTag, tkEOF}:
    # Initialize the attributes table if we have any attributes to
    # parse, so we don't create an empty table for elements without attributes.
    node.attributes = newTable[string, string]()

    # Parse attributes until we reach the end of the tag (indicated by '>' or '/>') or EOF.
    while p.curr.kind notin {tkTagClose, tkSelfClosingTag, tkEOF}:
      # Accept both explicit attribute-name token (if produced) and plain text tokens
      # which the lexer currently emits for unquoted attribute names.
      if p.curr.kind in {tkAttributeName, tkText}:
        var name = p.curr.value
        discard p.advance()
        
        # Skip stray '=' tokens (lexer may have emitted '=' as tkText)
        if p.curr.kind == tkText and p.curr.value == "=":
          discard p.advance()

        var value = ""
        if p.curr.kind == tkAttributeValue:
          value = p.curr.value
          discard p.advance()
        elif p.curr.kind == tkText:
          # Unquoted attribute value (e.g., attr=value)
          value = p.curr.value
          discard p.advance()

        if name.len > 0:
          node.attributes[name] = value
      else:
        # Unexpected token – just skip it (policy could raise an error)
        discard p.advance()

proc parseElement(p: var HtmlParser): HtmlNode =
  # Parse an HTML element, its attributes and all nested children.
  # Returns the constructed `HtmlNode`.
  let tagName = p.curr.value
  discard p.advance()               # move past the tag‑name token

  # Create the node for this element.
  var node = HtmlNode(kind: htmlTag, tag: getHtmlTag(tagName))

  parseAttributes(p, node)
  if p.curr.kind == tkSelfClosingTag:
    # `<br/>` style – consume `/>` and finish.
    discard p.advance()
    if p.curr.kind == tkTagClose:   # consume the trailing `>`
      discard p.advance()
    return node

  # Normal opening tag – consume the `>` that ends the start‑tag.
  if p.curr.kind == tkEOF:
    # Unterminated tag at EOF – silently close.
    discard
  elif p.curr.kind == tkTagClose and p.curr.value.len == 0:
    discard p.advance()
  else:
    # Missing `>` – policy may allow it, otherwise raise.
    if not p.policy.allowInvalidSyntax:
      p.error("Expected '>' after start tag")
    # Attempt to continue anyway.
    discard p.advance()

  # Void elements (br, hr, img, input, etc.) have no children or closing tag.
  if node.isSelfClosing:
    return node

  while p.curr.kind != tkEOF:
    # Closing tag for this element?
    if p.curr.kind == tkTagClose and p.curr.value == tagName:
      discard p.advance()                     # consume the tag name
      if p.curr.kind == tkTagClose and p.curr.value.len == 0:
        discard p.advance()                   # consume the trailing `>`
      break

    # Stray `>` that closes the opening tag (e.g. `<br>`).
    if p.curr.kind == tkTagClose and p.curr.value.len == 0:
      discard p.advance()
      continue

    case p.curr.kind
    of tkText:
      let child = p.parseInnerText()
      node.children.add(child)
    of tkTagOpen:
      let child = p.parseElement()
      node.children.add(child)
    of tkComment:
      if p.policy.allowComments:
        let child = HtmlNode(kind: htmlComment, comment: p.curr.value)
        node.children.add(child)
      discard p.advance()
    else:
      # Unexpected token – skip it (or raise based on policy).
      discard p.advance()

  # Reached EOF without finding the matching closing tag.
  if p.curr.kind == tkEOF and not p.policy.allowUnclosedTags:
    p.error("Unclosed tag: <" & tagName & ">")

  result = node

proc parseNodes(p: var HtmlParser) =
  # Parses a sequence of HTML nodes until the end of input or a closing tag.
  while p.curr.kind != tkEOF:
    case p.curr.kind
    of tkText:
      let node = p.parseInnerText()
      p.document.nodes.add(node)
    of tkTagOpen:
      let node = p.parseElement()
      p.document.nodes.add(node)
    of tkComment:
      if p.policy.allowComments:
        let node = HtmlNode(kind: htmlComment, comment: p.curr.value)
        p.document.nodes.add(node)
      discard p.advance()
    else:
      # Stray token (e.g. bare `>`) – skip it.
      discard p.advance()

proc defaulHtmlParsingPolicy*(): HtmlParserPolicy

proc parseHtmlFile*(path: string, policy: HtmlParserPolicy = defaulHtmlParsingPolicy()): HtmlDocument =
  ## Parses the HTML content of the specified file according to the given policy
  ## and returns the resulting parse tree.
  var mf: MemFile = memfiles.open(path, fmRead)
  defer: mf.close()
  var p = HtmlParser(
    lexer: HtmlLexer(data: cast[ptr UncheckedArray[char]](mf.mem), len: mf.size, line: 1, col: 1),
    document: HtmlDocument(),
    policy: policy,
  )
  p.lexer.current = p.lexer.charAt(p.lexer.pos)
  p.curr = p.lexer.nextToken()
  p.next = p.lexer.nextToken()
  p.parseNodes()
  result = p.document

proc defaulHtmlParsingPolicy*: HtmlParserPolicy =
  ## Returns a default HTML parser policy with common settings for typical HTML parsing.
  result = HtmlParserPolicy(
    allowSelfClosingTags: true,
    allowUnclosedTags: true,
    allowComments: true,
    allowDoctype: true,
    allowProcessingInstructions: false,
    allowCdata: false,
    allowScriptAndStyleContent: true,
    allowEntities: true,
    allowRawText: false,
    allowHtmlInAttributes: false,
    allowUnquotedAttributes: false,
    allowDuplicateAttributes: false,
    allowInvalidTags: false,
    allowInvalidAttributeNames: false,
    allowInvalidAttributeValues: false,
    allowInvalidNesting: false,
    allowInvalidSyntax: false
  )

proc parseHtml*(input: string, policy: HtmlParserPolicy = defaulHtmlParsingPolicy()): HtmlDocument =
  ## Parses the given HTML string according to the specified policy
  ## and returns the root node of the resulting parse tree.
  var p = HtmlParser(
    lexer: HtmlLexer(input: input, data: nil, len: input.len, line: 1, col: 1),
    document: HtmlDocument(),
    policy: policy,
  )
  p.lexer.current = p.lexer.charAt(p.lexer.pos)
  p.curr = p.lexer.nextToken()
  p.next = p.lexer.nextToken()
  
  # Start parsing the document
  p.parseNodes()
  result = p.document

when isMainModule:
  let html = """
    <html>
      <head><title>Test<span></span></title></head>
      <body>
        <h1 title="something here">Hello, World!</h1>
        <!--<p>This is a test.</p>-->
      </body>
    </html>
  """
  let root = parseHtml(html)
  echo toJson(root)