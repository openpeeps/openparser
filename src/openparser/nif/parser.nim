# A collection of tiny parsers and dumpers
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/openparser

## NIF Parser — 2027 spec, lazy symbol expansion, depth limit

import std/[strutils, options, memfiles, os]
import ./ast
import ./lexer
import ../private/lexutils

type
  NifParser* = object
    lexer: NifLexer
    prev*, curr*, next*: NifToken
    options*: NifOptions
    depth*: int
    moduleSuffix*: string

proc error*(p: var NifParser, msg: string) =
  var atPos = p.lexer.pos
  var atLine = p.lexer.line
  var atCol = p.lexer.col
  if p.curr != nil:
    atPos = p.curr.pos
    atLine = p.curr.line
    atCol = p.curr.col
  let ctx = getContext(p.lexer, atPos)
  raise newException(OpenParserNifError, ("\n" & ctx & "\n" & "Error ($1:$2) " % [$atLine, $atCol]) & msg)

proc checkMaxDepth(p: var NifParser) =
  if p.options != nil and p.options.maxDepth > 0:
    if p.depth > p.options.maxDepth:
      p.error("Maximum nesting depth exceeded")

proc nextTok(p: var NifParser): NifToken {.discardable.} =
  p.lexer.nextNifToken()

proc advance*(p: var NifParser): NifToken {.discardable.} =
  p.prev = p.curr
  p.curr = p.next
  p.next = p.nextTok()
  result = p.curr

proc expectSkip*(p: var NifParser, kind: NifTokenKind) =
  if p.curr.kind != kind:
    if p.curr.kind == ntkEof:
      p.error(errorEndOfFile % $kind)
    else:
      p.error(unexpectedToken % $p.curr.kind)
  else:
    p.advance()

proc initParser*(lex: NifLexer, opts: NifOptions = nil): NifParser =
  var o = opts
  if o == nil: o = defaultNifOptions()
  result = NifParser(lexer: lex, options: o, moduleSuffix: o.moduleSuffix)
  result.curr = result.nextTok()
  result.next = result.nextTok()

# symbol expansion
proc expandSymValue(val: string, suffixMod: string): string =
  if val.len == 0: return val
  if val[^1] != '.': return val
  if suffixMod.len == 0: return val
  # already expanded? check if it already ends with suffix (with dot)
  # simplistic: if val.count('.') >=2 we assume already expanded? but spec says `foo.0.` always expands.
  # To keep lazy idempotent, only expand if trailing dot and not already `...suffix`
  if val.endsWith("." & suffixMod): return val
  # remove trailing dot then add .suffix? Actually spec says `foo.0.` expands to `foo.0.modname` (keeps dot then mod)
  # val is "foo.0." -> we want "foo.0.modname" i.e. val + suffixMod
  result = val & suffixMod

proc makeAtomNode(p: var NifParser, t: NifToken): NifNode =
  let suf = t.suffix
  let liOpt = suf.lineInfo
  let cmtOpt = suf.comment
  case t.kind
  of ntkDot:
    result = NifNode(kind: nkEmpty)
    result.lineInfo = liOpt
    result.comment = cmtOpt
    result.rawSuffix = suf.rawLineInfo & (if suf.rawComment.len>0: "#" & suf.rawComment & "#" else: "")
  of ntkIdent:
    result = NifNode(kind: nkIdent, ident: t.value, rawIdent: t.raw)
    result.lineInfo = liOpt
    result.comment = cmtOpt
  of ntkSymbol:
    var v = t.value
    var r = t.raw
    if p.options.expandGlobalSymbols and v.endsWith("."):
      let expanded = expandSymValue(v, p.moduleSuffix)
      if expanded != v:
        v = expanded
        r = expanded # raw after expansion — no escapes needed
    result = NifNode(kind: nkSymbol, symbol: v, rawSymbol: r)
    result.lineInfo = liOpt
    result.comment = cmtOpt
  of ntkSymbolDef:
    var v = t.value
    var r = t.raw
    # t.raw includes leading ":" but our lexer stored raw without ":" for value? Actually stored raw with ":"
    # For consistency, rawSymbolDef should be without colon? In ast we store without colon? Check ast: rawSymDef vs symDef
    # In lexer readIdentSymbol for SymbolDef we set raw: ":" & symbolRaw — so value is symbolDec without colon.
    # But NifNode kind SymbolDef stores symDef without colon. Adjust.
    # r currently includes ":" prefix, v is without colon? Let's normalize: strip colon from r for storage.
    if r.len>0 and r[0]==':': r = r[1..^1]
    if p.options.expandGlobalSymbols and v.endsWith("."):
      let expanded = expandSymValue(v, p.moduleSuffix)
      if expanded != v:
        v = expanded
        r = expanded
    result = NifNode(kind: nkSymbolDef, symDef: v, rawSymDef: r)
    result.lineInfo = liOpt
    result.comment = cmtOpt
  of ntkInt:
    var iv:int64 = 0
    try: iv = parseBiggestInt(t.raw)
    except: iv = 0
    result = NifNode(kind: nkInt, intVal: iv, rawInt: t.raw)
    result.lineInfo = liOpt
    result.comment = cmtOpt
  of ntkUInt:
    var uv:uint64 = 0
    var s = t.raw
    if s.endsWith("u"): s = s[0..^2]
    try: uv = uint64(parseBiggestUInt(s))
    except: uv = 0
    result = NifNode(kind: nkUInt, uintVal: uv, rawUInt: t.raw)
    result.lineInfo = liOpt
    result.comment = cmtOpt
  of ntkFloat:
    var fv:float64 = 0.0
    try: fv = parseFloat(t.raw)
    except: fv = 0.0
    result = NifNode(kind: nkFloat, floatVal: fv, rawFloat: t.raw)
    result.lineInfo = liOpt
    result.comment = cmtOpt
  of ntkCharLit:
    var cInner = ""
    if t.raw.len >= 2: cInner = t.raw[1..^2]
    result = NifNode(kind: nkCharLit, charVal: t.value, rawChar: cInner)
    result.lineInfo = liOpt
    result.comment = cmtOpt
  of ntkStrLit:
    var innerRaw = ""
    if t.raw.len >= 2: innerRaw = t.raw[1..^2]
    result = NifNode(kind: nkStrLit, strVal: t.value, rawStr: innerRaw)
    result.lineInfo = liOpt
    result.comment = cmtOpt
  else:
    p.error("Unexpected token as atom: " & $t.kind)

proc parseNode(p: var NifParser): NifNode
proc parseCompound(p: var NifParser): NifNode

proc parseCompound(p: var NifParser): NifNode =
  if p.curr.kind != ntkLParen:
    p.error(unexpectedToken % $p.curr.kind)
  p.advance() # consume '('
  if p.curr.kind == ntkRParen:
    p.error("Empty compound — expected tag")
  # TagHead: NodeKind Suffix . Handle directive dot prefix
  var tag = ""
  var rawTag = ""
  var tagLI: Option[NifLineInfo] = none(NifLineInfo)
  var tagCmt: Option[string] = none(string)
  if p.curr.kind == ntkDot and p.next.kind == ntkIdent:
    # directive tag .xxx
    rawTag = "." & p.next.raw
    tag = "." & p.next.value
    tagLI = p.next.suffix.lineInfo
    tagCmt = p.next.suffix.comment
    p.advance() # dot
    p.advance() # ident
  elif p.curr.kind == ntkIdent:
    rawTag = p.curr.raw
    tag = p.curr.value
    tagLI = p.curr.suffix.lineInfo
    tagCmt = p.curr.suffix.comment
    p.advance()
  elif p.curr.kind == ntkDot:
    # tag could be '.'? Not valid but treat as?
    p.error("Tag cannot be empty '.'")
  else:
    p.error("Expected tag identifier after '(' got " & $p.curr.kind)

  inc p.depth
  checkMaxDepth(p)
  var children: seq[NifNode] = @[]
  while p.curr.kind notin {ntkRParen, ntkEof}:
    # allow stray brackets/braces as errors — but per spec they are control chars; if encountered treat as error?
    if p.curr.kind in {ntkLBracket, ntkRBracket, ntkLBrace, ntkRBrace}:
      p.error("Unexpected bracket/brace `" & $p.curr.kind & "` inside compound — only () for compound nodes")
    children.add(p.parseNode())
  if p.curr.kind != ntkRParen:
    p.error(errorEndOfFile % "compound — missing ')' for tag " & tag)
  p.advance() # consume ')'
  dec p.depth
  result = newNifCompound(tag, rawTag, children, tagLI, tagCmt)
  # Directive kind auto handled by newNifCompound

proc parseNode(p: var NifParser): NifNode =
  case p.curr.kind
  of ntkLParen:
    result = p.parseCompound()
  of ntkDot, ntkIdent, ntkSymbol, ntkSymbolDef, ntkInt, ntkUInt, ntkFloat, ntkCharLit, ntkStrLit:
    let t = p.curr
    p.advance()
    result = p.makeAtomNode(t)
  of ntkEof:
    p.error(errorEndOfFile % "node")
  else:
    p.error(unexpectedToken % $p.curr.kind)

proc parseModule*(p: var NifParser): NifModule =
  result = @[]
  # spec: version directive must be at byte 0 with no ws before
  let firstPos = if p.curr != nil: p.curr.pos else: 0
  var idx = 0
  while p.curr.kind != ntkEof:
    # skip any stray handling? Module is Node+ ; allow parsing
    let n = p.parseNode()
    # directive check for first node being .nif27 at pos 0
    if idx == 0 and n.kind == nkDirective and n.tag == ".nif27":
      if firstPos != 0:
        p.error("(.nif27) must be at byte 0 with no leading whitespace")
    result.add(n)
    inc idx
  if result.len == 0:
    p.error("Empty NIF module — expected at least one Node")

proc fromNif*(input: string, opts: NifOptions = nil): NifModule =
  ## Parse NIF from string
  var lex = newNifLexer(input)
  var p = initParser(lex, opts)
  result = p.parseModule()

proc fromNif*(mf: MemFile, opts: NifOptions = nil): NifModule =
  ## Parse NIF from MemFile (zero-copy-ish)
  var lex = newNifLexer(mf.mem, int(mf.size))
  var p = initParser(lex, opts)
  result = p.parseModule()

proc fromNifFile*(path: string, opts: NifOptions = nil): NifModule =
  ## Parse NIF file via memfiles
  if not fileExists(path):
    raise newException(IOError, "NIF file not found: " & path)
  var o = opts
  if o == nil: o = defaultNifOptions()
  if o.moduleSuffix.len == 0:
    let (_, name, _) = splitFile(path)
    var base = name
    let dotPos = base.find('.')
    if dotPos >= 0: base = base[0..dotPos-1]
    o.moduleSuffix = base
  var mf = memfiles.open(path, fmRead)
  defer: mf.close()
  var lex = newNifLexer(mf.mem, int(mf.size))
  var p = initParser(lex, o)
  result = p.parseModule()

proc dumpNif*(nodes: NifModule): string =
  ## Minimal canonical dump — space separated, suffixes re-emitted if present
  result = ""
  for i, n in nodes:
    if i>0: result.add("\n")
    result.add($n)

proc tokenizeNif*(input: string): seq[NifToken] =
  tokenize(input)

proc tokenizeNif*(mf: MemFile): seq[NifToken] =
  tokenize(mf)
