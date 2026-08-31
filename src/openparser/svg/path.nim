# A collection of tiny parsers and dumpers
#
# (c) 2026 George Lemon | MIT License

import std/[strutils, math]
import ./ast

proc isCmd(c: char): bool = c in {'M','m','L','l','H','h','V','v','C','c','S','s','Q','q','T','t','A','a','Z','z'}

proc argsNeeded(cmd: char): int =
  case cmd
  of 'M','m','L','l','T','t': 2
  of 'H','h','V','v': 1
  of 'C','c': 6
  of 'S','s','Q','q': 4
  of 'A','a': 7
  of 'Z','z': 0
  else: 0

proc parsePathData*(d: string): seq[SvgPathSeg] =
  result = @[]
  var i = 0
  let s = d.strip()
  var curCmd: char = '\0'
  proc skipSep() =
    while i < s.len and s[i] in {' ', '\t', '\n', '\r', ','}: inc i
  while i < s.len:
    skipSep()
    if i >= s.len: break
    if isCmd(s[i]):
      curCmd = s[i]
      inc i
      if curCmd in {'Z','z'}:
        result.add(SvgPathSeg(cmd: curCmd, args: @[]))
        curCmd = '\0'
        continue
    elif curCmd == '\0':
      # expected command
      inc i
      continue
    let need = argsNeeded(curCmd)
    if need == 0:
      continue
    var args: seq[float] = @[]
    # collect numbers until next cmd or enough for one segment, then flush
    var first = true
    while true:
      skipSep()
      if i >= s.len: break
      if isCmd(s[i]): break
      # parse number
      var start = i
      if s[i] in {'-','+'}: inc i
      var hasDot = false
      var hasExp = false
      while i < s.len:
        let ch = s[i]
        if ch in {'0'..'9'}: inc i
        elif ch == '.' and not hasDot: hasDot = true; inc i
        elif ch in {'e','E'} and not hasExp:
          hasExp = true; inc i
          if i < s.len and s[i] in {'-','+'}: inc i
        else: break
      if i == start:
        inc i
        continue
      let numStr = s[start..<i]
      try:
        args.add(parseFloat(numStr))
      except:
        discard
      if args.len == need:
        result.add(SvgPathSeg(cmd: curCmd, args: args))
        args = @[]
        # for M, subsequent pairs become L
        if curCmd == 'M': curCmd = 'L'
        elif curCmd == 'm':
          curCmd = 'l'
        # continue to see if more numbers without new cmd
        # need to peek if next is number -> another segment of same cmd
        var peek = i
        while peek < s.len and s[peek] in {' ', '\t', '\n', '\r', ','}: inc peek
        if peek < s.len and not isCmd(s[peek]):
          # continue loop to collect next segment
          discard
        else:
          break
      # if we have less than need, continue collecting
    if args.len > 0 and args.len < need:
      # incomplete trailing args ignore
      discard

proc pathSegToString*(seg: SvgPathSeg, minify: bool = false): string =
  if seg.cmd in {'Z','z'}: return $seg.cmd
  var parts: seq[string] = @[]
  for v in seg.args:
    let isInt = abs(v - round(v)) < 1e-9
    let s = if isInt: $int(round(v)) else: formatFloat(v, ffDecimal, 6).strip(chars={'0'}, trailing=true).strip(chars={'.'}, trailing=true)
    parts.add(s)
  let sep = if minify: " " else: " "
  # For minify we could remove space before negative, but keep simple
  $seg.cmd & parts.join(sep)

proc pathDataToString*(segs: seq[SvgPathSeg], minify: bool = false): string =
  var parts: seq[string] = @[]
  for s in segs:
    parts.add(pathSegToString(s, minify))
  if minify:
    # join with space, but cmd already includes compact
    result = parts.join(" ")
  else:
    result = parts.join(" ")
