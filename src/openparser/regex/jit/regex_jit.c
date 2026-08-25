/*
** This file has been pre-processed with DynASM.
** https://luajit.org/dynasm.html
** DynASM version 1.5.0, DynASM x64 version 1.5.0
** DO NOT EDIT! The original file is in "src/openparser/regex/jit/regex_jit.dasc".
*/

#line 1 "src/openparser/regex/jit/regex_jit.dasc"
//|.arch x64
#if DASM_VERSION != 10500
#error "Version mismatch between DynASM and included encoding engine"
#endif
#line 2 "src/openparser/regex/jit/regex_jit.dasc"
//|.section code
#define DASM_SECTION_CODE	0
#define DASM_MAXSECTION		1
#line 3 "src/openparser/regex/jit/regex_jit.dasc"

//|.actionlist regex_actions
static const unsigned char regex_actions[544] = {
  85,72,137,229,83,65,84,65,85,65,86,65,87,72,137,252,251,73,137,213,76,139,
  33,76,139,185,233,255,65,95,65,94,65,93,65,92,91,93,195,255,73,57,252,245,
  15,141,245,66,15,182,4,43,129,252,248,239,15,133,245,73,252,255,197,255,73,
  57,252,245,15,141,245,66,15,182,4,43,131,252,248,10,15,132,245,73,252,255,
  197,255,73,57,252,245,15,141,245,66,15,182,12,43,137,200,193,232,3,73,186,
  237,237,65,15,182,20,2,131,225,7,15,163,202,255,15,130,245,255,15,131,245,
  255,73,57,252,245,15,141,245,66,15,182,4,43,255,129,232,239,131,252,248,9,
  15,135,245,255,129,232,239,131,252,248,9,15,134,245,255,137,193,131,201,32,
  129,252,233,239,131,252,249,25,15,134,244,247,137,193,129,252,233,239,131,
  252,249,9,15,134,244,247,129,252,248,239,15,132,244,247,252,233,245,248,1,
  255,137,193,131,201,32,129,252,233,239,131,252,249,25,15,134,245,137,193,
  129,252,233,239,131,252,249,9,15,134,245,129,252,248,239,15,132,245,255,131,
  232,9,131,252,248,4,15,134,244,247,66,128,60,43,235,15,132,244,247,252,233,
  245,248,1,255,131,232,9,131,252,248,4,15,134,245,66,128,60,43,235,15,132,
  245,255,252,233,245,255,77,133,252,237,15,133,245,255,73,57,252,245,15,133,
  245,255,49,201,77,133,252,237,15,132,245,66,15,182,140,253,43,233,249,65,
  137,200,65,131,200,32,65,129,232,239,65,131,252,248,25,65,15,150,208,69,15,
  182,192,65,137,201,65,129,252,233,239,65,131,252,249,9,65,15,150,209,69,15,
  182,201,49,210,129,252,249,239,15,148,210,68,9,194,68,9,202,255,49,201,73,
  57,252,245,15,131,245,66,15,182,12,43,249,65,137,200,65,131,200,32,65,129,
  232,239,65,131,252,248,25,65,15,150,208,69,15,182,192,65,137,201,65,129,252,
  233,239,65,131,252,249,9,65,15,150,209,69,15,182,201,69,49,252,246,129,252,
  249,239,65,15,148,214,69,15,182,252,246,69,9,198,69,9,206,68,49,252,242,255,
  249,255,77,57,252,252,15,131,245,77,137,44,36,65,199,132,253,36,233,237,73,
  131,196,16,252,233,245,255,76,137,232,252,233,245,255,73,141,135,233,73,57,
  196,15,134,245,73,131,252,236,16,77,139,44,36,65,139,132,253,36,233,255,72,
  131,200,252,255,255
};

#line 5 "src/openparser/regex/jit/regex_jit.dasc"

// ---------------------------------------------------------------
// Regex JIT — native backtracking engine.
//
// Generated-code register contract:
//   rbx = input base pointer        (callee-saved)
//   rsi = input length
//   r13 = current position          (callee-saved)
//   r12 = backtrack stack top       (callee-saved, grows upward)
//   r15 = backtrack stack limit     (callee-saved)
//   rax, rcx, rdx, r8-r11, r14 = scratch
//
// Entry ABI: fn(rdi=input, rsi=len, rdx=startPos, rcx=ctx)
//   [rcx]     = backtrack stack base
//   [rcx + 8] = backtrack stack limit
// Returns: match end position (>= 0) or -1 on no match.
//
// Backtrack entry: 16 bytes { int64 pos; int32 resumeId; int32 pad }
// Every consuming/anchor failure jumps to the single fail-entry
// label which unwinds the backtrack stack. Splits push an entry
// and jump to their preferred branch.
//
// All cross-function labels are dynamic PC labels (dasm_growpc);
// they are global to the dasm_State, so emit functions may freely
// reference labels allocated by the Nim-side compiler or by other
// emit functions via =>label. Reserved PC label ids (fixed):
//   0 = match exit   1 = fail entry   2 = no-match
// ---------------------------------------------------------------

void regex_prologue(dasm_State** Dst) {
  //| push rbp
  //| mov rbp, rsp
  //| push rbx
  //| push r12
  //| push r13
  //| push r14
  //| push r15
  //| mov rbx, rdi            // input ptr
  //| mov r13, rdx            // pos = startPos
  //| mov r12, [rcx]          // backtrack top = base (empty)
  //| mov r15, [rcx + 8]      // backtrack limit
  dasm_put(Dst, 0, 8);
#line 46 "src/openparser/regex/jit/regex_jit.dasc"
}

void regex_epilogue(dasm_State** Dst) {
  //| pop r15
  //| pop r14
  //| pop r13
  //| pop r12
  //| pop rbx
  //| pop rbp
  //| ret
  dasm_put(Dst, 28);
#line 56 "src/openparser/regex/jit/regex_jit.dasc"
}

// Consume one literal character.
void regex_emit_char(dasm_State** Dst, int lit, int failLabel) {
  //| cmp r13, rsi
  //| jge =>failLabel
  //| movzx eax, byte [rbx + r13]
  //| cmp eax, lit&255
  //| jne =>failLabel
  //| inc r13
  dasm_put(Dst, 40, failLabel, lit&255, failLabel);
#line 66 "src/openparser/regex/jit/regex_jit.dasc"
}

// Consume any character except '\n'.
void regex_emit_any_char(dasm_State** Dst, int failLabel) {
  //| cmp r13, rsi
  //| jge =>failLabel
  //| movzx eax, byte [rbx + r13]
  //| cmp eax, 10
  //| je =>failLabel
  //| inc r13
  dasm_put(Dst, 64, failLabel, failLabel);
#line 76 "src/openparser/regex/jit/regex_jit.dasc"
}

// Consume one char via 256-bit class bitmap (pointer embedded).
void regex_emit_char_class(dasm_State** Dst, uintptr_t bitmapPtr, int negated, int failLabel) {
  //| cmp r13, rsi
  //| jge =>failLabel
  //| movzx ecx, byte [rbx + r13]      // c
  //| mov eax, ecx
  //| shr eax, 3
  //| mov64 r10, bitmapPtr
  //| movzx edx, byte [r10 + rax]      // bitmap[c >> 3]
  //| and ecx, 7
  //| bt edx, ecx                      // bit (c & 7)
  dasm_put(Dst, 88, failLabel, (unsigned int)(bitmapPtr), (unsigned int)((bitmapPtr)>>32));
#line 89 "src/openparser/regex/jit/regex_jit.dasc"
  if (negated) {
    //| jc =>failLabel
    dasm_put(Dst, 121, failLabel);
#line 91 "src/openparser/regex/jit/regex_jit.dasc"
  } else {
    //| jnc =>failLabel
    dasm_put(Dst, 125, failLabel);
#line 93 "src/openparser/regex/jit/regex_jit.dasc"
  }
  //| inc r13
  dasm_put(Dst, 59);
#line 95 "src/openparser/regex/jit/regex_jit.dasc"
}

// Consume one char via escape class (\d \D \w \W \s \S).
// `cls` is the escape letter itself ('d','D','w','W','s','S').
// Success falls through past the last emitted check.
void regex_emit_escape_class(dasm_State** Dst, int cls, int failLabel) {
  //| cmp r13, rsi
  //| jge =>failLabel
  //| movzx eax, byte [rbx + r13]
  dasm_put(Dst, 129, failLabel);
#line 104 "src/openparser/regex/jit/regex_jit.dasc"
  switch (cls) {
    case 'd':
      //| sub eax, '0'
      //| cmp eax, 9
      //| ja =>failLabel
      dasm_put(Dst, 142, '0', failLabel);
#line 109 "src/openparser/regex/jit/regex_jit.dasc"
      break;
    case 'D':
      //| sub eax, '0'
      //| cmp eax, 9
      //| jbe =>failLabel
      dasm_put(Dst, 153, '0', failLabel);
#line 114 "src/openparser/regex/jit/regex_jit.dasc"
      break;
    case 'w':
      //| mov ecx, eax
      //| or ecx, 0x20
      //| sub ecx, 'a'
      //| cmp ecx, 25
      //| jbe >1
      //| mov ecx, eax
      //| sub ecx, '0'
      //| cmp ecx, 9
      //| jbe >1
      //| cmp eax, '_'
      //| je >1
      //| jmp =>failLabel
      //|1:
      dasm_put(Dst, 164, 'a', '0', '_', failLabel);
#line 129 "src/openparser/regex/jit/regex_jit.dasc"
      break;
    case 'W':
      //| mov ecx, eax
      //| or ecx, 0x20
      //| sub ecx, 'a'
      //| cmp ecx, 25
      //| jbe =>failLabel
      //| mov ecx, eax
      //| sub ecx, '0'
      //| cmp ecx, 9
      //| jbe =>failLabel
      //| cmp eax, '_'
      //| je =>failLabel
      dasm_put(Dst, 209, 'a', failLabel, '0', failLabel, '_', failLabel);
#line 142 "src/openparser/regex/jit/regex_jit.dasc"
      break;
    case 's':
      // \t(9) \n(10) \v(11) \f(12) \r(13) are contiguous
      //| sub eax, 9
      //| cmp eax, 4
      //| jbe >1
      //| cmp byte [rbx + r13], ' '
      //| je >1
      //| jmp =>failLabel
      //|1:
      dasm_put(Dst, 246, ' ', failLabel);
#line 152 "src/openparser/regex/jit/regex_jit.dasc"
      break;
    case 'S':
      //| sub eax, 9
      //| cmp eax, 4
      //| jbe =>failLabel
      //| cmp byte [rbx + r13], ' '
      //| je =>failLabel
      dasm_put(Dst, 272, failLabel, ' ', failLabel);
#line 159 "src/openparser/regex/jit/regex_jit.dasc"
      break;
    default:
      //| jmp =>failLabel
      dasm_put(Dst, 291, failLabel);
#line 162 "src/openparser/regex/jit/regex_jit.dasc"
      break;
  }
  //| inc r13                  // success: consume the char
  dasm_put(Dst, 59);
#line 165 "src/openparser/regex/jit/regex_jit.dasc"
}

// Assert ^: absolute start of input.
void regex_emit_anchor_start(dasm_State** Dst, int failLabel) {
  //| test r13, r13
  //| jnz =>failLabel
  dasm_put(Dst, 295, failLabel);
#line 171 "src/openparser/regex/jit/regex_jit.dasc"
}

// Assert $: absolute end of input.
void regex_emit_anchor_end(dasm_State** Dst, int failLabel) {
  //| cmp r13, rsi
  //| jne =>failLabel
  dasm_put(Dst, 303, failLabel);
#line 177 "src/openparser/regex/jit/regex_jit.dasc"
}

// Assert \b / \B. lblPrevLoaded/lblCurLoaded are caller-allocated
// dynamic PC labels used as join points for the guarded loads.
void regex_emit_word_boundary(dasm_State** Dst, int negated, int failLabel, int lblPrevLoaded, int lblCurLoaded) {
  // isWord(prev char), 0 when pos == 0
  //| xor ecx, ecx
  //| test r13, r13
  //| jz =>lblPrevLoaded
  //| movzx ecx, byte [rbx + r13 - 1]
  //|=>lblPrevLoaded:
  //| mov r8d, ecx
  //| or r8d, 0x20
  //| sub r8d, 'a'
  //| cmp r8d, 25
  //| setbe r8b
  //| movzx r8d, r8b
  //| mov r9d, ecx
  //| sub r9d, '0'
  //| cmp r9d, 9
  //| setbe r9b
  //| movzx r9d, r9b
  //| xor edx, edx
  //| cmp ecx, '_'
  //| sete dl
  //| or edx, r8d
  //| or edx, r9d              // edx = isWord(prev)
  dasm_put(Dst, 311, lblPrevLoaded, - 1, lblPrevLoaded, 'a', '0', '_');
#line 204 "src/openparser/regex/jit/regex_jit.dasc"
  // isWord(current char), 0 when pos == len
  //| xor ecx, ecx
  //| cmp r13, rsi
  //| jae =>lblCurLoaded
  //| movzx ecx, byte [rbx + r13]
  //|=>lblCurLoaded:
  //| mov r8d, ecx
  //| or r8d, 0x20
  //| sub r8d, 'a'
  //| cmp r8d, 25
  //| setbe r8b
  //| movzx r8d, r8b
  //| mov r9d, ecx
  //| sub r9d, '0'
  //| cmp r9d, 9
  //| setbe r9b
  //| movzx r9d, r9b
  //| xor r14d, r14d
  //| cmp ecx, '_'
  //| sete r14b
  //| movzx r14d, r14b
  //| or r14d, r8d
  //| or r14d, r9d             // r14d = isWord(cur)
  //| xor edx, r14d            // edx = 1 iff boundary
  dasm_put(Dst, 389, lblCurLoaded, lblCurLoaded, 'a', '0', '_');
#line 228 "src/openparser/regex/jit/regex_jit.dasc"
  if (!negated) {
    //| jz =>failLabel         // \b wants a boundary
    dasm_put(Dst, 242, failLabel);
#line 230 "src/openparser/regex/jit/regex_jit.dasc"
  } else {
    //| jnz =>failLabel        // \B wants none
    dasm_put(Dst, 299, failLabel);
#line 232 "src/openparser/regex/jit/regex_jit.dasc"
  }
}

// Unconditional jump.
void regex_jmp(dasm_State** Dst, int targetLabel) {
  //| jmp =>targetLabel
  dasm_put(Dst, 291, targetLabel);
#line 238 "src/openparser/regex/jit/regex_jit.dasc"
}

// Define a dynamic PC label at the current position.
void regex_define_label(dasm_State** Dst, int label) {
  //|=>label:
  dasm_put(Dst, 477, label);
#line 243 "src/openparser/regex/jit/regex_jit.dasc"
}

// Fork execution: push {pos, resumeId} and try preferred branch.
// Greedy split passes arg1's label; lazy split passes arg2's label
// as tryFirstLabel (resumeTargetLabel is the deferred branch).
void regex_split(dasm_State** Dst, int tryFirstLabel, int resumeId, int resumeTargetLabel, int failLabel) {
  //| cmp r12, r15
  //| jae =>failLabel          // stack full -> treat path as failed
  //| mov [r12], r13
  //| mov dword [r12 + 8], resumeId+0
  //| add r12, 16
  //| jmp =>tryFirstLabel
  dasm_put(Dst, 479, failLabel, 8, resumeId+0, tryFirstLabel);
#line 255 "src/openparser/regex/jit/regex_jit.dasc"
}

// Success: return current position. In full-match mode the match only
// counts when it reached end of input; otherwise backtrack so that
// another alternation/quantifier path can try to consume the rest.
void regex_emit_match(dasm_State** Dst, int exitLabel, int failLabel, int wantFull) {
  if (wantFull) {
    //| cmp r13, rsi
    //| jne =>failLabel
    dasm_put(Dst, 303, failLabel);
#line 264 "src/openparser/regex/jit/regex_jit.dasc"
  }
  //| mov rax, r13
  //| jmp =>exitLabel
  dasm_put(Dst, 505, exitLabel);
#line 267 "src/openparser/regex/jit/regex_jit.dasc"
}

// Fail-entry head: unwind one backtrack entry into r13/rax,
// or jump to noMatchLabel when the stack is empty. stackBytes is
// the total capacity of the backtrack region in bytes; the base is
// recomputed from the limit since no register is reserved for it.
void regex_emit_fail_entry_head(dasm_State** Dst, int noMatchLabel, int stackBytes) {
  //| lea rax, [r15 - stackBytes+0]   // rax = stack base
  //| cmp r12, rax
  //| jbe =>noMatchLabel              // empty
  //| sub r12, 16
  //| mov r13, [r12]
  //| mov eax, [r12 + 8]
  dasm_put(Dst, 512, - stackBytes+0, noMatchLabel, 8);
#line 280 "src/openparser/regex/jit/regex_jit.dasc"
}

// One dispatch case for the unwound resume id (eax).
void regex_emit_dispatch_case(dasm_State** Dst, int id, int targetLabel) {
  //| cmp eax, id+0
  //| je =>targetLabel
  dasm_put(Dst, 238, id+0, targetLabel);
#line 286 "src/openparser/regex/jit/regex_jit.dasc"
}

// No match: return -1.
void regex_emit_no_match(dasm_State** Dst) {
  //| or rax, -1
  dasm_put(Dst, 538);
#line 291 "src/openparser/regex/jit/regex_jit.dasc"
}
