## Regex benchmark examples
In this folder we run benchmarks comparing OpenParser Regex against the Nim standard library `re` module (PCRE library).

#### Expectation vs reality
Note that OpenParser Regex is a pure Nim implementation Regex fully made with the chatbot, is not heavily optimized, and is not intended to be a production-ready regex engine. The benchmarks below are meant to demonstrate the capabilities of the built-in Regex (prefilters, pattern shape detection, SIMD acceleration).

Most important, we run these benchmarks to check that the OpenParser Regex engine is working correctly and producing the same matches as the PCRE-based `re` module. 

Performance is a secondary concern, and we expect the OpenParser Regex engine to be slower than the highly optimized PCRE library in many cases, especially for simple patterns where PCRE's JIT can shine.

```
./benchmark_regex example.h

Loaded : example.h
Size   : 15383424 bytes  (15.38 MB)  353149 lines

========================================================
  Identifier patterns
========================================================
  engine   : openregex
  pattern  : /[a-zA-Z_]\w*/
  shape    : psAlphaWordStar
  prefilter: pfAlpha
  input    : example.h
  matches  : 1207284
  cpu best : 54.422 ms  (282.7 MB/s)
  wall best: 54.442 ms

  engine   : stdlib
  pattern  : /[a-zA-Z_]\w*/
  shape    : n/a
  prefilter: n/a
  input    : example.h
  matches  : 1207284
  cpu best : 64.081 ms  (240.1 MB/s)
  wall best: 64.087 ms

  engine   : openregex
  pattern  : /[A-Z_][A-Z0-9_]{2,}/
  shape    : psUpperDigitUnder2Plus
  prefilter: pfAlpha
  input    : example.h
  matches  : 185100
  cpu best : 119.664 ms  (128.6 MB/s)
  wall best: 119.687 ms

  engine   : stdlib
  pattern  : /[A-Z_][A-Z0-9_]{2,}/
  shape    : n/a
  prefilter: n/a
  input    : example.h
  matches  : 185100
  cpu best : 25.299 ms  (608.1 MB/s)
  wall best: 25.326 ms


========================================================
  Type & declaration patterns
========================================================
  engine   : openregex
  pattern  : /typedef\s+\w+\s+\w+/
  shape    : psNone
  prefilter: pfLiteral
  input    : example.h
  matches  : 4164
  cpu best : 9.907 ms  (1552.8 MB/s)
  wall best: 9.909 ms

  engine   : stdlib
  pattern  : /typedef\s+\w+\s+\w+/
  shape    : n/a
  prefilter: n/a
  input    : example.h
  matches  : 4164
  cpu best : 6.220 ms  (2473.2 MB/s)
  wall best: 6.228 ms

  engine   : openregex
  pattern  : /struct\s+[a-zA-Z_]\w*/
  shape    : psNone
  prefilter: pfLiteral
  input    : example.h
  matches  : 14736
  cpu best : 15.309 ms  (1004.9 MB/s)
  wall best: 15.317 ms

  engine   : stdlib
  pattern  : /struct\s+[a-zA-Z_]\w*/
  shape    : n/a
  prefilter: n/a
  input    : example.h
  matches  : 14736
  cpu best : 7.978 ms  (1928.2 MB/s)
  wall best: 7.979 ms

  engine   : openregex
  pattern  : /enum\s+[a-zA-Z_]\w*/
  shape    : psNone
  prefilter: pfLiteral
  input    : example.h
  matches  : 4272
  cpu best : 10.733 ms  (1433.3 MB/s)
  wall best: 10.744 ms

  engine   : stdlib
  pattern  : /enum\s+[a-zA-Z_]\w*/
  shape    : n/a
  prefilter: n/a
  input    : example.h
  matches  : 4272
  cpu best : 9.283 ms  (1657.2 MB/s)
  wall best: 9.285 ms

  engine   : openregex
  pattern  : /(unsigned|signed)\s+\w+/
  shape    : psNone
  prefilter: pfLiteralAnchored
  input    : example.h
  matches  : 240
  cpu best : 5.177 ms  (2971.5 MB/s)
  wall best: 5.179 ms

  engine   : stdlib
  pattern  : /(unsigned|signed)\s+\w+/
  shape    : n/a
  prefilter: n/a
  input    : example.h
  matches  : 240
  cpu best : 8.074 ms  (1905.3 MB/s)
  wall best: 8.076 ms


========================================================
  Function signatures
========================================================
  engine   : openregex
  pattern  : /[a-zA-Z_]\w*\s*\([^)]*\)/
  shape    : psNone
  prefilter: pfInnerLiteral
  input    : example.h
  matches  : 184788
  cpu best : 125.459 ms  (122.6 MB/s)
  wall best: 125.478 ms

  engine   : stdlib
  pattern  : /[a-zA-Z_]\w*\s*\([^)]*\)/
  shape    : n/a
  prefilter: n/a
  input    : example.h
  matches  : 184788
  cpu best : 57.754 ms  (266.4 MB/s)
  wall best: 57.773 ms

  engine   : openregex
  pattern  : /\w+\s+\w+\s*\([^)]*\);/
  shape    : psNone
  prefilter: pfInnerLiteral
  input    : example.h
  matches  : 0
  cpu best : 73.595 ms  (209.0 MB/s)
  wall best: 73.625 ms

  engine   : stdlib
  pattern  : /\w+\s+\w+\s*\([^)]*\);/
  shape    : n/a
  prefilter: n/a
  input    : example.h
  matches  : 0
  cpu best : 16.292 ms  (944.2 MB/s)
  wall best: 16.330 ms


========================================================
  Preprocessor directives
========================================================
  engine   : openregex
  pattern  : /#define\s+\w+/
  shape    : psNone
  prefilter: pfLiteral
  input    : example.h
  matches  : 63372
  cpu best : 68.840 ms  (223.5 MB/s)
  wall best: 68.850 ms

  engine   : stdlib
  pattern  : /#define\s+\w+/
  shape    : n/a
  prefilter: n/a
  input    : example.h
  matches  : 63372
  cpu best : 11.651 ms  (1320.4 MB/s)
  wall best: 11.665 ms

  engine   : openregex
  pattern  : /"#include\s*[<\"][^>\"]+[>\"]"/
  shape    : psNone
  prefilter: pfLiteral
  input    : example.h
  matches  : 0
  cpu best : 0.870 ms  (17682.1 MB/s)
  wall best: 0.873 ms

  engine   : stdlib
  pattern  : /"#include\s*[<\"][^>\"]+[>\"]"/
  shape    : n/a
  prefilter: n/a
  input    : example.h
  matches  : 0
  cpu best : 5.108 ms  (3011.6 MB/s)
  wall best: 5.111 ms

  engine   : openregex
  pattern  : /#ifdef\s+\w+|#ifndef\s+\w+/
  shape    : psNone
  prefilter: pfLiteral
  input    : example.h
  matches  : 4440
  cpu best : 3.970 ms  (3874.9 MB/s)
  wall best: 3.972 ms

  engine   : stdlib
  pattern  : /#ifdef\s+\w+|#ifndef\s+\w+/
  shape    : n/a
  prefilter: n/a
  input    : example.h
  matches  : 4440
  cpu best : 8.121 ms  (1894.3 MB/s)
  wall best: 8.122 ms


========================================================
  Literals & constants
========================================================
  engine   : openregex
  pattern  : /0[xX][0-9a-fA-F]+/
  shape    : psNone
  prefilter: pfByte
  input    : example.h
  matches  : 40080
  cpu best : 8.315 ms  (1850.1 MB/s)
  wall best: 8.320 ms

  engine   : stdlib
  pattern  : /0[xX][0-9a-fA-F]+/
  shape    : n/a
  prefilter: n/a
  input    : example.h
  matches  : 40080
  cpu best : 2.795 ms  (5503.9 MB/s)
  wall best: 2.797 ms

  engine   : openregex
  pattern  : /\d+[uUlL]*/
  shape    : psNone
  prefilter: pfByteRange
  input    : example.h
  matches  : 198888
  cpu best : 23.502 ms  (654.6 MB/s)
  wall best: 23.505 ms

  engine   : stdlib
  pattern  : /\d+[uUlL]*/
  shape    : n/a
  prefilter: n/a
  input    : example.h
  matches  : 198888
  cpu best : 14.101 ms  (1090.9 MB/s)
  wall best: 14.105 ms

  engine   : openregex
  pattern  : /"[^"]*"/
  shape    : psNone
  prefilter: pfByte
  input    : example.h
  matches  : 3660
  cpu best : 1.101 ms  (13972.2 MB/s)
  wall best: 1.102 ms

  engine   : stdlib
  pattern  : /"[^"]*"/
  shape    : n/a
  prefilter: n/a
  input    : example.h
  matches  : 3660
  cpu best : 1.205 ms  (12766.3 MB/s)
  wall best: 1.206 ms


========================================================
  Comments
========================================================
  engine   : openregex
  pattern  : ///[^\n]*/
  shape    : psNone
  prefilter: pfLiteral
  input    : example.h
  matches  : 0
  cpu best : 1.146 ms  (13423.6 MB/s)
  wall best: 1.148 ms

  engine   : stdlib
  pattern  : ///[^\n]*/
  shape    : n/a
  prefilter: n/a
  input    : example.h
  matches  : 0
  cpu best : 1.280 ms  (12018.3 MB/s)
  wall best: 1.281 ms

  engine   : openregex
  pattern  : //\*[^*]*\*+([^/*][^*]*\*+)*//
  shape    : psNone
  prefilter: pfLiteral
  input    : example.h
  matches  : 0
  cpu best : 4.107 ms  (3745.7 MB/s)
  wall best: 4.119 ms

  engine   : stdlib
  pattern  : //\*[^*]*\*+([^/*][^*]*\*+)*//
  shape    : n/a
  prefilter: n/a
  input    : example.h
  matches  : 18792
  cpu best : 2.857 ms  (5384.5 MB/s)
  wall best: 2.864 ms


========================================================
  Pointer & reference patterns
========================================================
  engine   : openregex
  pattern  : /\w+\s*\*+\s*\w+/
  shape    : psNone
  prefilter: pfWordChar
  input    : example.h
  matches  : 134412
  cpu best : 3974.635 ms  (3.9 MB/s)
  wall best: 3980.111 ms

  engine   : stdlib
  pattern  : /\w+\s*\*+\s*\w+/
  shape    : n/a
  prefilter: n/a
  input    : example.h
  matches  : 134412
  cpu best : 20.705 ms  (743.0 MB/s)
  wall best: 20.751 ms

  engine   : openregex
  pattern  : /const\s+\w+\s*\*/
  shape    : psNone
  prefilter: pfLiteral
  input    : example.h
  matches  : 2268
  cpu best : 3.740 ms  (4113.2 MB/s)
  wall best: 3.748 ms

  engine   : stdlib
  pattern  : /const\s+\w+\s*\*/
  shape    : n/a
  prefilter: n/a
  input    : example.h
  matches  : 2268
  cpu best : 8.984 ms  (1712.3 MB/s)
  wall best: 9.032 ms


========================================================
  Anchored / worst-case patterns
========================================================
  engine   : openregex
  pattern  : /^#/
  shape    : psNone
  prefilter: pfAnchorStart
  input    : example.h
  matches  : 1
  cpu best : 0.001 ms  (15383424.0 MB/s)
  wall best: 0.002 ms

  engine   : stdlib
  pattern  : /^#/
  shape    : n/a
  prefilter: n/a
  input    : example.h
  matches  : 1
  cpu best : 0.001 ms  (15383424.0 MB/s)
  wall best: 0.001 ms

  engine   : openregex
  pattern  : /;\s*$/
  shape    : psNone
  prefilter: pfByte
  input    : example.h
  matches  : 0
  cpu best : 16.453 ms  (935.0 MB/s)
  wall best: 16.527 ms

  engine   : stdlib
  pattern  : /;\s*$/
  shape    : n/a
  prefilter: n/a
  input    : example.h
  matches  : 0
  cpu best : 2.325 ms  (6616.5 MB/s)
  wall best: 2.328 ms
```
