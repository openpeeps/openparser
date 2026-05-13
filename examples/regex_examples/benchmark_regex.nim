import ../../src/openparser/regex/[lexer, parser, compiler, prefilter, vm]

import std/[times, strutils, strformat, os, memfiles, monotimes, re]


type
  EngineKind = enum
    openregex, stdlib

  BenchResult = object
    engine:    EngineKind
    pattern:   string
    inputDesc: string
    matches:   int
    cpuMs, wallMs, mbPerSec: float
    shapeName: string    ## for openregex; "n/a" for stdlib
    pfKindName: string   ## for openregex; "n/a" for stdlib

proc bench(pattern, inputDesc, input: string; engine = EngineKind.openregex; runs = 1): BenchResult =
  result.pattern   = pattern
  result.inputDesc = inputDesc
  result.engine    = engine

  let inputMb  = input.len.float / 1_000_000.0
  var bestCpu  = high(float)
  var bestWall = initDuration(seconds = int.high)

  if engine == openregex:
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

  else: # stdlib
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
printResult bench(r"[a-zA-Z_]\w*",           path, input, openregex)
printResult bench(r"[a-zA-Z_]\w*",           path, input, stdlib)
printResult bench(r"[A-Z_][A-Z0-9_]{2,}",    path, input, openregex)  # macros / constants
printResult bench(r"[A-Z_][A-Z0-9_]{2,}",    path, input, stdlib)

section("Type & declaration patterns")
printResult bench(r"typedef\s+\w+\s+\w+",    path, input, openregex)
printResult bench(r"typedef\s+\w+\s+\w+",    path, input, stdlib)
printResult bench(r"struct\s+[a-zA-Z_]\w*",  path, input, openregex)
printResult bench(r"struct\s+[a-zA-Z_]\w*",  path, input, stdlib)
printResult bench(r"enum\s+[a-zA-Z_]\w*",    path, input, openregex)
printResult bench(r"enum\s+[a-zA-Z_]\w*",    path, input, stdlib)
printResult bench(r"(unsigned|signed)\s+\w+", path, input, openregex)
printResult bench(r"(unsigned|signed)\s+\w+", path, input, stdlib)

section("Function signatures")
printResult bench(r"[a-zA-Z_]\w*\s*\([^)]*\)", path, input, openregex)  # any call/decl
printResult bench(r"[a-zA-Z_]\w*\s*\([^)]*\)", path, input, stdlib)
printResult bench(r"\w+\s+\w+\s*\([^)]*\);",   path, input, openregex)  # forward decl
printResult bench(r"\w+\s+\w+\s*\([^)]*\);",   path, input, stdlib)

section("Preprocessor directives")
printResult bench(r"#define\s+\w+",                    path, input, openregex)
printResult bench(r"#define\s+\w+",                    path, input, stdlib)
printResult bench("\"#include\\s*[<\\\"][^>\\\"]+[>\\\"]\"", path, input, openregex)
printResult bench("\"#include\\s*[<\\\"][^>\\\"]+[>\\\"]\"", path, input, stdlib)
printResult bench(r"#ifdef\s+\w+|#ifndef\s+\w+",       path, input, openregex)
printResult bench(r"#ifdef\s+\w+|#ifndef\s+\w+",       path, input, stdlib)

section("Literals & constants")
printResult bench(r"0[xX][0-9a-fA-F]+",   path, input, openregex)  # hex literals
printResult bench(r"0[xX][0-9a-fA-F]+",   path, input, stdlib)
printResult bench(r"\d+[uUlL]*",          path, input, openregex)  # int literals
printResult bench(r"\d+[uUlL]*",          path, input, stdlib)
printResult bench("\"[^\"]*\"",           path, input, openregex)  # string literals  ← regular string
printResult bench("\"[^\"]*\"",           path, input, stdlib)

section("Comments")
printResult bench(r"//[^\n]*",               path, input, openregex)  # line comments
printResult bench(r"//[^\n]*",               path, input, stdlib)
printResult bench(r"/\*[^*]*\*+([^/*][^*]*\*+)*/", path, input, openregex)  # block comments
printResult bench(r"/\*[^*]*\*+([^/*][^*]*\*+)*/", path, input, stdlib)

section("Pointer & reference patterns")
printResult bench(r"\w+\s*\*+\s*\w+",        path, input, openregex)
printResult bench(r"\w+\s*\*+\s*\w+",        path, input, stdlib)
printResult bench(r"const\s+\w+\s*\*",       path, input, openregex)
printResult bench(r"const\s+\w+\s*\*",       path, input, stdlib)

section("Anchored / worst-case patterns")
printResult bench(r"^#",                     path, input, openregex)  # lines starting with #
printResult bench(r"^#",                     path, input, stdlib)
printResult bench(r";\s*$",                  path, input, openregex)  # lines ending with ;
printResult bench(r";\s*$",                  path, input, stdlib)