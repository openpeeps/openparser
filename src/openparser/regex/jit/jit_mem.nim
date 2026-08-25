# VanCode - A fast, extensible bytecode generator and VM for building
# Domain-Specific Languages (DSLs), or general-purpose programming language
#
# Powered by Nim.
#
# (c) 2025 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/vancode

## Low-level JIT code memory allocator. Provides `allocJitCode` and
## `freeJitCode` backed by platform-specific routines (e.g. mmap with
## PROT_EXEC) declared in `regex_jit_mem.h`.
import std/os
{.passC: "-I" & currentSourcePath().parentDir.}

proc allocJitCode*(size: int): pointer {.importc: "vc_alloc_jit_code", header: "regex_jit_mem.h".}
proc freeJitCode*(p: pointer, size: int) {.importc: "vc_free_jit_code", header: "regex_jit_mem.h".}
