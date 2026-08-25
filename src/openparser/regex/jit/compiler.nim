## Regex JIT compiler — compiles regex bytecode to native x86-64 code
## via DynASM. The generated code is a classic backtracking engine:
## splits push a resume entry onto an in-memory backtrack stack and
## all failures unwind through a single fail-entry point.
import std/[tables]
import ./wrapper, ./jit_mem
import ../compiler, ../simd

const
  DASM_MAXSECTION = 1
  ## Reserved dynamic PC label ids (allocated first by convention):
  lblMatchExit* = 0          ## success exit: rax = stop position
  lblFailEntry* = 1          ## common failure unwinder
  lblNoMatch*   = 2          ## rax = -1
  BacktrackMaxEntries = 16384 ## 256 KiB backtrack stack per program

type
  RegexJitFn* = proc(input: ptr char, inputLen: int, startPos: int,
                     ctx: ptr JitCtx): int {.cdecl.}

  JitCtx* = object
    stackBase*:  ptr UncheckedArray[byte]
    stackLimit*: pointer

  CompiledJit* = object
    fn*:       RegexJitFn
    ctx*:      ptr JitCtx
    codeSize*: int
    firstByte*: int   ## byte the match must start with, -1 = unknown
    anchored*: bool   ## program starts with ^: only startPos 0 can match

proc freeJit*(cj: var CompiledJit) =
  ## Release generated code, backtrack stack and context.
  if cj.ctx != nil:
    if cj.ctx.stackBase != nil:
      deallocShared(cast[pointer](cj.ctx.stackBase))
    deallocShared(cast[pointer](cj.ctx))
    cj.ctx = nil
  cj.fn = nil

proc compileRegex*(prog: Program, fullMatch = false): CompiledJit =
  ## Compile `prog` to native code. With `fullMatch`, opMatch only
  ## succeeds at end of input (PCRE fullmatch semantics: failed end
  ## checks backtrack into remaining alternatives). Returns a result
  ## with fn == nil when the program uses unsupported features
  ## (captures) or contains epsilon cycles.
  let numInstrs = prog.instrs.len
  if prog.numCaptures > 0 or numInstrs == 0:
    return

  # Pass 1: validate jump targets and pre-allocate dynamic PC labels.
  # Label ids 0..2 are reserved; jump/split targets get one label per pc,
  # word boundaries need two extra join labels each.
  var supported = true
  var pcToLabel = initTable[int, int]()
  var wbLabels  = initTable[int, tuple[prevLbl, curLbl: int]]()
  var nextLabel = 3
  template addTarget(t: untyped) =
    if t < 0 or t >= numInstrs:
      supported = false
    elif t notin pcToLabel:
      pcToLabel[t] = nextLabel
      inc nextLabel

  for i in 0 ..< numInstrs:
    let ins = prog.instrs[i]
    case ins.op
    of opSave: supported = false
    of opJmp: addTarget(ins.arg1)
    of opSplit, opSplitLazy:
      addTarget(ins.arg1)
      addTarget(ins.arg2)
    of opWordBoundary:
      wbLabels[i] = (nextLabel, nextLabel + 1)
      inc nextLabel, 2
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

  var d: ptr dasm_State = nil
  dasm_init(addr d, DASM_MAXSECTION)
  var globals: array[64, pointer]
  dasm_setupglobal(addr d, addr globals[0], 64)
  dasm_setup(addr d, get_regex_actions())
  dasm_growpc(addr d, nextLabel.cuint)

  regex_prologue(addr d)

  type ResumeCase = tuple[id, targetPc: int]
  var resumeCases: seq[ResumeCase] = @[]
  var nextResumeId = 0

  # Pass 2: emit opcode bodies.
  for pc in 0 ..< numInstrs:
    let ins = prog.instrs[pc]
    if pc in pcToLabel:
      regex_define_label(addr d, pcToLabel[pc].cint)

    case ins.op
    of opChar:
      regex_emit_char(addr d, ins.arg1.cint, lblFailEntry.cint)

    of opAnyChar:
      regex_emit_any_char(addr d, lblFailEntry.cint)

    of opCharClass:
      regex_emit_char_class(addr d,
        cast[uint](unsafeAddr prog.classes[ins.arg1].bitmap[0]),
        cint(ord(ins.neg)), lblFailEntry.cint)

    of opEscapeClass:
      regex_emit_escape_class(addr d, ins.arg1.cint, lblFailEntry.cint)

    of opAnchorStart:
      regex_emit_anchor_start(addr d, lblFailEntry.cint)

    of opAnchorEnd:
      regex_emit_anchor_end(addr d, lblFailEntry.cint)

    of opWordBoundary:
      let (pl, cl) = wbLabels[pc]
      regex_emit_word_boundary(addr d, cint(ord(ins.neg)),
                               lblFailEntry.cint, pl.cint, cl.cint)

    of opJmp:
      regex_emit_jmp(addr d, pcToLabel[ins.arg1].cint)

    of opSplit, opSplitLazy:
      let tryFirstPc = if ins.op == opSplit: ins.arg1 else: ins.arg2
      let resumePc   = if ins.op == opSplit: ins.arg2 else: ins.arg1
      resumeCases.add((nextResumeId, resumePc))
      regex_split(addr d, pcToLabel[tryFirstPc].cint, nextResumeId.cint,
                  pcToLabel[resumePc].cint, lblFailEntry.cint)
      inc nextResumeId

    of opMatch:
      regex_emit_match(addr d, lblMatchExit.cint, lblFailEntry.cint,
                       cint(ord(fullMatch)))

    of opProgress, opSave:
      discard  # pure epsilon: save is rejected earlier, progress harmless

  # Tail: match exit, failure unwinder with dispatch chain, no-match.
  regex_define_label(addr d, lblMatchExit.cint)
  regex_epilogue(addr d)

  regex_define_label(addr d, lblFailEntry.cint)
  regex_emit_fail_entry_head(addr d, lblNoMatch.cint,
                             cint(BacktrackMaxEntries * 16))
  for rc in resumeCases:
    regex_emit_dispatch_case(addr d, rc.id.cint, pcToLabel[rc.targetPc].cint)

  regex_define_label(addr d, lblNoMatch.cint)
  regex_emit_no_match(addr d)
  regex_epilogue(addr d)

  # Link, allocate executable memory and encode.
  var codeSize: csize_t
  if dasm_link(addr d, addr codeSize) != 0:
    dasm_free(addr d)
    return
  let codeBuf = allocJitCode(codeSize.int)
  if codeBuf == nil:
    dasm_free(addr d)
    return
  if dasm_encode(addr d, codeBuf) != 0:
    freeJitCode(codeBuf, codeSize.int)
    dasm_free(addr d)
    return
  dasm_free(addr d)

  let stackBytes = BacktrackMaxEntries * 16
  let stack = cast[ptr UncheckedArray[byte]](allocShared0(stackBytes))
  let ctx = cast[ptr JitCtx](allocShared0(sizeof(JitCtx)))
  ctx.stackBase  = stack
  ctx.stackLimit = cast[pointer](addr stack[stackBytes])

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

  result = CompiledJit(fn: cast[RegexJitFn](codeBuf),
                       ctx: ctx, codeSize: codeSize.int,
                       firstByte: firstByte, anchored: anchored)

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
  if cj.anchored and fromPos > 0:
    return
  when not defined(noRegexJit):
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
