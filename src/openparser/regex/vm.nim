# A collection of tiny parsers and dumpers
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/openparser

import std/[strutils, strformat, bitops, sequtils]
import ./[compiler, prefilter, simd]
export compiler

type
  Captures*    = seq[int]

  CaptureGroup* = object
    index*:  int     ## 0 = whole match, 1..n = numbered groups
    start*:  int
    stop*:   int
    matched*: bool   ## false when an optional group did not participate

  MatchResult* = object
    matched*:  bool
    start*:    int
    stop*:     int
    captures*: Captures

  RThread = object
    pc:   int
    pos:  int
    caps: Captures

  #
  # Compact bitset over program counters — zero-allocation NFA fast path
  #
  PcSet = object
    bits: seq[uint64]

  RegexVM* = object
    prog:      Program
    visited:   seq[uint32]
    gen:       uint32
    prefilter: Prefilter        ## cached after init
    
    # reusable PcSets (allocated once per VM, cleared per exec call)
    pcCur:     PcSet
    pcNxt:     PcSet
#
# PcSet operations
#

proc initPcSet(n: int): PcSet {.inline.} =
  result.bits = newSeq[uint64]((n + 63) div 64)

proc inclPc(s: var PcSet, pc: int) {.inline.} =
  s.bits[pc shr 6] = s.bits[pc shr 6] or (1u64 shl (pc and 63))

proc hasPc(s: PcSet, pc: int): bool {.inline.} =
  (s.bits[pc shr 6] and (1u64 shl (pc and 63))) != 0

proc clearPcSet(s: var PcSet) {.inline.} =
  for i in 0 ..< s.bits.len: s.bits[i] = 0

proc anyPc(s: PcSet): bool {.inline.} =
  for w in s.bits:
    if w != 0: return true
  false

proc noMatch*(): MatchResult {.inline.} =
  MatchResult(matched: false, start: -1, stop: -1)

proc matchEscapeClass(cls: char, ch: char): bool {.inline.} =
  case cls
  of 'd': ch in {'0'..'9'}
  of 'D': ch notin {'0'..'9'}
  of 'w': ch in {'a'..'z','A'..'Z','0'..'9','_'}
  of 'W': ch notin {'a'..'z','A'..'Z','0'..'9','_'}
  of 's': ch in {' ', '\t', '\n', '\r', '\f', '\v'}
  of 'S': ch notin {' ', '\t', '\n', '\r', '\f', '\v'}
  else:   false

proc matchCharClass(cls: CompiledClass, ch: char): bool {.inline.} =
  var found = false
  for item in cls.items:
    if item.isRange:
      if ch >= item.lo and ch <= item.hi: found = true; break
    else:
      if ch == item.ch: found = true; break
  result = if cls.negated: not found else: found

proc initRegexVM*(prog: Program): RegexVM =
  let n = prog.instrs.len + 1
  result.prog      = prog
  result.visited   = newSeq[uint32](n)
  result.gen       = 0
  result.prefilter = extractPrefilter(prog)
  result.pcCur     = initPcSet(n)
  result.pcNxt     = initPcSet(n)

proc addEpsilon(vm: var RegexVM, nxt: var PcSet,
                pc, inputPos, inputLen: int) =
  # Follow all epsilon transitions from `pc`, parking consuming PCs into `nxt`.
  # vm.visited[pc] == vm.gen prevents re-entry within a single closure step.
  if pc < 0 or pc >= vm.prog.instrs.len: return
  if vm.visited[pc] == vm.gen: return
  vm.visited[pc] = vm.gen

  let ins = vm.prog.instrs[pc]
  case ins.op
  of opJmp:
    addEpsilon(vm, nxt, ins.arg1, inputPos, inputLen)
  of opSplit:
    addEpsilon(vm, nxt, ins.arg1, inputPos, inputLen)
    addEpsilon(vm, nxt, ins.arg2, inputPos, inputLen)
  of opSplitLazy:
    addEpsilon(vm, nxt, ins.arg2, inputPos, inputLen)
    addEpsilon(vm, nxt, ins.arg1, inputPos, inputLen)
  of opSave, opProgress:
    addEpsilon(vm, nxt, pc + 1, inputPos, inputLen)
  of opAnchorStart:
    if inputPos == 0: addEpsilon(vm, nxt, pc + 1, inputPos, inputLen)
  of opAnchorEnd:
    if inputPos == inputLen: addEpsilon(vm, nxt, pc + 1, inputPos, inputLen)
  else:
    nxt.inclPc(pc)   ## consuming instruction — park for character step

proc execFast(vm: var RegexVM, input: string, startPos: int): MatchResult =
  let prog     = addr vm.prog
  let inputLen = input.len

  clearPcSet(vm.pcCur)
  clearPcSet(vm.pcNxt)
  inc vm.gen
  addEpsilon(vm, vm.pcCur, 0, startPos, inputLen)

  result = noMatch()
  var sp = startPos

  while true:
    inc vm.gen

    # Fast-path: if the ONLY active thread is opSkipTo, use SIMD to jump.
    # Check before the full word loop.
    block skipFastPath:
      var count = 0
      var onlyPc = -1
      for wordIdx in 0 ..< vm.pcCur.bits.len:
        var word = vm.pcCur.bits[wordIdx]
        while word != 0:
          let bit = countTrailingZeroBits(word)
          onlyPc = wordIdx * 64 + bit
          word   = word and (word - 1)
          inc count
          if count > 1: break skipFastPath
      if count == 1 and onlyPc >= 0 and onlyPc < prog.instrs.len:
        let ins = prog.instrs[onlyPc]
        if ins.op == opSkipTo:
          let stopCh = char(ins.arg1)
          let hit    = scanByte(input, sp, inputLen, stopCh)
          if hit < 0: break  # stop-char never found — no match possible
          # Jump sp to the stop-char; opSkipTo consumed [^stopCh]* via SIMD
          sp = hit
          clearPcSet(vm.pcCur)
          inc vm.gen
          addEpsilon(vm, vm.pcCur, onlyPc + 1, sp, inputLen)
          continue

    let ch    = if sp < inputLen: input[sp] else: '\0'
    let atEnd = sp == inputLen
    clearPcSet(vm.pcNxt)

    for wordIdx in 0 ..< vm.pcCur.bits.len:
      var word = vm.pcCur.bits[wordIdx]
      while word != 0:
        let bit = countTrailingZeroBits(word)
        let pc  = wordIdx * 64 + bit
        word    = word and (word - 1)
        if pc >= prog.instrs.len: continue
        let ins = prog.instrs[pc]
        case ins.op
        of opMatch:
          if not result.matched or sp > result.stop:
            result = MatchResult(matched: true, start: startPos,
                                 stop: sp, captures: @[])
        of opSkipTo:
          # Multi-thread case: treat as [^X]* step-by-step
          if not atEnd and ch != char(ins.arg1):
            addEpsilon(vm, vm.pcNxt, pc, sp + 1, inputLen)  # stay in loop
          elif not atEnd:
            addEpsilon(vm, vm.pcNxt, pc + 1, sp + 1, inputLen)  # exit loop, consume stopCh at next instr
        of opChar:
          if not atEnd and ord(ch) == ins.arg1:
            addEpsilon(vm, vm.pcNxt, pc + 1, sp + 1, inputLen)
        of opAnyChar:
          if not atEnd and ch != '\n':
            addEpsilon(vm, vm.pcNxt, pc + 1, sp + 1, inputLen)
        of opEscapeClass:
          if not atEnd and matchEscapeClass(char(ins.arg1), ch):
            addEpsilon(vm, vm.pcNxt, pc + 1, sp + 1, inputLen)
        of opCharClass:
          if not atEnd and matchCharClass(prog.classes[ins.arg1], ch):
            addEpsilon(vm, vm.pcNxt, pc + 1, sp + 1, inputLen)
        else: discard

    if atEnd: break
    if not anyPc(vm.pcNxt): break
    swap(vm.pcCur, vm.pcNxt)
    inc sp
#
# Epsilon closure
#
proc addRThread(vm: var RegexVM, queue: var seq[RThread],
                t: RThread, inputPos, inputLen: int) =
  if t.pc < 0 or t.pc >= vm.prog.instrs.len: return
  if vm.visited[t.pc] == vm.gen: return
  vm.visited[t.pc] = vm.gen

  let ins = vm.prog.instrs[t.pc]
  template next(newPc: int) =
    addRThread(vm, queue, RThread(pc: newPc, pos: t.pos, caps: t.caps),
               inputPos, inputLen)
  template nextT(th: RThread) =
    addRThread(vm, queue, th, inputPos, inputLen)

  case ins.op
  of opJmp:      next(ins.arg1)
  of opSplit:    next(ins.arg1); next(ins.arg2)
  of opSplitLazy: next(ins.arg2); next(ins.arg1)
  of opSave:
    var t2 = t; t2.caps[ins.arg1] = inputPos; t2.pc = t.pc + 1; nextT(t2)
  of opProgress: next(t.pc + 1)
  of opAnchorStart:
    if inputPos == 0: next(t.pc + 1)
  of opAnchorEnd:
    if inputPos == inputLen: next(t.pc + 1)
  else:
    queue.add(t)

proc execFull(vm: var RegexVM, input: string, startPos: int): MatchResult =
  let inputLen = input.len
  var cur, nxt: seq[RThread]
  # Initialize all slots to -1 so unmatched optional groups are detectable.
  # A slot value of 0 is a valid position (start of string), so we cannot
  # use 0 as the sentinel — only -1 is unambiguous.
  let initCaps = newSeqWith(vm.prog.numCaptures * 2, -1)

  inc vm.gen
  addRThread(vm, cur, RThread(pc: 0, pos: startPos, caps: initCaps),
             startPos, inputLen)

  result = noMatch()
  var sp = startPos

  while true:
    inc vm.gen
    nxt.setLen(0)

    let ch    = if sp < inputLen: input[sp] else: '\0'
    let atEnd = sp == inputLen

    ## Track whether any consuming thread fires before opMatch is seen.
    ## If opMatch is seen while nxtHasThread=false, that thread has the
    ## highest priority and wins immediately (correct for lazy quantifiers).
    ## If consuming threads fire first, opMatch records but doesn't stop
    ## (correct for greedy quantifiers).
    var nxtHasThread = false

    for t in cur:
      if t.pc < 0 or t.pc >= vm.prog.instrs.len: continue
      let ins = vm.prog.instrs[t.pc]
      case ins.op
      of opMatch:
        if not nxtHasThread:
          ## Highest-priority thread matched — return immediately.
          ## For lazy: match thread was added before consume thread (SPLIT_LAZY
          ## adds exit first), so this fires before any extend thread.
          ## For greedy: consume thread was added first, so nxtHasThread=true
          ## by the time we reach opMatch, so we fall to the else branch.
          return MatchResult(matched: true, start: startPos,
                             stop: sp, captures: t.caps)
        else:
          ## A consuming thread already extended — record but keep going.
          if not result.matched or sp > result.stop:
            result = MatchResult(matched: true, start: startPos,
                                 stop: sp, captures: t.caps)
      of opChar:
        if not atEnd and ord(ch) == ins.arg1:
          addRThread(vm, nxt, RThread(pc: t.pc+1, pos: sp+1, caps: t.caps),
                     sp+1, inputLen)
          nxtHasThread = true
      of opAnyChar:
        if not atEnd and ch != '\n':
          addRThread(vm, nxt, RThread(pc: t.pc+1, pos: sp+1, caps: t.caps),
                     sp+1, inputLen)
          nxtHasThread = true
      of opEscapeClass:
        if not atEnd and matchEscapeClass(char(ins.arg1), ch):
          addRThread(vm, nxt, RThread(pc: t.pc+1, pos: sp+1, caps: t.caps),
                     sp+1, inputLen)
          nxtHasThread = true
      of opCharClass:
        if not atEnd and matchCharClass(vm.prog.classes[ins.arg1], ch):
          addRThread(vm, nxt, RThread(pc: t.pc+1, pos: sp+1, caps: t.caps),
                     sp+1, inputLen)
          nxtHasThread = true
      else: discard

    if atEnd: break
    if nxt.len == 0: break
    cur = nxt
    inc sp

#
# Main execution loop
#
proc exec(vm: var RegexVM, input: string, startPos: int): MatchResult {.inline.} =
  if vm.prog.numCaptures == 0 and not vm.prog.hasLazy:
    execFast(vm, input, startPos)
  else:
    execFull(vm, input, startPos)

proc execShape(pf: Prefilter, input: string,
               startPos, inputLen: int): MatchResult {.inline.} =
  var stop = -1

  case pf.shape
  of psAlphaWordStar:
    ## pfAlpha guarantees [a-zA-Z_] head, but re-check defensively.
    if startPos >= inputLen: return noMatch()
    if input[startPos] notin {'a'..'z', 'A'..'Z', '_'}: return noMatch()
    stop = scanNonWordChar(input, startPos + 1, inputLen)
    if stop < 0: stop = inputLen

  of psWordCharPlus:
    if startPos >= inputLen: return noMatch()
    stop = scanNonWordChar(input, startPos + 1, inputLen)
    if stop < 0: stop = inputLen

  of psWordCharStar:
    if startPos >= inputLen: return noMatch()
    stop = scanNonWordChar(input, startPos, inputLen)
    if stop < 0: stop = inputLen

  of psUpperDigitUnderPlus:
    ## head must be [A-Z_]  (pfUpperAlpha is a superset: [A-Z0-9_])
    if startPos >= inputLen: return noMatch()
    if input[startPos] notin {'A'..'Z', '_'}: return noMatch()
    if startPos + 1 >= inputLen: return noMatch()
    if input[startPos + 1] notin {'A'..'Z', '0'..'9', '_'}: return noMatch()
    stop = scanNonUpperDigitUnder(input, startPos + 2, inputLen)
    if stop < 0: stop = inputLen

  of psUpperDigitUnder2Plus:
    ## head must be [A-Z_] + ≥2 body chars
    if startPos >= inputLen: return noMatch()
    if input[startPos] notin {'A'..'Z', '_'}: return noMatch()
    if startPos + 2 >= inputLen: return noMatch()
    if input[startPos + 1] notin {'A'..'Z', '0'..'9', '_'}: return noMatch()
    if input[startPos + 2] notin {'A'..'Z', '0'..'9', '_'}: return noMatch()
    stop = scanNonUpperDigitUnder(input, startPos + 3, inputLen)
    if stop < 0: stop = inputLen

  of psUpperDigitUnderStar:
    if startPos >= inputLen: return noMatch()
    if input[startPos] notin {'A'..'Z', '_'}: return noMatch()
    stop = scanNonUpperDigitUnder(input, startPos + 1, inputLen)
    if stop < 0: stop = inputLen

  of psDigitPlus:
    if startPos >= inputLen: return noMatch()
    stop = startPos + 1
    while stop < inputLen and input[stop] in {'0'..'9'}: inc stop

  of psDigitStar:
    if startPos >= inputLen: return noMatch()
    stop = startPos
    while stop < inputLen and input[stop] in {'0'..'9'}: inc stop

  of psNone:
    return noMatch()

  if stop <= startPos: return noMatch()
  result = MatchResult(matched: true, start: startPos,
                       stop: stop, captures: @[])

#
# Public API
#

proc match*(vm: var RegexVM, input: string): MatchResult =
  ## Anchored full match: must start at 0 AND consume the whole string.
  result = vm.exec(input, 0)
  if result.matched and (result.start != 0 or result.stop != input.len):
    result = noMatch()

proc injectEps(vm: var RegexVM, startOf: var seq[int],
               pc, start, inputPos, inputLen: int, nxt: var PcSet) =
  if pc < 0 or pc >= vm.prog.instrs.len: return
  if vm.visited[pc] == vm.gen: return
  vm.visited[pc] = vm.gen
  startOf[pc] = start
  let ins = vm.prog.instrs[pc]
  case ins.op
  of opJmp:
    injectEps(vm, startOf, ins.arg1, start, inputPos, inputLen, nxt)
  of opSplit:
    injectEps(vm, startOf, ins.arg1, start, inputPos, inputLen, nxt)
    injectEps(vm, startOf, ins.arg2, start, inputPos, inputLen, nxt)
  of opSplitLazy:
    injectEps(vm, startOf, ins.arg2, start, inputPos, inputLen, nxt)
    injectEps(vm, startOf, ins.arg1, start, inputPos, inputLen, nxt)
  of opSave, opProgress:
    injectEps(vm, startOf, pc + 1, start, inputPos, inputLen, nxt)
  of opAnchorStart:
    if inputPos == 0:
      injectEps(vm, startOf, pc + 1, start, inputPos, inputLen, nxt)
  of opAnchorEnd:
    if inputPos == inputLen:
      injectEps(vm, startOf, pc + 1, start, inputPos, inputLen, nxt)
  else:
    nxt.inclPc(pc)

proc backscanStart(input: string, anchorPos, minPos: int,
                   bs: BackscanKind): int {.inline.} =
  ## Walk backward from anchorPos-1 to find the NFA start position.
  ## Returns -1 if no valid start found.
  var s = anchorPos - 1
  case bs
  of bsAlphaWord:
    # skip optional whitespace
    while s >= minPos and input[s] in {' ', '\t'}: dec s
    # skip word chars
    while s >= minPos and input[s] in {'a'..'z','A'..'Z','0'..'9','_'}: dec s
    inc s
    if s < anchorPos and input[s] in {'a'..'z','A'..'Z','_'}: return s
    return -1
  of bsWordChar:
    while s >= minPos and input[s] in {'a'..'z','A'..'Z','0'..'9','_'}: dec s
    inc s
    if s < anchorPos: return s
    return -1
  of bsNone:
    return max(minPos, anchorPos - 1)

proc find*(vm: var RegexVM, input: string): MatchResult =
  ## Leftmost match anywhere in input, using SIMD prefilter to skip positions.
  let inputLen = input.len
  let pf = vm.prefilter
  var pos = 0

  if pf.shape != psNone:
    while pos <= inputLen:
      pos = pf.nextCandidate(input, pos, inputLen)
      if pos > inputLen: break
      let r = execShape(pf, input, pos, inputLen)
      if r.matched: return r
      inc pos
    return noMatch()
  
  # Literal prefix with fixed offset — common for identifiers
  if pf.kind == pfLiteralAnchored:
    let plen  = pf.prefix.len
    let first = pf.prefix[0]
    var i     = pf.offset
    while i <= inputLen - plen:
      let r = scanByte(input, i, inputLen - plen + 1, first)
      if r < 0: break
      var hit = true
      for j in 1 ..< plen:
        if input[r + j] != pf.prefix[j]: hit = false; break
      if hit:
        let startA = max(0, r - pf.offset)
        if startA >= pos:
          let ra = vm.exec(input, startA)
          if ra.matched: return ra
        let startB = max(0, r - pf.offset2)
        if startB >= pos and startB != max(0, r - pf.offset):
          let rb = vm.exec(input, startB)
          if rb.matched: return rb
      i = r + 1
    return noMatch()

  # Inner literal with backscan
  if pf.kind == pfInnerLiteral:
    var i = pos
    while i < inputLen:
      let r = scanByte(input, i, inputLen, pf.anchor)
      if r < 0: break
      let s = backscanStart(input, r, max(0, r - pf.maxLookback), pf.backscan)
      if s >= pos and s < r:
        let ra = vm.exec(input, s)
        if ra.matched and ra.stop > r:
          return ra
      i = r + 1
    return noMatch()

  while pos <= inputLen:
    pos = pf.nextCandidate(input, pos, inputLen)
    if pos > inputLen: break
    let r = vm.exec(input, pos)
    if r.matched: return r
    inc pos
  result = noMatch()

proc findAll*(vm: var RegexVM, input: string): seq[MatchResult] =
  ## Find all non-overlapping matches in input, using SIMD prefilter to skip positions.
  let inputLen = input.len
  let pf = vm.prefilter
  var pos = 0

  if pf.shape != psNone:
    while pos <= inputLen:
      pos = pf.nextCandidate(input, pos, inputLen)
      if pos > inputLen: break
      let r = execShape(pf, input, pos, inputLen)
      if r.matched:
        result.add r
        pos = r.stop
      else:
        inc pos
    return
  
  # Literal prefix with fixed offset — common for identifiers
  if pf.kind == pfLiteralAnchored:
    let plen  = pf.prefix.len
    let first = pf.prefix[0]
    var i     = pf.offset
    while i <= inputLen - plen:
      let r = scanByte(input, i, inputLen - plen + 1, first)
      if r < 0: break
      var hit = true
      for j in 1 ..< plen:
        if input[r + j] != pf.prefix[j]: hit = false; break
      if hit:
        let startA = max(0, r - pf.offset)
        if startA >= pos:
          let ra = vm.exec(input, startA)
          if ra.matched:
            result.add ra
            pos = ra.stop
            i = r + 1
            continue
        let startB = max(0, r - pf.offset2)
        if startB >= pos and startB != max(0, r - pf.offset):
          let rb = vm.exec(input, startB)
          if rb.matched:
            result.add rb
            pos = rb.stop
            i = r + 1
            continue
      i = r + 1
    return
  
  # Inner literal with backscan
  if pf.kind == pfInnerLiteral:
    var i = pos
    while i < inputLen:
      let r = scanByte(input, i, inputLen, pf.anchor)
      if r < 0: break
      let s = backscanStart(input, r, max(0, r - pf.maxLookback), pf.backscan)
      if s >= pos and s < r:
        let ra = vm.exec(input, s)
        if ra.matched and ra.stop > r:
          result.add ra
          pos = ra.stop
          i = ra.stop
          continue
      i = r + 1
    return

  while pos <= inputLen:
    pos = pf.nextCandidate(input, pos, inputLen)
    if pos > inputLen: break
    let r = vm.exec(input, pos)
    if r.matched:
      result.add r
      pos = r.stop
    else:
      inc pos

proc groupCount*(m: MatchResult): int {.inline.} =
  ## Number of capture groups (not counting the whole match at idx 0).
  m.captures.len div 2

proc group*(m: MatchResult, idx: int): CaptureGroup =
  result.index   = idx
  result.matched = false   ## explicit default — never rely on zero-init
  if idx == 0:
    result.start   = m.start
    result.stop    = m.stop
    result.matched = m.matched
    return
  if idx < 1: return       ## negative index → unmatched
  let slot = (idx - 1) * 2
  if m.captures.len == 0: return          ## no captures at all
  if slot + 1 >= m.captures.len: return   ## idx beyond allocated groups
  let lo = m.captures[slot]
  let hi = m.captures[slot + 1]
  if lo < 0 or hi < 0 or hi < lo: return  ## optional group did not participate
  result.start   = lo
  result.stop    = hi
  result.matched = true

proc str*(g: CaptureGroup, input: string): string {.inline.} =
  ## Extract the substring for a CaptureGroup.
  if not g.matched: return ""
  input[g.start ..< g.stop]

proc groupStr*(m: MatchResult, input: string, idx: int): string =
  ## Convenience: extract capture group string directly.
  ## idx = 0 → whole match.
  m.group(idx).str(input)

proc groups*(m: MatchResult, input: string): seq[string] =
  ## All capture groups as strings, index 1..n.
  ## An unmatched optional group is returned as "".
  let n = groupCount(m)
  result = newSeq[string](n)
  for i in 1 .. n:
    result[i - 1] = m.group(i).str(input)

proc allGroups*(m: MatchResult, input: string): seq[CaptureGroup] =
  ## All groups including whole match at [0].
  let n = groupCount(m)
  result = newSeq[CaptureGroup](n + 1)
  for i in 0 .. n:
    result[i] = m.group(i)

iterator eachGroup*(m: MatchResult, input: string): (int, string) =
  ## Yields (index, text) for every capture group 1..n.
  let n = groupCount(m)
  for i in 1 .. n:
    yield (i, m.group(i).str(input))

#
# Convenience one-liners
#
proc match*(pattern, input: string): MatchResult =
  var vm = initRegexVM(compile(pattern)); vm.match(input)

proc find*(pattern, input: string): MatchResult =
  var vm = initRegexVM(compile(pattern)); vm.find(input)

proc findAll*(pattern, input: string): seq[MatchResult] =
  var vm = initRegexVM(compile(pattern)); vm.findAll(input)

