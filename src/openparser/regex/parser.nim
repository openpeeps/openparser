# A collection of tiny parsers and dumpers
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/openparser

import std/strutils
import ./lexer

type
  RegexNodeKind* = enum
    rnChar          # literal character: 'a'
    rnEscaped       # escape sequence: \d \w \s \D etc.
    rnDot           # any character: .
    rnAnchorStart   # ^
    rnAnchorEnd     # $
    rnConcat        # AB
    rnAlternation   # A|B
    rnGroup         # (A)
    rnCharClass     # [abc] [^a-z]
    rnQuantifier    # A{n,m}  A*  A+  A?

  RegexQuantifierKind* = enum
    rqStar          # *  → {0, ∞}
    rqPlus          # +  → {1, ∞}
    rqQuestion      # ?  → {0, 1}
    rqRange         # {n,m}

  RegexNode* {.acyclic.} = ref object
    line*, col*, pos*: int
    case kind*: RegexNodeKind
    of rnChar:
      ch*: char
    of rnEscaped:
      escape*: char           # raw char after backslash
    of rnDot, rnAnchorStart, rnAnchorEnd:
      discard
    of rnConcat, rnAlternation:
      children*: seq[RegexNode]
    of rnGroup:
      capture*: bool
      index*: int             # capture group index (0 = non-capturing)
      child*: RegexNode
    of rnCharClass:
      negated*: bool
      items*: seq[CharClassItem]
    of rnQuantifier:
      qkind*: RegexQuantifierKind
      min*: int
      max*: int               # -1 = infinity
      lazy*: bool
      operand*: RegexNode

  CharClassItem* {.acyclic.} = object
    case isRange*: bool
    of true:
      lo*, hi*: char
    of false:
      ch*: char

  RegexParser* = object
    lexer*: RegexLexer
    current*: RegexToken
    prev*: RegexToken
    captureCount: int

#
# Helpers
#

proc advance(p: var RegexParser) {.inline.} =
  p.prev = p.current
  p.current = p.lexer.getToken()

proc check(p: RegexParser, kind: RegexTokenKind): bool {.inline.} =
  p.current.kind == kind

proc eat(p: var RegexParser, kind: RegexTokenKind): RegexToken {.discardable.} =
  if p.current.kind != kind:
    p.lexer.error("Expected " & $kind & " but got " & $p.current.kind &
                  " '" & p.current.lexeme & "'")
  result = p.current
  p.advance()

proc atEnd(p: RegexParser): bool {.inline.} =
  p.current.kind in {tkEof, tkNewline}

proc node(kind: RegexNodeKind, tok: RegexToken): RegexNode {.inline.} =
  RegexNode(kind: kind, line: tok.line, col: tok.col, pos: tok.pos)

#
# Forward declaration
#
proc parseAlternation(p: var RegexParser): RegexNode

#
# Character class  [abc]  [^a-z0-9]
#
proc parseCharClass(p: var RegexParser): RegexNode =
  let startTok = p.prev           # already consumed '['
  result = node(rnCharClass, startTok)

  if p.check(tkCaret):
    result.negated = true
    p.advance()

  while not p.check(tkRBracket) and not p.atEnd():
    let loTok = p.current
    var loChar: char

    case loTok.kind
    of tkChar, tkNumber:
      loChar = loTok.lexeme[0]
      p.advance()
    of tkEscaped:
      # Resolve escape sequences inside character classes
      loChar = case loTok.lexeme[0]
        of 'n': '\n'
        of 't': '\t'
        of 'r': '\r'
        of 'f': '\f'
        of 'v': '\v'
        else:   loTok.lexeme[0]
      p.advance()
    of tkDot:
      loChar = '.'
      p.advance()
    else:
      loChar = loTok.lexeme[0]
      p.advance()

    if p.check(tkHyphen):
      p.advance()
      if p.check(tkRBracket):
        result.items.add(CharClassItem(isRange: false, ch: loChar))
        result.items.add(CharClassItem(isRange: false, ch: '-'))
      else:
        let hiTok = p.current
        var hiChar: char
        case hiTok.kind
        of tkChar, tkNumber:
          hiChar = hiTok.lexeme[0]
          p.advance()
        of tkEscaped:
          hiChar = case hiTok.lexeme[0]   # same fix for hi side of range
            of 'n': '\n'
            of 't': '\t'
            of 'r': '\r'
            of 'f': '\f'
            of 'v': '\v'
            else:   hiTok.lexeme[0]
          p.advance()
        else:
          hiChar = hiTok.lexeme[0]
          p.advance()
        if loChar > hiChar:
          p.lexer.error("Character class range out of order: " &
                        $loChar & "-" & $hiChar)
        result.items.add(CharClassItem(isRange: true, lo: loChar, hi: hiChar))
    else:
      result.items.add(CharClassItem(isRange: false, ch: loChar))

  eat(p, tkRBracket)

#
# Quantifier suffix:  *  +  ?  {n}  {n,}  {n,m}
#
proc parseQuantifier(p: var RegexParser, operand: RegexNode): RegexNode =
  let tok = p.current
  result = node(rnQuantifier, tok)
  result.operand = operand

  case tok.kind
  of tkStar:
    p.advance()
    result.qkind = rqStar; result.min = 0; result.max = -1
  of tkPlus:
    p.advance()
    result.qkind = rqPlus; result.min = 1; result.max = -1
  of tkQuestion:
    p.advance()
    result.qkind = rqQuestion; result.min = 0; result.max = 1
  of tkLBrace:
    p.advance()
    result.qkind = rqRange
    let minTok = eat(p, tkNumber)
    result.min = parseInt(minTok.lexeme)
    if p.check(tkComma):
      p.advance()
      if p.check(tkNumber):
        result.max = parseInt(p.current.lexeme)
        p.advance()
      else:
        result.max = -1         # {n,} = n or more
    else:
      result.max = result.min   # {n} = exactly n
    eat(p, tkRBrace)
  else:
    return operand              # no quantifier – return operand unchanged

  # optional lazy modifier
  if p.check(tkQuestion):
    result.lazy = true
    p.advance()

#
# Atom: the smallest unit
#
proc parseAtom(p: var RegexParser): RegexNode =
  let tok = p.current

  case tok.kind
  of tkChar:
    p.advance()
    result = node(rnChar, tok)
    result.ch = tok.lexeme[0]

  of tkNumber:
    p.advance()
    # A number token may be multi-digit (e.g. "1234") outside a quantifier.
    # Expand each digit into a separate rnChar; wrap multi-char in rnConcat.
    if tok.lexeme.len == 1:
      result = node(rnChar, tok)
      result.ch = tok.lexeme[0]
    else:
      var parts: seq[RegexNode]
      for ch in tok.lexeme:
        let n = node(rnChar, tok)
        n.ch = ch
        parts.add(n)
      result = RegexNode(kind: rnConcat, line: tok.line,
                         col: tok.col, pos: tok.pos, children: parts)

  of tkEscaped:
    p.advance()
    result = node(rnEscaped, tok)
    result.escape = tok.lexeme[0]

  of tkDot:
    p.advance()
    result = node(rnDot, tok)

  of tkCaret:
    p.advance()
    result = node(rnAnchorStart, tok)

  of tkDollar:
    p.advance()
    result = node(rnAnchorEnd, tok)

  of tkLParen:
    p.advance()
    # Detect non-capturing group  (?:...)
    if p.current.kind == tkQuestion:
      # Speculatively consume '?' and check for ':'
      p.advance()
      if p.current.kind == tkChar and p.current.lexeme == ":":
        p.advance()   # consume ':'
        let inner = parseAlternation(p)
        eat(p, tkRParen)
        result = node(rnGroup, tok)
        result.capture = false
        result.index   = 0
        result.child   = inner
      else:
        # Not (?:...) — put back by parsing what we have as a quantifier
        # on an empty group is an error; surface it clearly.
        p.lexer.error("Expected ':' after '(?' for non-capturing group, got '" &
                      p.current.lexeme & "'")
    else:
      let captureIdx = p.captureCount
      inc p.captureCount
      let inner = parseAlternation(p)
      eat(p, tkRParen)
      result = node(rnGroup, tok)
      result.capture = true
      result.index   = captureIdx
      result.child   = inner

  of tkLBracket:
    p.advance()
    result = parseCharClass(p)
  
  of tkHyphen:
    # Outside a character class, '-' is just a literal character.
    p.advance()
    result = node(rnChar, tok)
    result.ch = '-'

  else:
    p.lexer.error("Unexpected token '" & tok.lexeme & "' (" & $tok.kind & ")")

#
# Quantified: atom followed by optional quantifier
#
proc parseQuantified(p: var RegexParser): RegexNode =
  var a = parseAtom(p)
  if p.current.kind in {tkStar, tkPlus, tkQuestion, tkLBrace}:
    a = parseQuantifier(p, a)
  return a

#
# Concat: one or more quantified atoms
#
proc parseConcat(p: var RegexParser): RegexNode =
  var parts: seq[RegexNode]
  while not p.atEnd() and
        p.current.kind notin {tkPipe, tkRParen, tkRBracket}:
    let a = parseQuantified(p)
    if a == nil: break
    parts.add(a)

  case parts.len
  of 0: p.lexer.error("Empty expression")
  of 1: return parts[0]
  else:
    result = RegexNode(kind: rnConcat)
    result.children = parts

#
# Alternation: concat ('|' concat)*
#
proc parseAlternation(p: var RegexParser): RegexNode =
  var branches: seq[RegexNode]
  branches.add(parseConcat(p))
  while p.check(tkPipe):
    p.advance()
    branches.add(parseConcat(p))

  case branches.len
  of 1: return branches[0]
  else:
    let tok = branches[0]
    result = RegexNode(kind: rnAlternation,
                       line: tok.line, col: tok.col, pos: tok.pos,
                       children: branches)

#
# Public API
#
proc initRegexParser*(input: string): RegexParser =
  result.lexer = initRegexLexer(input)
  result.current = result.lexer.getToken()

proc initRegexParser*(mf: MemFile): RegexParser =
  result.lexer = initRegexLexer(mf)
  result.current = result.lexer.getToken()

proc parse*(p: var RegexParser): RegexNode =
  # Parse a single regex expression.
  result = parseAlternation(p)
  if not p.atEnd():
    p.lexer.error("Unexpected token after expression: '" & p.current.lexeme & "'")

proc close*(p: var RegexParser) =
  p.lexer.close()

#
# Debug printer
#
proc `$`*(n: RegexNode, indent = 0): string =
  let pad = "  ".repeat(indent)
  case n.kind
  of rnChar:        pad & "Char(" & $n.ch & ")"
  of rnEscaped:     pad & "Escaped(\\" & $n.escape & ")"
  of rnDot:         pad & "Dot"
  of rnAnchorStart: pad & "AnchorStart(^)"
  of rnAnchorEnd:   pad & "AnchorEnd($)"
  of rnConcat:
    var s = pad & "Concat\n"
    for c in n.children: s.add(`$`(c, indent + 1) & "\n")
    s
  of rnAlternation:
    var s = pad & "Alternation\n"
    for c in n.children: s.add(`$`(c, indent + 1) & "\n")
    s
  of rnGroup:
    pad & "Group(capture=" & $n.capture & ", idx=" & $n.index & ")\n" &
    `$`(n.child, indent + 1)
  of rnCharClass:
    var s = pad & "CharClass(negated=" & $n.negated & ")\n"
    for item in n.items:
      if item.isRange: s.add(pad & "  Range(" & $item.lo & "-" & $item.hi & ")\n")
      else:            s.add(pad & "  Char(" & $item.ch & ")\n")
    s
  of rnQuantifier:
    let maxStr = if n.max == -1: "∞" else: $n.max
    pad & "Quantifier(" & $n.qkind & " " & $n.min & ".." & maxStr &
    (if n.lazy: " lazy" else: "") & ")\n" & `$`(n.operand, indent + 1)

proc captureCount*(p: RegexParser): lent int =
  p.captureCount

when isMainModule:
  import std/strformat
  const patterns = [
    r"a*",
    r"ab+",
    r"(cd|ef)?",
    r"[0-9]{2,4}",
    r"^hello.*world$",
    r"foo\.",
    r"a|b|c",
    r"\d+\s*\w",
  ]
  for pat in patterns:
    echo "=== " & pat & " ==="
    var p = initRegexParser(pat)
    let ast = p.parse()
    echo `$`(ast)