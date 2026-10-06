# A collection of tiny parsers and dumpers
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/openparser

when defined(napibuild):
  # Node.js native addon entry point. Built separately via
  # `denim build src/openparser.nim --cmake -y` so the library itself
  # gains no denim dependency and zero overhead.
  import denim
  include ./openparser/private/napi_convert
  include ./openparser/private/napi_bridge

elif defined(nimbase_extension):
  import std/[strutils, macros, os]
  
  macro readNimbleFile() =
    let pkgNimble = staticRead(getProjectPath().parentDir / "openparser.nimble")
    result = newStmtList()
    for ln in pkgNimble.split:
      if ln.startsWith("version"):
        echo ln
        break

    echo result.repr

  when defined(php_build):
    import nimbase/kits/phpkit

    phpModule do:
      name = "openparser"
      version = "0.1.0"

      proc helloWorld(name: string) =
        ecoh "👋 Hey there", name, " 👑 Nim is Awesome!"

elif defined(builddocs):
  # For documentation purposes, we re-export all parsers here
  import ./openparser/[json, csv, rss, feed, yaml, dotenv,
                    fbe, toml, bson, xml, nif, ical, vcard, plist, css, svg,
                    diff]
  export json, csv, rss, feed, yaml, dotenv,
      fbe, toml, bson, xml, nif, ical, vcard, plist, css, svg, diff

  import ./openparser/gettext/[po, mo]
  export po, mo

  import ./openparser/regex/[lexer, prefilter, parser, compiler, vm]
  export lexer, prefilter, parser, compiler, vm
else:
  {.error:"Import the specific parser you need".}