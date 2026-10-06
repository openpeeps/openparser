# A collection of tiny parsers and dumpers
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/openparser

## Read-only access to input bytes, independent of where they came from.
##
## The diff core must never learn whether it was handed a `string` or a
## memory-mapped file, or it stops being testable with literals. `ByteView`
## is that boundary: a raw pointer plus a length, mirroring the `data`/`len`
## pair `json.nim` already keeps alongside its owning `string`.
##
## A view is a borrowed reference. Keeping the bytes alive is the caller's
## job, and `FileView` exists to make that job easy by holding the `MemFile`
## open for as long as any view taken from it. Nim has no borrow checker
## here, so the ownership rule is stated once, here, and `diffFile` is the
## only entry point in the module that opens a file.
##
## Nothing is exposed as an `openArray[byte]`. That is a view type which Nim
## will not let a variable hold, so the kernels take a `ByteView` and offsets
## directly and read through the `[]` below. The result is one indirection
## fewer per byte than wrapping the pointer in an array view would cost.

import std/memfiles
import ./types

type
  FileView* = object
    ## Owns a memory mapping and hands out views into it. Released by
    ## `deinit`.
    ##
    ## The mapping stays open for the lifetime of this object on purpose: a
    ## `Diff` holds only offsets, but a `ByteView` the caller kept would
    ## otherwise be left dangling.
    path*: string
    mf: MemFile
    open: bool

proc view*(s: string): ByteView =
  ## View a string's bytes without copying them.
  ##
  ## `s` must stay alive for as long as the view is used. An empty string
  ## yields an empty view rather than a nil dereference.
  if s.len == 0:
    return ByteView(data: nil, len: 0)
  result.data = cast[ptr UncheckedArray[byte]](unsafeAddr s[0])
  result.len = s.len

proc view*(s: seq[byte]): ByteView =
  ## View a byte sequence's storage without copying it. Same ownership rule
  ## as the `string` overload.
  if s.len == 0:
    return ByteView(data: nil, len: 0)
  result.data = cast[ptr UncheckedArray[byte]](addr s[0])
  result.len = s.len

proc openFile*(path: string): FileView =
  ## Memory-map `path` read-only.
  ##
  ## A missing or unreadable file raises `IOError`, which is what `memfiles`
  ## raises. Deliberately not a `DiffError`: failing to open a file is not a
  ## malformed diff, and a caller already handles `IOError` everywhere else.
  result.mf = memfiles.open(path, fmRead)
  result.path = path
  result.open = true

proc deinit*(f: var FileView) =
  ## Unmap the file. Every `ByteView` taken from this object is dead after
  ## this call, so it must not run while one is still in use.
  if not f.open: return
  f.mf.close()
  f.open = false
  f.path = ""

proc view*(f: FileView): ByteView =
  ## View the mapped bytes. Empty for an unopened or empty file.
  if not f.open or f.mf.size == 0:
    return ByteView(data: nil, len: 0)
  result.data = cast[ptr UncheckedArray[byte]](f.mf.mem)
  result.len = f.mf.size