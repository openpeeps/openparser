# A collection of tiny parsers and dumpers
#
# (c) 2026 George Lemon | MIT License

import std/[strutils, tables]
import ../css/[parser, ast]

proc parseStyleAttribute*(style: string): seq[tuple[property, value: string]] =
  # style="fill:red; stroke:none" -> parse as css declarations via wrapped ruleset
  let s = style.strip()
  if s.len == 0: return @[]
  # wrap as dummy ruleset to reuse css parser
  let cssSrc = "x{" & s & "}"
  try:
    let sheet = parseCss(cssSrc)
    for node in sheet.nodes:
      if node.kind == cssRuleSet:
        for decl in node.declarations:
          if decl.kind == cssDeclaration:
            result.add((decl.property, decl.rawValue))
  except:
    # fallback: simple split by ;
    for part in s.split(';'):
      let p = part.strip()
      if p.len == 0: continue
      let idx = p.find(':')
      if idx >= 0:
        result.add((p[0..<idx].strip(), p[idx+1..^1].strip()))

proc styleDeclsToString*(decls: seq[tuple[property, value: string]], minify: bool = false): string =
  var parts: seq[string] = @[]
  for (k,v) in decls:
    if minify:
      parts.add(k & ":" & v)
    else:
      parts.add(k & ": " & v)
  if minify:
    parts.join(";")
  else:
    parts.join("; ")
