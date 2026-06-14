# A collection of tiny parsers and dumpers
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/openparser

import ./css/[parser, ast]
export parser, ast

when isMainModule:
  let style = parseCss(readFile("sample.css"))
  echo style