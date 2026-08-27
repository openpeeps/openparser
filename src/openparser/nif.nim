# A collection of tiny parsers and dumpers
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/openparser

## NIF parser — entry point
## Re-exports `nif/ast`, `nif/lexer`, `nif/parser`
## Provides `fromNif`, `fromNifFile`, `tokenizeNif` (+ MemFile overloads)
## Context-aware errors via `OpenParserNifError` (lexutils getContext window)

import std/memfiles

import ./nif/ast
import ./nif/lexer
import ./nif/parser

export ast
export lexer
export parser

proc openReadOnly*(filename: string, allowRemap = false,
                   mapFlags = cint(-1)): MemFile {.inline.} =
  ## Convenience helper for read-only memory-mapped file opening.
  open(filename, mode = fmRead, allowRemap = allowRemap, mapFlags = mapFlags)

proc isMapped*(m: MemFile): bool {.inline.} =
  ## True when this MemFile currently has a valid mapped region.
  m.mem != nil and m.size > 0
