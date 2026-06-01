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
## various HTML constructs and errors, making it suitable for both strict and lenient parsing scenarios.

import std/[strutils, tables, options, memfiles]
import ./json, ./html/ast

export HtmlTag, getHtmlTag, innerText

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
    allowSelfClosingTags: bool
    allowUnclosedTags: bool
    allowComments: bool
    allowDoctype: bool
    allowProcessingInstructions: bool # e.g., <?xml version="1.0"?>
    allowCdata: bool
    allowScriptAndStyleContent: bool
    allowEntities: bool
    allowRawText: bool
    allowHtmlInAttributes: bool
    allowUnquotedAttributes: bool
    allowDuplicateAttributes: bool
    allowInvalidTags: bool
    allowInvalidAttributeNames: bool
    allowInvalidAttributeValues: bool
    allowInvalidNesting: bool
    allowInvalidSyntax: bool

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
  if idx < 0 or idx >= l.len: return '\0'
  if l.data != nil: l.data[idx] else: l.input[idx]

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
          l.error("Unterminated comment")
        advance(l)
      result.kind = tkComment
      result.value = l.input[commentStart ..< l.pos]
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
      result.value = l.input[start ..< l.pos]
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
        if l.charAt(valueEnd) == '\0':
          l.error("Unterminated attribute value")
        inc valueEnd
      result.value = l.input[valueStart ..< valueEnd]
      l.pos = valueEnd + 1
      l.col += (valueEnd - valueStart) + 2
      l.current = l.charAt(l.pos)
    else:
      # outside a tag — just plain text content
      var start = l.pos
      while l.charAt(l.pos) notin {'<', '>', '\0'}:
        advance(l)
      result.kind = tkText
      result.value = l.input[start ..< l.pos]
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
    result.value = l.input[start ..< l.pos]
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
  ## Parse an HTML element, its attributes and all nested children.
  ## Returns the constructed `HtmlNode`.
  let tagName = p.curr.value
  discard p.advance()               # move past the tag‑name token

  # Create the node for this element.
  var node = HtmlNode(kind: htmlTag, tag: parseEnum[HtmlTag](tagName))

  parseAttributes(p, node)
  if p.curr.kind == tkSelfClosingTag:
    # `<br/>` style – consume `/>` and finish.
    discard p.advance()
    if p.curr.kind == tkTagClose:   # consume the trailing `>`
      discard p.advance()
    return node

  # Normal opening tag – consume the `>` that ends the start‑tag.
  if p.curr.kind == tkTagClose and p.curr.value.len == 0:
    discard p.advance()
  else:
    # Missing `>` – policy may allow it, otherwise raise.
    if not p.policy.allowInvalidSyntax:
      p.error("Expected '>' after start tag")
    # Attempt to continue anyway.
    discard p.advance()

  while p.curr.kind != tkEOF:
    # Closing tag for this element?
    if p.curr.kind == tkTagClose and p.curr.value == tagName:
      discard p.advance()                     # consume the tag name
      if p.curr.kind == tkTagClose and p.curr.value.len == 0:
        discard p.advance()                   # consume the trailing `>`
      break

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

  result = node

proc parseNodes(p: var HtmlParser) =
  ## Parses a sequence of HTML nodes until the end of input or a closing tag.
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
    else: discard

proc parseHtmlFile*(path: string, policy: HtmlParserPolicy): HtmlNode =
  ## Parses the HTML content of the specified file according to the given policy
  ## and returns the root node of the resulting parse tree.
  var mf: MemFile = memfiles.open(path, fmRead)
  defer: mf.close()
  var p = HtmlParser(lexer: HtmlLexer(data: cast[ptr UncheckedArray[char]](mf.mem), len: mf.size, line: 1, col: 1))

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
  echo input
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