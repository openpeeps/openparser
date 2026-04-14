# A collection of tiny parsers and dumpers
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/openparser

import std/[memfiles, os]

## This module implements a high-performance CSV parser that operates directly on memory-mapped files,
## providing zero-copy field slices and a callback-based API for processing rows. It supports configurable
## delimiters, quote characters, and strict parsing modes.
## 
## The parser is designed for large CSV files (datasets, logs, etc) that may not fit into memory,
## making it a great choice for data processing tasks where performance is critical.
## 
## If speed is not necessary, you can tweak the parser `batchSize` and `batchDelayMs` options
## to maintain a lower CPU usage in long-running parses.

type
  CsvRowCallback* = proc(fields: openArray[CsvFieldSlice], row: int): bool {.closure.}
    ## Callback type for processing parsed CSV rows. `fields` is an open array of
    ## `CsvFieldSlice` representing the fields in the row, and `row` is the 1-based row number.
    ## The callback should return `true` to continue parsing or `false` to stop.

  CsvOptions* = object
    ## Configuration options for CSV parsing
    delimiter*: char = ','
      ## The character used to separate fields (default is comma).
    quote*: char = '"'
      ## The character used to quote fields that contain special characters (e.g. delimiter, newline).
    strict*: bool = true
      ## If `true`, the parser will raise errors for malformed CSV (e.g. unclosed quotes, unexpected characters after closing quotes).
      ## If `false`, the parser will attempt to recover from common CSV issues (e.g. ignore unexpected characters after closing quotes).
    batchDelayMs*: int
      ## Optional delay in milliseconds between batches when `batchSize` is set, allowing
      ## for cooperative multitasking in long-running parses.
    batchSize*: int = 10000
      ## Optional batching parameters for processing large files in chunks.

  CsvFieldSlice* = object
    ## Zero-copy CSV field view into mapped memory.
    data*: pointer
      ## Pointer to the start of the field data in the memory-mapped file. Valid only during callback execution.
    size*: int
      ## Length of the field data in bytes.
    quoted*: bool
      ## Whether the field was enclosed in quotes.
    escapedQuotes*: bool
      ## Whether the field contains escaped quotes (e.g. "" within a quoted field).
    quoteChar*: char
      ## The quote character used for this field (from options).

  CsvParseError* = object of CatchableError

proc defaultCsvOptions*(): CsvOptions {.inline.} =
  CsvOptions()

proc toString*(f: CsvFieldSlice): string =
  if f.size <= 0:
    return ""
  if not f.escapedQuotes:
    result = newString(f.size)
    copyMem(addr result[0], f.data, f.size)
    return

  let src = cast[ptr UncheckedArray[char]](f.data)
  result = newString(f.size)
  var i = 0
  var j = 0
  while i < f.size:
    let c = src[i]
    if c == f.quoteChar and i + 1 < f.size and src[i + 1] == f.quoteChar:
      result[j] = f.quoteChar
      inc j
      i += 2
    else:
      result[j] = c
      inc j
      inc i
  setLen(result, j)

proc `$`*(f: CsvFieldSlice): string {.inline.} =
  toString(f)

proc asChars*(mfile: MemFile): ptr UncheckedArray[char] {.inline.} =
  ## Fast raw char view over `mfile.mem` for pointer/index based parsers.
  cast[ptr UncheckedArray[char]](mfile.mem)


proc parseCsv*(mfile: MemFile, onRow: CsvRowCallback, options: CsvOptions = defaultCsvOptions()) =
  ## High-performance CSV parser over memory-mapped files.
  ## `fields` are valid only during callback execution (seq is reused).
  if onRow.isNil or mfile.mem == nil or mfile.size <= 0:
    return

  let data = mfile.asChars()
  let n = mfile.size

  # Hoist frequently used options out of hot loops.
  let delim = options.delimiter
  let quote = options.quote
  let strict = options.strict
  let hasBatch = options.batchDelayMs > 0 and options.batchSize > 0
  let batchDelayMs = options.batchDelayMs
  let batchSize = options.batchSize

  var i = 0
  var rowNo = 0
  var fields = newSeqOfCap[CsvFieldSlice](64)
  var batchCount = 0

  template fail(msg: string) =
    raise newException(CsvParseError, msg & " at byte offset " & $i)

  template pushField(start, stop: int, quoted, escaped: bool) =
    let idx = fields.len
    fields.setLen(idx + 1)
    fields[idx].data = (if stop > start: cast[pointer](unsafeAddr data[start]) else: nil)
    fields[idx].size = stop - start
    fields[idx].quoted = quoted
    fields[idx].escapedQuotes = escaped
    fields[idx].quoteChar = quote

  template emitRow() =
    inc rowNo
    if hasBatch:
      inc batchCount
    if not onRow(fields, rowNo):
      return
    if hasBatch and batchCount >= batchSize:
      sleep(batchDelayMs)
      batchCount = 0

  while i < n:
    fields.setLen(0)

    while true:
      var start = i
      var stop = i
      var quoted = false
      var escaped = false

      if i < n and data[i] == quote:
        quoted = true
        inc i
        start = i
        var closed = false
        while i < n:
          let c = data[i]
          if c == quote:
            if i + 1 < n and data[i + 1] == quote:
              escaped = true
              i += 2
            else:
              stop = i
              inc i
              closed = true
              break
          else:
            inc i

        if not closed:
          fail("Unclosed quoted field")

        if i < n:
          let c = data[i]
          if c != delim and c != '\n' and c != '\r':
            if strict:
              fail("Unexpected character after closing quote")
            while i < n and data[i] != delim and data[i] != '\n' and data[i] != '\r':
              inc i
      else:
        start = i
        while i < n:
          let c = data[i]
          if c == delim or c == '\n' or c == '\r':
            break
          inc i
        stop = i

      pushField(start, stop, quoted, escaped)

      if i >= n:
        emitRow()
        break

      let sep = data[i]
      if sep == delim:
        inc i
        continue

      if sep == '\r':
        inc i
        if i < n and data[i] == '\n':
          inc i
      elif sep == '\n':
        inc i

      emitRow()
      break

proc parseFile*(filename: string, onRow: CsvRowCallback,
                options: CsvOptions = defaultCsvOptions()) =
  ## Convenience wrapper to parse CSV files directly from disk.
  if unlikely(onRow.isNil): return

  if unlikely(not fileExists(filename)):
    raise newException(IOError, "CSV file not found: " & filename)

  let size = getFileSize(filename)
  if unlikely(size <= 0): return # empty file -> no rows

  if unlikely(size > BiggestInt(int.high)):
    raise newException(IOError,
      "CSV file is too large to map on this platform: " & filename)

  var mf = memfiles.open(filename, mode = fmRead, mappedSize = int(size))
  defer: mf.close()
  parseCsv(mf, onRow, options)
