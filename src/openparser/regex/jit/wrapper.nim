## C FFI bindings to the DynASM assembler library for regex JIT compilation.
when defined(regexJitDynlib):
  const dynasmLib* {.strdefine.} = "libregexjit.dylib"
  {.pragma: dynasm, importc, cdecl, dynlib: dynasmLib.}
else:
  {.compile: "regex_jit_glue.c".}
  {.pragma: dynasm, importc, cdecl.}

type
  dasm_State* = object

# DynASM core API
proc dasm_init*(Dst: ptr ptr dasm_State; maxsection: cint) {.dynasm, importc: "dasm_init".}
proc dasm_free*(Dst: ptr ptr dasm_State) {.dynasm, importc: "dasm_free".}
proc dasm_setupglobal*(Dst: ptr ptr dasm_State; gl: ptr pointer; maxgl: cuint) {.dynasm, importc: "dasm_setupglobal".}
proc dasm_setup*(Dst: ptr ptr dasm_State; actionlist: pointer) {.dynasm, importc: "dasm_setup".}
proc dasm_growpc*(Dst: ptr ptr dasm_State; maxpc: cuint) {.dynasm, importc: "dasm_growpc".}
proc dasm_link*(Dst: ptr ptr dasm_State; szp: ptr csize_t): cint {.dynasm, importc: "dasm_link".}
proc dasm_encode*(Dst: ptr ptr dasm_State; buf: pointer): cint {.dynasm, importc: "dasm_encode".}

# Regex JIT emit functions
proc regex_prologue*(Dst: ptr ptr dasm_State) {.dynasm, importc: "regex_prologue".}
proc regex_epilogue*(Dst: ptr ptr dasm_State) {.dynasm, importc: "regex_epilogue".}
proc regex_emit_char*(Dst: ptr ptr dasm_State; lit: cint; failLabel: cint) {.dynasm, importc: "regex_emit_char".}
proc regex_emit_any_char*(Dst: ptr ptr dasm_State; failLabel: cint) {.dynasm, importc: "regex_emit_any_char".}
proc regex_emit_char_class*(Dst: ptr ptr dasm_State; bitmapPtr: uint; negated: cint; failLabel: cint) {.dynasm, importc: "regex_emit_char_class".}
proc regex_emit_escape_class*(Dst: ptr ptr dasm_State; cls: cint; failLabel: cint) {.dynasm, importc: "regex_emit_escape_class".}
proc regex_emit_anchor_start*(Dst: ptr ptr dasm_State; failLabel: cint) {.dynasm, importc: "regex_emit_anchor_start".}
proc regex_emit_anchor_end*(Dst: ptr ptr dasm_State; failLabel: cint) {.dynasm, importc: "regex_emit_anchor_end".}
proc regex_emit_word_boundary*(Dst: ptr ptr dasm_State; negated: cint; failLabel: cint; lblPrevLoaded: cint; lblCurLoaded: cint) {.dynasm, importc: "regex_emit_word_boundary".}
proc regex_emit_jmp*(Dst: ptr ptr dasm_State; targetLabel: cint) {.dynasm, importc: "regex_jmp".}
proc regex_split*(Dst: ptr ptr dasm_State; tryFirstLabel: cint; resumeId: cint; resumeTargetLabel: cint; failLabel: cint) {.dynasm, importc: "regex_split".}
proc regex_emit_match*(Dst: ptr ptr dasm_State; exitLabel: cint; failLabel: cint; wantFull: cint) {.dynasm, importc: "regex_emit_match".}
proc regex_emit_fail_entry_head*(Dst: ptr ptr dasm_State; noMatchLabel: cint; stackBytes: cint) {.dynasm, importc: "regex_emit_fail_entry_head".}
proc regex_emit_dispatch_case*(Dst: ptr ptr dasm_State; id: cint; targetLabel: cint) {.dynasm, importc: "regex_emit_dispatch_case".}
proc regex_emit_no_match*(Dst: ptr ptr dasm_State) {.dynasm, importc: "regex_emit_no_match".}
proc regex_define_label*(Dst: ptr ptr dasm_State; label: cint) {.dynasm, importc: "regex_define_label".}
proc get_regex_actions*(): pointer {.dynasm, importc: "get_regex_actions".}
