--define:release
# AVX2 is x86-64 only: clang rejects -mavx2 for arm64-apple targets.
when defined(amd64):
  --define:avx2
  --passC:"-mavx2"
  --passL:"-mavx2"