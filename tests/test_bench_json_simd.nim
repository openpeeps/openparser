import std/[unittest, os, times, strformat]
import ../src/openparser/json

suite "JSON SIMD Benchmark":
  proc run(label: string, data: string, n: int) =
    when defined(openparserJsonNoSimd):
      echo "\n── ", label, " SIMD OFF ──"
    else:
      echo "\n── ", label, " SIMD ON ──"
    discard fromJson(data)
    let t0 = cpuTime()
    for _ in 0 ..< n:
      discard fromJson(data)
    let elapsed = cpuTime() - t0
    let avgUs = elapsed / n.float * 1e6
    let totalBytes = data.len * n
    let throughput = totalBytes.float / elapsed
    echo fmt"  {n} iterations in {elapsed:.3f}s"
    echo fmt"  Avg:    {avgUs:.1f}µs per parse"
    echo fmt"  Input:  {data.len} bytes"
    echo fmt"  Throughput: {throughput/1024/1024:.1f} MB/s"

  test "Small file (example.json)":
    run("example.json", readFile("tests/data/example.json"), 20000)

  test "Large file (large-file.json)":
    run("large-file.json", readFile("tests/data/large-file.json"), 3)

  test "fromJsonFile (MemFile)":
    when defined(openparserJsonNoSimd):
      echo "\n── fromJsonFile SIMD OFF ──"
    else:
      echo "\n── fromJsonFile SIMD ON ──"
    # single pass — no loop to avoid memory pile-up
    discard fromJsonFile("tests/data/large-file.json")
    let t0 = cpuTime()
    for _ in 0 ..< 3:
      discard fromJsonFile("tests/data/large-file.json")
    let elapsed = cpuTime() - t0
    let avgUs = elapsed / 3.0 * 1e6
    let totalBytes = 3 * 78424027
    let throughput = totalBytes.float / elapsed
    echo fmt"  3 iterations in {elapsed:.3f}s"
    echo fmt"  Avg:    {avgUs:.1f}µs per parse"
    echo fmt"  Throughput: {throughput/1024/1024:.1f} MB/s"
