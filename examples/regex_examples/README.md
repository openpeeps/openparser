## Regex benchmark examples

OpenParser's regex engine is SIMD-accelerated and JIT compiled to native x86-64 code via DynASM. For unsupported patterns (captures, epsilon-cycle loops) or when built with `-d:noRegexJit`, it falls back to a Pike-style NFA simulator with shape-based fast paths and bitmap character-class lookup. All paths produce PCRE-style (leftmost-first) match results.

Run with `clue build` (or `nimble`, `nim c`) (+ `-d:release` for benchmarks):

```
clue build examples/regex_examples/benchmark_regex.nim --release
./benchmark_regex example.h
```

Benchmarking the following regex engines:
- [openparser](https://github.com/openpeeps/openparser)
- [nitely's regex](https://github.com/nitely/nim-regex)
- [reni regex](https://github.com/fox0430/reni)
- [std/regex PCRE](https://nim-lang.org/docs/re.html)


```

  Pattern                                  openparser        nitely          reni            stdlib(PCRE)
  ----------------------------------------------------------------------------------------------------------------
  [a-zA-Z_]\w*                          *48.8   ms 315.3  MB/s     1267.9 ms 12.1   MB/s     162.1  ms 94.9   MB/s     55.6   ms 276.8  MB/s
  [A-Z_][A-Z0-9_]{2,}                    29.9   ms 514.8  MB/s     536.4  ms 28.7   MB/s     131.7  ms 116.8  MB/s    *24.7   ms 622.6  MB/s
  typedef\s+\w+\s+\w+                    6.3    ms 2429.5 MB/s     21.9   ms 703.7  MB/s     42.5   ms 362.1  MB/s    *5.8    ms 2635.1 MB/s
  struct\s+[a-zA-Z_]\w*                 *4.8    ms 3187.0 MB/s     39.2   ms 392.2  MB/s     29.2   ms 526.4  MB/s     7.6    ms 2034.0 MB/s
  enum\s+[a-zA-Z_]\w*                   *8.2    ms 1864.9 MB/s     23.2   ms 664.3  MB/s     62.1   ms 247.9  MB/s     9.1    ms 1690.5 MB/s
  (unsigned|signed)\s+\w+               *5.3    ms 2908.6 MB/s     555.7  ms 27.7   MB/s     62.5   ms 246.1  MB/s     8.1    ms 1903.9 MB/s
  [a-zA-Z_]\w*\s*\([^)]*\)              *17.0   ms 904.3  MB/s     977.6  ms 15.7   MB/s     103.1  ms 149.2  MB/s     52.3   ms 294.2  MB/s
  \w+\s+\w+\s*\([^)]*\);                *14.2   ms 1086.1 MB/s     406.6  ms 37.8   MB/s     46.6   ms 330.3  MB/s     16.5   ms 930.8  MB/s
  #define\s+\w+                         *2.8    ms 5591.9 MB/s     170.8  ms 90.1   MB/s     13.7   ms 1125.4 MB/s     9.6    ms 1602.1 MB/s
  "#include\s*[<\"][^>\"]+[>\"]"         0.8    ms 18489.7MB/s     7.4    ms 2091.0 MB/s    *0.7    ms 21913.7MB/s     5.0    ms 3055.3 MB/s
  #ifdef\s+\w+|#ifndef\s+\w+            *1.4    ms 11075.2MB/s     417.0  ms 36.9   MB/s     7.8    ms 1977.0 MB/s     7.9    ms 1937.5 MB/s
  0[xX][0-9a-fA-F]+                     *2.1    ms 7424.4 MB/s     23.1   ms 666.4  MB/s     7.4    ms 2091.3 MB/s     2.7    ms 5624.7 MB/s
  \d+[uUlL]*                            *6.5    ms 2372.5 MB/s     345.4  ms 44.5   MB/s     44.0   ms 349.8  MB/s     13.1   ms 1170.2 MB/s
  "[^"]*"                               *1.0    ms 15523.1MB/s     8.2    ms 1886.4 MB/s     1.2    ms 12426.0MB/s     1.0    ms 14877.6MB/s
  //[^\n]*                               1.3    ms 11636.5MB/s     7.5    ms 2044.9 MB/s     2.1    ms 7395.9 MB/s    *1.2    ms 12959.9MB/s
  /\*[^*]*\*+([^/*][^*]*\*+)*/           3.0    ms 5162.2 MB/s     50.1   ms 306.9  MB/s     7.1    ms 2160.9 MB/s    *2.1    ms 7239.3 MB/s
  \w+\s*\*+\s*\w+                       *10.1   ms 1526.9 MB/s     844.6  ms 18.2   MB/s     58.9   ms 261.3  MB/s     18.9   ms 813.9  MB/s
  const\s+\w+\s*\*                      *2.7    ms 5616.4 MB/s     11.2   ms 1377.7 MB/s     12.8   ms 1205.9 MB/s     8.8    ms 1756.1 MB/s
  ^#                                     0.0    ms 5127808.0MB/s   4.7    ms 3278.0 MB/s     8.5    ms 1808.3 MB/s    *0.0    ms 7691712.0MB/s
  ;\s*$                                 *2.2    ms 7050.1 MB/s     44.4   ms 346.2  MB/s     22.8   ms 674.5  MB/s     2.2    ms 6879.9 MB/s

  * = fastest engine for this pattern
```

Gist with full results: https://gist.github.com/georgelemon/94bf5d8a89a25252f6f3ce52458f1534