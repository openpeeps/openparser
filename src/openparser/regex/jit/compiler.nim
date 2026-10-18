## Regex JIT compiler — native x86-64 backtracking engine via pure-Nim dynasm.
##
## The generated code is a classic backtracking engine: splits push a resume
## entry onto an in-memory backtrack stack and all failures unwind through
## a single fail-entry point.
##
## Previously this backend emitted through LuaJIT's DynASM (a C toolchain:
## dasm headers, Lua scripts, a pre-generated regex_jit.c and glue). It is
## now assembled at runtime with the pure-Nim `dynasm` package, so the JIT
## needs no C files, no Lua and no code-generation step.
import std/[tables]
import dynasm except byte, word, dword, qword
import ../compiler, ../simd

const
  BacktrackMaxEntries = 16384 ## backtrack entries per program (each entry
                              ## holds pos + resumeId + all capture slots)

type
  RegexJitFn* = proc(input: ptr char, inputLen: int, startPos: int,
                     ctx: ptr JitCtx): int {.cdecl.}

  JitCtx* = object
    stackBase*:  ptr UncheckedArray[byte]
    stackLimit*: pointer
    capsBase*:   ptr UncheckedArray[byte]  ## capture working buffer

  CompiledJit* = object
    fn*:       RegexJitFn
    ctx*:      ptr JitCtx
    buf*:      ExecutableBuffer  ## owns the generated code
    codeSize*: int
    firstByte*: int   ## byte the match must start with, -1 = unknown
    anchored*: bool   ## program starts with ^: only startPos 0 can match
    classBitmaps*: ptr UncheckedArray[uint8]  ## owned copy of class bitmaps
    numClasses*: int                          ## number of 32-byte bitmaps
    capsBuf*:  ptr UncheckedArray[int]  ## owned capture working buffer
    numSlots*: int                      ## capture slots (numCaptures*2)

proc freeJit*(cj: var CompiledJit) =
  ## Release generated code, backtrack stack and context. Safe to call
  ## multiple times.
  if not cj.buf.isEmpty:
    cj.buf.destroy()
  cj.fn = nil
  if cj.ctx != nil:
    if cj.ctx.stackBase != nil:
      deallocShared(cast[pointer](cj.ctx.stackBase))
    deallocShared(cast[pointer](cj.ctx))
    cj.ctx = nil
  if cj.classBitmaps != nil:
    deallocShared(cast[pointer](cj.classBitmaps))
    cj.classBitmaps = nil
  if cj.capsBuf != nil:
    deallocShared(cast[pointer](cj.capsBuf))
    cj.capsBuf = nil
  cj.codeSize = 0
  cj.numClasses = 0
  cj.numSlots = 0

proc jitCaptures*(cj: CompiledJit): seq[int] =
  ## Copy the capture slots written by the last successful run.
  ## Unmatched optional groups read back as -1 (prologue sentinel).
  result = newSeq[int](cj.numSlots)
  for i in 0 ..< cj.numSlots:
    result[i] = cj.capsBuf[i]

when defined(windows) or defined(noRegexJit) or not defined(amd64):
  # No JIT on Windows (System-V vs Win64 calling convention mismatch),
  # when explicitly disabled, or on non-x86_64 targets: the backend below
  # emits x86-64 machine code.
  proc compileRegex*(prog: Program, fullMatch = false): CompiledJit =
    ## Stub: JIT unavailable, the caller keeps using the interpreter.
    result = CompiledJit()

else:
  #
  # Generated-code register contract:
  #   rbx = input base pointer        (callee-saved)
  #   rsi = input length
  #   r13 = current position          (callee-saved)
  #   r12 = backtrack stack top       (callee-saved, grows upward)
  #   r15 = backtrack stack limit     (callee-saved)
  #   r14 = capture working buffer    (callee-saved)
  #   rax, rcx, rdx, r8-r11 = scratch
  #
  # Entry ABI: fn(rdi=input, rsi=len, rdx=startPos, rcx=ctx)
  #   [rcx]      = backtrack stack base
  #   [rcx + 8]  = backtrack stack limit
  #   [rcx + 16] = capture working buffer (numSlots int64s, or nil)
  # Returns: match end position (>= 0) or -1 on no match.
  #
  # Backtrack entry: 16 + 8*numSlots bytes
  #   { int64 pos; int32 resumeId; int32 pad; int64 caps[numSlots] }
  # Every consuming/anchor failure jumps to the single fail-entry
  # label which unwinds the backtrack stack, restoring captures.
  # Splits push an entry and jump to their preferred branch.
  #

  proc emitPrologue(a: var Assembler, numSlots: int) =
    dynasm a:
      arch x64
      push rbp
      mov rbp, rsp
      push rbx
      push r12
      push r13
      push r14
      push r15
      mov rbx, rdi            # input ptr
      mov r13, rdx            # pos = startPos
      mov r12, [rcx]          # backtrack top = base (empty)
      mov r15, [rcx + 8]      # backtrack limit
      mov r14, [rcx + 16]     # capture working buffer
    # Sentinel-fill the capture slots so untouched optional groups
    # read back as -1 (mirrors the interpreter's initCaps).
    for i in 0 ..< numSlots:
      let off = i * 8
      dynasm a:
        arch x64
        mov qword [r14 + off], -1

  proc emitEpilogue(a: var Assembler) =
    dynasm a:
      arch x64
      pop r15
      pop r14
      pop r13
      pop r12
      pop rbx
      pop rbp
      ret()

  proc emitDefine(a: var Assembler, L: DynamicLabel) =
    dynasm a:
      arch x64
      dynamicLabel L

  # Consume one literal character.
  proc emitChar(a: var Assembler, lit: int, fail: DynamicLabel) =
    dynasm a:
      arch x64
      cmp r13, rsi
      jge dyn(fail)
      movzx eax, byte [rbx + r13*1]
      cmp eax, lit
      jne dyn(fail)
      inc r13

  # Consume any character except '\n'.
  proc emitAnyChar(a: var Assembler, fail: DynamicLabel) =
    dynasm a:
      arch x64
      cmp r13, rsi
      jge dyn(fail)
      movzx eax, byte [rbx + r13*1]
      cmp eax, 10
      je dyn(fail)
      inc r13

  # Consume one char via 256-bit class bitmap (address embedded with
  # movabs). The bit test that DynASM expressed as `bt` is spelled as
  # shr+and here: edx holds the bitmap byte, ecx the bit index.
  proc emitCharClass(a: var Assembler, bitmapAddr: uint, negated: bool,
                     fail: DynamicLabel) =
    dynasm a:
      arch x64
      cmp r13, rsi
      jge dyn(fail)
      movzx ecx, byte [rbx + r13*1]  # c
      mov eax, ecx
      `shr` eax, 3
      movabs r10, bitmapAddr
      movzx edx, byte [r10 + rax*1]  # bitmap[c >> 3]
      `and` ecx, 7
      `shr` edx, cl
      `and` edx, 1
    if negated:
      dynasm a:
        arch x64
        jnz dyn(fail)
    else:
      dynasm a:
        arch x64
        jz dyn(fail)
    dynasm a:
      arch x64
      inc r13                       # success: consume the char

  # Consume one char via escape class (\d \D \w \W \s \S).
  # `cls` is the escape letter itself. Success falls through past the
  # last emitted check; each multi-branch shape gets a fresh join label.
  proc emitEscapeClass(a: var Assembler, cls: char, fail: DynamicLabel) =
    dynasm a:
      arch x64
      cmp r13, rsi
      jge dyn(fail)
      movzx eax, byte [rbx + r13*1]
    case cls
    of 'd':
      dynasm a:
        arch x64
        sub eax, ord('0')
        cmp eax, 9
        ja dyn(fail)
    of 'D':
      dynasm a:
        arch x64
        sub eax, ord('0')
        cmp eax, 9
        jbe dyn(fail)
    of 'w':
      let ok = a.newDynamicLabel()
      dynasm a:
        arch x64
        mov ecx, eax
        `or` ecx, 0x20
        sub ecx, ord('a')
        cmp ecx, 25
        jbe dyn(ok)
        mov ecx, eax
        sub ecx, ord('0')
        cmp ecx, 9
        jbe dyn(ok)
        cmp eax, ord('_')
        je dyn(ok)
        jmp dyn(fail)
        dynamicLabel ok
    of 'W':
      dynasm a:
        arch x64
        mov ecx, eax
        `or` ecx, 0x20
        sub ecx, ord('a')
        cmp ecx, 25
        jbe dyn(fail)
        mov ecx, eax
        sub ecx, ord('0')
        cmp ecx, 9
        jbe dyn(fail)
        cmp eax, ord('_')
        je dyn(fail)
    of 's':
      # \t(9) \n(10) \v(11) \f(12) \r(13) are contiguous
      let ok = a.newDynamicLabel()
      dynasm a:
        arch x64
        sub eax, 9
        cmp eax, 4
        jbe dyn(ok)
        cmp byte [rbx + r13*1], ord(' ')
        je dyn(ok)
        jmp dyn(fail)
        dynamicLabel ok
    of 'S':
      dynasm a:
        arch x64
        sub eax, 9
        cmp eax, 4
        jbe dyn(fail)
        cmp byte [rbx + r13*1], ord(' ')
        je dyn(fail)
    else:
      dynasm a:
        arch x64
        jmp dyn(fail)
    dynasm a:
      arch x64
      inc r13                       # success: consume the char

  # Assert ^: absolute start of input.
  proc emitAnchorStart(a: var Assembler, fail: DynamicLabel) =
    dynasm a:
      arch x64
      test r13, r13
      jnz dyn(fail)

  # Assert $: absolute end of input.
  proc emitAnchorEnd(a: var Assembler, fail: DynamicLabel) =
    dynasm a:
      arch x64
      cmp r13, rsi
      jne dyn(fail)

  # Assert \b / \B. prevLoaded/curLoaded are caller-allocated join
  # labels for the guarded loads. Uses r11 as scratch: r14 is the
  # capture buffer base and must survive.
  proc emitWordBoundary(a: var Assembler, negated: bool, fail: DynamicLabel,
                        prevLoaded, curLoaded: DynamicLabel) =
    dynasm a:
      arch x64
      # isWord(prev char), 0 when pos == 0
      `xor` ecx, ecx
      test r13, r13
      jz dyn(prevLoaded)
      movzx ecx, byte [rbx + r13*1 - 1]
      dynamicLabel prevLoaded
      mov r8d, ecx
      `or` r8d, 0x20
      sub r8d, ord('a')
      cmp r8d, 25
      setbe r8b
      movzx r8d, r8b
      mov r9d, ecx
      sub r9d, ord('0')
      cmp r9d, 9
      setbe r9b
      movzx r9d, r9b
      `xor` edx, edx
      cmp ecx, ord('_')
      sete dl
      `or` edx, r8d
      `or` edx, r9d              # edx = isWord(prev)
      # isWord(current char), 0 when pos == len
      `xor` ecx, ecx
      cmp r13, rsi
      jae dyn(curLoaded)
      movzx ecx, byte [rbx + r13*1]
      dynamicLabel curLoaded
      mov r8d, ecx
      `or` r8d, 0x20
      sub r8d, ord('a')
      cmp r8d, 25
      setbe r8b
      movzx r8d, r8b
      mov r9d, ecx
      sub r9d, ord('0')
      cmp r9d, 9
      setbe r9b
      movzx r9d, r9b
      `xor` r11d, r11d
      cmp ecx, ord('_')
      sete r11b
      movzx r11d, r11b
      `or` r11d, r8d
      `or` r11d, r9d             # r11d = isWord(cur)
      `xor` edx, r11d            # edx = 1 iff boundary
    if negated:
      dynasm a:
        arch x64
        jnz dyn(fail)            # \B wants none
    else:
      dynasm a:
        arch x64
        jz dyn(fail)             # \b wants a boundary

  # Unconditional jump.
  proc emitJmp(a: var Assembler, target: DynamicLabel) =
    dynasm a:
      arch x64
      jmp dyn(target)

  # Save the current position into capture slot `slot`.
  proc emitSave(a: var Assembler, slot: int) =
    let off = slot * 8
    dynasm a:
      arch x64
      mov [r14 + off], r13

  # Fork execution: push {pos, resumeId, caps...} and try preferred branch.
  # Greedy split passes arg1's label; lazy split passes arg2's label
  # as tryFirst. Captures are snapshotted so the deferred branch resumes
  # with the values live at the fork point (PCRE semantics).
  proc emitSplit(a: var Assembler, tryFirst: DynamicLabel,
                 resumeId, entryBytes, numSlots: int, fail: DynamicLabel) =
    dynasm a:
      arch x64
      cmp r12, r15
      jae dyn(fail)              # stack full -> treat path as failed
      mov [r12], r13
      mov dword [r12 + 8], resumeId
    for i in 0 ..< numSlots:
      let off = 16 + i * 8
      let src = i * 8
      dynasm a:
        arch x64
        mov rax, [r14 + src]
        mov [r12 + off], rax
    dynasm a:
      arch x64
      add r12, entryBytes
      jmp dyn(tryFirst)

  # Success: return current position. In full-match mode the match only
  # counts when it reached end of input; otherwise backtrack so that
  # another alternation/quantifier path can try to consume the rest.
  proc emitMatch(a: var Assembler, exitLbl, fail: DynamicLabel,
                 wantFull: bool) =
    if wantFull:
      dynasm a:
        arch x64
        cmp r13, rsi
        jne dyn(fail)
    dynasm a:
      arch x64
      mov rax, r13
      jmp dyn(exitLbl)

  # Fail-entry head: unwind one backtrack entry into r13/eax,
  # restoring the capture snapshot, or jump to noMatch when the stack
  # is empty. The base is recomputed from the limit since no register
  # is reserved for it. The restore uses r10 as temp so eax (resume id)
  # survives for the dispatch chain.
  proc emitFailHead(a: var Assembler, noMatch: DynamicLabel,
                    entryBytes, numSlots: int, stackBytes: int) =
    dynasm a:
      arch x64
      lea rax, [r15 - stackBytes]  # rax = stack base
      cmp r12, rax
      jbe dyn(noMatch)             # empty
      sub r12, entryBytes
      mov r13, [r12]
      mov eax, [r12 + 8]
    for i in 0 ..< numSlots:
      let off = 16 + i * 8
      let dst = i * 8
      dynasm a:
        arch x64
        mov r10, [r12 + off]
        mov [r14 + dst], r10

  # One dispatch case for the unwound resume id (eax).
  proc emitDispatch(a: var Assembler, id: int, target: DynamicLabel) =
    dynasm a:
      arch x64
      cmp eax, id
      je dyn(target)

  # No match: return -1.
  proc emitNoMatch(a: var Assembler) =
    dynasm a:
      arch x64
      `or` rax, -1

  proc compileRegex*(prog: Program, fullMatch = false): CompiledJit =
    ## Compile `prog` to native code. With `fullMatch`, opMatch only
    ## succeeds at end of input (PCRE fullmatch semantics: failed end
    ## checks backtrack into remaining alternatives). Capture groups are
    ## supported: saves write the working buffer, splits snapshot it.
    ## Returns a result with fn == nil when the program contains
    ## epsilon cycles.
    let numInstrs = prog.instrs.len
    if numInstrs == 0:
      return
    let numSlots = prog.numCaptures * 2
    let entryBytes = 16 + numSlots * 8
    let stackBytes = BacktrackMaxEntries * entryBytes

    var a = newAssembler(akX64)

    # Reserved dynamic labels, allocated first by convention.
    let matchExit = a.newDynamicLabel()  ## success exit: rax = stop position
    let failEntry = a.newDynamicLabel()  ## common failure unwinder
    let noMatch = a.newDynamicLabel()    ## rax = -1

    # Pass 1: validate jump targets and pre-allocate dynamic labels.
    var supported = true
    var pcToLabel = initTable[int, DynamicLabel]()
    var wbLabels = initTable[int, tuple[prevLbl, curLbl: DynamicLabel]]()
    template addTarget(t: int) =
      if t < 0 or t >= numInstrs:
        supported = false
      elif t notin pcToLabel:
        pcToLabel[t] = a.newDynamicLabel()

    for i in 0 ..< numInstrs:
      let ins = prog.instrs[i]
      case ins.op
      of opJmp: addTarget(ins.arg1)
      of opSplit, opSplitLazy:
        addTarget(ins.arg1)
        addTarget(ins.arg2)
      of opCharClass:
        if ins.arg1 < 0 or ins.arg1 >= prog.classes.len:
          supported = false
      of opWordBoundary:
        wbLabels[i] = (a.newDynamicLabel(), a.newDynamicLabel())
      else: discard

    # Reject programs containing epsilon-only cycles: a backtracking
    # engine could loop forever on them without consuming input (e.g.
    # (?:a*)*). The interpreter's visited-set handles these fine.
    if supported:
      var color = newSeq[int8](numInstrs)   # 0 white, 1 gray, 2 black
      proc epsilonSuccs(pc: int): seq[int] =
        let ins = prog.instrs[pc]
        case ins.op
        of opJmp: @[ins.arg1]
        of opSplit, opSplitLazy: @[ins.arg1, ins.arg2]
        of opAnchorStart, opAnchorEnd, opWordBoundary, opProgress, opSave: @[pc + 1]
        else: @[]                    # consuming ops / match terminate paths

      proc visit(pc: int) =
        if not supported or pc < 0 or pc >= numInstrs:
          return
        if color[pc] == 1:           # gray: found a cycle
          supported = false
          return
        if color[pc] == 2:
          return
        color[pc] = 1
        for succ in epsilonSuccs(pc):
          if not supported: return
          visit(succ)
        color[pc] = 2

      for i in 0 ..< numInstrs:
        if not supported: break
        if color[i] == 0:
          visit(i)

    if not supported:
      return

    # Own a stable copy of the class bitmaps. The generated code embeds raw
    # pointers to these bytes, so they must outlive `prog` (which the caller
    # may free while the JIT is still alive) and must not move. GC-managed
    # seq storage does not qualify: `prog` is passed by value and its buffer
    # is freed on return, leaving embedded pointers dangling (observed as
    # findAll dropping matches past the third once the freed block is reused).
    let numClasses = prog.classes.len
    var bitmapStore: ptr UncheckedArray[uint8] = nil
    if numClasses > 0:
      bitmapStore = cast[ptr UncheckedArray[uint8]](allocShared0(numClasses * 32))
      if bitmapStore == nil:
        return
      for ci in 0 ..< numClasses:
        copyMem(addr bitmapStore[ci * 32],
                unsafeAddr prog.classes[ci].bitmap[0], 32)

    emitPrologue(a, numSlots)

    type ResumeCase = tuple[id: int, target: DynamicLabel]
    var resumeCases: seq[ResumeCase] = @[]
    var nextResumeId = 0

    # Pass 2: emit opcode bodies.
    for pc in 0 ..< numInstrs:
      let ins = prog.instrs[pc]
      if pc in pcToLabel:
        emitDefine(a, pcToLabel[pc])

      case ins.op
      of opChar:
        emitChar(a, ins.arg1, failEntry)

      of opAnyChar:
        emitAnyChar(a, failEntry)

      of opCharClass:
        # Bounds were validated in Pass 1, but re-check defensively: an
        # invalid index must reject compilation, never read OOB.
        if ins.arg1 < 0 or ins.arg1 >= numClasses:
          if bitmapStore != nil:
            deallocShared(cast[pointer](bitmapStore))
          return
        emitCharClass(a, cast[uint](addr bitmapStore[ins.arg1 * 32]),
                      ins.neg, failEntry)

      of opEscapeClass:
        emitEscapeClass(a, char(ins.arg1), failEntry)

      of opAnchorStart:
        emitAnchorStart(a, failEntry)

      of opAnchorEnd:
        emitAnchorEnd(a, failEntry)

      of opWordBoundary:
        let (pl, cl) = wbLabels[pc]
        emitWordBoundary(a, ins.neg, failEntry, pl, cl)

      of opJmp:
        emitJmp(a, pcToLabel[ins.arg1])

      of opSplit, opSplitLazy:
        let tryFirstPc = if ins.op == opSplit: ins.arg1 else: ins.arg2
        let resumePc   = if ins.op == opSplit: ins.arg2 else: ins.arg1
        resumeCases.add((nextResumeId, pcToLabel[resumePc]))
        emitSplit(a, pcToLabel[tryFirstPc], nextResumeId,
                  entryBytes, numSlots, failEntry)
        inc nextResumeId

      of opMatch:
        emitMatch(a, matchExit, failEntry, fullMatch)

      of opProgress:
        discard  # pure epsilon

      of opSave:
        # Bounds mirror the compiler invariant (slot < numCaptures*2),
        # but never trust bytecode blindly with raw stores.
        if ins.arg1 < 0 or ins.arg1 >= numSlots:
          if bitmapStore != nil:
            deallocShared(cast[pointer](bitmapStore))
          return
        emitSave(a, ins.arg1)

    # Tail: match exit, failure unwinder with dispatch chain, no-match.
    emitDefine(a, matchExit)
    emitEpilogue(a)

    emitDefine(a, failEntry)
    emitFailHead(a, noMatch, entryBytes, numSlots, stackBytes)
    for rc in resumeCases:
      emitDispatch(a, rc.id, rc.target)

    emitDefine(a, noMatch)
    emitNoMatch(a)
    emitEpilogue(a)

    # Seal the buffer: after finalize the code is executable in place.
    var buf = a.finalize()

    # Own a stable capture working buffer. The generated code reaches it
    # through ctx.capsBase (prologue fill, saves, split snapshots), so it
    # must outlive `prog` and must not move. GC-managed storage does not
    # qualify for the same reason as the class bitmaps above.
    var capsBuf: ptr UncheckedArray[int] = nil
    if numSlots > 0:
      capsBuf = cast[ptr UncheckedArray[int]](allocShared0(numSlots * 8))
      if capsBuf == nil:
        if bitmapStore != nil:
          deallocShared(cast[pointer](bitmapStore))
        buf.destroy()
        return

    let stack = cast[ptr UncheckedArray[byte]](allocShared0(stackBytes))
    if stack == nil:
      if capsBuf != nil:
        deallocShared(cast[pointer](capsBuf))
      if bitmapStore != nil:
        deallocShared(cast[pointer](bitmapStore))
      buf.destroy()
      return
    let ctx = cast[ptr JitCtx](allocShared0(sizeof(JitCtx)))
    if ctx == nil:
      deallocShared(cast[pointer](stack))
      if capsBuf != nil:
        deallocShared(cast[pointer](capsBuf))
      if bitmapStore != nil:
        deallocShared(cast[pointer](bitmapStore))
      buf.destroy()
      return
    ctx.stackBase  = stack
    ctx.stackLimit = cast[pointer](addr stack[stackBytes])
    ctx.capsBase   = cast[ptr UncheckedArray[byte]](capsBuf)

    # Scan hints: a leading ^ pins matches to position 0; a leading
    # literal byte lets jitScan use SIMD to skip between candidates.
    var firstByte = -1
    var anchored = false
    block hintPass:
      var i = 0
      if prog.instrs[0].op == opAnchorStart:
        anchored = true
        i = 1
      if i < numInstrs and prog.instrs[i].op == opChar:
        firstByte = prog.instrs[i].arg1

    let fn = cast[RegexJitFn](buf.ptrAt(AssemblyOffset(0)))
    result = CompiledJit(fn: fn,
                         ctx: ctx, buf: buf, codeSize: buf.len,
                         firstByte: firstByte, anchored: anchored,
                         classBitmaps: bitmapStore, numClasses: numClasses,
                         capsBuf: capsBuf, numSlots: numSlots)

proc jitExec*(cj: CompiledJit, input: string, startPos = 0): int {.inline.} =
  ## Run the JIT'd matcher anchored at `startPos`.
  ## Returns the match end position, or -1 on no match.
  assert startPos >= 0 and startPos <= input.len
  let p = if input.len > 0: unsafeAddr input[0] else: nil
  cj.fn(cast[ptr char](p), input.len, startPos, cj.ctx)

proc jitScan*(cj: CompiledJit, input: string, fromPos = 0): tuple[start, stop: int] =
  ## Leftmost scan starting at `fromPos`: try every start offset until one
  ## matches. Returns (-1, -1) when nothing matches.
  result = (-1, -1)
  if cj.fn == nil:
    return
  if cj.anchored and fromPos > 0:
    return
  when not defined(noRegexJit) and not defined(windows):
    if cj.firstByte >= 0:
      # SIMD hop between candidate positions where the required first
      # byte occurs; full verification still runs in generated code.
      var sp = max(fromPos, 0)
      while sp <= input.len:
        let hit = scanByte(input, sp, input.len, char(cj.firstByte))
        if hit < 0:
          return
        let stopPos = cj.jitExec(input, hit)
        if stopPos >= 0:
          return (hit, stopPos)
        sp = hit + 1
      return
  for sp in fromPos .. input.len:
    let stopPos = cj.jitExec(input, sp)
    if stopPos >= 0:
      return (sp, stopPos)
