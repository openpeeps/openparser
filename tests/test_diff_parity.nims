# Parity against real `git diff` shells out and writes files, so it stays
# opt-in: plain `clue test` compiles this without `-d:diffParity` and every
# body is skipped. Run it explicitly with `clue test test_diff_parity`.
#
# The define stays off on Windows: runGit() shells out with POSIX-only
# redirection (`2>/dev/null`), which hangs the Windows leg instead of
# failing. Bodies skip there via `enabled()`.
when not defined(windows):
  --define:diffParity
