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
[a-zA-Z_]\w*                          *52.0   ms 296.0  MB/s     1262.8 ms 12.2   MB/s     60.2   ms 255.6  MB/s
[A-Z_][A-Z0-9_]{2,}                    28.8   ms 533.4  MB/s     535.3  ms 28.7   MB/s    *24.4   ms 631.1  MB/s
typedef\s+\w+\s+\w+                    6.2    ms 2490.4 MB/s     22.7   ms 678.8  MB/s    *6.0    ms 2544.4 MB/s
struct\s+[a-zA-Z_]\w*                 *4.8    ms 3216.9 MB/s     39.6   ms 388.1  MB/s     7.5    ms 2045.7 MB/s
enum\s+[a-zA-Z_]\w*                   *8.2    ms 1875.1 MB/s     22.2   ms 692.1  MB/s     9.2    ms 1668.8 MB/s
(unsigned|signed)\s+\w+               *4.7    ms 3299.7 MB/s     554.1  ms 27.8   MB/s     8.2    ms 1874.4 MB/s
[a-zA-Z_]\w*\s*\([^)]*\)              *17.1   ms 901.0  MB/s     991.3  ms 15.5   MB/s     52.3   ms 294.2  MB/s
\w+\s+\w+\s*\([^)]*\);                *14.4   ms 1065.9 MB/s     411.5  ms 37.4   MB/s     16.7   ms 918.7  MB/s
#define\s+\w+                         *2.9    ms 5363.8 MB/s     167.7  ms 91.7   MB/s     9.5    ms 1625.8 MB/s
"#include\s*[<\"][^>\"]+[>\"]"        *0.9    ms 17992.3MB/s     7.6    ms 2024.1 MB/s     5.0    ms 3058.9 MB/s
#ifdef\s+\w+|#ifndef\s+\w+            *1.7    ms 8959.5 MB/s     420.3  ms 36.6   MB/s     8.1    ms 1910.0 MB/s
0[xX][0-9a-fA-F]+                     *2.0    ms 7511.4 MB/s     22.7   ms 677.0  MB/s     2.6    ms 5995.1 MB/s
\d+[uUlL]*                            *6.4    ms 2413.5 MB/s     348.3  ms 44.2   MB/s     13.8   ms 1116.1 MB/s
"[^"]*"                               *1.0    ms 15201.0MB/s     8.3    ms 1860.1 MB/s     1.0    ms 15201.0MB/s
//[^\n]*                               1.3    ms 11480.2MB/s     7.6    ms 2020.9 MB/s    *1.0    ms 14650.9MB/s
/\*[^*]*\*+([^/*][^*]*\*+)*/           2.6    ms 5842.5 MB/s     49.4   ms 311.4  MB/s    *2.1    ms 7364.0 MB/s
\w+\s*\*+\s*\w+                       *9.8    ms 1570.7 MB/s     766.4  ms 20.1   MB/s     18.5   ms 831.1  MB/s
const\s+\w+\s*\*                      *2.7    ms 5596.0 MB/s     11.2   ms 1378.6 MB/s     8.7    ms 1773.3 MB/s
^#                                     0.0    ms 3845856.0MB/s   5.1    ms 3033.6 MB/s    *0.0    ms 7691712.0MB/s
;\s*$                                 *2.2    ms 6976.6 MB/s     43.6   ms 352.9  MB/s     2.2    ms 6889.1 MB/s

* = fastest engine for this pattern
```
