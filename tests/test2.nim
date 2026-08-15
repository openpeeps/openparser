import std/[unittest, os, times, memfiles, sequtils, strutils]
import ../src/openparser/csv

# Examples
#
# Parse a CSV file from disk, row by row:
#   parseFile("./tests/data/example.csv",
#     proc(fields: openArray[CsvFieldSlice], row: int): bool =
#       for field in fields:
#         echo toString(field)
#       true   # return `false` to stop parsing early
#   )
#
# Parse with custom options (semicolon delimiter, single-quote char):
#   var opts = defaultCsvOptions()
#   opts.delimiter = ';'
#   opts.quote = '\''
#   parseFile("./tests/data/example.csv", onRow, opts)
#
# Parse a memory-mapped file directly:
#   var mf = memfiles.open("./tests/data/example.csv", mode = fmRead)
#   defer: mf.close()
#   parseCsv(mf, onRow)
#
# Inspect field metadata (quoted/escaped flags):
#   parseFile("./tests/data/example.csv",
#     proc(fields: openArray[CsvFieldSlice], row: int): bool =
#       for field in fields:
#         echo field.quoted, " ", field.escapedQuotes
#       true
#   )
#
# Zero-copy with a reused buffer: fields are views into the memory-mapped file,
# so aggregate data directly from the slices and reuse a fixed buffer per row.
# No `toString`, no per-row allocation:
#   var buffer: array[9, CsvFieldSlice]
#   parseFile("./tests/data/example.csv",
#     proc(fields: openArray[CsvFieldSlice], row: int): bool =
#       for i, f in fields:
#         buffer[i] = f              # reuse buffer, no new memory
#       totalPrep += parseSliceInt(buffer[3])
#       true
#   )

const
  exampleCsv* = "./tests/data/example.csv"
  expectedHeader = ["name", "ingredients", "diet", "prep_time", "cook_time",
                    "flavor_profile", "course", "state", "region"]

# Helpers -------------------------------------------------------------------

proc tmpCsv(content: string): string =
  ## Write `content` to a temp file and return its path.
  result = getTempDir() / "openparser_test2_" & $getCurrentProcessId() & ".csv"
  writeFile(result, content)

proc rowCount(filename: string, options: CsvOptions = defaultCsvOptions()): int =
  ## Number of rows parsed from `filename` (callback always continues).
  var count = 0
  parseFile(filename, proc(fields: openArray[CsvFieldSlice], row: int): bool =
    inc count
    true
  , options)
  result = count

proc collect(filename: string, options: CsvOptions = defaultCsvOptions()): tuple[rows: seq[seq[string]], rowNos: seq[int]] =
  ## Parse `filename`, collecting every row as a seq of decoded strings.
  var res: tuple[rows: seq[seq[string]], rowNos: seq[int]]
  parseFile(filename, proc(fields: openArray[CsvFieldSlice], row: int): bool =
    res.rows.add @[]
    for f in fields:
      res.rows[^1].add toString(f)
    res.rowNos.add row
    true
  , options)
  result = res

proc collectStr(content: string, options: CsvOptions = defaultCsvOptions()): tuple[rows: seq[seq[string]], rowNos: seq[int]] =
  ## Parse `content` written to a temp file, collecting every row.
  let tmp = tmpCsv(content)
  defer: removeFile(tmp)
  result = collect(tmp, options)

proc parseSliceInt(f: CsvFieldSlice): int =
  ## Zero-allocation integer parse directly from the mmap-backed slice.
  ## Unlike `parseInt(toString(f))`, this never allocates a string.
  if f.data == nil or f.size == 0:
    return 0
  let p = cast[ptr UncheckedArray[char]](f.data)
  var i = 0
  var neg = false
  if i < f.size and p[i] == '-':
    neg = true
    inc i
  while i < f.size and p[i] in {'0'..'9'}:
    result = result * 10 + (ord(p[i]) - ord('0'))
    inc i
  if neg:
    result = -result

suite "CSV parsing tests":
  # Benchmark-ish sanity test over the bundled example file
  test "CSV parsing with default options":
    var i = 0
    let t = cpuTime()
    parseFile(exampleCsv,
      proc(fields: openArray[CsvFieldSlice], row: int): bool =
        inc i
        true
    )
    let elapsed = cpuTime() - t
    echo "Parsed ", i, " rows in ", elapsed, " seconds"

  test "row and field counts on the bundled example":
    # 1 header row + 255 data rows, 9 columns each
    var rows = 0
    var fieldCount = -1
    parseFile(exampleCsv, proc(fields: openArray[CsvFieldSlice], row: int): bool =
      inc rows
      if fieldCount < 0: fieldCount = fields.len
      else: check fields.len == fieldCount
      true
    )
    check rows == 256
    check fieldCount == 9

  test "header row matches expected columns":
    let rows = collect(exampleCsv).rows
    check rows.len == 256
    for i in 0..<9:
      check rows[0][i] == expectedHeader[i]

  test "row numbers are 1-based and sequential":
    check collect(exampleCsv).rowNos == toSeq(1..256)

  test "quoted fields are decoded (commas inside quotes)":
    # Row 2: Balu shahi, "Maida flour, yogurt, oil, sugar", ...
    let rows = collect(exampleCsv).rows
    check rows[1][0] == "Balu shahi"
    check rows[1][1] == "Maida flour, yogurt, oil, sugar"
    check rows[1][4] == "25"
    check rows[1][7] == "West Bengal"

  test "fields keep quoted flag per column":
    var ingColQuoted = true
    var nameColQuoted = false
    parseFile(exampleCsv, proc(fields: openArray[CsvFieldSlice], row: int): bool =
      if row > 1: # skip header
        ingColQuoted = ingColQuoted and fields[1].quoted
        nameColQuoted = nameColQuoted or fields[0].quoted
      true
    )
    check ingColQuoted
    check not nameColQuoted

  test "parseCsv over a MemFile directly":
    var mf = memfiles.open(exampleCsv, mode = fmRead)
    defer: mf.close()
    var rows: seq[seq[string]]
    parseCsv(mf, proc(fields: openArray[CsvFieldSlice], row: int): bool =
      rows.add @[]
      for f in fields: rows[^1].add toString(f)
      true
    )
    check rows.len == 256
    check rows[0] == @expectedHeader
    check rows[1][1] == "Maida flour, yogurt, oil, sugar"

  test "callback can stop parsing early":
    var seen = 0
    parseFile(exampleCsv, proc(fields: openArray[CsvFieldSlice], row: int): bool =
      inc seen
      seen < 3 # stop after the third row
    )
    check seen == 3

  test "parseFile with missing file raises":
    expect IOError:
      discard rowCount("/definitely/not/here.csv")

  test "empty file produces no rows":
    let tmp = tmpCsv("")
    defer: removeFile(tmp)
    check rowCount(tmp) == 0

suite "CSV edge cases":
  test "custom delimiter (semicolon)":
    var opts = defaultCsvOptions()
    opts.delimiter = ';'
    let r = collectStr("a;b;c\n1;2;3", opts)
    check r.rows[0] == @["a", "b", "c"]
    check r.rows[1] == @["1", "2", "3"]

  test "custom delimiter (tab)":
    var opts = defaultCsvOptions()
    opts.delimiter = '\t'
    let r = collectStr("a\tb\tc\n1\t2\t3", opts)
    check r.rows[0] == @["a", "b", "c"]

  test "custom quote character":
    var opts = defaultCsvOptions()
    opts.quote = '\''
    let r = collectStr("a,'x,y',c\n", opts)
    check r.rows[0] == @["a", "x,y", "c"]

  test "quoted fields with embedded newline":
    let r = collectStr("name,note\nAlice,\"line one\nline two\"\n")
    check r.rows.len == 2
    check r.rows[1] == @["Alice", "line one\nline two"]

  test "escaped quotes inside quoted fields":
    let r = collectStr("quote,value\n\"say \"\"hi\"\"\",ok\n")
    check r.rows[1][0] == "say \"hi\""
    check r.rows[1][1] == "ok"

  test "quoted/escaped flags are reported":
    let tmp = tmpCsv("\"hello\",plain,\"a \"\"b\"\"\"\n")
    defer: removeFile(tmp)
    var flags: seq[tuple[quoted, escaped: bool]]
    parseFile(tmp, proc(fields: openArray[CsvFieldSlice], row: int): bool =
      for f in fields:
        flags.add (quoted: f.quoted, escaped: f.escapedQuotes)
      true
    )
    check flags == @[(quoted: true, escaped: false),
                     (quoted: false, escaped: false),
                     (quoted: true, escaped: true)]

  test "empty fields and trailing delimiter":
    let r = collectStr("a,,c\n,d,\n")
    check r.rows[0] == @["a", "", "c"]
    check r.rows[1] == @["", "d", ""]

  test "empty string fields in quotes":
    let r = collectStr("a,\"\",c\n")
    check r.rows[0] == @["a", "", "c"]

  test "CRLF line endings":
    let r = collectStr("a,b,c\r\n1,2,3\r\n4,5,6\r\n")
    check r.rows.len == 3
    check r.rows[1] == @["1", "2", "3"]
    check r.rows[2] == @["4", "5", "6"]

  test "trailing newline is not an extra row":
    check collectStr("a,b\n1,2\n").rows.len == 2

  test "no trailing newline":
    check collectStr("a,b\n1,2").rows.len == 2

  test "single column single row":
    let r = collectStr("hello")
    check r.rows == @[@["hello"]]

  test "single empty row":
    let r = collectStr("\n")
    check r.rows == @[@[""]]

suite "CSV strict/non-strict behavior":
  test "strict mode raises on unclosed quote":
    let tmp = tmpCsv("a,b\n\"unclosed,c\n")
    defer: removeFile(tmp)
    expect CsvParseError:
      discard rowCount(tmp)

  test "strict mode raises on characters after closing quote":
    let tmp = tmpCsv("\"a\"x,b\n")
    defer: removeFile(tmp)
    expect CsvParseError:
      discard rowCount(tmp)

  test "non-strict mode recovers from chars after closing quote":
    var opts = defaultCsvOptions()
    opts.strict = false
    let r = collectStr("\"a\"x,b\n", opts)
    # trailing junk is skipped, field keeps the quoted content
    check r.rows[0] == @["a", "b"]

  test "non-strict mode still raises on unclosed quote":
    var opts = defaultCsvOptions()
    opts.strict = false
    let tmp = tmpCsv("a,\"unclosed\n")
    defer: removeFile(tmp)
    expect CsvParseError:
      discard rowCount(tmp, opts)

  test "strict mode accepts escaped quotes":
    let r = collectStr("\"a \"\"b\"\" c\",d\n")
    check r.rows[0] == @["a \"b\" c", "d"]

  test "stringification of field slices":
    let tmp = tmpCsv("\"x,y\",plain\n")
    defer: removeFile(tmp)
    var output: string
    parseFile(tmp, proc(fields: openArray[CsvFieldSlice], row: int): bool =
      for f in fields:
        output.add $f & "|"
      true
    )
    check output == "x,y|plain|"

suite "CSV batch processing":
  test "batchSize/batchDelayMs keep row count correct":
    var opts = defaultCsvOptions()
    opts.batchSize = 2
    opts.batchDelayMs = 1
    check rowCount(exampleCsv, opts) == 256

  test "batching does not change field contents":
    var opts = defaultCsvOptions()
    opts.batchSize = 2
    opts.batchDelayMs = 1
    let r = collect(exampleCsv, opts)
    check r.rows.len == 256
    check r.rows[0] == @expectedHeader
    check r.rows[1][1] == "Maida flour, yogurt, oil, sugar"
    check r.rows[255][0] == "Pinaca"

suite "Zero-copy parsing":
  test "aggregate from slices with a reused buffer (no per-row allocations)":
    # Fields are views into the memory-mapped file. We sum numeric columns
    # directly from the slices, reusing a fixed buffer every row. No string
    # is ever allocated inside the callback, so heap stays flat.
    var buffer: seq[CsvFieldSlice] # reused for every row (grows only if a wider row shows up)
    var totalPrep = 0
    var totalCook = 0
    var dataRows = 0
    let heapBefore = getOccupiedMem()
    parseFile(exampleCsv, proc(fields: openArray[CsvFieldSlice], row: int): bool =
      if row == 1:
        return true # skip header row
      if buffer.len < fields.len:
        buffer.setLen(fields.len) # one-time growth, then fully reused
      for i, f in fields:
        buffer[i] = f # copy 16-byte slices only, no new memory
      # columns: name, ingredients, diet, prep_time, cook_time, ...
      totalPrep += parseSliceInt(buffer[3])
      totalCook += parseSliceInt(buffer[4])
      inc dataRows
      true
    )
    let heapAfter = getOccupiedMem()
    echo "Zero-copy: ", dataRows, " data rows, heap delta ",
         heapAfter - heapBefore, " bytes"

    check dataRows == 255
    check heapAfter - heapBefore <= 2048 # no meaningful allocations

  test "slice aggregation matches toString-based parsing":
    # Sanity check: the zero-copy path must produce identical numbers to the
    # toString() path, proving the slices point at the right bytes.
    var buffer: seq[CsvFieldSlice]
    var sliceSum = 0
    parseFile(exampleCsv, proc(fields: openArray[CsvFieldSlice], row: int): bool =
      if row > 1:
        if buffer.len < fields.len:
          buffer.setLen(fields.len)
        for i, f in fields:
          buffer[i] = f
        sliceSum += parseSliceInt(buffer[3]) + parseSliceInt(buffer[4])
      true
    )

    let rows = collect(exampleCsv).rows
    var strSum = 0
    for i in 1..<rows.len:
      strSum += parseInt(rows[i][3]) + parseInt(rows[i][4])

    check sliceSum == strSum
    echo "Zero-copy sum ", sliceSum, " == toString sum ", strSum

  when defined(testCsvLocal):
    # https://www.kaggle.com/datasets/stefanoleone992/tripadvisor-european-restaurants
    test "600MB tripadvisor CSV parses end-to-end with zero-copy":
      const huge = "./tests/data/tripadvisor_european_restaurants.csv"
      if fileExists(huge):
        var buffer: seq[CsvFieldSlice]
        var rows = 0
        var fieldCount = -1
        var totalReviews = 0 # total_reviews_count (col 28)
        var heapBefore = getOccupiedMem()
        let t = cpuTime()
        parseFile(huge, proc(fields: openArray[CsvFieldSlice], row: int): bool =
          inc rows
          if buffer.len < fields.len:
            buffer.setLen(fields.len)
          for i, f in fields:
            buffer[i] = f
          
          echo buffer # will print all lines, one by one!
          
          if fieldCount < 0: fieldCount = fields.len
          totalReviews += parseSliceInt(buffer[28])
          true
        )
        let elapsed = cpuTime() - t
        let heapDelta = getOccupiedMem() - heapBefore
        echo "Parsed ", huge, " (", getFileSize(huge) div (1024*1024),
            " MiB): ", rows, " rows, ", fieldCount, " columns, ",
            totalReviews, " total reviews, in ", elapsed, " seconds, ",
            "heap delta ", heapDelta, " bytes"

        check rows > 1_000_000
        check fieldCount == 42
        check totalReviews > 0
        check heapDelta <= 2048 # reused buffer => no per-row allocations
      else:
        echo "SKIP: ", huge, " not present"
