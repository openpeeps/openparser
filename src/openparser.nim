# Working with Nim's macros is just Voodoo
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/voodoo

when not defined(builddocs):
  {.error:"Import the specific parser you need".}
else:
  # For documentation purposes, we re-export all parsers here
  import ./openparser/[json, csv, rss, feed]
  export json, csv, rss, feed