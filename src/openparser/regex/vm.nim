# A collection of tiny parsers and dumpers
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/openparser

import std/[strutils, strformat, bitops, sequtils]
import ./[compiler, prefilter, simd]
import ./jit/compiler as jitcore
export compiler

type
  SkipLoopKind = enum
    slkNone,       ## not a skipable loop
    slkByte,       ## stop on specific byte: [^X]*
    slkNonWord,    ## stop on first non-\w: \w* \w+
    slkNonDigit,   ## stop on first non-\d: \d* \d+
    slkNonSpace,   ## stop on first non-\s: \s* \s+
    slkNonUpperDigitUnder,  ## stop on first non-[A-Z0-9_]

  SkipLoop = tuple[kind: SkipLoopKind, stopCh: char, exit: int, ok: bool]

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

    # JIT compiled matcher; fn == nil when unsupported or disabled.
    # When active, match/find/findAll take the PCRE-style backtracking
    # path instead of the Pike VM.
    jit:       jitcore.CompiledJit
    jitFull:   jitcore.CompiledJit  ## lazy: full-match variant for match()
    jitFullTried: bool
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
  let b = ch.byte
  let hit = (cls.bitmap[b shr 3] and (1u8 shl (b and 7))) != 0
  result = if cls.negated: not hit else: hit

proc isWordChar(ch: char): bool {.inline.} =
  ch in {'a'..'z', 'A'..'Z', '0'..'9', '_'}

proc wordBoundaryAt(input: string, pos, inputLen: int): bool {.inline.} =
  ## True when pos sits on a \b boundary: exactly one side holds a word char.
  let left  = pos > 0 and isWordChar(input[pos - 1])
  let right = pos < inputLen and isWordChar(input[pos])
  left != right

proc skipLoopInfo(prog: Program, pc: int): SkipLoop =
  ## Given a consuming PC parked in the PcSet, look backwards to see if it's
  ## the body of a simple greedy loop. Recognizes:
  ##   [^X]*  → split(pc-2, exit); charclass at pc; jmp(split) at pc+1
  ##   \w+    → split(pc-3, exit); progress at pc-1; escapeClass at pc; jmp(split) at pc+1
  ##   \w*    → split(pc-2, exit); escapeClass at pc; jmp(split) at pc+1
  ## Returns the loop kind and the exit pc when the pattern matches.
  result.kind = slkNone
  result.ok   = false
  if pc < 0 or pc >= prog.instrs.len: return
  let cur = prog.instrs[pc]

  # --- Pattern A: [^X]*  ---  split; charclass; jmp(split)
  # The charClass body is at pc. split is at pc-1 or earlier, jmp at pc+1.
  if cur.op == opCharClass and pc + 1 < prog.instrs.len:
    let back = prog.instrs[pc + 1]
    if back.op == opJmp and back.arg1 >= 0 and back.arg1 < prog.instrs.len:
      let splitPc = back.arg1
      let splitIns = prog.instrs[splitPc]
      if splitIns.op == opSplit and splitIns.arg1 == pc and splitPc + 1 == pc:
        let exit = splitIns.arg2
        let cls = prog.classes[cur.arg1]
        if cls.negated and cls.items.len == 1:
          let item = cls.items[0]
          if not item.isRange and not item.isEscape:
            result.kind   = slkByte
            result.stopCh = item.ch
            result.exit   = exit
            result.ok     = true
            return

  # --- Pattern B: \w+ / \d+ / \s+  ---  split; progress; escapeClass; jmp(split)
  # escapeClass body is at pc. split is at pc-2, progress at pc-1, jmp at pc+1.
  if cur.op == opEscapeClass and pc >= 2 and pc + 1 < prog.instrs.len:
    let prev = prog.instrs[pc - 1]
    let back = prog.instrs[pc + 1]
    if prev.op == opProgress and back.op == opJmp and back.arg1 >= 0:
      let splitPc = back.arg1
      let splitIns = prog.instrs[splitPc]
      if splitIns.op == opSplit and splitIns.arg1 == pc - 1:
        let exit = splitIns.arg2
        case char(cur.arg1)
        of 'w': result.kind = slkNonWord
        of 'd': result.kind = slkNonDigit
        of 's': result.kind = slkNonSpace
        else: return
        result.exit = exit
        result.ok   = true
        return

  # --- Pattern C: \w* / \d* / \s*  ---  split; escapeClass; jmp(split)
  # escapeClass body is at pc. split is at pc-1, jmp at pc+1.
  if cur.op == opEscapeClass and pc >= 1 and pc + 1 < prog.instrs.len:
    let back = prog.instrs[pc + 1]
    if back.op == opJmp and back.arg1 >= 0:
      let splitPc = back.arg1
      let splitIns = prog.instrs[splitPc]
      if splitIns.op == opSplit and splitIns.arg1 == pc:
        let exit = splitIns.arg2
        case char(cur.arg1)
        of 'w': result.kind = slkNonWord
        of 'd': result.kind = slkNonDigit
        of 's': result.kind = slkNonSpace
        else: return
        result.exit = exit
        result.ok   = true
        return

proc skipLoopIsSafe(prog: Program, loop: SkipLoop): bool =
  ## The SIMD jump is sound when the loop's exit successor can handle the
  ## character at the jump position — epsilon transitions are always safe
  ## (the NFA follows them), and consuming instructions are safe only if
  ## they match the stop character.
  let exit = loop.exit
  if exit < 0 or exit >= prog.instrs.len: return false
  let exitIns = prog.instrs[exit]
  case exitIns.op
  of opChar:
    # Only safe for byte-stop loops where the char matches
    if loop.kind == slkByte:
      return exitIns.arg1 == ord(loop.stopCh)
    return false
  of opMatch, opAnchorEnd:
    return true
  of opSplit, opSplitLazy, opSave, opProgress, opJmp:
    # Epsilon transitions — NFA follows them, always safe
    return true
  else:
    return false

proc initRegexVM*(prog: Program): RegexVM =
  let n = prog.instrs.len + 1
  result.prog      = prog
  result.visited   = newSeq[uint32](n)
  result.gen       = 0
  result.prefilter = extractPrefilter(prog)
  result.pcCur     = initPcSet(n)
  result.pcNxt     = initPcSet(n)
  when not defined(noRegexJit):
    # Programs with captures or epsilon cycles get fn == nil here and
    # keep using the interpreter below.
    result.jit = jitcore.compileRegex(prog)

proc closeRegexVM*(vm: var RegexVM) =
  ## Release JIT resources held by the VM. Safe to call multiple times.
  vm.jit.freeJit()
  vm.jitFull.freeJit()

proc hasJit(vm: RegexVM): bool {.inline.} =
  when defined(noRegexJit): false else: vm.jit.fn != nil

proc ensureJitFull(vm: var RegexVM): bool =
  ## Lazily compile the full-match JIT variant (opMatch requires end of
  ## input and otherwise backtracks). Returns false when unavailable.
  when defined(noRegexJit):
    false
  else:
    if vm.jit.fn == nil:
      return false
    if vm.jitFull.fn == nil and not vm.jitFullTried:
      vm.jitFullTried = true
      vm.jitFull = jitcore.compileRegex(vm.prog, true)
    vm.jitFull.fn != nil

proc addEpsilon(vm: var RegexVM, nxt: var PcSet,
                pc, inputPos, inputLen: int; input: string) =
  # Follow all epsilon transitions from `pc`, parking consuming PCs into `nxt`.
  # vm.visited[pc] == vm.gen prevents re-entry within a single closure step.
  if pc < 0 or pc >= vm.prog.instrs.len: return
  if vm.visited[pc] == vm.gen: return
  vm.visited[pc] = vm.gen

  let ins = vm.prog.instrs[pc]
  case ins.op
  of opJmp:
    addEpsilon(vm, nxt, ins.arg1, inputPos, inputLen, input)
  of opSplit:
    addEpsilon(vm, nxt, ins.arg1, inputPos, inputLen, input)
    addEpsilon(vm, nxt, ins.arg2, inputPos, inputLen, input)
  of opSplitLazy:
    addEpsilon(vm, nxt, ins.arg2, inputPos, inputLen, input)
    addEpsilon(vm, nxt, ins.arg1, inputPos, inputLen, input)
  of opSave, opProgress:
    addEpsilon(vm, nxt, pc + 1, inputPos, inputLen, input)
  of opAnchorStart:
    if inputPos == 0: addEpsilon(vm, nxt, pc + 1, inputPos, inputLen, input)
  of opAnchorEnd:
    if inputPos == inputLen: addEpsilon(vm, nxt, pc + 1, inputPos, inputLen, input)
  of opWordBoundary:
    let isBnd = wordBoundaryAt(input, inputPos, inputLen)
    if isBnd != ins.neg:
      addEpsilon(vm, nxt, pc + 1, inputPos, inputLen, input)
  else:
    nxt.inclPc(pc)   ## consuming instruction — park for character step

proc execFast(vm: var RegexVM, input: string, startPos: int): MatchResult =
  let prog     = addr vm.prog
  let inputLen = input.len

  clearPcSet(vm.pcCur)
  clearPcSet(vm.pcNxt)
  inc vm.gen
  addEpsilon(vm, vm.pcCur, 0, startPos, inputLen, input)

  result = noMatch()
  var sp = startPos

  while true:
    inc vm.gen

    # Fast-path: if the ONLY active thread is a greedy loop whose exit
    # successor is safe, use SIMD to jump straight to the stop point.
    # Any other shape (multi-thread, backtracking needed) runs the generic NFA.
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
        let loop = skipLoopInfo(prog[], onlyPc)
        if loop.ok and skipLoopIsSafe(prog[], loop):
          var hit = -1
          case loop.kind
          of slkByte:
            hit = scanByte(input, sp, inputLen, loop.stopCh)
          of slkNonWord:
            hit = scanNonWordChar(input, sp, inputLen)
          of slkNonDigit:
            hit = scanNonDigit(input, sp, inputLen)
          of slkNonSpace:
            hit = scanNonSpace(input, sp, inputLen)
          of slkNonUpperDigitUnder:
            hit = scanNonUpperDigitUnder(input, sp, inputLen)
          of slkNone:
            discard
          if hit >= 0:
            sp = hit
            clearPcSet(vm.pcCur)
            inc vm.gen
            addEpsilon(vm, vm.pcCur, loop.exit, sp, inputLen, input)
            continue
          else:
            # No stop char found — loop consumes entire rest of input
            sp = inputLen
            clearPcSet(vm.pcCur)
            inc vm.gen
            addEpsilon(vm, vm.pcCur, loop.exit, sp, inputLen, input)
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
        of opChar:
          if not atEnd and ord(ch) == ins.arg1:
            addEpsilon(vm, vm.pcNxt, pc + 1, sp + 1, inputLen, input)
        of opAnyChar:
          if not atEnd and ch != '\n':
            addEpsilon(vm, vm.pcNxt, pc + 1, sp + 1, inputLen, input)
        of opEscapeClass:
          if not atEnd and matchEscapeClass(char(ins.arg1), ch):
            addEpsilon(vm, vm.pcNxt, pc + 1, sp + 1, inputLen, input)
        of opCharClass:
          if not atEnd and matchCharClass(prog.classes[ins.arg1], ch):
            addEpsilon(vm, vm.pcNxt, pc + 1, sp + 1, inputLen, input)
        else: discard

    if atEnd: break
    if not anyPc(vm.pcNxt): break
    swap(vm.pcCur, vm.pcNxt)
    inc sp
#
# Epsilon closure
#
proc addRThread(vm: var RegexVM, queue: var seq[RThread],
                t: RThread, inputPos, inputLen: int; input: string) =
  if t.pc < 0 or t.pc >= vm.prog.instrs.len: return
  if vm.visited[t.pc] == vm.gen: return
  vm.visited[t.pc] = vm.gen

  let ins = vm.prog.instrs[t.pc]
  template next(newPc: int) =
    addRThread(vm, queue, RThread(pc: newPc, caps: t.caps),
               inputPos, inputLen, input)
  template nextT(th: RThread) =
    addRThread(vm, queue, th, inputPos, inputLen, input)

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
  of opWordBoundary:
    let isBnd = wordBoundaryAt(input, inputPos, inputLen)
    if isBnd != ins.neg:
      next(t.pc + 1)
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
  addRThread(vm, cur, RThread(pc: 0, caps: initCaps),
             startPos, inputLen, input)

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
          addRThread(vm, nxt, RThread(pc: t.pc+1, caps: t.caps),
                     sp+1, inputLen, input)
          nxtHasThread = true
      of opAnyChar:
        if not atEnd and ch != '\n':
          addRThread(vm, nxt, RThread(pc: t.pc+1, caps: t.caps),
                     sp+1, inputLen, input)
          nxtHasThread = true
      of opEscapeClass:
        if not atEnd and matchEscapeClass(char(ins.arg1), ch):
          addRThread(vm, nxt, RThread(pc: t.pc+1, caps: t.caps),
                     sp+1, inputLen, input)
          nxtHasThread = true
      of opCharClass:
        if not atEnd and matchCharClass(vm.prog.classes[ins.arg1], ch):
          addRThread(vm, nxt, RThread(pc: t.pc+1, caps: t.caps),
                     sp+1, inputLen, input)
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

proc execFrom(vm: var RegexVM, input: string, startPos, startPc: int): MatchResult {.inline.} =
  ## Execute NFA starting from a specific PC (for literal advance optimization).
  ## Only works for the fast path (no captures, no lazy).
  if vm.prog.numCaptures == 0 and not vm.prog.hasLazy:
    # execFast variant that starts from startPc instead of pc=0
    let prog = addr vm.prog
    let inputLen = input.len
    clearPcSet(vm.pcCur)
    clearPcSet(vm.pcNxt)
    inc vm.gen
    addEpsilon(vm, vm.pcCur, startPc, startPos, inputLen, input)
    result = noMatch()
    var sp = startPos
    while true:
      inc vm.gen
      let ch = if sp < inputLen: input[sp] else: '\0'
      let atEnd = sp == inputLen
      clearPcSet(vm.pcNxt)
      for wordIdx in 0 ..< vm.pcCur.bits.len:
        var word = vm.pcCur.bits[wordIdx]
        while word != 0:
          let bit = countTrailingZeroBits(word)
          let pc = wordIdx * 64 + bit
          word = word and (word - 1)
          if pc >= prog.instrs.len: continue
          let ins = prog.instrs[pc]
          case ins.op
          of opMatch:
            if not result.matched or sp > result.stop:
              result = MatchResult(matched: true, start: startPos, stop: sp, captures: @[])
          of opChar:
            if not atEnd and ord(ch) == ins.arg1:
              addEpsilon(vm, vm.pcNxt, pc + 1, sp + 1, inputLen, input)
          of opAnyChar:
            if not atEnd and ch != '\n':
              addEpsilon(vm, vm.pcNxt, pc + 1, sp + 1, inputLen, input)
          of opEscapeClass:
            if not atEnd and matchEscapeClass(char(ins.arg1), ch):
              addEpsilon(vm, vm.pcNxt, pc + 1, sp + 1, inputLen, input)
          of opCharClass:
            if not atEnd and matchCharClass(prog.classes[ins.arg1], ch):
              addEpsilon(vm, vm.pcNxt, pc + 1, sp + 1, inputLen, input)
          else: discard
      if atEnd: break
      if not anyPc(vm.pcNxt): break
      swap(vm.pcCur, vm.pcNxt)
      inc sp
  else:
    result = execFull(vm, input, startPos)

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

  of psEndAnchorByte:
    ## X\s*$ — single byte + optional whitespace + anchor end
    ## The prefilter already found the byte; just check \s*$ from here.
    if startPos >= inputLen: return noMatch()
    # Skip whitespace after the byte
    var p = startPos + 1
    while p < inputLen and input[p] in {' ', '\t', '\n', '\r', '\f', '\v'}: inc p
    # Must be at end of input for $ anchor
    if p != inputLen: return noMatch()
    return MatchResult(matched: true, start: startPos, stop: inputLen, captures: @[])

  of psWordSpaceStarWord:
    ## \w+\s*\*+\s*\w+ — 5 SIMD phases, no NFA
    var p = startPos
    # Phase 1: \w+
    if p >= inputLen or input[p] notin {'a'..'z','A'..'Z','0'..'9','_'}:
      return noMatch()
    p = scanNonWordChar(input, p + 1, inputLen)
    if p < 0: p = inputLen
    # Phase 2: \s*
    while p < inputLen and input[p] in {' ', '\t', '\n', '\r', '\f', '\v'}: inc p
    # Phase 3: \*+
    if p >= inputLen or input[p] != '*': return noMatch()
    inc p
    while p < inputLen and input[p] == '*': inc p
    # Phase 4: \s*
    while p < inputLen and input[p] in {' ', '\t', '\n', '\r', '\f', '\v'}: inc p
    # Phase 5: \w+
    if p >= inputLen or input[p] notin {'a'..'z','A'..'Z','0'..'9','_'}:
      return noMatch()
    p = scanNonWordChar(input, p + 1, inputLen)
    if p < 0: p = inputLen
    return MatchResult(matched: true, start: startPos, stop: p, captures: @[])

  of psLitSpaceWordPlus:
    ## <literal>\s+\w+ — startPos is AFTER the literal prefix
    if startPos >= inputLen: return noMatch()
    var p = startPos
    # \s+: skip whitespace (at least 1)
    while p < inputLen and input[p] in {' ', '\t', '\n', '\r', '\f', '\v'}: inc p
    if p == startPos: return noMatch()
    # \w+: skip word chars (at least 1)
    if p >= inputLen or input[p] notin {'a'..'z','A'..'Z','0'..'9','_'}:
      return noMatch()
    p = scanNonWordChar(input, p + 1, inputLen)
    if p < 0: p = inputLen
    return MatchResult(matched: true, start: startPos, stop: p, captures: @[])

  of psHexPrefixHexPlus:
    ## 0[xX][0-9a-fA-F]+ — startPos is at '0'
    if startPos + 2 >= inputLen: return noMatch()
    if input[startPos] != '0': return noMatch()
    let xc = input[startPos + 1]
    if xc != 'x' and xc != 'X': return noMatch()
    var p = startPos + 2
    # [0-9a-fA-F]+: scan hex digits (at least 1)
    if p >= inputLen or input[p] notin {'0'..'9','a'..'f','A'..'F'}:
      return noMatch()
    inc p
    while p < inputLen and input[p] in {'0'..'9','a'..'f','A'..'F'}: inc p
    return MatchResult(matched: true, start: startPos, stop: p, captures: @[])

  of psLitWordSpaceWord:
    ## <literal>\s+[a-zA-Z_]\w* — startPos is AFTER the literal prefix
    if startPos >= inputLen: return noMatch()
    var p = startPos
    # \s+: skip whitespace (at least 1)
    while p < inputLen and input[p] in {' ', '\t', '\n', '\r', '\f', '\v'}: inc p
    if p == startPos: return noMatch()
    # [a-zA-Z_]: check head
    if p >= inputLen or input[p] notin {'a'..'z','A'..'Z','_'}: return noMatch()
    inc p
    # \w*: skip word chars
    p = scanNonWordChar(input, p, inputLen)
    if p < 0: p = inputLen
    return MatchResult(matched: true, start: startPos, stop: p, captures: @[])

  of psDigitPlusULSuffix:
    ## \d+[uUlL]* — startPos is at first digit
    if startPos >= inputLen or input[startPos] notin {'0'..'9'}:
      return noMatch()
    var p = startPos + 1
    # \d+: skip digits
    while p < inputLen and input[p] in {'0'..'9'}: inc p
    # [uUlL]*: skip suffix chars
    while p < inputLen and input[p] in {'u','U','l','L'}: inc p
    return MatchResult(matched: true, start: startPos, stop: p, captures: @[])

  of psLitWordSpaceWordPlus:
    ## <literal>\s+\w+\s+\w+ — startPos is AFTER the literal prefix
    if startPos >= inputLen: return noMatch()
    var p = startPos
    # \s+: skip whitespace (at least 1)
    while p < inputLen and input[p] in {' ', '\t', '\n', '\r', '\f', '\v'}: inc p
    if p == startPos: return noMatch()
    # \w+: skip word chars (at least 1)
    if p >= inputLen or input[p] notin {'a'..'z','A'..'Z','0'..'9','_'}:
      return noMatch()
    p = scanNonWordChar(input, p + 1, inputLen)
    if p < 0: p = inputLen
    # \s*: skip whitespace (optional)
    while p < inputLen and input[p] in {' ', '\t', '\n', '\r', '\f', '\v'}: inc p
    # \w+: skip word chars (at least 1)
    if p >= inputLen or input[p] notin {'a'..'z','A'..'Z','0'..'9','_'}:
      return noMatch()
    p = scanNonWordChar(input, p + 1, inputLen)
    if p < 0: p = inputLen
    return MatchResult(matched: true, start: startPos, stop: p, captures: @[])

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
  when not defined(noRegexJit):
    if ensureJitFull(vm):
      let stopPos = jitcore.jitExec(vm.jitFull, input, 0)
      if stopPos >= 0 and stopPos == input.len:
        return MatchResult(matched: true, start: 0, stop: stopPos,
                           captures: @[])
      return noMatch()
  result = vm.exec(input, 0)
  if result.matched and (result.start != 0 or result.stop != input.len):
    result = noMatch()

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
    # Optional whitespace may sit between the word run and the anchor
    # (e.g. \w+\s*= or \s\w+=): skip spaces first, then word chars.
    while s >= minPos and input[s] in {' ', '\t'}: dec s
    while s >= minPos and input[s] in {'a'..'z', 'A'..'Z', '0'..'9', '_'}: dec s
    inc s
    if s < anchorPos: return s
    return -1
  of bsNone:
    return max(minPos, anchorPos - 1)

proc find*(vm: var RegexVM, input: string): MatchResult =
  ## Leftmost match anywhere in input, using SIMD prefilter to skip positions.
  when not defined(noRegexJit):
    if vm.jit.fn != nil:
      # PCRE-style backtracking scan: leftmost start, first matching
      # alternative within that start. The JIT is faster than the
      # prefilter + NFA combo, so the prefilter is bypassed entirely.
      let (s, e) = jitcore.jitScan(vm.jit, input, 0)
      if s >= 0:
        return MatchResult(matched: true, start: s, stop: e, captures: @[])
      return noMatch()
  let inputLen = input.len
  let pf = vm.prefilter
  var pos = 0

  if pf.shape != psNone:
    while pos <= inputLen:
      pos = pf.nextCandidate(input, pos, inputLen)
      if pos > inputLen: break
      # For shapes with literal prefixes, execShape expects startPos AFTER the literal
      var shapeStart = pos
      if pf.kind == pfLiteral and pf.literalEndPc > 0 and
         pf.shape in {psLitSpaceWordPlus, psLitWordSpaceWord, psLitWordSpaceWordPlus}:
        shapeStart = pos + pf.prefix.len
      let r = execShape(pf, input, shapeStart, inputLen)
      if r.matched:
        # For literal-prefix shapes, correct the start position
        if pf.kind == pfLiteral and pf.shape in {psLitSpaceWordPlus, psLitWordSpaceWord, psLitWordSpaceWordPlus}:
          return MatchResult(matched: true, start: pos, stop: r.stop, captures: r.captures)
        return r
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
  when not defined(noRegexJit):
    if vm.jit.fn != nil:
      var pos = 0
      while pos <= input.len:
        let (s, e) = jitcore.jitScan(vm.jit, input, pos)
        if s < 0: break
        result.add MatchResult(matched: true, start: s, stop: e, captures: @[])
        # advance past the match; empty matches move forward by one
        pos = if e > s: e else: s + 1
      return
  let inputLen = input.len
  let pf = vm.prefilter
  var pos = 0

  if pf.shape != psNone:
    while pos <= inputLen:
      pos = pf.nextCandidate(input, pos, inputLen)
      if pos > inputLen: break
      # For shapes with literal prefixes, execShape expects startPos AFTER the literal
      var shapeStart = pos
      if pf.kind == pfLiteral and pf.literalEndPc > 0 and
         pf.shape in {psLitSpaceWordPlus, psLitWordSpaceWord, psLitWordSpaceWordPlus}:
        shapeStart = pos + pf.prefix.len
      let r = execShape(pf, input, shapeStart, inputLen)
      if r.matched:
        # For literal-prefix shapes, correct the start position
        if pf.kind == pfLiteral and pf.shape in {psLitSpaceWordPlus, psLitWordSpaceWord, psLitWordSpaceWordPlus}:
          result.add MatchResult(matched: true, start: pos, stop: r.stop, captures: r.captures)
        else:
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
    if pf.kind == pfLiteral and pf.literalEndPc > 0:
      # Literal advance: verify prefix, then start NFA from after the literal
      let plen = pf.prefix.len
      if pos + plen <= inputLen:
        var hit = true
        for j in 0 ..< plen:
          if input[pos + j] != pf.prefix[j]: hit = false; break
        if hit:
          let r = vm.execFrom(input, pos + plen, pf.literalEndPc)
          if r.matched:
            # Correct the start position to include the literal prefix
            result.add MatchResult(matched: true, start: pos,
                                   stop: r.stop, captures: r.captures)
            pos = r.stop
            continue
      inc pos
    else:
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
  var vm = initRegexVM(compile(pattern))
  result = vm.match(input)
  vm.closeRegexVM()

proc find*(pattern, input: string): MatchResult =
  var vm = initRegexVM(compile(pattern))
  result = vm.find(input)
  vm.closeRegexVM()

proc findAll*(pattern, input: string): seq[MatchResult] =
  var vm = initRegexVM(compile(pattern))
  result = vm.findAll(input)
  vm.closeRegexVM()

