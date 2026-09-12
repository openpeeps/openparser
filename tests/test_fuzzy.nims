--define:release
# AVX2 is x86-64 only: clang rejects -mavx2 for arm64-apple targets.
# The fuzzy module compiles NEON lanes on arm64 with no extra C flag.
when defined(amd64):
  --define:avx2
  --passC:"-mavx2"
  --passL:"-mavx2"
