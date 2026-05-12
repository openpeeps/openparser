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
  engine   : datregex
  pattern  : /[a-zA-Z_]\w*/
  shape    : psAlphaWordStar
  prefilter: pfAlpha
  input    : example.h
  matches  : 1207284
  cpu best : 55.920 ms  (275.1 MB/s)
  wall best: 55.949 ms

  engine   : stdlib
  pattern  : /[a-zA-Z_]\w*/
  shape    : n/a
  prefilter: n/a
  input    : example.h
  matches  : 1207284
  cpu best : 64.942 ms  (236.9 MB/s)
  wall best: 64.952 ms

  engine   : datregex
  pattern  : /[A-Z_][A-Z0-9_]{2,}/
  shape    : psUpperDigitUnder2Plus
  prefilter: pfAlpha
  input    : example.h
  matches  : 185100
  cpu best : 120.257 ms  (127.9 MB/s)
  wall best: 120.293 ms

  engine   : stdlib
  pattern  : /[A-Z_][A-Z0-9_]{2,}/
  shape    : n/a
  prefilter: n/a
  input    : example.h
  matches  : 185100
  cpu best : 25.423 ms  (605.1 MB/s)
  wall best: 25.450 ms


========================================================
  Type & declaration patterns
========================================================
  engine   : datregex
  pattern  : /typedef\s+\w+\s+\w+/
  shape    : psNone
  prefilter: pfLiteral
  input    : example.h
  matches  : 4164
  cpu best : 9.930 ms  (1549.2 MB/s)
  wall best: 9.932 ms

  engine   : stdlib
  pattern  : /typedef\s+\w+\s+\w+/
  shape    : n/a
  prefilter: n/a
  input    : example.h
  matches  : 4164
  cpu best : 6.071 ms  (2533.9 MB/s)
  wall best: 6.076 ms

  engine   : datregex
  pattern  : /struct\s+[a-zA-Z_]\w*/
  shape    : psNone
  prefilter: pfLiteral
  input    : example.h
  matches  : 14736
  cpu best : 14.953 ms  (1028.8 MB/s)
  wall best: 14.956 ms

  engine   : stdlib
  pattern  : /struct\s+[a-zA-Z_]\w*/
  shape    : n/a
  prefilter: n/a
  input    : example.h
  matches  : 14736
  cpu best : 7.854 ms  (1958.7 MB/s)
  wall best: 7.859 ms

  engine   : datregex
  pattern  : /enum\s+[a-zA-Z_]\w*/
  shape    : psNone
  prefilter: pfLiteral
  input    : example.h
  matches  : 4272
  cpu best : 10.442 ms  (1473.2 MB/s)
  wall best: 10.444 ms

  engine   : stdlib
  pattern  : /enum\s+[a-zA-Z_]\w*/
  shape    : n/a
  prefilter: n/a
  input    : example.h
  matches  : 4272
  cpu best : 9.434 ms  (1630.6 MB/s)
  wall best: 9.446 ms

  engine   : datregex
  pattern  : /(unsigned|signed)\s+\w+/
  shape    : psNone
  prefilter: pfLiteralAnchored
  input    : example.h
  matches  : 240
  cpu best : 4.944 ms  (3111.5 MB/s)
  wall best: 4.945 ms

  engine   : stdlib
  pattern  : /(unsigned|signed)\s+\w+/
  shape    : n/a
  prefilter: n/a
  input    : example.h
  matches  : 240
  cpu best : 8.092 ms  (1901.1 MB/s)
  wall best: 8.094 ms


========================================================
  Function signatures
========================================================
  engine   : datregex
  pattern  : /[a-zA-Z_]\w*\s*\([^)]*\)/
  shape    : psNone
  prefilter: pfInnerLiteral
  input    : example.h
  matches  : 184788
  cpu best : 124.311 ms  (123.7 MB/s)
  wall best: 124.323 ms

  engine   : stdlib
  pattern  : /[a-zA-Z_]\w*\s*\([^)]*\)/
  shape    : n/a
  prefilter: n/a
  input    : example.h
  matches  : 184788
  cpu best : 57.449 ms  (267.8 MB/s)
  wall best: 57.458 ms

  engine   : datregex
  pattern  : /\w+\s+\w+\s*\([^)]*\);/
  shape    : psNone
  prefilter: pfInnerLiteral
  input    : example.h
  matches  : 0
  cpu best : 74.568 ms  (206.3 MB/s)
  wall best: 74.574 ms

  engine   : stdlib
  pattern  : /\w+\s+\w+\s*\([^)]*\);/
  shape    : n/a
  prefilter: n/a
  input    : example.h
  matches  : 0
  cpu best : 16.605 ms  (926.4 MB/s)
  wall best: 16.610 ms


========================================================
  Preprocessor directives
========================================================
  engine   : datregex
  pattern  : /#define\s+\w+/
  shape    : psNone
  prefilter: pfLiteral
  input    : example.h
  matches  : 63372
  cpu best : 67.313 ms  (228.5 MB/s)
  wall best: 67.317 ms

  engine   : stdlib
  pattern  : /#define\s+\w+/
  shape    : n/a
  prefilter: n/a
  input    : example.h
  matches  : 63372
  cpu best : 11.714 ms  (1313.3 MB/s)
  wall best: 11.727 ms

  engine   : datregex
  pattern  : /"#include\s*[<\"][^>\"]+[>\"]"/
  shape    : psNone
  prefilter: pfLiteral
  input    : example.h
  matches  : 0
  cpu best : 0.867 ms  (17743.3 MB/s)
  wall best: 0.869 ms

  engine   : stdlib
  pattern  : /"#include\s*[<\"][^>\"]+[>\"]"/
  shape    : n/a
  prefilter: n/a
  input    : example.h
  matches  : 0
  cpu best : 5.012 ms  (3069.3 MB/s)
  wall best: 5.013 ms

  engine   : datregex
  pattern  : /#ifdef\s+\w+|#ifndef\s+\w+/
  shape    : psNone
  prefilter: pfLiteral
  input    : example.h
  matches  : 4440
  cpu best : 3.926 ms  (3918.3 MB/s)
  wall best: 3.927 ms

  engine   : stdlib
  pattern  : /#ifdef\s+\w+|#ifndef\s+\w+/
  shape    : n/a
  prefilter: n/a
  input    : example.h
  matches  : 4440
  cpu best : 8.039 ms  (1913.6 MB/s)
  wall best: 8.041 ms


========================================================
  Literals & constants
========================================================
  engine   : datregex
  pattern  : /0[xX][0-9a-fA-F]+/
  shape    : psNone
  prefilter: pfByte
  input    : example.h
  matches  : 40080
  cpu best : 8.069 ms  (1906.5 MB/s)
  wall best: 8.071 ms

  engine   : stdlib
  pattern  : /0[xX][0-9a-fA-F]+/
  shape    : n/a
  prefilter: n/a
  input    : example.h
  matches  : 40080
  cpu best : 2.794 ms  (5505.9 MB/s)
  wall best: 2.796 ms

  engine   : datregex
  pattern  : /\d+[uUlL]*/
  shape    : psNone
  prefilter: pfByteRange
  input    : example.h
  matches  : 198888
  cpu best : 24.091 ms  (638.6 MB/s)
  wall best: 24.108 ms

  engine   : stdlib
  pattern  : /\d+[uUlL]*/
  shape    : n/a
  prefilter: n/a
  input    : example.h
  matches  : 198888
  cpu best : 13.825 ms  (1112.7 MB/s)
  wall best: 13.833 ms

  engine   : datregex
  pattern  : /"[^"]*"/
  shape    : psNone
  prefilter: pfByte
  input    : example.h
  matches  : 3660
  cpu best : 1.123 ms  (13698.5 MB/s)
  wall best: 1.125 ms

  engine   : stdlib
  pattern  : /"[^"]*"/
  shape    : n/a
  prefilter: n/a
  input    : example.h
  matches  : 3660
  cpu best : 1.187 ms  (12959.9 MB/s)
  wall best: 1.188 ms


========================================================
  Comments
========================================================
  engine   : datregex
  pattern  : ///[^\n]*/
  shape    : psNone
  prefilter: pfLiteral
  input    : example.h
  matches  : 0
  cpu best : 1.030 ms  (14935.4 MB/s)
  wall best: 1.032 ms

  engine   : stdlib
  pattern  : ///[^\n]*/
  shape    : n/a
  prefilter: n/a
  input    : example.h
  matches  : 0
  cpu best : 1.172 ms  (13125.8 MB/s)
  wall best: 1.174 ms

  engine   : datregex
  pattern  : //\*[^*]*\*+([^/*][^*]*\*+)*//
  shape    : psNone
  prefilter: pfLiteral
  input    : example.h
  matches  : 0
  cpu best : 3.904 ms  (3940.4 MB/s)
  wall best: 3.905 ms

  engine   : stdlib
  pattern  : //\*[^*]*\*+([^/*][^*]*\*+)*//
  shape    : n/a
  prefilter: n/a
  input    : example.h
  matches  : 18792
  cpu best : 2.807 ms  (5480.4 MB/s)
  wall best: 2.809 ms


========================================================
  Pointer & reference patterns
========================================================
  engine   : datregex
  pattern  : /\w+\s*\*+\s*\w+/
  shape    : psNone
  prefilter: pfWordChar
  input    : example.h
  matches  : 134412
  cpu best : 3980.012 ms  (3.9 MB/s)
  wall best: 3986.834 ms

  engine   : stdlib
  pattern  : /\w+\s*\*+\s*\w+/
  shape    : n/a
  prefilter: n/a
  input    : example.h
  matches  : 134412
  cpu best : 21.213 ms  (725.2 MB/s)
  wall best: 21.264 ms

  engine   : datregex
  pattern  : /const\s+\w+\s*\*/
  shape    : psNone
  prefilter: pfLiteral
  input    : example.h
  matches  : 2268
  cpu best : 3.364 ms  (4573.0 MB/s)
  wall best: 3.366 ms

  engine   : stdlib
  pattern  : /const\s+\w+\s*\*/
  shape    : n/a
  prefilter: n/a
  input    : example.h
  matches  : 2268
  cpu best : 8.935 ms  (1721.7 MB/s)
  wall best: 8.944 ms


========================================================
  Anchored / worst-case patterns
========================================================
  engine   : datregex
  pattern  : /^#/
  shape    : psNone
  prefilter: pfAnchorStart
  input    : example.h
  matches  : 1
  cpu best : 0.001 ms  (15383424.0 MB/s)
  wall best: 0.001 ms

  engine   : stdlib
  pattern  : /^#/
  shape    : n/a
  prefilter: n/a
  input    : example.h
  matches  : 1
  cpu best : 0.000 ms  (inf MB/s)
  wall best: 0.001 ms

  engine   : datregex
  pattern  : /;\s*$/
  shape    : psNone
  prefilter: pfByte
  input    : example.h
  matches  : 0
  cpu best : 15.954 ms  (964.2 MB/s)
  wall best: 15.963 ms

  engine   : stdlib
  pattern  : /;\s*$/
  shape    : n/a
  prefilter: n/a
  input    : example.h
  matches  : 0
  cpu best : 2.270 ms  (6776.8 MB/s)
  wall best: 2.272 ms
```
