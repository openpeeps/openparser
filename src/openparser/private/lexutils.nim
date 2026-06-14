proc charAt*[T](l: T, idx: int): char {.inline.} =
  if idx < 0 or idx >= l.len: return '\0'
  when compiles(l.data):
    if l.data != nil: l.data[idx] else: l.input[idx]
  else:
    return l.input[idx]

proc advance*[T](l: var T) =
  ## Advances the lexer's position by one character,
  ## updating the current character and column.
  if l.pos < l.len - 1:
    inc l.pos
    l.current = l.charAt(l.pos)
    inc l.col
  else:
    l.pos = l.len
    l.current = '\0'

proc skipWhitespace*[T](l: var T) =
  ## A generic procedure to skip whitespace characters in a lexer.
  ## 
  ## It advances the lexer's position until it encounters a non-whitespace character
  while l.current in {' ', '\t', '\n', '\r'}:
    if l.current == '\n':
      inc l.line
      l.col = 0
    l.advance()

proc getContext*[T](l: T, posOverride: int = -1, maxContext: int = 80): string =
  ## Show a window around the error position, capped to `maxContext` chars on each side.
  ## Prevents dumping entire minified files on error.
  let rawPos = if posOverride >= 0: posOverride else: l.pos
  let atPos = max(0, min(rawPos, l.len))

  # Find line boundaries
  var lineStart = atPos
  while lineStart > 0 and l.charAt(lineStart - 1) != '\n':
    dec lineStart

  var lineEnd = atPos
  while lineEnd < l.len and l.charAt(lineEnd) notin {'\n', '\r'}:
    inc lineEnd

  # Cap the window around the error position
  let windowStart = max(lineStart, atPos - maxContext)
  let windowEnd = min(lineEnd, atPos + maxContext)

  var snippet: string
  if l.input.len > 0:
    snippet = l.input[windowStart ..< windowEnd]
  else:
    snippet = newStringOfCap(max(0, windowEnd - windowStart))
    for i in windowStart ..< windowEnd:
      snippet.add(l.charAt(i))

  let markerPos = max(0, min(snippet.len, atPos - windowStart))

  # Add ellipsis if we truncated
  var prefix = ""
  var suffix = ""
  if windowStart > lineStart:
    prefix = "... "
  if windowEnd < lineEnd:
    suffix = " ..."

  result = prefix & snippet & suffix & "\n" & " ".repeat(prefix.len + markerPos) & "^"

# proc error*[T](l: var T, msg: string) =
#   # Raise a lexer error
#   let context = getContext(l)
#   raise newException(OpenParserJsonError, ("\n" & context & "\n" & "Error ($1:$2) " % [$l.line, $l.col]) & msg)