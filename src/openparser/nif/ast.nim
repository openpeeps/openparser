# A collection of tiny parsers and dumpers
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/openparser

## NIF AST — node kinds following nifspec 2027
## Each atom / tag may carry an optional LineInfo suffix and Comment suffix

import std/options

type
  OpenParserNifError* = object of CatchableError

  NifOptions* = ref object
    ## Parser options
    moduleSuffix*: string
      ## Suffix for global symbol expansion: `foo.0.` -> `foo.0.<moduleSuffix>`
    expandGlobalSymbols*: bool
      ## When true, parser expands trailing-dot symbols lazily
    maxDepth*: int
      ## 0 = unlimited; else max compound nesting
    preserveComments*: bool
    skipUnknownDirectives*: bool

  NifLineInfo* = object
    ## Absolute or diff-based? Spec stores diffs relative to parent.
    ## We keep decoded signed ints; raw base62 kept for round-trip.
    colDiff*: int
    lineDiff*: int
    hasLineDiff*: bool
    filename*: Option[string]
    rawCol*: string
    rawLine*: string
    rawFilename*: string
    hasAt*: bool
    hasTildeShorthand*: bool
    hasFilename*: bool

  NifSuffix* = object
    ## `Suffix ::= LineInfo? Comment?` directly after atom/tag with no ws
    lineInfo*: Option[NifLineInfo]
    comment*: Option[string]
    rawLineInfo*: string
    rawComment*: string # without surrounding #

  NifNodeKind* = enum
    nkEmpty       ## '.'
    nkIdent       ## identifier
    nkSymbol      ## symbol use
    nkSymbolDef   ## :symbol
    nkInt         ## signed integer
    nkUInt        ## unsigned with `u` suffix
    nkFloat       ## float with '.' or 'E'
    nkCharLit     ## 'c'
    nkStrLit      ## "string"
    nkCompound    ## (tag children...)
    nkDirective   ## (.directive ...) — subset of nkCompound with tag[0]=='.'

  NifNode* {.acyclic.} = ref object
    ## A single NIF node. Compound nodes carry `tag`+`children`.
    ## Atoms carry value fields. Every node may carry suffix.
    lineInfo*: Option[NifLineInfo]
    comment*: Option[string]
    rawComment*: string
    rawSuffix*: string # raw suffix text for debugging
    case kind*: NifNodeKind
    of nkEmpty:
      discard
    of nkIdent:
      ident*: string
      rawIdent*: string
    of nkSymbol:
      symbol*: string
      rawSymbol*: string
    of nkSymbolDef:
      symDef*: string
      rawSymDef*: string
    of nkInt:
      intVal*: int64
      rawInt*: string
    of nkUInt:
      uintVal*: uint64
      rawUInt*: string
    of nkFloat:
      floatVal*: float64
      rawFloat*: string
    of nkCharLit:
      charVal*: string # decoded single char/string (may be escape)
      rawChar*: string
    of nkStrLit:
      strVal*: string  # decoded
      rawStr*: string  # raw inside quotes (with escapes preserved)
    of nkCompound, nkDirective:
      tag*: string
      rawTag*: string
      tagLineInfo*: Option[NifLineInfo]
      tagComment*: Option[string]
      rawTagSuffix*: string
      children*: seq[NifNode]

  NifModule* = seq[NifNode]
    ## A NIF file is `Node+` — directives + root compound(s)

  NifIndexEntry* = object
    symbol*: string
    offsetDiff*: int # diff-based as in spec
    offsetAbs*: int  # computed absolute byte offset
    visibility*: string # "x" exported or "h" hidden

proc defaultNifOptions*(): NifOptions =
  NifOptions(
    expandGlobalSymbols: true,
    maxDepth: 0,
    preserveComments: true,
    skipUnknownDirectives: true
  )

proc isDirectiveTag*(tag: string): bool =
  tag.len > 0 and tag[0] == '.'

proc newNifEmpty*(suffix = NifSuffix()): NifNode =
  result = NifNode(kind: nkEmpty)
  if suffix.lineInfo.isSome: result.lineInfo = suffix.lineInfo
  if suffix.comment.isSome: result.comment = suffix.comment
  result.rawSuffix = suffix.rawLineInfo & (if suffix.rawComment.len > 0: "#" & suffix.rawComment & "#" else: "")

proc newNifIdent*(ident, raw: string, suffix = NifSuffix()): NifNode =
  result = NifNode(kind: nkIdent, ident: ident, rawIdent: raw)
  if suffix.lineInfo.isSome: result.lineInfo = suffix.lineInfo
  if suffix.comment.isSome: result.comment = suffix.comment

proc newNifSymbol*(sym, raw: string, suffix = NifSuffix()): NifNode =
  result = NifNode(kind: nkSymbol, symbol: sym, rawSymbol: raw)
  if suffix.lineInfo.isSome: result.lineInfo = suffix.lineInfo
  if suffix.comment.isSome: result.comment = suffix.comment

proc newNifSymbolDef*(sym, raw: string, suffix = NifSuffix()): NifNode =
  result = NifNode(kind: nkSymbolDef, symDef: sym, rawSymDef: raw)
  if suffix.lineInfo.isSome: result.lineInfo = suffix.lineInfo
  if suffix.comment.isSome: result.comment = suffix.comment

proc newNifCompound*(tag, rawTag: string, children: seq[NifNode] = @[],
                     tagLI: Option[NifLineInfo] = none(NifLineInfo),
                     tagCmt: Option[string] = none(string)): NifNode =
  if isDirectiveTag(tag):
    result = NifNode(kind: nkDirective, tag: tag, rawTag: rawTag, children: children)
  else:
    result = NifNode(kind: nkCompound, tag: tag, rawTag: rawTag, children: children)
  result.tagLineInfo = tagLI
  result.tagComment = tagCmt

proc `$`*(n: NifNode): string =
  if n == nil: return "nil"
  let suffix =
    (if n.lineInfo.isSome:
      let li = n.lineInfo.get
      var s: string
      if li.hasTildeShorthand:
        s = li.rawCol
      else:
        let prefix = if li.hasAt: "@" else: "@"
        s = prefix & li.rawCol
      if li.hasLineDiff: s.add("," & li.rawLine)
      if li.hasFilename: s.add("," & li.rawFilename)
      s
    else: "") &
    (if n.comment.isSome: "#" & n.comment.get & "#" else: "")
  case n.kind
  of nkEmpty: result = "." & suffix
  of nkIdent: result = n.rawIdent & suffix
  of nkSymbol: result = n.rawSymbol & suffix
  of nkSymbolDef: result = ":" & n.rawSymDef & suffix
  of nkInt: result = n.rawInt & suffix
  of nkUInt: result = n.rawUInt & suffix
  of nkFloat: result = n.rawFloat & suffix
  of nkCharLit: result = "'" & n.rawChar & "'" & suffix
  of nkStrLit: result = "\"" & n.rawStr & "\"" & suffix
  of nkCompound, nkDirective:
    let tagSuffix =
      (if n.tagLineInfo.isSome:
        let li = n.tagLineInfo.get
        var s: string
        if li.hasTildeShorthand:
          s = li.rawCol
        else:
          let p = if li.hasAt: "@" else: "@"
          s = p & li.rawCol
        if li.hasLineDiff: s.add("," & li.rawLine)
        if li.hasFilename: s.add("," & li.rawFilename)
        s
      else: "") &
      (if n.tagComment.isSome: "#" & n.tagComment.get & "#" else: "")
    result = "(" & n.rawTag & tagSuffix
    for c in n.children:
      result.add(" " & $c)
    result.add(")")

proc isNifDirective*(n: NifNode): bool =
  n != nil and n.kind == nkDirective

proc directiveName*(n: NifNode): string =
  if n.isNifDirective: n.tag else: ""

proc getStrVal*(n: NifNode): string =
  if n != nil and n.kind == nkStrLit: n.strVal else: ""

proc getIdentVal*(n: NifNode): string =
  if n != nil and n.kind == nkIdent: n.ident else: ""
