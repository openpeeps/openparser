# A collection of tiny parsers and dumpers
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/openparser

## Prefilter: static analysis of a Program to extract a cheap "first-byte hint"
## that lets the VM skip impossible start positions.

import ./compiler, ./simd

type
  BackscanKind* = enum
    bsNone, bsAlphaWord, bsWordChar

  PrefilterKind* = enum
    pfNone
    pfByte
    pfLiteral
    pfByteRange
    pfAnyOf2
    pfAnchorStart
    pfAlpha          ## [a-zA-Z_]
    pfWordChar       ## [a-zA-Z0-9_]
    pfUpperAlpha     ## [A-Z_]  — macro/constant start
    pfLiteralAnchored
    pfInnerLiteral

  Prefilter* {.acyclic.} = ref object
    case kind*: PrefilterKind
    of pfByte:
      byte1*: char
    of pfLiteral, pfLiteralAnchored:
        prefix*: string
        offset*: int   ## max lookback
        offset2*: int  ## min lookback
    of pfInnerLiteral:
      anchor*: char
      maxLookback*: int
      backscan*: BackscanKind
    of pfByteRange:
      lo*, hi*: char
    of pfAnyOf2:
      alt1*, alt2*: char
    of pfAnchorStart, pfNone, pfAlpha, pfWordChar, pfUpperAlpha: discard
    shape*: PatternShape
    literalEndPc*: int  ## PC after literal prefix (for pfLiteral advance optimization)

proc findInnerLiteral(prog: Program): tuple[ch: char, maxLookback: int, bs: BackscanKind] =
  # Walk instruction stream past variable-width prefix looking for a selective
  # mandatory literal (e.g. '(' in `\w*\s*\([^)]*\)`).
  # Returns '\0' if not found or if the lookback would be unbounded.
  const SELECTIVE = {'(', ')', ';', ':', '#', '"', '<', '>', '[', ']', '{', '}', '!', '=', '/', '*'}
  const MAX = 1024
  var pc = 0
  var maxLookback = 0
  var seenAlphaClass = false
  var seenWordClass  = false

  while pc < prog.instrs.len and maxLookback <= MAX:
    let ins = prog.instrs[pc]
    case ins.op
    of opChar:
      if char(ins.arg1) in SELECTIVE:
        let bs = if seenAlphaClass: bsAlphaWord
                 elif seenWordClass: bsWordChar
                 else: bsNone
        return (char(ins.arg1), maxLookback, bs)
      inc maxLookback; inc pc
    of opSave, opProgress, opJmp:
      inc pc                              # transparent — don't count
    of opEscapeClass:
      let cls = char(ins.arg1)
      if cls in {'w', 'W', 'd', 'D', 's', 'S'}: seenWordClass = true
      maxLookback = min(maxLookback + 8, MAX)
      inc pc
    of opCharClass:
      seenAlphaClass = true
      maxLookback = min(maxLookback + 8, MAX)
      inc pc
    of opAnyChar:
      maxLookback = min(maxLookback + 8, MAX)
      inc pc
    of opSplit, opSplitLazy:
      # Peek at loop body for literals inside quantifier loops.
      # A quantifier loop has a JMP back-edge to the SPLIT itself.
      # For + quantifier: SPLIT(body, exit); PROGRESS; <body>; JMP(split)
      # For * quantifier: SPLIT(body, exit); <body>; JMP(split)
      let bodyPc = ins.arg1
      let exitPc = ins.arg2
      # Check if this is a quantifier loop (exit has JMP back to this split)
      let isLoop = exitPc >= 0 and exitPc < prog.instrs.len and
                   prog.instrs[exitPc].op == opJmp and
                   prog.instrs[exitPc].arg1 == pc
      if isLoop and bodyPc < prog.instrs.len:
        let bodyIns = prog.instrs[bodyPc]
        var litPc = bodyPc
        if bodyIns.op == opProgress and bodyPc + 1 < prog.instrs.len:
          litPc = bodyPc + 1  # skip PROGRESS to get to actual body
        if litPc < prog.instrs.len and prog.instrs[litPc].op == opChar:
          let ch = char(prog.instrs[litPc].arg1)
          if ch in SELECTIVE:
            let bs = if seenAlphaClass: bsAlphaWord
                     elif seenWordClass: bsWordChar
                     else: bsNone
            return (ch, maxLookback + 1, bs)
      # Continue with exit branch as before
      maxLookback = min(maxLookback + 32, MAX)
      pc = if ins.op == opSplit: ins.arg2 else: ins.arg1  # exit branch
      # no inc pc — pc is already set to exit
    else:
      break

  ('\0', 0, bsNone)

proc longestCommonSubstring(a, b: string): tuple[s: string, offA, offB: int] =
  # Returns the longest common substring of a and b, plus its offsets in each.
  var best = ""
  var bestOA, bestOB = 0
  for i in 0 ..< a.len:
    for j in 0 ..< b.len:
      var k = 0
      while i+k < a.len and j+k < b.len and a[i+k] == b[j+k]: inc k
      if k > best.len:
        best  = a[i ..< i+k]
        bestOA = i; bestOB = j
  (best, bestOA, bestOB)

proc extractAlternationPrefilter(branches: seq[string], shape: PatternShape): Prefilter =
  # Given literal prefixes of each alternation branch, find the best anchor.
  if branches.len == 0: return Prefilter(kind: pfNone, shape: shape)

  # All branches share full prefix → standard pfLiteral
  var common = branches[0]
  for b in branches[1..^1]:
    var i = 0
    while i < common.len and i < b.len and common[i] == b[i]: inc i
    common = common[0 ..< i]
  if common.len >= 2:
    return Prefilter(kind: pfLiteral, prefix: common, offset: 0, shape: shape)

  # Two branches share a common substring pfLiteralAnchored with lookaround
  if branches.len == 2:
    let (sub, offA, offB) = longestCommonSubstring(branches[0], branches[1])
    if sub.len >= 3:
      let maxOff = max(offA, offB)
      let minOff = min(offA, offB)
      return Prefilter(kind: pfLiteralAnchored, prefix: sub,
                       offset: maxOff, offset2: minOff, shape: shape)

  # Fallback: first byte of shortest branch
  var shortest = branches[0]
  for b in branches[1..^1]:
    if b.len < shortest.len: shortest = b
  if shortest.len >= 1:
    return Prefilter(kind: pfByte, byte1: shortest[0], shape: shape)
  Prefilter(kind: pfNone, shape: shape)

proc extractLiteralPrefix(prog: Program): string =
  ## Walk instructions from pc=0, collecting consecutive opChar bytes,
  ## skipping pure epsilon ops (opJmp/opSave/opProgress).
  var pc = 0
  while pc < prog.instrs.len:
    let ins = prog.instrs[pc]
    case ins.op
    of opChar:
      result.add char(ins.arg1)
      inc pc
    of opJmp, opSave, opProgress:
      inc pc   # transparent epsilon — keep looking
    else:
      break    # first non-literal consuming op

proc extractPrefilter*(prog: Program): Prefilter =
  ## Walk the first instruction(s) of the program and derive the cheapest
  ## possible prefilter.  We resolve Splits one level deep.
  if prog.instrs.len == 0:
    return Prefilter(kind: pfNone, shape: psNone)

  let shape = prog.shape   # set by compiler — always correct
  # Alternation: collect per-branch literal prefixes
  proc branchLiterals(prog: Program): seq[string] =
    ## Walk a top-level Split chain and extract the literal prefix of each branch.
    ## Returns empty if structure isn't a simple alternation of literal-prefixed branches.
    var pc = 0
    # skip leading epsilon ops before the Split
    while pc < prog.instrs.len:
      let ins = prog.instrs[pc]
      if ins.op in {opSave, opProgress, opJmp}:
        inc pc
      else:
        break

    while pc < prog.instrs.len:
      let ins = prog.instrs[pc]
      if ins.op == opSplit:
        var s = ""
        var p = ins.arg1
        # also skip epsilons inside each branch
        while p < prog.instrs.len and prog.instrs[p].op in {opSave, opProgress, opJmp}:
          inc p
        while p < prog.instrs.len and prog.instrs[p].op == opChar:
          s.add char(prog.instrs[p].arg1); inc p
        if s.len >= 2: result.add s
        pc = ins.arg2
        # skip epsilons on second branch too
        while pc < prog.instrs.len and prog.instrs[pc].op in {opSave, opProgress, opJmp}:
          inc pc
      elif ins.op == opChar:
        var s = ""
        var p = pc
        while p < prog.instrs.len and prog.instrs[p].op == opChar:
          s.add char(prog.instrs[p].arg1); inc p
        if s.len >= 2: result.add s
        break
      else: break

  # 1. Multi-byte literal prefix — most selective
  let lit = extractLiteralPrefix(prog)
  if lit.len >= 2:
    # Calculate literalEndPc: the PC after the last literal char
    var lpc = 0
    while lpc < prog.instrs.len:
      let ins = prog.instrs[lpc]
      case ins.op
      of opChar: inc lpc
      of opJmp, opSave, opProgress: inc lpc
      else: break
    return Prefilter(kind: pfLiteral, prefix: lit, offset: 0, shape: shape, literalEndPc: lpc)

  # 2. Alternation with shared/anchored literal
  let branches = branchLiterals(prog)
  if branches.len >= 2:
    let pf = extractAlternationPrefilter(branches, shape)
    if pf.kind notin {pfNone, pfByte}: return pf

  # 3. Inner mandatory literal — check BEFORE falling back to class prefilters.
  #    A selective char like '(' is far cheaper than pfAlpha/pfWordChar.
  #    Skip for shapes that have their own SIMD fast-path.
  if shape notin {psWordSpaceStarWord, psLitSpaceWordPlus, psLitWordSpaceWord,
                   psLitWordSpaceWordPlus, psHexPrefixHexPlus, psDigitPlusULSuffix,
                   psEndAnchorByte}:
    let (innerCh, maxLb, bs) = findInnerLiteral(prog)
    if innerCh != '\0' and maxLb > 0:
      return Prefilter(kind: pfInnerLiteral, anchor: innerCh,
                       maxLookback: maxLb, backscan: bs, shape: shape)

  # 4. Shape fast-path (pure SIMD, no NFA)
  if shape != psNone:
    # derive first-byte prefilter from shape
    case shape
    of psAlphaWordStar, psUpperDigitUnderPlus,
       psUpperDigitUnder2Plus, psUpperDigitUnderStar:
      return Prefilter(kind: pfAlpha, shape: shape)
    of psWordCharPlus, psWordCharStar:
      return Prefilter(kind: pfWordChar, shape: shape)
    of psEndAnchorByte:
      # X\s*$ — use pfByte to scan for the byte, shape fast-path handles the rest
      if prog.instrs.len > 0 and prog.instrs[0].op == opChar:
        return Prefilter(kind: pfByte, byte1: char(prog.instrs[0].arg1), shape: shape)
      return Prefilter(kind: pfNone, shape: shape)
    of psWordSpaceStarWord:
      # \w+\s*\*+\s*\w+ — scan for first word char
      return Prefilter(kind: pfWordChar, shape: shape)
    of psLitSpaceWordPlus, psLitWordSpaceWord, psLitWordSpaceWordPlus:
      # <literal>... — use pfLiteral to scan for literal prefix, shape fast-path handles rest
      let lit = extractLiteralPrefix(prog)
      if lit.len >= 2:
        var lpc = 0
        while lpc < prog.instrs.len:
          let ins = prog.instrs[lpc]
          case ins.op
          of opChar: inc lpc
          of opJmp, opSave, opProgress: inc lpc
          else: break
        return Prefilter(kind: pfLiteral, prefix: lit, offset: 0,
                         shape: shape, literalEndPc: lpc)
      return Prefilter(kind: pfNone, shape: shape)
    of psHexPrefixHexPlus:
      # 0[xX][0-9a-fA-F]+ — scan for '0'
      return Prefilter(kind: pfByte, byte1: '0', shape: shape)
    of psDigitPlusULSuffix:
      # \d+[uUlL]* — scan for digit
      return Prefilter(kind: pfByteRange, lo: '0', hi: '9', shape: shape)
    else: discard

  proc firstConsuming(prog: Program, pc: int,
                      depth = 0): tuple[op: OpCode, arg1: int] =
    if depth > 64 or pc < 0 or pc >= prog.instrs.len:
      return (opMatch, 0)
    let ins = prog.instrs[pc]
    case ins.op
    of opJmp:                return firstConsuming(prog, ins.arg1, depth+1)
    of opSplit, opSplitLazy: return firstConsuming(prog, ins.arg1, depth+1)
    of opSave, opProgress:   return firstConsuming(prog, pc+1,    depth+1)
    of opAnchorStart:        return (opAnchorStart, 0)
    else:                    return (ins.op, ins.arg1)

  let (op, arg1) = firstConsuming(prog, 0)

  template make(k: PrefilterKind): Prefilter =
    Prefilter(kind: k, shape: shape)

  case op
  of opAnchorStart:
    return make(pfAnchorStart)
  of opChar:
    let ins0 = prog.instrs[0]
    if ins0.op in {opSplit, opSplitLazy} and ins0.arg2 >= 0:
      let (op2, arg2) = firstConsuming(prog, ins0.arg2)
      if op2 == opChar:
        return Prefilter(kind: pfAnyOf2, alt1: char(arg1), alt2: char(arg2),
                         shape: shape)
    return Prefilter(kind: pfByte, byte1: char(arg1), shape: shape)
  of opCharClass:
    let cls = prog.classes[arg1]
    if not cls.negated:
      var hasLo, hasUp, hasUs, hasDi: bool
      var other = 0
      for it in cls.items:
        if it.isRange:
          if   it.lo=='a' and it.hi=='z': hasLo = true
          elif it.lo=='A' and it.hi=='Z': hasUp = true
          elif it.lo=='0' and it.hi=='9': hasDi = true
          else: inc other
        else:
          if it.ch == '_': hasUs = true
          else: inc other
      if other == 0:
        if hasLo and hasUp and hasUs and hasDi: return make(pfWordChar)
        if hasLo and hasUp and hasUs:           return make(pfAlpha)
        if hasUp and hasUs and not hasLo:       return make(pfUpperAlpha)  ## [A-Z_]
      if cls.items.len == 1 and cls.items[0].isRange:
        return Prefilter(kind: pfByteRange,
                         lo: cls.items[0].lo, hi: cls.items[0].hi, shape: shape)
    return make(pfNone)
  of opEscapeClass:
    case char(arg1)
    of 'd': return Prefilter(kind: pfByteRange, lo: '0', hi: '9', shape: shape)
    of 'w': return make(pfWordChar)
    of 's': return Prefilter(kind: pfAnyOf2, alt1: ' ', alt2: '\t', shape: shape)
    else:   return make(pfNone)
  else:
    return make(pfNone)

proc nextCandidate*(pf: Prefilter, input: string,
                    pos, inputLen: int): int {.inline.} =
  ## Given a prefilter and an input position, return the next position at
  ## or after pos that could possibly match, or inputLen+1 if no such position exists.
  case pf.kind
  of pfNone:        pos
  of pfAnchorStart:
    if pos == 0: 0 else: inputLen + 1
  of pfByte:
    let r = scanByte(input, pos, inputLen, pf.byte1)
    if r < 0: inputLen + 1 else: r
  of pfLiteral:
    # Simple forward scan for first byte, then verify full prefix.
    # Even naive search over N-byte prefix is far faster than NFA-per-byte.
    let first = pf.prefix[0]
    let plen  = pf.prefix.len
    var i = pos
    while i <= inputLen - plen:
      let r = scanByte(input, i, inputLen - plen + 1, first)
      if r < 0: return inputLen + 1
      # verify remaining prefix bytes
      var match = true
      for j in 1 ..< plen:
        if input[r + j] != pf.prefix[j]: match = false; break
      if match: return r
      i = r + 1
    inputLen + 1
  of pfByteRange:
    let r = scanByteRange(input, pos, inputLen, pf.lo, pf.hi)
    if r < 0: inputLen + 1 else: r
  of pfAnyOf2:
    let r = scanAnyOf(input, pos, inputLen, pf.alt1, pf.alt2)
    if r < 0: inputLen + 1 else: r
  of pfAlpha:
    let r = scanAlphaUnderscore(input, pos, inputLen)
    if r < 0: inputLen + 1 else: r
  of pfWordChar:
    let r = scanWordChar(input, pos, inputLen)
    if r < 0: inputLen + 1 else: r
  of pfUpperAlpha:
    let r = scanUpperDigitUnder(input, pos, inputLen)   ## [A-Z0-9_] ⊇ [A-Z_]
    if r < 0: inputLen + 1 else: r
  of pfLiteralAnchored:
    # Scan for the anchor substring, return pos adjusted by lookback.
    let first = pf.prefix[0]
    let plen  = pf.prefix.len
    var i = pos + pf.offset   # don't scan before we could have a valid start
    while i <= inputLen - plen:
      let r = scanByte(input, i, inputLen - plen + 1, first)
      if r < 0: return inputLen + 1
      var match = true
      for j in 1 ..< plen:
        if input[r + j] != pf.prefix[j]: match = false; break
      if match:
        return max(0, r - pf.offset)   # NFA start with lookback
      i = r + 1
    inputLen + 1
  of pfInnerLiteral:
    # Scan for the selective anchor char; backscan to NFA start is done in find/findAll.
    # nextCandidate just returns the anchor position for the VM to handle.
    let r = scanByte(input, pos, inputLen, pf.anchor)
    if r < 0: inputLen + 1 else: r