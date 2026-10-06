# Parity against real `git diff` shells out and writes files, so it stays
# opt-in: plain `clue test` compiles this without `-d:diffParity` and every
# body is skipped. Run it explicitly with `clue test test_diff_parity`.
--define:diffParity
