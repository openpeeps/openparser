# A collection of tiny parsers and dumpers
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/openparser

when defined(napibuild):
  discard
elif defined(builddocs):
  # For documentation purposes, we re-export all parsers here
  import ./openparser/[json, csv, rss, feed, yaml, dotenv, fbe, toml, bson, xml, nif, ical]
  export json, csv, rss, feed, yaml, dotenv, fbe, toml, bson, xml, nif, ical

  import ./openparser/gettext/[po, mo]
  export po, mo

  import ./openparser/regex/[lexer, prefilter, parser, compiler, vm]
  export lexer, prefilter, parser, compiler, vm
else:
  {.error:"Import the specific parser you need".}