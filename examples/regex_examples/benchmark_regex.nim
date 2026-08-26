import ../../src/openparser/regex/[lexer, parser, compiler, prefilter, vm]
import pkg/regex

import std/[times, strutils, strformat, os, memfiles, monotimes, re]


type
  EngineKind = enum
    openparser, stdlib, nitely

  BenchResult = object
    engine:    EngineKind
    pattern:   string
    inputDesc: string
    matches:   int
    cpuMs, wallMs, mbPerSec: float
    shapeName: string    ## for openparser; "n/a" for stdlib
    pfKindName: string   ## for openparser; "n/a" for stdlib

var allResults: seq[BenchResult]

proc bench(pattern, inputDesc, input: string; engine = EngineKind.openparser; runs = 1): BenchResult =
  result.pattern   = pattern
  result.inputDesc = inputDesc
  result.engine    = engine

  let inputMb  = input.len.float / 1_000_000.0
  var bestCpu  = high(float)
  var bestWall = initDuration(seconds = int.high)

  case engine
  of openparser:
    let prog = compile(pattern)
    result.shapeName  = $prog.shape
    result.pfKindName = $extractPrefilter(prog).kind

    var vm = initRegexVM(prog)
    discard vm.findAll(input)   # warmup

    for _ in 0 ..< runs:
      vm = initRegexVM(prog)

      let wallT0 = getMonoTime()
      let cpuT0  = cpuTime()
      let ms     = vm.findAll(input)
      let cpuT1  = cpuTime()
      let wallT1 = getMonoTime()

      let cpu  = (cpuT1 - cpuT0) * 1000.0   # seconds → ms
      let wall = wallT1 - wallT0

      if cpu < bestCpu:
        bestCpu      = cpu
        result.matches = ms.len
      if wall < bestWall:
        bestWall = wall

  of stdlib:
    result.shapeName  = "n/a"
    result.pfKindName = "n/a"

    let stdre = re.re(pattern)
    discard re.findAll(input, stdre)

    for _ in 0 ..< runs:
      let wallT0 = getMonoTime()
      let cpuT0  = cpuTime()
      let ms     = findAll(input, stdre)
      let cpuT1  = cpuTime()
      let wallT1 = getMonoTime()

      let cpu  = (cpuT1 - cpuT0) * 1000.0   # seconds → ms
      let wall = wallT1 - wallT0

      if cpu < bestCpu:
        bestCpu      = cpu
        result.matches = ms.len
      if wall < bestWall:
        bestWall = wall

  of nitely:
    result.shapeName  = "n/a"
    result.pfKindName = "n/a"

    let nre = re2(pattern)
    let ms0 = findAll(input, nre)
    discard ms0

    for _ in 0 ..< runs:
      let wallT0 = getMonoTime()
      let cpuT0  = cpuTime()
      let ms     = findAll(input, nre)
      let cpuT1  = cpuTime()
      let wallT1 = getMonoTime()

      let cpu  = (cpuT1 - cpuT0) * 1000.0
      let wall = wallT1 - wallT0

      if cpu < bestCpu:
        bestCpu      = cpu
        result.matches = ms.len
      if wall < bestWall:
        bestWall = wall

  result.cpuMs    = bestCpu
  result.wallMs   = bestWall.inMicroseconds.float / 1000.0
  result.mbPerSec = inputMb / (bestCpu / 1000.0)

  result.cpuMs    = bestCpu
  result.wallMs   = bestWall.inMicroseconds.float / 1000.0
  result.mbPerSec = inputMb / (bestCpu / 1000.0)

proc printResult(r: BenchResult) =
  echo &"  engine   : {r.engine}"
  echo &"  pattern  : /{r.pattern}/"
  echo &"  shape    : {r.shapeName}"
  echo &"  prefilter: {r.pfKindName}"
  echo &"  input    : {r.inputDesc}"
  echo &"  matches  : {r.matches}"
  echo &"  cpu best : {r.cpuMs:.3f} ms  ({r.mbPerSec:.1f} MB/s)"
  echo &"  wall best: {r.wallMs:.3f} ms"
  echo ""
  allResults.add(r)

proc printSummary() =
  echo "\n" & "=".repeat(90)
  echo "  SUMMARY"
  echo "=".repeat(90)
  echo ""
  echo "  Pattern" & " ".repeat(34) & "openparser        nitely       stdlib(PCRE)"
  echo "  " & "-".repeat(86)

  # Group results by pattern (3 results per pattern: openparser, nitely, stdlib)
  var i = 0
  while i < allResults.len:
    let pat = allResults[i].pattern
    var opMs, nlMs, stMs: float
    var opMbs, nlMbs, stMbs: float

    for j in i ..< min(i + 3, allResults.len):
      if allResults[j].pattern == pat:
        case allResults[j].engine
        of openparser:
          opMs = allResults[j].cpuMs
          opMbs = allResults[j].mbPerSec
        of nitely:
          nlMs = allResults[j].cpuMs
          nlMbs = allResults[j].mbPerSec
        of stdlib:
          stMs = allResults[j].cpuMs
          stMbs = allResults[j].mbPerSec

    let winnerMs = min(opMs, min(nlMs, stMs))
    let patShort = if pat.len > 36: pat[0 ..< 33] & "..." else: pat

    proc fmtCol(ms, mbs, winnerMs: float): string =
      let tag = if ms == winnerMs: "*" else: " "
      tag & $ms.formatFloat(ffDecimal, 1).alignLeft(7) & "ms " & $mbs.formatFloat(ffDecimal, 1).alignLeft(7) & "MB/s"

    echo "  " & patShort.alignLeft(38) & fmtCol(opMs, opMbs, winnerMs).alignLeft(26) &
         fmtCol(nlMs, nlMbs, winnerMs).alignLeft(26) & fmtCol(stMs, stMbs, winnerMs)
    i += 3

  echo ""
  echo "  * = fastest engine for this pattern"
  echo ""

proc section(title: string) =
  echo "\n" & "=".repeat(56)
  echo "  " & title
  echo "=".repeat(56)

# ---------------------------------------------------------------------------
# Load input
# ---------------------------------------------------------------------------

if paramCount() < 1:
  echo "Usage: bench <path/to/header.h>"
  quit(1)

let path = paramStr(1)
if not fileExists(path):
  echo "File not found: " & path
  quit(1)

var mf       = memfiles.open(path, fmRead)
let inputLen = int(mf.size)
var input    = newString(inputLen)
if inputLen > 0:
  copyMem(addr input[0], mf.mem, inputLen)
memfiles.close(mf)

let lineCount = input.count('\n') + 1
echo &"\nLoaded : {path}"
echo &"Size   : {inputLen} bytes  ({inputLen.float/1_000_000:.2f} MB)  {lineCount} lines"

# ---------------------------------------------------------------------------
# Benchmark suite — patterns tuned for C headers
# ---------------------------------------------------------------------------

section("Identifier patterns")
printResult bench(r"[a-zA-Z_]\w*",           path, input, openparser)
printResult bench(r"[a-zA-Z_]\w*",           path, input, nitely)
printResult bench(r"[a-zA-Z_]\w*",           path, input, stdlib)
printResult bench(r"[A-Z_][A-Z0-9_]{2,}",    path, input, openparser)  # macros / constants
printResult bench(r"[A-Z_][A-Z0-9_]{2,}",    path, input, nitely)
printResult bench(r"[A-Z_][A-Z0-9_]{2,}",    path, input, stdlib)

section("Type & declaration patterns")
printResult bench(r"typedef\s+\w+\s+\w+",    path, input, openparser)
printResult bench(r"typedef\s+\w+\s+\w+",    path, input, nitely)
printResult bench(r"typedef\s+\w+\s+\w+",    path, input, stdlib)
printResult bench(r"struct\s+[a-zA-Z_]\w*",  path, input, openparser)
printResult bench(r"struct\s+[a-zA-Z_]\w*",  path, input, nitely)
printResult bench(r"struct\s+[a-zA-Z_]\w*",  path, input, stdlib)
printResult bench(r"enum\s+[a-zA-Z_]\w*",    path, input, openparser)
printResult bench(r"enum\s+[a-zA-Z_]\w*",    path, input, nitely)
printResult bench(r"enum\s+[a-zA-Z_]\w*",    path, input, stdlib)
printResult bench(r"(unsigned|signed)\s+\w+", path, input, openparser)
printResult bench(r"(unsigned|signed)\s+\w+", path, input, nitely)
printResult bench(r"(unsigned|signed)\s+\w+", path, input, stdlib)

section("Function signatures")
printResult bench(r"[a-zA-Z_]\w*\s*\([^)]*\)", path, input, openparser)  # any call/decl
printResult bench(r"[a-zA-Z_]\w*\s*\([^)]*\)", path, input, nitely)
printResult bench(r"[a-zA-Z_]\w*\s*\([^)]*\)", path, input, stdlib)
printResult bench(r"\w+\s+\w+\s*\([^)]*\);",   path, input, openparser)  # forward decl
printResult bench(r"\w+\s+\w+\s*\([^)]*\);",   path, input, nitely)
printResult bench(r"\w+\s+\w+\s*\([^)]*\);",   path, input, stdlib)

section("Preprocessor directives")
printResult bench(r"#define\s+\w+",                    path, input, openparser)
printResult bench(r"#define\s+\w+",                    path, input, nitely)
printResult bench(r"#define\s+\w+",                    path, input, stdlib)
printResult bench("\"#include\\s*[<\\\"][^>\\\"]+[>\\\"]\"", path, input, openparser)
printResult bench("\"#include\\s*[<\\\"][^>\\\"]+[>\\\"]\"", path, input, nitely)
printResult bench("\"#include\\s*[<\\\"][^>\\\"]+[>\\\"]\"", path, input, stdlib)
printResult bench(r"#ifdef\s+\w+|#ifndef\s+\w+",       path, input, openparser)
printResult bench(r"#ifdef\s+\w+|#ifndef\s+\w+",       path, input, nitely)
printResult bench(r"#ifdef\s+\w+|#ifndef\s+\w+",       path, input, stdlib)

section("Literals & constants")
printResult bench(r"0[xX][0-9a-fA-F]+",   path, input, openparser)  # hex literals
printResult bench(r"0[xX][0-9a-fA-F]+",   path, input, nitely)
printResult bench(r"0[xX][0-9a-fA-F]+",   path, input, stdlib)
printResult bench(r"\d+[uUlL]*",          path, input, openparser)  # int literals
printResult bench(r"\d+[uUlL]*",          path, input, nitely)
printResult bench(r"\d+[uUlL]*",          path, input, stdlib)
printResult bench("\"[^\"]*\"",           path, input, openparser)  # string literals  ← regular string
printResult bench("\"[^\"]*\"",           path, input, nitely)
printResult bench("\"[^\"]*\"",           path, input, stdlib)

section("Comments")
printResult bench(r"//[^\n]*",               path, input, openparser)  # line comments
printResult bench(r"//[^\n]*",               path, input, nitely)
printResult bench(r"//[^\n]*",               path, input, stdlib)
printResult bench(r"/\*[^*]*\*+([^/*][^*]*\*+)*/", path, input, openparser)  # block comments
printResult bench(r"/\*[^*]*\*+([^/*][^*]*\*+)*/", path, input, nitely)
printResult bench(r"/\*[^*]*\*+([^/*][^*]*\*+)*/", path, input, stdlib)

section("Pointer & reference patterns")
printResult bench(r"\w+\s*\*+\s*\w+",        path, input, openparser)
printResult bench(r"\w+\s*\*+\s*\w+",        path, input, nitely)
printResult bench(r"\w+\s*\*+\s*\w+",        path, input, stdlib)
printResult bench(r"const\s+\w+\s*\*",       path, input, openparser)
printResult bench(r"const\s+\w+\s*\*",       path, input, nitely)
printResult bench(r"const\s+\w+\s*\*",       path, input, stdlib)

section("Anchored / worst-case patterns")
printResult bench(r"^#",                     path, input, openparser)  # lines starting with #
printResult bench(r"^#",                     path, input, nitely)
printResult bench(r"^#",                     path, input, stdlib)
printResult bench(r";\s*$",                  path, input, openparser)  # lines ending with ;
printResult bench(r";\s*$",                  path, input, nitely)
printResult bench(r";\s*$",                  path, input, stdlib)

printSummary()
