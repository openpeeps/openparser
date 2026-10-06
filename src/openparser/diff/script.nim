# A collection of tiny parsers and dumpers
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/openparser

## The edit script vocabulary every algorithm in this module produces.
##
## Kept apart from `myers.nim` so the anchoring passes can build and splice
## scripts without importing the search itself, and so the shape of a diff is
## stated exactly once.

import ./types

type
  LineOpKind* = enum
    opEqual, opDelete, opInsert
    ## Mirrors `DiffLineKind`. Kept distinct until `ops.nim` fuses a script
    ## into `DiffLine`s, so no stage has to guess at a conversion.

  LineOp* = object
    ## One step of an edit script, as line indices into each side.
    ##
    ## A consumed line always carries its index. The side a step does not
    ## consume is -1, which is exactly how a consumer tells a one-sided step
    ## from a matched pair without consulting `kind`.
    kind*: LineOpKind
    aIdx*: int
    bIdx*: int

proc equalOp*(aIdx, bIdx: int): LineOp {.inline.} =
  LineOp(kind: opEqual, aIdx: aIdx, bIdx: bIdx)

proc deleteOp*(aIdx: int): LineOp {.inline.} =
  LineOp(kind: opDelete, aIdx: aIdx, bIdx: -1)

proc insertOp*(bIdx: int): LineOp {.inline.} =
  LineOp(kind: opInsert, aIdx: -1, bIdx: bIdx)

proc isEqual*(op: LineOp): bool {.inline.} = op.kind == opEqual

proc kindOf*(op: LineOp): DiffLineKind {.inline.} =
  case op.kind
  of opEqual: dlEqual
  of opDelete: dlDelete
  of opInsert: dlInsert