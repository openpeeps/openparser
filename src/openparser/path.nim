# A collection of tiny parsers and dumpers
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/openparser

## This module implements a simple local and network path parser that can handle
## various URL schemes (http, https, ssh, git, ftp, sftp, mailto) as well as local filesystem paths

import std/[strutils, sequtils, options, tables]

type
  PathKind* = enum
    pkLocal       ## Local filesystem path
    pkWeb         ## HTTP/HTTPS URL
    pkSSH         ## SSH connection
    pkGit         ## Git repository URL
    pkFTP         ## FTP URL
    pkSFTP        ## SFTP URL
    pkMail        ## mailto: address
    pkUnknown     ## Unrecognized path

  AuthInfo* = object
    user*: string
    password*: Option[string]

  QueryParam* = tuple[key: string, value: string]

  Path* = object
    raw*: string
    kind*: PathKind
    case isLocal*: bool
    of true:
      drive*: Option[string]       ## Windows drive letter (e.g. "C")
      isAbsolute*: bool
      segments*: seq[string]
      localExt*: Option[string]
    of false:
      scheme*: string
      auth*: Option[AuthInfo]
      host*: string
      port*: Option[int]
      path*: string
      pathSegments*: seq[string]
      query*: seq[QueryParam]
      fragment*: Option[string]
      ext*: Option[string]

  OpenParserPathError* = object of CatchableError

# Helpers

proc extractExtension(segment: string): Option[string] =
  let dotPos = segment.rfind('.')
  if dotPos > 0 and dotPos < segment.len - 1:
    return some(segment[dotPos + 1 .. ^1])
  return none(string)

proc splitPathSegments(p: string): seq[string] =
  result = @[]
  for seg in p.split('/'):
    if seg.len > 0:
      result.add(seg)

proc parseQueryString(qs: string): seq[QueryParam] =
  result = @[]
  if qs.len == 0: return
  for pair in qs.split('&'):
    let eqPos = pair.find('=')
    if eqPos < 0:
      result.add((key: pair, value: ""))
    else:
      result.add((key: pair[0 ..< eqPos], value: pair[eqPos + 1 .. ^1]))

proc parseAuthority(authority: string): tuple[auth: Option[AuthInfo], host: string, port: Option[int]] =
  ## Parses [user[:password]@]host[:port]
  var remaining = authority
  var auth = none(AuthInfo)
  var port = none(int)

  # Extract user info
  let atPos = remaining.rfind('@')
  if atPos >= 0:
    let userInfo = remaining[0 ..< atPos]
    remaining = remaining[atPos + 1 .. ^1]
    let colonPos = userInfo.find(':')
    if colonPos >= 0:
      auth = some(AuthInfo(
        user: userInfo[0 ..< colonPos],
        password: some(userInfo[colonPos + 1 .. ^1])
      ))
    else:
      auth = some(AuthInfo(user: userInfo, password: none(string)))

  # Extract port (handle IPv6 brackets)
  if remaining.startsWith('['):
    # IPv6
    let closeBracket = remaining.find(']')
    if closeBracket >= 0:
      let host = remaining[1 ..< closeBracket]
      let afterBracket = remaining[closeBracket + 1 .. ^1]
      if afterBracket.startsWith(':'):
        try: port = some(parseInt(afterBracket[1 .. ^1]))
        except ValueError: discard
      return (auth, host, port)
  else:
    let colonPos = remaining.rfind(':')
    if colonPos >= 0:
      let portStr = remaining[colonPos + 1 .. ^1]
      try:
        port = some(parseInt(portStr))
        remaining = remaining[0 ..< colonPos]
      except ValueError:
        discard

  result = (auth, remaining, port)

proc detectKind*(scheme: string): PathKind =
  ## Detect path kind based on URL scheme.
  case scheme.toLowerAscii()
  of "http", "https":   pkWeb
  of "ssh":             pkSSH
  of "git", "git+ssh",
     "git+https",
     "git+http":        pkGit
  of "ftp":             pkFTP
  of "sftp":            pkSFTP
  of "mailto":          pkMail
  of "file":            pkLocal
  else:                 pkUnknown

proc parseLocalPath(raw: string): Path =
  result = Path(raw: raw, kind: pkLocal, isLocal: true)
  var p = raw

  # Normalize backslashes
  p = p.replace('\\', '/')

  # Windows drive letter
  if p.len >= 2 and p[1] == ':':
    result.drive = some($p[0])
    p = p[2 .. ^1]

  result.isAbsolute = p.startsWith('/')
  if result.isAbsolute:
    p = p[1 .. ^1]

  result.segments = splitPathSegments(p)

  if result.segments.len > 0:
    result.localExt = extractExtension(result.segments[^1])
  else:
    result.localExt = none(string)

proc parseNetworkPath(raw, scheme: string, kind: PathKind): Path =
  result = Path(raw: raw, kind: kind, isLocal: false)
  result.scheme = scheme

  var rest = raw[scheme.len + 1 .. ^1] # skip "scheme:"

  # mailto is special — no authority
  if kind == pkMail:
    result.host = rest
    result.path = ""
    result.fragment = none(string)
    result.ext = none(string)
    result.auth = none(AuthInfo)
    result.port = none(int)
    return

  # Strip leading "//"
  if rest.startsWith("//"):
    rest = rest[2 .. ^1]

  # Fragment
  let hashPos = rest.find('#')
  if hashPos >= 0:
    result.fragment = some(rest[hashPos + 1 .. ^1])
    rest = rest[0 ..< hashPos]
  else:
    result.fragment = none(string)

  # Query
  let qPos = rest.find('?')
  if qPos >= 0:
    result.query = parseQueryString(rest[qPos + 1 .. ^1])
    rest = rest[0 ..< qPos]

  # Authority vs path
  let slashPos = rest.find('/')
  var authority: string
  var pathPart: string
  if slashPos >= 0:
    authority = rest[0 ..< slashPos]
    pathPart = rest[slashPos .. ^1]
  else:
    authority = rest
    pathPart = ""

  let (auth, host, port) = parseAuthority(authority)
  result.auth = auth
  result.host = host
  result.port = port
  result.path = pathPart
  result.pathSegments = splitPathSegments(pathPart)

  if result.pathSegments.len > 0:
    result.ext = extractExtension(result.pathSegments[^1])
  else:
    result.ext = none(string)

# Main Entry Point

proc isWindowsPath(s: string): bool =
  s.len >= 2 and s[1] == ':' and s[0].isAlphaAscii()

proc isLocalPath(s: string): bool =
  s.startsWith('/') or s.startsWith("./") or
  s.startsWith("../") or s == "." or s == ".." or
  isWindowsPath(s) or (not s.contains("://") and not s.startsWith("mailto:"))

proc parsePath*(raw: string): Path =
  ## Parse any supported path or URL string into a `Path` object.
  if raw.len == 0:
    raise newException(OpenParserPathError, "Empty path string")

  let trimmed = raw.strip()

  # Check for scheme
  let colonPos = trimmed.find(':')
  if colonPos > 0 and not isWindowsPath(trimmed):
    let scheme = trimmed[0 ..< colonPos].toLowerAscii()
    let kind = detectKind(scheme)
    if kind != pkUnknown:
      return parseNetworkPath(trimmed, scheme, kind)

  # Fallback to local
  return parseLocalPath(trimmed)

proc `$`*(p: Path): string =
  ## Convert a `Path` object back to its string representation
  if p.isLocal:
    result = ""
    if p.drive.isSome:
      result &= p.drive.get() & ":"
    if p.isAbsolute:
      result &= "/"
    result &= p.segments.join("/")
  else:
    result = p.scheme & ":"
    if p.kind != pkMail:
      result &= "//"
    if p.auth.isSome:
      result &= p.auth.get().user
      if p.auth.get().password.isSome:
        result &= ":" & p.auth.get().password.get()
      result &= "@"
    result &= p.host
    if p.port.isSome:
      result &= ":" & $p.port.get()
    result &= p.path
    if p.query.len > 0:
      result &= "?" & p.query.mapIt(it.key & "=" & it.value).join("&")
    if p.fragment.isSome:
      result &= "#" & p.fragment.get()

when isMainModule:
  let url  = parsePath("https://user:pass@example.com:8080/path/to/file.html?q=1&page=2#section")
  let ssh  = parsePath("ssh://deploy@192.168.1.1:22/var/www")
  let git  = parsePath("git+ssh://git@github.com/user/repo.git")
  let mail = parsePath("mailto:hello@example.com")
  let loc  = parsePath("/home/user/docs/file.txt")
  let win  = parsePath("C:\\Users\\George\\file.nim")
