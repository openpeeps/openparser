## Regex benchmark examples

OpenParser's regex engine is SIMD-accelerated and JIT compiled to native x86-64
code via DynASM. For unsupported patterns (captures, epsilon-cycle loops) or
when built with `-d:noRegexJit`, it falls back to a Pike-style NFA simulator
with shape-based fast paths and bitmap character-class lookup. All paths
produce PCRE-style (leftmost-first) match results.

Run with `clue build` (or `--release` for benchmarks):

```
clue build examples/regex_examples/benchmark_regex.nim --release
./benchmark_regex example.h
```

The benchmark compares openparser against
[nitely/regex](https://github.com/nitely/nim-regex) and the Nim stdlib
`re` module (PCRE). Input is `example.h`, a ~15 MB C header file.

```
Pattern                                  openparser        nitely       stdlib(PCRE)
--------------------------------------------------------------------------------------
[a-zA-Z_]\w*                           80.5   ms 191.2  MB/s     1367.4 ms 11.3   MB/s    *54.7   ms 281.4  MB/s
[A-Z_][A-Z0-9_]{2,}                    55.5   ms 277.3  MB/s     614.1  ms 25.1   MB/s    *24.8   ms 620.6  MB/s
typedef\s+\w+\s+\w+                    7.6    ms 2016.4 MB/s     26.3   ms 585.9  MB/s    *5.8    ms 2633.2 MB/s
struct\s+[a-zA-Z_]\w*                 *5.9    ms 2591.5 MB/s     45.8   ms 335.6  MB/s     7.6    ms 2034.3 MB/s
enum\s+[a-zA-Z_]\w*                    11.1   ms 1380.3 MB/s     26.5   ms 580.8  MB/s    *9.1    ms 1687.7 MB/s
(unsigned|signed)\s+\w+               *5.1    ms 3013.4 MB/s     612.8  ms 25.1   MB/s     8.4    ms 1833.1 MB/s
[a-zA-Z_]\w*\s*\([^)]*\)               186.7  ms 82.4   MB/s     1109.2 ms 13.9   MB/s    *55.6   ms 276.9  MB/s
\w+\s+\w+\s*\([^)]*\);                 402.6  ms 38.2   MB/s     432.2  ms 35.6   MB/s    *20.7   ms 744.8  MB/s
#define\s+\w+                         *5.8    ms 2634.6 MB/s     190.4  ms 80.8   MB/s     9.6    ms 1600.4 MB/s
"#include\s*[<\"][^>\"]+[>\"]"        *1.5    ms 10242.0MB/s     12.8   ms 1206.4 MB/s     5.0    ms 3049.2 MB/s
#ifdef\s+\w+|#ifndef\s+\w+             54.0   ms 284.9  MB/s     450.7  ms 34.1   MB/s    *8.0    ms 1921.2 MB/s
0[xX][0-9a-fA-F]+                     *1.9    ms 8058.4 MB/s     24.8   ms 619.7  MB/s     2.7    ms 5735.8 MB/s
\d+[uUlL]*                             45.2   ms 340.5  MB/s     726.1  ms 21.2   MB/s    *13.6   ms 1131.9 MB/s
"[^"]*"                               *1.1    ms 14581.4MB/s     9.0    ms 1704.9 MB/s     1.2    ms 12346.2MB/s
//[^\n]*                              *1.1    ms 13458.8MB/s     11.5   ms 1333.1 MB/s     1.4    ms 10690.4MB/s
/\*[^*]*\*+([^/*][^*]*\*+)*/           2.6    ms 5903.1 MB/s     56.7   ms 271.5  MB/s    *2.4    ms 6281.5 MB/s
\w+\s*\*+\s*\w+                        416.9  ms 36.9   MB/s     833.9  ms 18.4   MB/s    *18.4   ms 835.2  MB/s
const\s+\w+\s*\*                      *3.3    ms 4674.4 MB/s     15.4   ms 998.5  MB/s     8.6    ms 1797.3 MB/s
^#                                     0.0    ms 7691712.0MB/s   5.1    ms 3009.9 MB/s    *0.0    ms 15383424.0MB/s
;\s*$                                  2.5    ms 6243.3 MB/s     45.8   ms 335.7  MB/s    *2.3    ms 6744.2 MB/s

* = fastest engine for this pattern
```
