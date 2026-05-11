# A collection of tiny parsers and dumpers
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/openparser

## Prefilter: static analysis of a Program to extract a cheap "first-byte hint"
## that lets the VM skip impossible start positions.

import ./compiler, ./simd

type
  PrefilterKind* = enum
    pfNone
    pfByte
    pfByteRange
    pfAnyOf2
    pfAnchorStart
    pfAlpha          ## [a-zA-Z_]
    pfWordChar       ## [a-zA-Z0-9_]
    pfUpperAlpha     ## [A-Z_]  — macro/constant start

  Prefilter* = object
    case kind*: PrefilterKind
    of pfByte:      byte1*: char
    of pfByteRange: lo*, hi*: char
    of pfAnyOf2:    alt1*, alt2*: char
    of pfAnchorStart, pfNone, pfAlpha, pfWordChar, pfUpperAlpha: discard
    shape*: PatternShape

proc extractPrefilter*(prog: Program): Prefilter =
  ## Walk the first instruction(s) of the program and derive the cheapest
  ## possible prefilter.  We resolve Splits one level deep.
  if prog.instrs.len == 0:
    return Prefilter(kind: pfNone, shape: psNone)

  let shape = prog.shape   ## set by compiler — always correct

  proc firstConsuming(prog: Program, pc: int,
                      depth = 0): tuple[op: OpCode, arg1: int] =
    if depth > 64 or pc < 0 or pc >= prog.instrs.len:
      return (opMatch, 0)
    let ins = prog.instrs[pc]
    case ins.op
    of opJmp:                return firstConsuming(prog, ins.arg1, depth+1)
    of opSplit, opSplitLazy: return firstConsuming(prog, ins.arg1, depth+1)
    of opSave, opProgress:   return firstConsuming(prog, pc+1,    depth+1)
    of opAnchorStart:        return (opAnchorStart, 0)
    else:                    return (ins.op, ins.arg1)

  let (op, arg1) = firstConsuming(prog, 0)

  template make(k: PrefilterKind): Prefilter =
    Prefilter(kind: k, shape: shape)

  case op
  of opAnchorStart:
    return make(pfAnchorStart)
  of opChar:
    let ins0 = prog.instrs[0]
    if ins0.op in {opSplit, opSplitLazy} and ins0.arg2 >= 0:
      let (op2, arg2) = firstConsuming(prog, ins0.arg2)
      if op2 == opChar:
        return Prefilter(kind: pfAnyOf2, alt1: char(arg1), alt2: char(arg2),
                         shape: shape)
    return Prefilter(kind: pfByte, byte1: char(arg1), shape: shape)
  of opCharClass:
    let cls = prog.classes[arg1]
    if not cls.negated:
      var hasLo, hasUp, hasUs, hasDi: bool
      var other = 0
      for it in cls.items:
        if it.isRange:
          if   it.lo=='a' and it.hi=='z': hasLo = true
          elif it.lo=='A' and it.hi=='Z': hasUp = true
          elif it.lo=='0' and it.hi=='9': hasDi = true
          else: inc other
        else:
          if it.ch == '_': hasUs = true
          else: inc other
      if other == 0:
        if hasLo and hasUp and hasUs and hasDi: return make(pfWordChar)
        if hasLo and hasUp and hasUs:           return make(pfAlpha)
        if hasUp and hasUs and not hasLo:       return make(pfUpperAlpha)  ## [A-Z_]
      if cls.items.len == 1 and cls.items[0].isRange:
        return Prefilter(kind: pfByteRange,
                         lo: cls.items[0].lo, hi: cls.items[0].hi, shape: shape)
    return make(pfNone)
  of opEscapeClass:
    case char(arg1)
    of 'd': return Prefilter(kind: pfByteRange, lo: '0', hi: '9', shape: shape)
    of 'w': return make(pfWordChar)
    of 's': return Prefilter(kind: pfAnyOf2, alt1: ' ', alt2: '\t', shape: shape)
    else:   return make(pfNone)
  else:
    return make(pfNone)

proc nextCandidate*(pf: Prefilter, input: string,
                    pos, inputLen: int): int {.inline.} =
  case pf.kind
  of pfNone:        pos
  of pfAnchorStart:
    if pos == 0: 0 else: inputLen + 1
  of pfByte:
    let r = scanByte(input, pos, inputLen, pf.byte1)
    if r < 0: inputLen + 1 else: r
  of pfByteRange:
    let r = scanByteRange(input, pos, inputLen, pf.lo, pf.hi)
    if r < 0: inputLen + 1 else: r
  of pfAnyOf2:
    let r = scanAnyOf(input, pos, inputLen, pf.alt1, pf.alt2)
    if r < 0: inputLen + 1 else: r
  of pfAlpha:
    let r = scanAlphaUnderscore(input, pos, inputLen)
    if r < 0: inputLen + 1 else: r
  of pfWordChar:
    let r = scanWordChar(input, pos, inputLen)
    if r < 0: inputLen + 1 else: r
  of pfUpperAlpha:
    let r = scanUpperDigitUnder(input, pos, inputLen)   ## [A-Z0-9_] ⊇ [A-Z_]
    if r < 0: inputLen + 1 else: r