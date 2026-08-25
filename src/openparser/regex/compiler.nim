# A collection of tiny parsers and dumpers
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/openparser

import std/[strutils, strformat]
import ./parser

#
# Instruction set
#
type
  OpCode* = enum
    opChar          ## match exact character
    opAnyChar       ## match any character (.)
    opCharClass     ## match character class [abc] [^a-z]
    opEscapeClass   ## match \d \w \s \D \W \S
    opAnchorStart   ## assert position ^ 
    opAnchorEnd     ## assert position $
    opMatch         ## successful match
    opJmp           ## unconditional jump
    opSplit         ## fork execution (greedy: try t1 first, then t2)
    opSplitLazy     ## fork execution (lazy:   try t2 first, then t1)
    opSave          ## save current position into capture slot
    opProgress      ## guard against zero-width infinite loops
    opWordBoundary  ## assert word boundary: \b (neg=false) or \B (neg=true)

  Instr* = object
    op*:     OpCode
    arg1*:   int          ## char ordinal / jump target / slot index
    arg2*:   int          ## second jump target (Split) / class index
    neg*:    bool         ## negate match (opCharClass / opEscapeClass)

  CompiledClass* = object
    ## Stored separately; instructions reference by index
    negated*: bool
    items*:   seq[CharClassItem]
    bitmap*:  array[32, uint8]  ## 256-bit lookup: bitmap[byte shr 3] and (1u8 shl (byte and 7))

  PatternShape* = enum
    psNone
    psAlphaWordStar         ## [a-zA-Z_]\w*
    psWordCharPlus          ## \w+
    psWordCharStar          ## \w*
    psUpperDigitUnderPlus   ## [A-Z_][A-Z0-9_]+   (min total = 2)
    psUpperDigitUnderStar   ## [A-Z_][A-Z0-9_]*   (min total = 1)
    psUpperDigitUnder2Plus  ## [A-Z_][A-Z0-9_]{2,} (min total = 3)
    psDigitPlus             ## \d+
    psDigitStar             ## \d*
    psEndAnchorByte         ## X\s*$  (single byte + optional whitespace + anchor end)
    psWordSpaceStarWord     ## \w+\s*\*+\s*\w+
    psLitSpaceWordPlus      ## <literal>\s+\w+
    psHexPrefixHexPlus      ## 0[xX][0-9a-fA-F]+
    psLitWordSpaceWord      ## <literal>\s+[a-zA-Z_]\w*
    psDigitPlusULSuffix     ## \d+[uUlL]*
    psLitWordSpaceWordPlus  ## <literal>\w+\s+\w+

  Program* = object
    instrs*:  seq[Instr]
    classes*: seq[CompiledClass]
    numCaptures*: int      ## total capture slots (each group uses 2: open/close)
    shape*:       PatternShape   ## set by compiler from AST
    hasLazy*:     bool

  Regex* = Program

  RegexCompiler* = object
    prog: Program

#
# Helpers
#

proc emit(c: var RegexCompiler, instr: Instr): int {.inline, discardable.} =
  ## Append instruction, return its index.
  result = c.prog.instrs.len
  c.prog.instrs.add(instr)

proc here(c: RegexCompiler): int {.inline.} =
  c.prog.instrs.len

proc patch(c: var RegexCompiler, idx: int, target: int) {.inline.} =
  ## Back-patch a jump target.
  c.prog.instrs[idx].arg1 = target

proc patch2(c: var RegexCompiler, idx: int, target: int) {.inline.} =
  c.prog.instrs[idx].arg2 = target

proc setBitmapBit(bitmap: var array[32, uint8], b: byte) {.inline.} =
  bitmap[b shr 3] = bitmap[b shr 3] or (1u8 shl (b and 7))

proc buildClassBitmap*(cls: var CompiledClass) {.inline.} =
  ## Populate cls.bitmap from cls.items. Called once at compile time.
  for item in cls.items:
    if item.isEscape:
      case item.escapeChar
      of 'd':
        for c in '0'..'9': setBitmapBit(cls.bitmap, c.byte)
      of 'D':
        for c in char(0)..char(255):
          if c notin {'0'..'9'}: setBitmapBit(cls.bitmap, c.byte)
      of 'w':
        for c in {'a'..'z','A'..'Z','0'..'9','_'}: setBitmapBit(cls.bitmap, c.byte)
      of 'W':
        for c in char(0)..char(255):
          if c notin {'a'..'z','A'..'Z','0'..'9','_'}: setBitmapBit(cls.bitmap, c.byte)
      of 's':
        for c in {' ','\t','\n','\r','\f','\v'}: setBitmapBit(cls.bitmap, c.byte)
      of 'S':
        for c in char(0)..char(255):
          if c notin {' ','\t','\n','\r','\f','\v'}: setBitmapBit(cls.bitmap, c.byte)
      else: discard
    elif item.isRange:
      for ci in ord(item.lo)..ord(item.hi):
        setBitmapBit(cls.bitmap, byte(ci))
    else:
      setBitmapBit(cls.bitmap, item.ch.byte)

proc addClass(c: var RegexCompiler, cls: CompiledClass): int {.inline.} =
  result = c.prog.classes.len
  var built = cls
  buildClassBitmap(built)
  c.prog.classes.add(built)

proc hasLazyNode(n: RegexNode): bool =
  case n.kind
  of rnQuantifier:
    if n.lazy: return true
    return hasLazyNode(n.operand)
  of rnConcat, rnAlternation:
    for c in n.children:
      if hasLazyNode(c): return true
  of rnGroup:
    return hasLazyNode(n.child)
  else: discard
  false

#
# Core compiler  (AST → instruction stream)
#
proc compileNode(c: var RegexCompiler, n: RegexNode)

proc compileQuantifier(c: var RegexCompiler, n: RegexNode) =
  let minRep = n.min
  let maxRep = n.max
  let lazy   = n.lazy

  for _ in 0 ..< minRep:
    compileNode(c, n.operand)

  if maxRep == -1:
    if minRep == 0:
      # pure *  → split(body, exit); body; jmp(split)
      let splitPos = c.here()
      let splitIdx = c.emit(Instr(op: if lazy: opSplitLazy else: opSplit,
                                   arg1: splitPos + 1, arg2: -1))
      compileNode(c, n.operand)
      c.emit(Instr(op: opJmp, arg1: splitPos))
      patch2(c, splitIdx, c.here())   # arg2 = exit
    else:
      # + tail → split(body, exit); progress; body; jmp(split)
      # Split comes FIRST so the loop-back target is the split itself,
      # not progress. This prevents the visited-guard from blocking
      # re-entry via the loop-back jmp.
      let splitPos = c.here()
      let splitIdx = c.emit(Instr(op: if lazy: opSplitLazy else: opSplit,
                                   arg1: splitPos + 1, arg2: -1))
      c.emit(Instr(op: opProgress))
      compileNode(c, n.operand)
      c.emit(Instr(op: opJmp, arg1: splitPos))
      patch2(c, splitIdx, c.here())   # arg2 = exit (same for greedy & lazy)

  elif maxRep == minRep:
    discard   # already emitted exactly minRep copies

  else:
    # Bounded optional tail: (maxRep - minRep) optional copies.
    # arg1 always points to the body (instruction right after split).
    # arg2 always points to the shared exit position.
    # opSplit      → tries arg1 (body) first, arg2 (exit) second  → greedy
    # opSplitLazy  → tries arg2 (exit) first, arg1 (body) second  → lazy
    let extra = maxRep - minRep
    var splitIdxs: seq[int]
    for _ in 0 ..< extra:
      let splitPos = c.here()
      let si = c.emit(Instr(op: if lazy: opSplitLazy else: opSplit,
                             arg1: splitPos + 1, arg2: -1))
      splitIdxs.add(si)
      compileNode(c, n.operand)
    let exitPos = c.here()
    for si in splitIdxs:
      patch2(c, si, exitPos)   # arg2 = exit for both greedy and lazy

proc compileNode(c: var RegexCompiler, n: RegexNode) =
  case n.kind

  of rnChar:
    c.emit(Instr(op: opChar, arg1: ord(n.ch)))

  of rnDot:
    c.emit(Instr(op: opAnyChar))

  of rnAnchorStart:
    c.emit(Instr(op: opAnchorStart))

  of rnAnchorEnd:
    c.emit(Instr(op: opAnchorEnd))

  of rnEscaped:
    ## \d \D \w \W \s \S  → escape class
    ## \b \B              → word boundary assertion
    ## anything else      → literal char
    case n.escape
    of 'd', 'D', 'w', 'W', 's', 'S':
      c.emit(Instr(op: opEscapeClass, arg1: ord(n.escape)))
    of 'b': c.emit(Instr(op: opWordBoundary))
    of 'B': c.emit(Instr(op: opWordBoundary, neg: true))
    of 'n': c.emit(Instr(op: opChar, arg1: ord('\n')))
    of 'r': c.emit(Instr(op: opChar, arg1: ord('\r')))
    of 't': c.emit(Instr(op: opChar, arg1: ord('\t')))
    else:
      c.emit(Instr(op: opChar, arg1: ord(n.escape)))

  of rnCharClass:
    let idx = c.addClass(CompiledClass(negated: n.negated, items: n.items))
    c.emit(Instr(op: opCharClass, arg1: idx, neg: n.negated))

  of rnConcat:
    for child in n.children:
      compileNode(c, child)

  of rnAlternation:
    ## A|B|C  →
    ##   split L_A, L_next
    ## L_A:  <A>; jmp L_end
    ## L_next: split L_B, L_next2
    ## L_B:  <B>; jmp L_end
    ##   ...
    ## L_end:
    var jmpIdxs: seq[int]
    for i, branch in n.children:
      if i < n.children.high:
        let si = c.emit(Instr(op: opSplit, arg1: c.here() + 1, arg2: -1))
        compileNode(c, branch)
        jmpIdxs.add(c.emit(Instr(op: opJmp, arg1: -1)))
        patch2(c, si, c.here())
      else:
        compileNode(c, branch)
    let endPos = c.here()
    for ji in jmpIdxs:
      patch(c, ji, endPos)

  of rnGroup:
    let openSlot  = n.index * 2
    let closeSlot = openSlot + 1
    if n.capture:
      c.emit(Instr(op: opSave, arg1: openSlot))
    compileNode(c, n.child)
    if n.capture:
      c.emit(Instr(op: opSave, arg1: closeSlot))
  of rnQuantifier:
    compileQuantifier(c, n)

proc detectProgramShape(ast: RegexNode): PatternShape =
  ## Detect shape from the root AST node.
  ## Handles star (*), plus (+), and bounded-minimum ({n,}) quantifiers.

  ## Unwrap a single-node concat
  let root = if ast.kind == rnConcat and ast.children.len == 1:
               ast.children[0]
             else:
               ast

  proc isEscape(n: RegexNode, c: char): bool {.inline.} =
    n.kind == rnEscaped and n.escape == c

  proc isCharClassOf(n: RegexNode, ranges: seq[(char,char)],
                     singles: seq[char]): bool =
    if n.kind != rnCharClass or n.negated: return false
    var gotRanges: seq[(char,char)]
    var gotSingles: seq[char]
    for it in n.items:
      if it.isRange: gotRanges.add((it.lo, it.hi))
      else:          gotSingles.add(it.ch)
    if gotRanges.len != ranges.len or gotSingles.len != singles.len: return false
    for i in 0 ..< ranges.len:
      if gotRanges[i] != ranges[i]: return false
    for i in 0 ..< singles.len:
      if gotSingles[i] != singles[i]: return false
    true

  proc isQuantifier(n: RegexNode, minReq: int, escapeChar: char): bool =
    n.kind == rnQuantifier and n.max == -1 and not n.lazy and
    n.min >= minReq and isEscape(n.operand, escapeChar)

  proc isLiteral(n: RegexNode, ch: char): bool =
    n.kind == rnChar and n.ch == ch

  ## \w+ / \w*  — single escape quantified
  if root.kind == rnQuantifier and root.max == -1 and not root.lazy:
    let body = root.operand
    if isEscape(body, 'w'):
      return if root.min >= 1: psWordCharPlus else: psWordCharStar
    if isEscape(body, 'd'):
      return if root.min >= 1: psDigitPlus else: psDigitStar

  if root.kind != rnConcat: return psNone
  let kids = root.children
  let nkids = kids.len

  ## X\s*$ — single byte + optional \s + anchor end (3 children)
  if nkids == 3:
    if kids[0].kind == rnChar and
       kids[1].kind == rnQuantifier and kids[1].max == -1 and not kids[1].lazy and
       kids[1].min == 0 and isEscape(kids[1].operand, 's') and
       kids[2].kind == rnAnchorEnd:
      return psEndAnchorByte

  ## --- 2-child concat patterns ---
  if nkids == 2:
    let head = kids[0]
    let tail = kids[1]
    if tail.kind == rnQuantifier and tail.max == -1 and not tail.lazy:
      let body = tail.operand
      let minRep = tail.min

      ## [a-zA-Z_]\w*
      if isCharClassOf(head, @[('a','z'),('A','Z')], @['_']) and
         isEscape(body, 'w') and minRep == 0:
        return psAlphaWordStar

      ## [A-Z_][A-Z0-9_]{n,}
      if isCharClassOf(head, @[('A','Z')], @['_']) and
         isCharClassOf(body, @[('A','Z'),('0','9')], @['_']):
        case minRep
        of 0: return psUpperDigitUnderStar
        of 1: return psUpperDigitUnderPlus
        else: return psUpperDigitUnder2Plus

      ## \d+[uUlL]*
      if isEscape(head, 'd') and minRep >= 1:
        if body.kind == rnCharClass and not body.negated:
          var ulOk = true
          for it in body.items:
            if it.isRange: ulOk = false; break
            elif it.ch notin {'u','U','l','L'}: ulOk = false; break
          if ulOk: return psDigitPlusULSuffix

    ## \d+[uUlL]*  — head is \d+, tail is [uUlL]*
    if head.kind == rnQuantifier and head.max == -1 and not head.lazy and
       head.min >= 1 and isEscape(head.operand, 'd'):
      if tail.kind == rnQuantifier and tail.max == -1 and not tail.lazy and tail.min == 0:
        let clsBody = tail.operand
        if clsBody.kind == rnCharClass and not clsBody.negated:
          var ulOk = true
          for it in clsBody.items:
            if it.isRange: ulOk = false; break
            elif it.ch notin {'u','U','l','L'}: ulOk = false; break
          if ulOk: return psDigitPlusULSuffix

  ## --- Multi-segment patterns (3+ children) ---

  ## \w+\s*\*+\s*\w+  — 5 children
  if nkids == 5:
    if kids[0].isQuantifier(1, 'w') and
       kids[1].isQuantifier(0, 's') and
       kids[2].kind == rnQuantifier and kids[2].max == -1 and not kids[2].lazy and
       kids[2].min >= 1 and kids[2].operand.kind == rnEscaped and
       kids[2].operand.escape == '*' and
       kids[3].isQuantifier(0, 's') and
       kids[4].isQuantifier(1, 'w'):
      return psWordSpaceStarWord

  ## 0[xX][0-9a-fA-F]+  — 3 children: '0', [xX], [hex]+
  if nkids == 3:
    if kids[0].isLiteral('0') and
       kids[1].kind == rnCharClass and not kids[1].negated:
      var hasX = false
      for it in kids[1].items:
        if it.isRange and it.lo == 'x' and it.hi == 'X': hasX = true
        elif not it.isRange and (it.ch == 'x' or it.ch == 'X'): hasX = true
      if hasX and
         kids[2].kind == rnQuantifier and kids[2].max == -1 and not kids[2].lazy and
         kids[2].min >= 1:
        let body = kids[2].operand
        if body.kind == rnCharClass and not body.negated:
          var hexOk = true
          for it in body.items:
            if it.isRange:
              if not ((it.lo >= '0' and it.hi <= '9') or
                      (it.lo >= 'a' and it.hi <= 'f') or
                      (it.lo >= 'A' and it.hi <= 'F')):
                hexOk = false; break
            elif it.ch notin {'0'..'9','a'..'f','A'..'F'}:
              hexOk = false; break
          if hexOk: return psHexPrefixHexPlus

  ## Find literal prefix length (consecutive rnChar children at start)
  var litEnd = 0
  while litEnd < nkids and kids[litEnd].kind == rnChar: inc litEnd

  ## <literal>\s+\w+  (e.g. #define\s+\w+)
  if litEnd >= 1 and litEnd + 2 == nkids:
    if kids[litEnd].isQuantifier(1, 's') and
       kids[litEnd + 1].isQuantifier(1, 'w'):
      return psLitSpaceWordPlus

  ## <literal>\w+\s+\w+  (e.g. typedef\s+\w+\s+\w+)
  if litEnd >= 1 and litEnd + 4 == nkids:
    if kids[litEnd].isQuantifier(1, 's') and
       kids[litEnd + 1].isQuantifier(1, 'w') and
       kids[litEnd + 2].isQuantifier(1, 's') and
       kids[litEnd + 3].isQuantifier(1, 'w'):
      return psLitWordSpaceWordPlus

  ## <literal>\s+[a-zA-Z_]\w*  (e.g. struct\s+[a-zA-Z_]\w*)
  ## Parser flattens [a-zA-Z_]\w* into 3 separate children: \s+, [a-zA-Z_], \w*
  if litEnd >= 1 and litEnd + 3 == nkids:
    if kids[litEnd].isQuantifier(1, 's') and
       kids[litEnd + 1].kind == rnCharClass and not kids[litEnd + 1].negated and
       isCharClassOf(kids[litEnd + 1], @[('a','z'),('A','Z')], @['_']) and
       kids[litEnd + 2].kind == rnQuantifier and kids[litEnd + 2].max == -1 and
       not kids[litEnd + 2].lazy and kids[litEnd + 2].min == 0 and
       isEscape(kids[litEnd + 2].operand, 'w'):
      return psLitWordSpaceWord

  psNone

#
# Public API
#

proc compile*(ast: RegexNode, numCaptures: int): Program =
  ## Compile from AST. numCaptures is needed to allocate capture slots, but
  ## is not stored in the Program itself (since it can be derived from the Save instructions)
  var c = RegexCompiler()
  c.prog.numCaptures = numCaptures
  c.prog.shape       = detectProgramShape(ast)
  c.prog.hasLazy     = hasLazyNode(ast)
  c.compileNode(ast)
  c.emit(Instr(op: opMatch))
  result = c.prog

proc compile*(input: string): Program =
  ## Convenience wrapper: compile directly from pattern string.
  var p = initRegexParser(input)
  let ast = p.parse()
  result = compile(ast, p.captureCount)

proc re*(input: string): Program {.inline.} =
  ## Convenience wrapper: compile directly from pattern string.
  compile(input)

#
# Disassembler
#
proc disassemble*(prog: Program): string =
  ## Disassemble instruction stream into human-readable form.
  var lines: seq[string]
  for i, ins in prog.instrs:
    let prefix = &"{i:04d}  "
    let s = case ins.op
      of opChar:
        let ch = char(ins.arg1)
        let repr = if ch in {' ' .. '~'}: &"'{ch}'" else: &"0x{ins.arg1:02x}"
        &"CHAR        {repr}"
      of opAnyChar:      "ANYCHAR"
      of opAnchorStart:  "ANCHOR_START"
      of opAnchorEnd:    "ANCHOR_END"
      of opEscapeClass:
        &"ESCAPE_CLASS  \\{char(ins.arg1)}"
      of opCharClass:
        let cls = prog.classes[ins.arg1]
        var desc = "["
        if cls.negated: desc.add('^')
        for it in cls.items:
          if it.isRange: desc.add(&"{it.lo}-{it.hi}")
          else:          desc.add($it.ch)
        desc.add(']')
        &"CHAR_CLASS  #{ins.arg1} {desc}"
      of opMatch:        "MATCH"
      of opJmp:          &"JMP         {ins.arg1:04d}"
      of opSplit:        &"SPLIT       {ins.arg1:04d}, {ins.arg2:04d}"
      of opSplitLazy:    &"SPLIT_LAZY  {ins.arg1:04d}, {ins.arg2:04d}"
      of opSave:         &"SAVE        slot[{ins.arg1}]"
      of opProgress:     "PROGRESS"
      of opWordBoundary:
        if ins.neg: "WORD_BOUNDARY \\B" else: "WORD_BOUNDARY \\b"
    lines.add(prefix & s)
  result = lines.join("\n")

when isMainModule:
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
    let prog = compile(pat)
    echo disassemble(prog)
    echo ""