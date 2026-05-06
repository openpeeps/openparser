# A collection of tiny parsers and dumpers
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/openparser

## This module implements parsing and loading of `.env` files, supporting features like
## - variable expansion
## - command substitution
## - layered profiles (e.g. .env.local, .env.production)

import std/[strutils, os, envvars, tables, osproc]

type
  DotenvEntry* = tuple[key: string, value: string, expand: bool]
    ## A single entry from a .env file, with the key, raw value, and whether it should be expanded.
  MultiDotEnv* = TableRef[string, TableRef[string, DotenvEntry]]
    ## Keyed by env name: ".env.local" -> "local", ".env.production" -> "production".
    ## Each entry has key, value, and whether it should be expanded.
  
proc findClosingQuote(s: string; quote: char): int =
  if quote == '\'':
    return s.find('\'')
  var escaped = false
  for i, c in s:
    if c == '\\' and not escaped:
      escaped = true
      continue
    if c == '"' and not escaped:
      return i
    escaped = false
  -1

proc unescapeDoubleQuoted(s: string): string =
  result = newStringOfCap(s.len)
  var i = 0
  while i < s.len:
    if s[i] == '\\' and i + 1 < s.len:
      case s[i + 1]
      of 'n': result.add('\n')
      of 'r': result.add('\r')
      of 't': result.add('\t')
      of '"': result.add('"')
      of '\\': result.add('\\')
      of '$': result.add('$')
      else:
        result.add(s[i + 1])
      i += 2
    else:
      result.add(s[i])
      inc i

proc stripInlineCommentUnquoted(s: string): string =
  var i = 0
  while i < s.len:
    if s[i] == '#':
      if i == 0 or s[i - 1].isSpaceAscii:
        return s[0 ..< i].strip()
    if s[i] == '\\' and i + 1 < s.len:
      i += 2
    else:
      inc i
  s.strip()

proc parseEnv*(content: string): seq[DotenvEntry] =
  ## Parse .env file content into a sequence of entries.
  let lines = content.splitLines()
  var i = 0

  while i < lines.len:
    var line = lines[i].strip(leading = true, trailing = false)

    if line.len == 0 or line[0] == '#':
      inc i
      continue

    if line.startsWith("export "):
      line = line[7 .. ^1].strip(leading = true, trailing = false)

    let eq = line.find('=')
    if eq <= 0:
      inc i
      continue

    let key = line[0 ..< eq].strip()
    var rhs = line[eq + 1 .. ^1].strip(leading = true, trailing = false)

    if rhs.len == 0:
      result.add((key, "", true))
      inc i
      continue

    # Quoted value (can be multiline)
    if rhs[0] == '"' or rhs[0] == '\'':
      let q = rhs[0]
      var chunk = rhs[1 .. ^1]
      var value = ""
      var lineIdx = i

      while true:
        let closePos = findClosingQuote(chunk, q)
        if closePos >= 0:
          value.add(chunk[0 ..< closePos])
          break

          # If quote closed, ignore rest of that line (including comments)
        else:
          value.add(chunk)
          inc lineIdx
          if lineIdx >= lines.len:
            break
          value.add("\n")
          chunk = lines[lineIdx]

      if q == '"':
        value = unescapeDoubleQuoted(value)
        result.add((key, value, true))
      else:
        result.add((key, value, false)) # single quoted: no expansion

      i = lineIdx + 1
      continue

    # Unquoted value
    let raw = stripInlineCommentUnquoted(rhs)
    result.add((key, raw, true))
    inc i

proc resolveVar(name: string; local: Table[string, string]): string =
  if local.hasKey(name):
    return local[name]
  if existsEnv(name):
    return getEnv(name)
  ""

proc runCommandSub(cmd: string; cmdCache: var Table[string, string]): string =
  if cmdCache.hasKey(cmd):
    return cmdCache[cmd]

  try:
    let (outp, code) = execCmdEx(cmd, options = {poEvalCommand, poUsePath, poStdErrToStdOut})
    if code == 0:
      result = outp.strip(chars = {'\r', '\n'}, leading = false, trailing = true)
    else:
      result = ""
  except CatchableError:
    result = ""

  cmdCache[cmd] = result

proc expandValue*(value: string; local: var Table[string, string]; cmdCache: var Table[string, string]): string =
  ## Expand variables and command substitutions in the value string.
  result = newStringOfCap(value.len)
  var i = 0

  while i < value.len:
    if value[i] == '\\' and i + 1 < value.len and value[i + 1] == '$':
      result.add('$')
      i += 2
      continue

    if value[i] != '$':
      result.add(value[i])
      inc i
      continue

    if i + 1 >= value.len:
      result.add('$')
      inc i
      continue

    # ${VAR}
    if value[i + 1] == '{':
      var j = i + 2
      while j < value.len and value[j] != '}':
        inc j
      if j < value.len and value[j] == '}':
        let name = value[i + 2 ..< j]
        result.add(resolveVar(name, local))
        i = j + 1
      else:
        result.add('$')
        inc i
      continue

    # $(command)
    if value[i + 1] == '(':
      var depth = 1
      var j = i + 2
      while j < value.len and depth > 0:
        if value[j] == '(':
          inc depth
        elif value[j] == ')':
          dec depth
        inc j

      if depth == 0:
        let cmd = value[i + 2 ..< (j - 1)]
        result.add(runCommandSub(cmd, cmdCache))
        i = j
      else:
        result.add('$')
        inc i
      continue

    # $VAR
    var j = i + 1
    if j < value.len and (value[j].isAlphaAscii or value[j] == '_'):
      inc j
      while j < value.len and (value[j].isAlphaNumeric or value[j] == '_'):
        inc j
      let name = value[i + 1 ..< j]
      result.add(resolveVar(name, local))
      i = j
    else:
      result.add('$')
      inc i

proc envKeyFromPath(path: string): string =
  let name = extractFilename(path)
  if name == ".env":
    return "default"
  if name.startsWith(".env."):
    return name[5 .. ^1] # ".env.local" -> "local"
  name

proc resolveEntries(entries: seq[DotenvEntry]): Table[string, string] =
  result = initTable[string, string]()
  var local = initTable[string, string]()
  var cmdCache = initTable[string, string]()

  for e in entries:
    let finalValue =
      if e.expand: expandValue(e.value, local, cmdCache)
      else: e.value
    local[e.key] = finalValue
    result[e.key] = finalValue

proc loadDotenvFile*(path: string; override = false): Table[string, string] =
  ## Load one .env-like file into process env.
  ## Returns key/value pairs that were set (or resolved while loading).
  result = initTable[string, string]()
  if not fileExists(path):
    return

  let resolved = resolveEntries(parseEnv(readFile(path)))
  for k, v in resolved:
    if override or not existsEnv(k):
      putEnv(k, v)
      result[k] = v
    else:
      result[k] = getEnv(k)

proc loadDotenvFiles*(paths: openArray[string]; override = false): MultiDotEnv =
  ## Load multiple dotenv files into isolated profiles (no process-env mutation).
  ## Keyed by env name: ".env.local" -> "local", ".env.production" -> "production".
  result = newTable[string, TableRef[string, DotenvEntry]]()

  for p in paths:
    if not fileExists(p): continue
    let envKey = envKeyFromPath(p)
    if not result.hasKey(envKey):
      result[envKey] = newTable[string, DotenvEntry]()

    let resolved = resolveEntries(parseEnv(readFile(p)))
    for k, v in resolved:
      result[envKey][k] = (key: k, value: v, expand: false)

proc applyDotenvProfile*(profiles: MultiDotEnv; envName: string; override = false): Table[string, string] =
  ## Apply one loaded profile to process env.
  result = initTable[string, string]()
  if profiles.isNil or not profiles.hasKey(envName):
    return

  for k, entry in profiles[envName]:
    if override or not existsEnv(k):
      putEnv(k, entry.value)
      result[k] = entry.value
    else:
      result[k] = getEnv(k)

proc loadDotenvForEnv*(envName: string; override = false) =
  ## Apply selected layered files to process env.
  let files = [
    ".env",
    ".env.local",
    ".env." & envName,
    ".env." & envName & ".local"
  ]
  for f in files:
    discard loadDotenvFile(f, override = override)