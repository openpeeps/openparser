# A collection of tiny parsers and dumpers
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/openparser

## Prefilter: static analysis of a Program to extract a cheap "first-byte hint"
## that lets the VM skip impossible start positions.

import ./compiler, ./simd

type
  PrefilterKind* = enum
    pfNone
    pfByte
    pfLiteral
    pfByteRange
    pfAnyOf2
    pfAnyOfN         ## first bytes of a 3+-branch alternation (cap 8)
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
      firstAlpha*: bool  ## match start must be [a-zA-Z_]
      gapFirst*: bool    ## prefix may start with a gap: try every window pos
      fastStarts*: bool  ## exact-word loop first: only run starts can win
      runGroups*: int    ## logical run clusters in the prefix
      skipPairs*: bool   ## no lone `*` runs: first-run window is exact
    of pfByteRange:
      lo*, hi*: char
    of pfAnyOf2:
      alt1*, alt2*: char
    of pfAnyOfN:
      alts*: seq[char]  ## distinct first bytes, 3..8 (owned by the prefilter)
    of pfAnchorStart, pfNone, pfAlpha, pfWordChar, pfUpperAlpha: discard
    shape*: PatternShape
    literalEndPc*: int  ## PC after literal prefix (for pfLiteral advance optimization)

proc isLoopSplit(prog: Program, pc: int): bool =
  ## True if instrs[pc] heads a greedy/lazy quantifier loop: the body
  ## follows immediately and a jump back to pc closes it before the exit.
  ## Alternation and bounded `{m,n}`/`?` forks have no back edge.
  if pc < 0 or pc + 1 >= prog.instrs.len: return false
  let s = prog.instrs[pc]
  if s.op notin {opSplit, opSplitLazy}: return false
  if s.arg1 != pc + 1 or s.arg2 < 0 or s.arg2 > prog.instrs.len: return false
  for q in pc + 1 ..< min(s.arg2, prog.instrs.len):
    if prog.instrs[q].op == opJmp and prog.instrs[q].arg1 == pc:
      return true
  false

proc findInnerLiteral(prog: Program): tuple[ch: char, firstAlpha, gapFirst, firstExact, firstLoop: bool, groups: int, skipOk: bool] =
  # Walk instruction stream past variable-width prefix looking for a selective
  # mandatory literal (e.g. '(' in `\w+\s*\([^)]*\)`).
  # Returns ('\0', false, false) when no sound filter exists. Soundness rules:
  # - every walked consuming op must consume only word/space chars, so any
  #   match that uses this anchor occurrence starts inside the maximal
  #   word/space region before it. The VM enumerates every position in that
  #   window and lets the verifier pick the leftmost: overshoot and
  #   undershoot are impossible by construction;
  # - only transparent epsilons and quantifier loops (followed via the exit
  #   every complete match takes) may be walked; forks whose branches need
  #   not contain the literal bail out;
  # - the anchor must be mandatory on all walked paths.
  const SELECTIVE = {'(', ')', ';', ':', '#', '"', '<', '>', '[', ']', '{', '}', '!', '=', '/', '*'}
  const WordChars = {'a'..'z', 'A'..'Z', '0'..'9', '_'}
  const AlphaChars = {'a'..'z', 'A'..'Z', '_'}
  const SpaceChars = {' ', '\t', '\n', '\r', '\f', '\v'}
  var pc = 0
  var guard = prog.instrs.len * 4 + 64
  var runs = 0
  var sawGap = false
  var firstKind = 0  # 0 unset, 1 word-run, 2 alpha-run, 3 gap
  var firstExact = false  # first run accepts any word char (\w / exact class)
  var firstLoop = false   # first run is loop-like (body, or single + star loop)
  var groups = 0     # logical run clusters separated by gaps
  var runOpen = false     # currently inside a logical run
  var gapPending = false  # a gap was seen since the current logical run
  var hasLoneStar = false # a lone `*` loop (nullable run) precedes the anchor

  template noLiteral(): tuple[ch: char, firstAlpha, gapFirst, firstExact, firstLoop: bool, groups: int, skipOk: bool] = ('\0', false, false, false, false, 0, false)
  template loopHeadExactWord(splitPc: int): bool =
    ## True when the loop at splitPc repeats an exact-word atom
    ## (\w or an exact [A-Za-z0-9_] class): a following star loop makes
    ## a leading inline single loop-like (plus-form copy + star tail).
    var ok = false
    var hq = splitPc + 1
    while hq < prog.instrs.len and prog.instrs[hq].op in {opSave, opProgress}:
      inc hq
    if hq < prog.instrs.len:
      case prog.instrs[hq].op
      of opEscapeClass:
        ok = char(prog.instrs[hq].arg1) == 'w'
      of opCharClass:
        ok = exactWord(prog.classes[prog.instrs[hq].arg1])
      else: discard
    ok
  template noteRun(alphaOnly, exactWordAtom, loopLike: bool) =
    ## A run-ish atom (word/alpha consumption). The first one decides the
    ## candidate filter: alpha-only first atoms need only alpha positions;
    ## exact-word loop-like first atoms need only run starts (fast path).
    ## Adjacent run atoms merge into one logical run (plus-form copy +
    ## star tail); only a run after a gap opens a new cluster.
    if firstKind == 0:
      firstKind = if alphaOnly: 2 else: 1
      firstExact = exactWordAtom
      firstLoop = loopLike
    if not runOpen:
      groups += 1
    runOpen = true
    gapPending = false
    inc runs
  template noteGap() =
    ## A gap atom (spaces). A gap-first prefix may start on a space, so
    ## the VM must try every window position unfiltered.
    if firstKind == 0:
      firstKind = 3
    sawGap = true
    gapPending = true
    runOpen = false
  template exactWord(cls: CompiledClass): bool =
    ## True when the class matches exactly [A-Za-z0-9_] (or \w).
    var ok = not cls.negated
    var hasLo, hasUp, hasDi, hasUs, hasW = false
    if ok:
      for it in cls.items:
        if it.isRange:
          if it.lo == 'a' and it.hi == 'z': hasLo = true
          elif it.lo == 'A' and it.hi == 'Z': hasUp = true
          elif it.lo == '0' and it.hi == '9': hasDi = true
          else: ok = false; break
        elif it.isEscape:
          if it.escapeChar == 'w': hasW = true
          else: ok = false; break
        else:
          if it.ch == '_': hasUs = true
          else: ok = false; break
      ok = ok and ((hasLo and hasUp and hasDi and hasUs) or hasW)
    ok
  template classSets(cls: CompiledClass): tuple[w, s, a, ws: bool] =
    ## w: matches only word chars; s: only spaces; a: only alpha;
    ## ws: only word-or-space (mixed, e.g. [\w\s] — treated as a gap).
    ## Anything else (negations, dots-outside-class, \D\W\S) clears all.
    var w = not cls.negated
    var s = not cls.negated
    var a = not cls.negated
    var ws = not cls.negated
    if w or s or a or ws:
      for it in cls.items:
        var iw, sp, ia: bool
        if it.isRange:
          iw = (it.lo == 'a' and it.hi == 'z') or
               (it.lo == 'A' and it.hi == 'Z') or
               (it.lo == '0' and it.hi == '9') or
               (it.lo == it.hi and it.lo in WordChars)
          sp = it.lo == '\t' and it.hi == '\r'
          ia = (it.lo == 'a' and it.hi == 'z') or
               (it.lo == 'A' and it.hi == 'Z') or
               (it.lo == it.hi and it.lo in AlphaChars)
        elif it.isEscape:
          case it.escapeChar
          of 'w': iw = true
          of 'd': iw = true  # digits are word chars
          of 's': sp = true
          else: discard
        else:
          iw = it.ch in WordChars
          sp = it.ch in SpaceChars
          ia = it.ch in AlphaChars
        if iw: discard
        else: w = false
        if sp: discard
        else: s = false
        if ia: discard
        else: a = false
        if not (iw or sp): ws = false
        if not w and not s and not a and not ws: break
    (w, s, a, ws)

  while pc < prog.instrs.len and guard > 0:
    dec guard
    let ins = prog.instrs[pc]
    case ins.op
    of opSave, opProgress, opJmp, opAnchorStart, opAnchorEnd, opWordBoundary:
      inc pc  # transparent — zero-width, no window impact
    of opChar:
      let c = char(ins.arg1)
      if c in SELECTIVE:
        # An anchor with no run or gap behind it is handled by cheaper
        # prefilters; the window needs something to anchor the scan.
        if runs == 0 and not sawGap:
          return noLiteral()
        return (c, firstKind == 2, firstKind == 3, firstExact, firstLoop, groups, not hasLoneStar)
      if c in SpaceChars:
        noteGap()
      elif c in WordChars:
        # A concrete word char: the window plus verifier still locate
        # the start soundly (the verifier checks the exact char).
        # Singles are subset runs: only the loop lookahead matters
        # for loop-likeness, and singles never qualify as exact.
        noteRun(c in AlphaChars, false, false)
      else:
        # Consumes outside word/space: the match start may lie outside
        # the region the VM walks back over — bail out.
        return noLiteral()
      inc pc
    of opEscapeClass:
      case char(ins.arg1)
      of 'w':
        noteRun(false, true,
                pc + 1 < prog.instrs.len and isLoopSplit(prog, pc + 1) and
                loopHeadExactWord(pc + 1))
      of 'd':
        noteRun(false, false, false)  # digits: subset run, full window
      of 's':
        noteGap()
      else:
        return noLiteral()
      inc pc
    of opCharClass:
      let sets = classSets(prog.classes[ins.arg1])
      if sets.a:
        noteRun(true, false, false)
      elif sets.w:
        noteRun(false, exactWord(prog.classes[ins.arg1]),
                pc + 1 < prog.instrs.len and isLoopSplit(prog, pc + 1) and
                loopHeadExactWord(pc + 1))
      elif sets.s or sets.ws:
        noteGap()
      else:
        return noLiteral()
      inc pc
    of opAnyChar:
      # Matches anything, including region break chars.
      return noLiteral()
    of opSplit, opSplitLazy:
      # Only quantifier loops may be followed, via the exit every
      # complete match takes (greedy and lazy share the layout).
      # Anything else is a fork whose branches need not contain the
      # literal: bail out.
      if not isLoopSplit(prog, pc):
        return noLiteral()
      var bodyPc = pc + 1
      var plusForm = false
      if prog.instrs[bodyPc].op == opProgress and bodyPc + 1 < prog.instrs.len:
        plusForm = true
        bodyPc += 1

      if plusForm and bodyPc < prog.instrs.len and
         prog.instrs[bodyPc].op == opChar:
        let ch = char(prog.instrs[bodyPc].arg1)
        if ch in SELECTIVE:
          # `+` runs its body at least once, so a selective literal
          # opening the body is mandatory. The window covers the
          # pre-loop prefix, which the flags describe.
          if runs == 0 and not sawGap:
            return noLiteral()
          return (ch, firstKind == 2, firstKind == 3, firstExact, firstLoop, groups, not hasLoneStar)
      # The loop body must be a single word/space-compatible consuming
      # op; anything else may hide characters outside the region.
      # Find the back-jump first.
      var jmpPc = -1
      var q = bodyPc
      while q < prog.instrs.len:
        if prog.instrs[q].op == opJmp and prog.instrs[q].arg1 == pc:
          jmpPc = q
          break
        if prog.instrs[q].op notin {opSave, opProgress}:
          # First consuming op: it must be the whole body (followed
          # only by transparent epsilons, then the back-jump).
          var r = q + 1
          while r < prog.instrs.len and prog.instrs[r].op in {opSave, opProgress}:
            inc r
          if r >= prog.instrs.len or prog.instrs[r].op != opJmp or
             prog.instrs[r].arg1 != pc:
            return noLiteral()  # multi-op body: cannot verify coverage
          jmpPc = r
          break
        inc q
      if jmpPc < 0:
        return noLiteral()  # no back edge found (should not happen)
      # Walk the single body op for compatibility, like inline code.
      # (bodyPc points at/after progress; re-skip transparent epsilons)
      var bq = bodyPc
      while bq < prog.instrs.len and prog.instrs[bq].op in {opSave, opProgress}:
        inc bq
      if bq < prog.instrs.len:
        case prog.instrs[bq].op
        of opChar:
          let c = char(prog.instrs[bq].arg1)
          if c in SELECTIVE:
            # Selective body char without +-form peek: the loop may
            # skip it, so it is not mandatory. Bail out.
            return noLiteral()
          elif c in SpaceChars:
            noteGap()
          elif c in WordChars:
            # A lone `*` run body matches empty: pattern runs can vanish,
            # so the backward run alignment may shift and the VM must not
            # narrow the window. (Plus-form tails are covered by their
            # mandatory copy, so they stay precise.)
            if not plusForm: hasLoneStar = true
            noteRun(c in AlphaChars, false, true)
          else:
            return noLiteral()
        of opEscapeClass:
          case char(prog.instrs[bq].arg1)
          of 'w':
            if not plusForm: hasLoneStar = true
            noteRun(false, true, true)
          of 'd':
            if not plusForm: hasLoneStar = true
            noteRun(false, false, true)
          of 's':
            noteGap()
          else:
            return noLiteral()
        of opCharClass:
          let sets = classSets(prog.classes[prog.instrs[bq].arg1])
          if sets.a:
            if not plusForm: hasLoneStar = true
            noteRun(true, false, true)
          elif sets.w:
            if not plusForm: hasLoneStar = true
            noteRun(false, exactWord(prog.classes[prog.instrs[bq].arg1]), true)
          elif sets.s or sets.ws:
            noteGap()
          else:
            return noLiteral()
        else:
          return noLiteral()
      else:
        return noLiteral()
      pc = ins.arg2  # exit branch (shared layout for greedy and lazy)
    else:
      break

  noLiteral()

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

proc extractAlternationPrefilter(branches: seq[string], total: int,
                                 shape: PatternShape): Prefilter =
  # Every alternation branch must carry a literal prefix for byte
  # filtering to be sound: otherwise a non-literal branch could match
  # where no literal occurs (e.g. `cat|dog` must not filter on 'c').
  if branches.len == 0 or branches.len != total:
    return Prefilter(kind: pfNone, shape: shape)

  # All branches share full prefix → standard pfLiteral
  var common = branches[0]
  for b in branches[1..^1]:
    var i = 0
    while i < common.len and i < b.len and common[i] == b[i]: inc i
    common = common[0 ..< i]
  if common.len >= 2:
    return Prefilter(kind: pfLiteral, prefix: common, offset: 0, shape: shape)

  if branches.len == 2:
    # Two branches share a common substring pfLiteralAnchored with lookaround
    let (sub, offA, offB) = longestCommonSubstring(branches[0], branches[1])
    if sub.len >= 3:
      let maxOff = max(offA, offB)
      let minOff = min(offA, offB)
      return Prefilter(kind: pfLiteralAnchored, prefix: sub,
                       offset: maxOff, offset2: minOff, shape: shape)
    # No shared literal: a match must start with one of the two bytes.
    return Prefilter(kind: pfAnyOf2, alt1: branches[0][0],
                     alt2: branches[1][0], shape: shape)

  # Three or more branches, no long shared anchor: a match must start
  # with one of the branches' first bytes. Beyond 8 distinct bytes the
  # SIMD OR-tree costs more than it saves → no filter.
  var firstBytes: seq[char] = @[]
  for s in branches:
    if s[0] notin firstBytes: firstBytes.add(s[0])
  case firstBytes.len
  of 1:
    return Prefilter(kind: pfByte, byte1: firstBytes[0], shape: shape)
  of 2:
    return Prefilter(kind: pfAnyOf2, alt1: firstBytes[0],
                     alt2: firstBytes[1], shape: shape)
  of 3..8:
    return Prefilter(kind: pfAnyOfN, alts: firstBytes, shape: shape)
  else:
    return Prefilter(kind: pfNone, shape: shape)

proc extractLiteralPrefix(prog: Program): string =
  ## Walk instructions from pc=0, collecting consecutive opChar bytes,
  ## skipping pure epsilon ops (opJmp/opSave/opProgress). Bails with ""
  ## on any split: a fork means the collected bytes only prefix one
  ## branch (e.g. `ab` in `ab|\d+`), never the whole program.
  var pc = 0
  while pc < prog.instrs.len:
    let ins = prog.instrs[pc]
    case ins.op
    of opChar:
      result.add char(ins.arg1)
      inc pc
    of opJmp, opSave, opProgress:
      inc pc   # transparent epsilon — keep looking
    of opSplit, opSplitLazy:
      result = ""  # fork: collected bytes are not a global prefix
      break
    else:
      break    # first non-literal consuming op ends a global prefix

proc extractPrefilterInner(prog: Program): Prefilter =
  ## Walk the first instruction(s) of the program and derive the cheapest
  ## possible prefilter.  We resolve Splits one level deep.
  if prog.instrs.len == 0:
    return Prefilter(kind: pfNone, shape: psNone)

  let shape = prog.shape   # set by compiler — always correct
  # Alternation: collect per-branch literal prefixes plus branch count.
  proc branchLiterals(prog: Program): tuple[strs: seq[string], total: int] =
    ## Walk a top-level Split chain and extract the literal prefix of each branch.
    ## `total` counts every branch; filtering is only sound when each one
    ## contributed a literal (`strs.len == total`). Single-char prefixes
    ## are kept: they feed AnyOf2 when longer anchors are absent.
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
        inc result.total
        var s = ""
        var p = ins.arg1
        # also skip epsilons inside each branch
        while p < prog.instrs.len and prog.instrs[p].op in {opSave, opProgress, opJmp}:
          inc p
        while p < prog.instrs.len and prog.instrs[p].op == opChar:
          s.add char(prog.instrs[p].arg1); inc p
        if s.len >= 1: result.strs.add s
        pc = ins.arg2
        # skip epsilons on second branch too
        while pc < prog.instrs.len and prog.instrs[pc].op in {opSave, opProgress, opJmp}:
          inc pc
      elif ins.op == opChar:
        inc result.total
        var s = ""
        var p = pc
        while p < prog.instrs.len and prog.instrs[p].op == opChar:
          s.add char(prog.instrs[p].arg1); inc p
        if s.len >= 1: result.strs.add s
        break
      else:
        # final branch without a literal prefix (e.g. \d+ in `ab|\d+`)
        inc result.total
        break

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
  let (altStrs, altTotal) = branchLiterals(prog)
  if altTotal >= 2:
    let pf = extractAlternationPrefilter(altStrs, altTotal, shape)
    if pf.kind != pfNone: return pf

  # 3. Inner mandatory literal — check BEFORE falling back to class prefilters.
  #    A selective char like '(' is far cheaper than pfAlpha/pfWordChar:
  #    the VM scans for the rare anchor, then enumerates the word/space
  #    window before it and lets the verifier pick the leftmost start.
  #    Skip for shapes that have their own SIMD fast-path.
  if shape notin {psWordSpaceStarWord, psLitSpaceWordPlus, psLitWordSpaceWord,
                   psLitWordSpaceWordPlus, psHexPrefixHexPlus, psDigitPlusULSuffix,
                   psEndAnchorByte}:
    let (innerCh, innerAlpha, innerGap, innerExact,
         innerLoop, innerGroups, innerSkip) = findInnerLiteral(prog)
    if innerCh != '\0':
      return Prefilter(kind: pfInnerLiteral, anchor: innerCh,
                       firstAlpha: innerAlpha, gapFirst: innerGap,
                       fastStarts: not innerGap and not innerAlpha and
                                   innerExact and innerLoop,
                       runGroups: innerGroups, skipPairs: innerSkip,
                       shape: shape)

  # 4. Shape fast-path (pure SIMD, no NFA)
  if shape != psNone:
    # derive first-byte prefilter from shape
    case shape
    of psAlphaWordStar:
      return Prefilter(kind: pfAlpha, shape: shape)
    of psUpperDigitUnderPlus,
       psUpperDigitUnder2Plus, psUpperDigitUnderStar:
      # Head must be [A-Z_]: scan the [A-Z0-9_] superset (fewer
      # candidates than pfAlpha); execShape rejects digit heads.
      return Prefilter(kind: pfUpperAlpha, shape: shape)
    of psWordCharPlus, psWordCharStar:
      return Prefilter(kind: pfWordChar, shape: shape)
    of psEndAnchorByte:
      # X\s*$ — use pfByte to scan for the byte, shape fast-path handles the rest
      if prog.instrs.len > 0 and prog.instrs[0].op == opChar:
        return Prefilter(kind: pfByte, byte1: char(prog.instrs[0].arg1), shape: shape)
      return Prefilter(kind: pfNone, shape: shape)
    of psWordSpaceStarWord:
      # \w+\s*\*+\s*\w+ — the '*' run is mandatory and sparse: anchor
      # candidates on it and enumerate the window to the \w+ start
      # instead of trying every (dense) word char.
      return Prefilter(kind: pfInnerLiteral, anchor: '*',
                       firstAlpha: false, gapFirst: false,
                       fastStarts: true, runGroups: 1, skipPairs: true,
                       shape: shape)
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

  # First consuming op along a single path. Stops at splits: a fork
  # means the opener depends on the branch taken, so only the
  # alternation-aware step above may filter on it.
  proc firstConsuming(prog: Program, pc: int,
                      depth = 0): tuple[op: OpCode, arg1: int] =
    if depth > 64 or pc < 0 or pc >= prog.instrs.len:
      return (opMatch, 0)
    let ins = prog.instrs[pc]
    case ins.op
    of opJmp:                return firstConsuming(prog, ins.arg1, depth+1)
    of opSplit, opSplitLazy: return (opSplit, 0)
    of opSave, opProgress:   return firstConsuming(prog, pc+1,    depth+1)
    of opAnchorStart:        return (opAnchorStart, 0)
    else:                    return (ins.op, ins.arg1)

  let (op, arg1) = firstConsuming(prog, 0)

  template make(k: PrefilterKind): Prefilter =
    Prefilter(kind: k, shape: shape)

  case op
  of opAnchorStart:
    return make(pfAnchorStart)
  of opSplit, opSplitLazy:
    # Fork on the path: branches are covered at step 2 when every one
    # opens with a literal, otherwise no sound filter exists.
    return make(pfNone)
  of opChar:
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

proc extractPrefilter*(prog: Program): Prefilter =
  ## Prefilter with a nullability guard. A nullable pattern can match
  ## empty at a skipped offset, so every position must be verified: only
  ## a start anchor still filters soundly, and shape fast paths are off.
  ## (Skipping is only unsound for emptiness; the verifiers themselves
  ## handle empty matches correctly.)
  let pf = extractPrefilterInner(prog)
  if progCanBeEmpty(prog):
    if pf.kind == pfAnchorStart:
      return Prefilter(kind: pfAnchorStart, shape: psNone,
                       literalEndPc: pf.literalEndPc)
    return Prefilter(kind: pfNone, shape: psNone)
  pf

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
  of pfAnyOfN:
    let r = scanAnyOfN(input, pos, inputLen, pf.alts)
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