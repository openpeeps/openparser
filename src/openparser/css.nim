import ./css/[parser, ast]
export parser, ast

when isMainModule:
  let style = parseCss(readFile("sample.css"))
  echo style