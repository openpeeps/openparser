/* Glue file: includes DynASM runtime + generated action list + emit functions.
   Compiled once by Nim's {.compile.} pragma. */
#include "dasm_proto.h"
#include "dasm_x86.h"
#include "regex_jit.c"

/* Re-export the action list pointer */
const void* get_regex_actions(void) {
  return (const void*)regex_actions;
}

/* Helper: set up a dasm_State with our action list. */
int regex_setup(dasm_State** d, void** globals, unsigned int maxgl) {
  dasm_init(d, DASM_MAXSECTION);
  if (*d == NULL) return -1;
  dasm_setupglobal(d, globals, maxgl);
  dasm_setup(d, regex_actions);
  return 0;
}
