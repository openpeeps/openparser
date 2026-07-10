import std/[strutils, sequtils]

type
  SyntaxKind* = enum
    skKeyword
    skType
    skFunction
    skPropertyRef
    skString
    skNumeric
    skTokenRef
    skDelim
    skGroup
    skAlternatives
    skAtLeastOne
    skAll
    skJuxtapose
    skOptional
    skZeroOrMore
    skOneOrMore
    skCommaSep
    skRequired
    skMulti

  SyntaxNode* = ref object
    case kind*: SyntaxKind
    of skKeyword:
      kw*: string
    of skType:
      cssType*: string
    of skFunction:
      cssFunc*: string
    of skPropertyRef:
      propRef*: string
    of skString:
      str*: string
    of skNumeric:
      numeric*: string
    of skTokenRef:
      tokenType*: string
    of skDelim:
      delim*: string
    of skGroup:
      group*: SyntaxNode
    of skAlternatives:
      alternatives*: seq[SyntaxNode]
    of skAtLeastOne:
      options*: seq[SyntaxNode]
    of skAll:
      required*: seq[SyntaxNode]
    of skJuxtapose:
      sequence*: seq[SyntaxNode]
    of skOptional:
      optionalInner*: SyntaxNode
    of skZeroOrMore:
      starInner*: SyntaxNode
    of skOneOrMore:
      plusInner*: SyntaxNode
    of skCommaSep:
      hashInner*: SyntaxNode
    of skRequired:
      bangInner*: SyntaxNode
    of skMulti:
      multiInner*: SyntaxNode
      multiMin*, multiMax*: int

  SyntaxLexer = object
    input: string
    pos: int
    current: char

  SyntaxTokenKind = enum
    stkIdent
    stkType
    stkFunction
    stkPropertyRef
    stkString
    stkNumber
    stkTokenRef
    stkPipe
    stkDoublePipe
    stkDoubleAmp
    stkLBracket
    stkRBracket
    stkQuestion
    stkBang
    stkHash
    stkStar
    stkDelim
    stkPlus
    stkComma
    stkLBrace
    stkRBrace
    stkEOF

  SyntaxToken = object
    kind: SyntaxTokenKind
    value: string

proc initSyntaxLexer(input: string): SyntaxLexer =
  SyntaxLexer(input: input, pos: 0, current: if input.len > 0: input[0] else: '\0')

proc advance(l: var SyntaxLexer) =
  if l.pos < l.input.len - 1:
    inc l.pos
    l.current = l.input[l.pos]
  else:
    l.pos = l.input.len
    l.current = '\0'

proc peek(l: var SyntaxLexer, offset: int = 0): char =
  let idx = l.pos + offset
  if idx < 0 or idx >= l.input.len: '\0' else: l.input[idx]

proc skipWhitespace(l: var SyntaxLexer) =
  while l.current in {' ', '\t', '\n', '\r', '\f'}:
    l.advance()

proc nextToken(l: var SyntaxLexer): SyntaxToken =
  l.skipWhitespace()
  if l.current == '\0':
    return SyntaxToken(kind: stkEOF)

  # Property reference: <'name'>
  if l.current == '<' and l.peek(1) == '\'':
    l.advance(); l.advance() # skip <'
    var value = ""
    while l.current != '\'' and l.current != '\0':
      value.add(l.current)
      l.advance()
    if l.current == '\'':
      l.advance()
    if l.current == '>':
      l.advance()
    return SyntaxToken(kind: stkPropertyRef, value: value)

  # Type reference: <name> or <name [constraints]>
  if l.current == '<':
    l.advance()
    var value = ""
    while l.current notin {'>', '\0'}:
      value.add(l.current)
      l.advance()
    if l.current == '>':
      l.advance()
    value = value.strip()
    if value.endsWith(")"):
      value.setLen(value.len - 1)
      let parenIdx = value.find('(')
      if parenIdx >= 0:
        return SyntaxToken(kind: stkFunction, value: value[0..<parenIdx])
    else:
      let bracketPos = value.find('[')
      if bracketPos >= 0:
        value = value[0..<bracketPos].strip()
    return SyntaxToken(kind: stkType, value: value)

  # String literal: '...'
  if l.current == '\'':
    l.advance()
    var value = ""
    while l.current != '\'' and l.current != '\0':
      value.add(l.current)
      l.advance()
    if l.current == '\'':
      l.advance()
    return SyntaxToken(kind: stkString, value: value)

  if l.current == '[':
    l.advance()
    return SyntaxToken(kind: stkLBracket, value: "[")

  if l.current == ']':
    l.advance()
    return SyntaxToken(kind: stkRBracket, value: "]")

  if l.current == '{':
    l.advance()
    var value = ""
    while l.current notin {'}', '\0'}:
      value.add(l.current)
      l.advance()
    if l.current == '}':
      l.advance()
    return SyntaxToken(kind: stkLBrace, value: value)

  if l.current == ',':
    l.advance()
    return SyntaxToken(kind: stkComma, value: ",")

  if l.current == '|':
    if l.peek(1) == '|':
      l.advance(); l.advance()
      return SyntaxToken(kind: stkDoublePipe, value: "||")
    else:
      l.advance()
      return SyntaxToken(kind: stkPipe, value: "|")

  if l.current == '&':
    if l.peek(1) == '&':
      l.advance(); l.advance()
      return SyntaxToken(kind: stkDoubleAmp, value: "&&")

  if l.current == '?':
    l.advance()
    return SyntaxToken(kind: stkQuestion, value: "?")

  if l.current == '!':
    l.advance()
    return SyntaxToken(kind: stkBang, value: "!")

  if l.current == '#':
    l.advance()
    return SyntaxToken(kind: stkHash, value: "#")

  if l.current == '+':
    l.advance()
    return SyntaxToken(kind: stkPlus, value: "+")

  if l.current == '*':
    l.advance()
    return SyntaxToken(kind: stkStar, value: "*")

  if l.current.isDigit() or (l.current == '.' and l.peek(1).isDigit()):
    var value = ""
    while l.current.isDigit() or l.current == '.' or l.current in {'e', 'E', '+', '-'}:
      value.add(l.current)
      l.advance()
      if l.current in {'e', 'E'} and value[^1] notin {'e', 'E'}:
        continue
    return SyntaxToken(kind: stkNumber, value: value)

  if l.current.isAlphaNumeric() or l.current in {'-', '_'}:
    var value = ""
    while l.current.isAlphaNumeric() or l.current in {'-', '_'}:
      value.add(l.current)
      l.advance()
    return SyntaxToken(kind: stkIdent, value: value)

  let ch = $l.current
  l.advance()
  return SyntaxToken(kind: stkDelim, value: ch)

type
  SyntaxParser = object
    tokens: seq[SyntaxToken]
    pos: int

proc initSyntaxParser(tokens: seq[SyntaxToken]): SyntaxParser =
  SyntaxParser(tokens: tokens, pos: 0)

proc curr(p: SyntaxParser): SyntaxToken =
  if p.pos < p.tokens.len: p.tokens[p.pos] else: SyntaxToken(kind: stkEOF)

proc next(p: var SyntaxParser) =
  if p.pos < p.tokens.len: inc p.pos

proc parseAlternatives(p: var SyntaxParser): SyntaxNode

proc parseMulti(p: var SyntaxParser): SyntaxNode =
  if p.curr.kind == stkLBrace:
    let val = p.curr.value
    let parts = val.split(',')
    var minV = 0
    var maxV = 0
    try:
      if parts.len == 1:
        minV = parseInt(parts[0])
        maxV = minV
      elif parts.len == 2:
        minV = parseInt(parts[0])
        maxV = parseInt(parts[1])
      else:
        return nil
    except ValueError:
      return nil
    p.next()
    return SyntaxNode(kind: skMulti, multiInner: nil, multiMin: minV, multiMax: maxV)

proc parseJuxtapose(p: var SyntaxParser): SyntaxNode

proc parseModifier(p: var SyntaxParser, node: SyntaxNode): SyntaxNode =
  case p.curr.kind
  of stkQuestion:
    p.next()
    SyntaxNode(kind: skOptional, optionalInner: node)
  of stkBang:
    p.next()
    SyntaxNode(kind: skRequired, bangInner: node)
  of stkHash:
    p.next()
    SyntaxNode(kind: skCommaSep, hashInner: node)
  of stkPlus:
    p.next()
    SyntaxNode(kind: skOneOrMore, plusInner: node)
  of stkStar:
    p.next()
    SyntaxNode(kind: skZeroOrMore, starInner: node)
  of stkLBrace:
    let multi = parseMulti(p)
    if multi != nil:
      SyntaxNode(kind: skMulti, multiInner: node, multiMin: multi.multiMin, multiMax: multi.multiMax)
    else:
      p.next() # skip invalid multi spec
      node
  else:
    node

proc parseAtom(p: var SyntaxParser): SyntaxNode =
  case p.curr.kind
  of stkIdent:
    let node = SyntaxNode(kind: skKeyword, kw: p.curr.value)
    p.next()
    result = parseModifier(p, node)
  of stkType:
    let node = SyntaxNode(kind: skType, cssType: p.curr.value)
    p.next()
    result = parseModifier(p, node)
  of stkFunction:
    let node = SyntaxNode(kind: skFunction, cssFunc: p.curr.value)
    p.next()
    result = parseModifier(p, node)
  of stkPropertyRef:
    let node = SyntaxNode(kind: skPropertyRef, propRef: p.curr.value)
    p.next()
    result = parseModifier(p, node)
  of stkString:
    let node = SyntaxNode(kind: skString, str: p.curr.value)
    p.next()
    result = parseModifier(p, node)
  of stkNumber:
    let node = SyntaxNode(kind: skNumeric, numeric: p.curr.value)
    p.next()
    result = parseModifier(p, node)
  of stkLBracket:
    p.next() # skip [
    let inner = parseAlternatives(p)
    if p.curr.kind == stkRBracket:
      p.next()
    result = parseModifier(p, SyntaxNode(kind: skGroup, group: inner))
  of stkComma:
    let node = SyntaxNode(kind: skDelim, delim: ",")
    p.next()
    result = parseModifier(p, node)
  of stkDelim:
    let node = SyntaxNode(kind: skDelim, delim: p.curr.value)
    p.next()
    result = parseModifier(p, node)
  else:
    discard
  while result != nil and p.curr.kind in {stkQuestion, stkBang, stkHash, stkPlus, stkStar, stkLBrace}:
    result = parseModifier(p, result)

proc parseJuxtapose(p: var SyntaxParser): SyntaxNode =
  var items: seq[SyntaxNode] = @[]
  let first = parseAtom(p)
  if first == nil: return nil
  items.add(first)
  while true:
    if p.curr.kind in {stkRBracket, stkPipe, stkDoublePipe, stkDoubleAmp, stkEOF}:
      break
    let next = parseAtom(p)
    if next == nil: break
    items.add(next)
  if items.len == 1:
    items[0]
  else:
    SyntaxNode(kind: skJuxtapose, sequence: items)

proc parseAll(p: var SyntaxParser): SyntaxNode =
  var items: seq[SyntaxNode] = @[]
  let first = parseJuxtapose(p)
  if first == nil: return nil
  items.add(first)
  while p.curr.kind == stkDoubleAmp:
    p.next()
    let node = parseJuxtapose(p)
    if node != nil:
      items.add(node)
    if p.curr.kind == stkRBracket:
      break
  if items.len == 1:
    items[0]
  else:
    SyntaxNode(kind: skAll, required: items)

proc parseAtLeastOne(p: var SyntaxParser): SyntaxNode =
  var items: seq[SyntaxNode] = @[]
  let first = parseAll(p)
  if first == nil: return nil
  items.add(first)
  while p.curr.kind == stkDoublePipe:
    p.next()
    let node = parseAll(p)
    if node != nil:
      items.add(node)
  if items.len == 1:
    items[0]
  else:
    SyntaxNode(kind: skAtLeastOne, options: items)

proc parseAlternatives(p: var SyntaxParser): SyntaxNode =
  var items: seq[SyntaxNode] = @[]
  let first = parseAtLeastOne(p)
  if first == nil: return nil
  items.add(first)
  while p.curr.kind == stkPipe:
    p.next()
    let node = parseAtLeastOne(p)
    if node != nil:
      items.add(node)
    if p.curr.kind == stkRBracket:
      break
  if items.len == 1:
    items[0]
  else:
    SyntaxNode(kind: skAlternatives, alternatives: items)

proc parseSyntax*(input: string): SyntaxNode =
  var lexer = initSyntaxLexer(input)
  var tokens: seq[SyntaxToken] = @[]
  while true:
    let tok = lexer.nextToken()
    if tok.kind == stkEOF: break
    if tok.kind != stkEOF:
      tokens.add(tok)
  var parser = initSyntaxParser(tokens)
  result = parseAlternatives(parser)
  if result == nil:
    result = SyntaxNode(kind: skKeyword, kw: "")

proc `$`*(node: SyntaxNode): string =
  if node == nil: return ""
  case node.kind
  of skKeyword: node.kw
  of skType: "<" & node.cssType & ">"
  of skFunction: "<" & node.cssFunc & "()>"
  of skPropertyRef: "<'" & node.propRef & "'>"
  of skString: "'" & node.str & "'"
  of skNumeric: node.numeric
  of skTokenRef: "<" & node.tokenType & "-token>"
  of skGroup: "[" & $node.group & "]"
  of skAlternatives:
    node.alternatives.mapIt($it).join(" | ")
  of skAtLeastOne:
    node.options.mapIt($it).join(" || ")
  of skAll:
    node.required.mapIt($it).join(" && ")
  of skJuxtapose:
    node.sequence.mapIt($it).join(" ")
  of skDelim: node.delim
  of skOptional:
    $node.optionalInner & "?"
  of skZeroOrMore:
    $node.starInner & "*"
  of skOneOrMore:
    $node.plusInner & "+"
  of skCommaSep:
    $node.hashInner & "#"
  of skRequired:
    $node.bangInner & "!"
  of skMulti:
    $node.multiInner & "{" & $node.multiMin & "," & $node.multiMax & "}"
