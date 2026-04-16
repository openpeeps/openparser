import std/[unittest, os, times]
import ../src/openparser/csv

suite "CSV parsing tests":
  test "CSV parsing with default options":
    var i = 0
    let t = cpuTime()
    parseFile("./tests/data/example.csv",
      proc(fields: openArray[CsvFieldSlice], row: int): bool =
        inc i
        true
    )
    let elapsed = cpuTime() - t
    echo "Parsed ", i, " rows in ", elapsed, " seconds"