# A collection of tiny parsers and dumpers
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/openparser

import std/[strutils, strformat, tables, memfiles]
export memfiles

type
  RegexTokenKind* = enum
    tkEof
    tkChar
    tkEscaped
    tkNumber
    tkDot
    tkStar
    tkPlus
    tkQuestion
    tkPipe
    tkLParen
    tkRParen
    tkLBracket
    tkRBracket
    tkLBrace
    tkRBrace
    tkCaret
    tkDollar
    tkComma
    tkHyphen
    tkNewline

  RegexLexer* = object
    data: ptr UncheckedArray[char]
    mf: MemFile
    viaMemFiles: bool
    emitNewlines: bool
    input: string
    len: int
    line: int
    col: int
    pos: int

  RegexToken* {.acyclic.} = object
    kind*: RegexTokenKind
    lexeme*: string
    line*: int
    col*: int
    pos*: int

  OpenParserRegexError* = object of CatchableError
    ## Exception type for regex lexer errors, includes line and column information.

proc charAt(l: RegexLexer, idx: int): char {.inline.} =
  # Returns the character at the given index, or '\0' if out of bounds
  if idx < 0 or idx >= l.len: return '\0'
  if l.data != nil: l.data[idx] else: l.input[idx]

proc current(l: RegexLexer): char {.inline.} =
  # Returns the current character at the lexer's position,
  # or '\0' if out of bounds
  l.charAt(l.pos)

proc advance(l: var RegexLexer): char {.inline.} =
  # Advance the lexer by one character, updating line and column numbers.
  # Returns the character at the new position.
  result = l.current()
  if result == '\0':
    return
  inc l.pos
  if result == '\n':
    inc l.line
    l.col = 1
  else:
    inc l.col

proc getLexeme*(l: RegexLexer, startPos: int, stopPos: int): string =
  ## Extracts the substring from startPos to stopPos as a new string
  if l.data != nil:
    let n = stopPos - startPos
    result = newString(n)
    copyMem(addr result[0], addr l.data[startPos], n)
  else:
    result = l.input[startPos..<stopPos]

proc makeToken(kind: RegexTokenKind, line, col, pos: int, lexeme: string): RegexToken {.inline.} =
  RegexToken(kind: kind, lexeme: lexeme, line: line, col: col, pos: pos)

proc makeToken(kind: RegexTokenKind, line, col, pos: int): RegexToken {.inline.} =
  RegexToken(kind: kind, line: line, col: col, pos: pos)

proc getContext(l: RegexLexer, posOverride: int = -1): string =
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

proc error*(l: var RegexLexer, msg: string) =
  # Raise a lexer error
  let context = getContext(l)
  raise newException(OpenParserRegexError, ("\n" & context & "\n" & "Error ($1:$2) " % [$l.line, $l.col]) & msg)

proc getToken*(l: var RegexLexer): RegexToken =
  while true:
    let startLine = l.line
    let startCol  = l.col
    let startPos  = l.pos
    let c = l.current()

    if c == '\0':
      return makeToken(tkEof, startLine, startCol, startPos)

    if c == '\r' or c == '\n':
      discard l.advance()
      if c == '\r' and l.current() == '\n':
        discard l.advance()
      if l.emitNewlines:
        return makeToken(tkNewline, startLine, startCol, startPos, "\\n")
      continue

    discard l.advance()

    # Always carry the lexeme so parseCharClass can safely read [0]
    # even when a meta-char appears as a literal inside [...].
    case c
    of '.': return makeToken(tkDot,      startLine, startCol, startPos, ".")
    of '*': return makeToken(tkStar,     startLine, startCol, startPos, "*")
    of '+': return makeToken(tkPlus,     startLine, startCol, startPos, "+")
    of '?': return makeToken(tkQuestion, startLine, startCol, startPos, "?")
    of '|': return makeToken(tkPipe,     startLine, startCol, startPos, "|")
    of '(': return makeToken(tkLParen,   startLine, startCol, startPos, "(")
    of ')': return makeToken(tkRParen,   startLine, startCol, startPos, ")")
    of '[': return makeToken(tkLBracket, startLine, startCol, startPos, "[")
    of ']': return makeToken(tkRBracket, startLine, startCol, startPos, "]")
    of '{': return makeToken(tkLBrace,   startLine, startCol, startPos, "{")
    of '}': return makeToken(tkRBrace,   startLine, startCol, startPos, "}")
    of '^': return makeToken(tkCaret,    startLine, startCol, startPos, "^")
    of '$': return makeToken(tkDollar,   startLine, startCol, startPos, "$")
    of ',': return makeToken(tkComma,    startLine, startCol, startPos, ",")
    of '-': return makeToken(tkHyphen,   startLine, startCol, startPos, "-")
    of '\\':
      let esc = l.current()
      if esc == '\0':
        l.error("Unterminated escape sequence")
      discard l.advance()
      return makeToken(tkEscaped, startLine, startCol, startPos, $esc)
    of '0'..'9':
      var s = $c
      while l.current() in {'0'..'9'}:
        s.add(l.advance())
      return makeToken(tkNumber, startLine, startCol, startPos, s)
    else:
      return makeToken(tkChar, startLine, startCol, startPos, $c)

proc initRegexLexer*(input: string): RegexLexer =
  ## Initialize lexer from an in-memory regex string.
  result = RegexLexer(
    data: nil,
    viaMemFiles: false,
    input: input,
    len: input.len,
    line: 1,
    col: 1,
    pos: 0
  )

proc initRegexLexer*(mf: MemFile): RegexLexer =
  ## Initialize lexer from a mapped file.
  ## Works for non-empty mappings; empty files map to len=0.
  let n = int(mf.size)
  result = RegexLexer(
    data: (if n > 0: cast[ptr UncheckedArray[char]](mf.mem) else: nil),
    mf: mf,
    viaMemFiles: true,
    input: "",
    len: n,
    line: 1,
    col: 1,
    pos: 0
  )

proc close*(l: var RegexLexer) =
  ## Close mapped file if lexer owns one.
  if l.viaMemFiles:
    memfiles.close(l.mf)
    l.viaMemFiles = false
    l.data = nil
    l.len = 0

when isMainModule:
  import std/[os, times]
  var lexer = initRegexLexer(memfiles.open("./example.txt", fmRead))
  var tok = lexer.getToken()
  while tok.kind != tkEof:
    echo &"Token: {tok.kind} at line {tok.line}, col {tok.col}, pos {tok.pos}, lexeme: {tok.lexeme}"
    tok = lexer.getToken()
  lexer.close()