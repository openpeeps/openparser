# A collection of tiny parsers and dumpers
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/openparser

when not defined(builddocs):
  {.error:"Import the specific parser you need".}
else:
  # For documentation purposes, we re-export all parsers here
  import ./openparser/[json, csv, rss, feed, yaml]
  export json, csv, rss, feed, yaml