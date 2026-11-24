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
    stackBytes*: int  ## owned backtrack stack size (for freeJitCtx)
    numSlots*:   int  ## capture slots in capsBase (for jitCapturesIn)
    fullFlag*:   int  ## nonzero requires opMatch at end of input (match())

  CompiledJit* = object
    fn*:       RegexJitFn
    ctx*:      ptr JitCtx
    buf*:      ExecutableBuffer  ## owns the generated code
    codeSize*: int
    firstByte*: int   ## byte the match must start with, -1 = unknown
    anchored*: bool   ## program starts with ^: only startPos 0 can match
    classBitmaps*: ptr UncheckedArray[uint8]  ## owned copy of class bitmaps
    numClasses*: int                          ## number of 32-byte bitmaps
    auxTable*:   ptr UncheckedArray[uint8]  ## owned 256-byte class table:
                                            ## bit0 = isWord, bit1 = isSpace
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
  if cj.auxTable != nil:
    deallocShared(cast[pointer](cj.auxTable))
    cj.auxTable = nil
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

#
# Thread-shared execution
#
# The generated code is immutable, but every run needs scratch space: a
# backtrack stack and a capture working buffer. That state lives in
# `JitCtx`, so a `CompiledJit` shared across threads needs one context
# per thread — allocate them with `newJitCtx` and run matches with
# `jitExecIn` / read captures with `jitCapturesIn`.
#

proc newJitCtx*(numSlots: int): ptr JitCtx =
  ## Allocate an independent execution context with `numSlots` capture
  ## slots. Contexts are bound to the calling thread: run the same
  ## `CompiledJit` concurrently by giving each thread its own context.
  ## A context sized for N slots also serves programs with fewer slots.
  ## Returns nil on allocation failure.
  let slots = max(numSlots, 0)
  let entryBytes = 16 + slots * 8
  let stackBytes = BacktrackMaxEntries * entryBytes
  let stack = cast[ptr UncheckedArray[byte]](allocShared(stackBytes))
  if stack == nil:
    return nil
  var capsBuf: ptr UncheckedArray[int] = nil
  if slots > 0:
    capsBuf = cast[ptr UncheckedArray[int]](allocShared(slots * 8))
    if capsBuf == nil:
      deallocShared(cast[pointer](stack))
      return nil
  let ctx = cast[ptr JitCtx](allocShared(sizeof(JitCtx)))
  if ctx == nil:
    deallocShared(cast[pointer](stack))
    if capsBuf != nil:
      deallocShared(cast[pointer](capsBuf))
    return nil
  ctx.stackBase = stack
  ctx.stackLimit = cast[pointer](addr stack[stackBytes])
  ctx.capsBase = cast[ptr UncheckedArray[byte]](capsBuf)
  ctx.stackBytes = stackBytes
  ctx.numSlots = slots
  ctx.fullFlag = 0
  ctx

proc freeJitCtx*(ctx: ptr JitCtx) =
  ## Release a context created by `newJitCtx`. Never pass the context
  ## owned by a `CompiledJit` — that one is released by `freeJit`.
  if ctx == nil: return
  if ctx.stackBase != nil:
    deallocShared(cast[pointer](ctx.stackBase))
  if ctx.capsBase != nil:
    deallocShared(cast[pointer](ctx.capsBase))
  deallocShared(cast[pointer](ctx))

proc jitExecIn*(cj: CompiledJit, ctx: ptr JitCtx, input: string,
                startPos = 0): int {.inline.} =
  ## Run the JIT'd matcher anchored at `startPos` using an explicit
  ## execution context. Returns the match end position, or -1 on no
  ## match (also when there is no compiled code or the context is nil).
  ## For full-match (`match()`) semantics set `ctx.fullFlag` to 1 around
  ## the call; `find()`/`findAll()` leave it 0.
  if cj.fn == nil or ctx == nil: return -1
  if startPos < 0 or startPos > input.len: return -1
  let p = if input.len > 0: unsafeAddr input[0] else: nil
  cj.fn(cast[ptr char](p), input.len, startPos, ctx)

proc jitCapturesIn*(ctx: ptr JitCtx): seq[int] =
  ## Copy the capture slots written by the last successful `jitExecIn`
  ## run on this context. Unmatched optional groups read back as -1.
  if ctx == nil: return @[]
  result = newSeq[int](ctx.numSlots)
  let caps = cast[ptr UncheckedArray[int]](ctx.capsBase)
  for i in 0 ..< ctx.numSlots:
    result[i] = caps[i]

proc skipExitFor*(prog: Program, splitPc: int):
    tuple[exit: int, kind: SkipLoopKind, stopCh: char] =
  ## If `splitPc` heads a greedy loop replaceable by a run scan, return
  ## the exit pc plus loop kind; else `exit` is -1. Sound only when the
  ## exit's first consuming op provably excludes loop characters (or the
  ## exit is end-anchored): backtracking into shorter runs could then
  ## never succeed, so the per-char backtrack entries are dead weight.
  ## The body must be a single class/escape/char op with a jmp back to
  ## the split (no saves inside), and the
  ## exit is classified by following epsilon transitions (saves, jumps,
  ## anchors) to the first consuming op; a fork (split) gives up.
  result = (-1, slkNone, '\0')
  let n = prog.instrs.len
  if splitPc < 0 or splitPc + 2 >= n: return
  let s = prog.instrs[splitPc]
  if s.op != opSplit or s.arg1 != splitPc + 1: return
  var bodyPc = splitPc + 1
  if prog.instrs[bodyPc].op == opProgress:
    # +-form: split(body, exit); progress; body; jmp(split)
    if splitPc + 3 >= n: return
    bodyPc = splitPc + 2
  var loopKind = slkNone
  var loopCh = '\0'
  # The body must be a single consuming op with a jmp back to the split:
  # an unbounded `*`/`+` loop. This excludes `?` optionals (no back-edge)
  # and multi-op bodies (which may contain saves).
  let jmpPc = bodyPc + 1
  if jmpPc >= n: return
  let j = prog.instrs[jmpPc]
  if j.op != opJmp or j.arg1 != splitPc: return
  if prog.instrs[bodyPc].op == opChar:
    # Literal-char loop (a* a+): consume while equal. Unlike slkByte the
    # scan consumes the run, so a same-char exit could match a shorter
    # retry (`a*a`) and only a *different* exit char is sound.
    loopKind = slkChar
    loopCh = char(prog.instrs[bodyPc].arg1)
  elif prog.instrs[bodyPc].op in {opCharClass, opEscapeClass}:
    let loop = skipLoopInfo(prog, bodyPc)
    if not loop.ok or loop.exit != s.arg2: return
    if loop.kind notin {slkByte, slkNonWord, slkNonDigit, slkNonSpace}: return
    loopKind = loop.kind
    loopCh = loop.stopCh
  else:
    return
  var epc = s.arg2
  var depth = 0
  while true:
    if epc < 0 or epc >= n or depth > 64: return (-1, slkNone, '\0')
    let e = prog.instrs[epc]
    case e.op
    of opJmp: epc = e.arg1
    of opSave, opProgress: epc = epc + 1
    of opAnchorStart, opAnchorEnd, opWordBoundary: epc = epc + 1
    of opMatch: return (s.arg2, loopKind, loopCh)
    of opChar:
      let c = char(e.arg1)
      var sound = false
      case loopKind
      of slkByte: sound = c == loopCh
      of slkChar: sound = c != loopCh
      of slkNonWord: sound = c notin {'a'..'z', 'A'..'Z', '0'..'9', '_'}
      of slkNonDigit: sound = c notin {'0'..'9'}
      of slkNonSpace: sound = c notin {' ', '\t', '\n', '\r', '\f', '\v'}
      else: discard
      if sound: return (s.arg2, loopKind, loopCh)
      return (-1, slkNone, '\0')
    else: return (-1, slkNone, '\0')  # split, class, escape, anychar: give up
    inc depth

when defined(windows) or defined(noRegexJit) or not defined(amd64):
  # No JIT on Windows (System-V vs Win64 calling convention mismatch),
  # when explicitly disabled, or on non-x86_64 targets: the backend below
  # emits x86-64 machine code.
  proc compileRegex*(prog: Program): CompiledJit =
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
  #   rbp = execution context (ctx)   (callee-saved, repurposed)
  #   rax, rcx, rdx, r8-r11 = scratch
  #
  # Entry ABI: fn(rdi=input, rsi=len, rdx=startPos, rcx=ctx)
  # The prologue copies ctx to rbp (the frame pointer is unused by
  # generated code: pushes/pops stay balanced), freeing rcx as scratch:
  #   [rbp]      = backtrack stack base
  #   [rbp + 8]  = backtrack stack limit
  #   [rbp + 16] = capture working buffer (numSlots int64s, or nil)
  #   [rbp + 40] = full-match flag: when nonzero, opMatch requires pos == len
  # Returns: match end position (>= 0) or -1 on no match.
  #
  # Backtrack entry: 16 + 8*numSlots bytes
  #   { int64 pos; uint64 resumeAddr; int64 caps[numSlots] }
  # Every consuming/anchor failure jumps to the single fail-entry
  # label which unwinds the backtrack stack, restoring captures, and
  # indirect-jumps to the stored resume address.
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
      mov rbp, rcx            # ctx (frame unused: pushes stay balanced)
      mov r13, rdx            # pos = startPos
      mov r12, [rbp]          # backtrack top = base (empty)
      mov r15, [rbp + 8]      # backtrack limit
      mov r14, [rbp + 16]     # capture working buffer
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

  # Consume a run of literal characters with one bounds check, then
  # wide compares (qword/dword) and single-byte tail checks. Offsets
  # are relative to the entry r13, which advances once at the end.
  proc emitLiteralRun(a: var Assembler, bytes: openArray[int],
                      fail: DynamicLabel) =
    let n = bytes.len
    doAssert n >= 2
    dynasm a:
      arch x64
      lea rax, [r13 + n]
      cmp rax, rsi
      ja dyn(fail)
    var off = 0
    while off + 8 <= n:
      var w: uint64 = 0
      for i in 0 ..< 8:
        w = w or (uint64(bytes[off + i]) shl (i * 8))
      dynasm a:
        arch x64
        mov rax, [rbx + r13*1 + off]
        movabs r10, w
        cmp rax, r10
        jne dyn(fail)
      off += 8
    if off + 4 <= n:
      var w: uint32 = 0
      for i in 0 ..< 4:
        w = w or (uint32(bytes[off + i]) shl (i * 8))
      dynasm a:
        arch x64
        cmp dword [rbx + r13*1 + off], w
        jne dyn(fail)
      off += 4
    while off < n:
      let b = bytes[off]
      dynasm a:
        arch x64
        movzx eax, byte [rbx + r13*1 + off]
        cmp eax, b
        jne dyn(fail)
      inc off
    dynasm a:
      arch x64
      add r13, n

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
  # `tblAddr` is the aux class table (bit0=word, bit1=space); \d stays
  # inline (sub+cmp is already minimal), \w/\s go through the table.
  # Success falls through; each multi-branch shape gets a fresh join label.
  proc emitEscapeClass(a: var Assembler, cls: char, fail: DynamicLabel,
                       tblAddr = 0'u) =
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
    of 'w', 'W', 's', 'S':
      let bit = if cls in {'w', 'W'}: 1 else: 2
      dynasm a:
        arch x64
        movabs r10, tblAddr
        movzx eax, byte [r10 + rax*1]
        `and` eax, bit
      if cls in {'w', 's'}:
        dynasm a:
          arch x64
          jz dyn(fail)
      else:
        dynasm a:
          arch x64
          jnz dyn(fail)
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

  # Assert \b / \B via the aux class table (bit0 = isWord).
  # prevLoaded/curLoaded are caller-allocated join labels for the guarded
  # loads. Uses r10 for the table base and ecx/edx as scratch.
  proc emitWordBoundary(a: var Assembler, tblAddr: uint, negated: bool,
                        fail: DynamicLabel,
                        prevLoaded, curLoaded: DynamicLabel) =
    dynasm a:
      arch x64
      # isWord(prev char), 0 when pos == 0
      `xor` ecx, ecx
      test r13, r13
      jz dyn(prevLoaded)
      movzx ecx, byte [rbx + r13*1 - 1]
      dynamicLabel prevLoaded
      movabs r10, tblAddr
      movzx ecx, byte [r10 + rcx*1]
      `and` ecx, 1                # ecx = isWord(prev)
      # isWord(current char), 0 when pos == len
      `xor` edx, edx
      cmp r13, rsi
      jae dyn(curLoaded)
      movzx edx, byte [rbx + r13*1]
      dynamicLabel curLoaded
      movzx edx, byte [r10 + rdx*1]
      `and` edx, 1                # edx = isWord(cur)
      `xor` ecx, edx              # ecx = 1 iff boundary
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

  # Greedy-loop skip: replace per-char push/consume/unwind traffic with a
  # single scan to the run end, then continue at the exit. Sound only for
  # the exits classified by skipExitFor below.
  proc emitSkipLoop(a: var Assembler, kind: SkipLoopKind, stopCh: char,
                    tblAddr: uint, exitLbl: DynamicLabel) =
    let scan = a.newDynamicLabel()
    let done = a.newDynamicLabel()
    let stopOrd = ord(stopCh)
    case kind
    of slkByte:
      dynasm a:
        arch x64
        dynamicLabel scan
        cmp r13, rsi
        jae dyn(done)
        movzx eax, byte [rbx + r13*1]
        cmp eax, stopOrd
        je dyn(done)
        inc r13
        jmp dyn(scan)
        dynamicLabel done
    of slkNonWord, slkNonSpace:
      let bit = if kind == slkNonWord: 1 else: 2
      dynasm a:
        arch x64
        movabs r10, tblAddr
        dynamicLabel scan
        cmp r13, rsi
        jae dyn(done)
        movzx eax, byte [rbx + r13*1]
        movzx eax, byte [r10 + rax*1]
        `and` eax, bit
        jz dyn(done)
        inc r13
        jmp dyn(scan)
        dynamicLabel done
    of slkNonDigit:
      dynasm a:
        arch x64
        dynamicLabel scan
        cmp r13, rsi
        jae dyn(done)
        movzx eax, byte [rbx + r13*1]
        sub eax, ord('0')
        cmp eax, 9
        ja dyn(done)
        inc r13
        jmp dyn(scan)
        dynamicLabel done
    of slkChar:
      # Consume while equal to the loop char (a* a+).
      dynasm a:
        arch x64
        dynamicLabel scan
        cmp r13, rsi
        jae dyn(done)
        movzx eax, byte [rbx + r13*1]
        cmp eax, stopOrd
        jne dyn(done)
        inc r13
        jmp dyn(scan)
        dynamicLabel done
    else:
      doAssert false, "emitSkipLoop: unsupported kind"
    dynasm a:
      arch x64
      jmp dyn(exitLbl)

  # Fork execution: push {pos, resumeAddr, caps...} and try preferred branch.
  # Greedy split passes arg1's label; lazy split passes arg2's label
  # as tryFirst. The deferred address is a code pointer (RIP-relative LEA,
  # resolved at finalize), so failure unwinds with a single indirect jump
  # instead of a linear id-dispatch chain. Captures are snapshotted so the
  # deferred branch resumes with the values live at the fork point (PCRE
  # semantics). Entry stays 16 + 8*numSlots bytes: {pos:8, addr:8, caps}.
  proc emitSplit(a: var Assembler, tryFirst, resume: DynamicLabel,
                 entryBytes, numSlots: int, fail: DynamicLabel) =
    dynasm a:
      arch x64
      cmp r12, r15
      jae dyn(fail)              # stack full -> treat path as failed
      mov [r12], r13
      mov rax, dyn(resume)
      mov [r12 + 8], rax
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

  # Success: return current position. When the context full-match flag
  # is set (match()), the match only counts at end of input; otherwise
  # backtrack so another alternation/quantifier path can consume the rest.
  # One dynamic check serves both match() and find()/findAll() from a
  # single compilation (opMatch runs at most once per verification).
  proc emitMatch(a: var Assembler, exitLbl, fail: DynamicLabel) =
    let fullOk = a.newDynamicLabel()
    dynasm a:
      arch x64
      cmp qword [rbp + 40], 0
      je dyn(fullOk)
      cmp r13, rsi
      jne dyn(fail)
      dynamicLabel fullOk
      mov rax, r13
      jmp dyn(exitLbl)

  # Fail-entry head: unwind one backtrack entry into r13/rax,
  # restoring the capture snapshot, or jump to noMatch when the stack
  # is empty. The base is recomputed from the limit since no register
  # is reserved for it. The restore uses r10 as temp so rax (resume
  # address) survives for the final indirect jump.
  proc emitFailHead(a: var Assembler, noMatch: DynamicLabel,
                    entryBytes, numSlots: int, stackBytes: int) =
    dynasm a:
      arch x64
      lea rax, [r15 - stackBytes]  # rax = stack base
      cmp r12, rax
      jbe dyn(noMatch)             # empty
      sub r12, entryBytes
      mov r13, [r12]
      mov rax, [r12 + 8]
    for i in 0 ..< numSlots:
      let off = 16 + i * 8
      let dst = i * 8
      dynasm a:
        arch x64
        mov r10, [r12 + off]
        mov [r14 + dst], r10
    dynasm a:
      arch x64
      jmp rax                      # O(1) resume: no id-dispatch chain

  # No match: return -1.
  proc emitNoMatch(a: var Assembler) =
    dynasm a:
      arch x64
      `or` rax, -1

  proc compileRegex*(prog: Program): CompiledJit =
    ## Compile `prog` to native code. A single compilation serves both
    ## `match()` (sets the context full-match flag so opMatch requires
    ## end of input, with PCRE fullmatch backtracking semantics) and
    ## `find()`/`findAll()`. Capture groups are supported: saves write
    ## the working buffer, splits snapshot it.
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
      bitmapStore = cast[ptr UncheckedArray[uint8]](allocShared(numClasses * 32))
      if bitmapStore == nil:
        return
      for ci in 0 ..< numClasses:
        copyMem(addr bitmapStore[ci * 32],
                unsafeAddr prog.classes[ci].bitmap[0], 32)

    # Skip-loop pre-pass: greedy loops with sound exits become run scans
    # (no backtrack traffic). Runs before aux-table sizing since word/
    # space scans need the table.
    var skipExits = initTable[int, tuple[exit: int, kind: SkipLoopKind,
                                         stopCh: char]]()
    var skipNeedsTbl = false
    for pc in 0 ..< numInstrs:
      if prog.instrs[pc].op != opSplit: continue
      let sk = skipExitFor(prog, pc)
      if sk.exit < 0: continue
      skipExits[pc] = sk
      if sk.kind in {slkNonWord, slkNonSpace}: skipNeedsTbl = true

    # Aux class table (bit0 = isWord, bit1 = isSpace) for \b and
    # \w\W\s\S. Allocated only when the program uses them; the generated
    # code embeds a raw pointer, so it must outlive `prog` like the
    # bitmaps above.
    var auxTable: ptr UncheckedArray[uint8] = nil
    block allocAux:
      var needAux = skipNeedsTbl
      if not needAux:
        for ins in prog.instrs:
          if ins.op == opWordBoundary:
            needAux = true
            break
          if ins.op == opEscapeClass and char(ins.arg1) in {'w', 'W', 's', 'S'}:
            needAux = true
            break
      if not needAux:
        break allocAux
      auxTable = cast[ptr UncheckedArray[uint8]](allocShared(256))
      if auxTable == nil:
        if bitmapStore != nil:
          deallocShared(cast[pointer](bitmapStore))
        return
      for c in 0 ..< 256:
        var b = 0'u8
        let ch = char(c)
        if ch in {'a'..'z', 'A'..'Z', '0'..'9', '_'}: b = b or 1
        if ch in {' ', '\t', '\n', '\r', '\f', '\v'}: b = b or 2
        auxTable[c] = b
    let tblAddr = if auxTable != nil: cast[uint](auxTable) else: 0'u

    emitPrologue(a, numSlots)

    # Pass 2: emit opcode bodies.
    var pc = 0
    while pc < numInstrs:
      let ins = prog.instrs[pc]
      if pc in pcToLabel:
        emitDefine(a, pcToLabel[pc])

      case ins.op
      of opChar:
        # Coalesce maximal literal runs (stop before jump targets that
        # land mid-run so every label keeps its position).
        var run = @[ins.arg1]
        var q = pc + 1
        while q < numInstrs and prog.instrs[q].op == opChar and
            q notin pcToLabel:
          run.add(prog.instrs[q].arg1)
          inc q
        if run.len >= 2:
          emitLiteralRun(a, run, failEntry)
        else:
          emitChar(a, ins.arg1, failEntry)
        pc = q
        continue

      of opAnyChar:
        emitAnyChar(a, failEntry)

      of opCharClass:
        # Bounds were validated in Pass 1, but re-check defensively: an
        # invalid index must reject compilation, never read OOB.
        if ins.arg1 < 0 or ins.arg1 >= numClasses:
          if bitmapStore != nil:
            deallocShared(cast[pointer](bitmapStore))
          if auxTable != nil:
            deallocShared(cast[pointer](auxTable))
          return
        emitCharClass(a, cast[uint](addr bitmapStore[ins.arg1 * 32]),
                      ins.neg, failEntry)

      of opEscapeClass:
        emitEscapeClass(a, char(ins.arg1), failEntry, tblAddr)

      of opAnchorStart:
        emitAnchorStart(a, failEntry)

      of opAnchorEnd:
        emitAnchorEnd(a, failEntry)

      of opWordBoundary:
        let (pl, cl) = wbLabels[pc]
        emitWordBoundary(a, tblAddr, ins.neg, failEntry, pl, cl)

      of opJmp:
        emitJmp(a, pcToLabel[ins.arg1])

      of opSplit, opSplitLazy:
        if pc in skipExits:
          let sk = skipExits[pc]
          emitSkipLoop(a, sk.kind, sk.stopCh, tblAddr, pcToLabel[sk.exit])
        else:
          let tryFirstPc = if ins.op == opSplit: ins.arg1 else: ins.arg2
          let resumePc   = if ins.op == opSplit: ins.arg2 else: ins.arg1
          emitSplit(a, pcToLabel[tryFirstPc], pcToLabel[resumePc],
                    entryBytes, numSlots, failEntry)

      of opMatch:
        emitMatch(a, matchExit, failEntry)

      of opProgress:
        discard  # pure epsilon

      of opSave:
        # Bounds mirror the compiler invariant (slot < numCaptures*2),
        # but never trust bytecode blindly with raw stores.
        if ins.arg1 < 0 or ins.arg1 >= numSlots:
          if bitmapStore != nil:
            deallocShared(cast[pointer](bitmapStore))
          if auxTable != nil:
            deallocShared(cast[pointer](auxTable))
          return
        emitSave(a, ins.arg1)
      inc pc

    # Tail: match exit, failure unwinder (O(1) indirect resume), no-match.
    emitDefine(a, matchExit)
    emitEpilogue(a)

    emitDefine(a, failEntry)
    emitFailHead(a, noMatch, entryBytes, numSlots, stackBytes)

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
      capsBuf = cast[ptr UncheckedArray[int]](allocShared(numSlots * 8))
      if capsBuf == nil:
        if bitmapStore != nil:
          deallocShared(cast[pointer](bitmapStore))
        if auxTable != nil:
          deallocShared(cast[pointer](auxTable))
        buf.destroy()
        return

    let stack = cast[ptr UncheckedArray[byte]](allocShared(stackBytes))
    if stack == nil:
      if capsBuf != nil:
        deallocShared(cast[pointer](capsBuf))
      if bitmapStore != nil:
        deallocShared(cast[pointer](bitmapStore))
      if auxTable != nil:
        deallocShared(cast[pointer](auxTable))
      buf.destroy()
      return
    let ctx = cast[ptr JitCtx](allocShared(sizeof(JitCtx)))
    if ctx == nil:
      deallocShared(cast[pointer](stack))
      if capsBuf != nil:
        deallocShared(cast[pointer](capsBuf))
      if bitmapStore != nil:
        deallocShared(cast[pointer](bitmapStore))
      if auxTable != nil:
        deallocShared(cast[pointer](auxTable))
      buf.destroy()
      return
    ctx.stackBase  = stack
    ctx.stackLimit = cast[pointer](addr stack[stackBytes])
    ctx.capsBase   = cast[ptr UncheckedArray[byte]](capsBuf)
    ctx.stackBytes = stackBytes
    ctx.numSlots   = numSlots
    ctx.fullFlag   = 0

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
                         auxTable: auxTable,
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
