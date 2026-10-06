# A collection of tiny parsers and dumpers
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/openparser

## Byte-level changes inside a line that the line-level pass already reported
## as changed.
##
## This is what lets a UI underline the word that moved instead of the whole
## line, and it is opt-in because it is the only part of the module whose cost
## scales with bytes rather than lines.
##
## The shape of the work: for a deleted line paired with an inserted line, trim
## the common prefix and suffix, then report what is left over. Trimming first
## is what keeps this cheap in the common case where a short token changed
## inside a long line, since the leftovers are then only as long as the change
## itself. Lines longer than `DiffOptions.maxSpanBytes` are skipped outright
## and stay whole-line changes, which is the right answer for minified or
## generated lines where character-level output would be unreadable noise.
##
## One range per side, never a refined set. Splitting a changed middle into
## several ranges would need a character-level Myers walk costing O(bytes * D),
## which is the version deliberately not taken here. A single range bracketed
## by the shared prefix and suffix is still what a highlight wants, and it is
## honest about not having searched.

import ./types
import ./kernel

proc spansForPair*(aView, bView: ByteView, aStart, aLen, bStart, bLen,
                   maxBytes: int): (seq[DiffSpan], seq[DiffSpan]) =
  ## Byte ranges that changed, for side A and side B.
  ##
  ## Two sequences rather than one because the two sides carry different
  ## information: the deleted line's ranges describe what A lost, the inserted
  ## line's describe what B gained, and a caller drawing a line needs the right
  ## one for the side it is drawing.
  ##
  ## An empty result on both sides means "no finer detail available", which is
  ## a normal outcome for a line past `maxBytes` and not an error.
  if maxBytes <= 0 or aLen <= 0 or bLen <= 0: return
  # A line this long is nearly always generated, and character-level output on
  # one is unreadable regardless of how fast it computes.
  if aLen > maxBytes or bLen > maxBytes: return

  let shared = min(aLen, bLen)
  var prefix = 0
  var suffix = 0
  if shared > 0:
    prefix = equalPrefixScalar(aView, bView, aStart, bStart, shared)
  if shared > prefix:
    suffix = equalSuffixScalar(aView, bView, aStart + prefix, bStart + prefix,
                               shared - prefix)

  # Ends of the differing middle on each side. The suffix is trimmed off the
  # end, the prefix off the front, so an unchanged line collapses to nothing
  # and a whole-line change spans everything.
  let aMid = aLen - suffix
  let bMid = bLen - suffix

  if aMid > prefix:
    result[0] = @[DiffSpan(start: prefix, stop: aMid)]
  if bMid > prefix:
    result[1] = @[DiffSpan(start: prefix, stop: bMid)]