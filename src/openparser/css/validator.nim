import std/[strutils, sequtils, tables]
import ./[ast, syntax, syntaxdata]

type
  ValidationError* = object
    message*: string
    property*: string
    value*: string

  ValidationResult* = object
    valid*: bool
    errors*: seq[ValidationError]

const ValuePrefixes = ["-webkit-", "-moz-", "-ms-", "-o-"]

proc stripVendorPrefix(val: string): string =
  for prefix in ValuePrefixes:
    if val.startsWith(prefix):
      return val[prefix.len..^1]
  val

proc isWhitespace(val: CssValue): bool =
  val.kind == cvkPreserved and val.preservedValue in [" ", "\t", "\n", "\r"]

proc isIgnoredValue(val: CssValue): bool =
  isWhitespace(val) or val.kind == cvkComment

proc stripWhitespace(vals: seq[CssValue]): seq[CssValue] =
  for v in vals:
    if not isIgnoredValue(v):
      result.add(v)

proc valueToString(val: CssValue): string =
  case val.kind
  of cvkFunction:
    val.funcName & "(" & val.args.map(valueToString).join(" ") & ")"
  of cvkNumber: val.numValue
  of cvkDimension: val.dimValue & val.dimUnit
  of cvkPercentage: val.pctValue
  of cvkString: "\"" & val.strValue & "\""
  of cvkUrl: "url(" & val.urlValue & ")"
  of cvkIdent: val.identValue
  of cvkHash: "#" & val.hashValue
  of cvkComment: "/*" & val.commentText & "*/"
  of cvkPreserved: val.preservedValue
  else: ""

proc valueListToString(vals: seq[CssValue]): string =
  var parts: seq[string] = @[]
  for v in vals:
    parts.add(valueToString(v))
  parts.join(" ")

const
  CssWideKeywords* = ["inherit", "initial", "unset", "revert", "revert-layer"]
  UniversalFunctions* = ["var", "env", "calc", "clamp", "min", "max", "round", "mod", "rem"]
  MathFunctions* = ["calc", "clamp", "min", "max", "round", "mod", "rem", "abs", "sign",
                    "sin", "cos", "tan", "asin", "acos", "atan", "atan2",
                    "pow", "sqrt", "hypot", "log", "exp"]
  MaxRecursionDepth* = 32

proc isVarOrEnvCall(val: CssValue): bool =
  val.kind == cvkFunction and val.funcName in ["var", "env"]

proc isCalcLikeCall(val: CssValue): bool =
  val.kind == cvkFunction and val.funcName in MathFunctions

proc isZeroLength(val: CssValue): bool =
  val.kind == cvkNumber and (val.numValue == "0" or val.numValue == "0.0")

proc isLengthUnit(unit: string): bool =
  unit in ["px", "em", "ex", "ch", "ic", "rem", "lh", "rlh",
           "vw", "vh", "vmin", "vmax", "vb", "vi",
           "svw", "svh", "slvw", "slvh", "lvw", "lvh", "dvw", "dvh",
           "cqw", "cqh", "cqi", "cqb", "cqmin", "cqmax",
           "cm", "mm", "Q", "in", "pt", "pc", "mozmm"]

proc isAngleUnit(unit: string): bool =
  unit in ["deg", "rad", "grad", "turn"]

proc isTimeUnit(unit: string): bool =
  unit in ["s", "ms"]

proc isFreqUnit(unit: string): bool =
  unit in ["hz", "kHz"]

proc isFlexUnit(unit: string): bool =
  unit == "fr"

proc isResolutionUnit(unit: string): bool =
  unit in ["dpi", "dpcm", "dppx", "x"]

proc matchValue*(data: CssData, val: CssValue, syn: SyntaxNode, depth: int = 0): bool
proc matchSequence*(data: CssData, vals: seq[CssValue], syn: SyntaxNode, depth: int = 0): tuple[matched: bool, consumed: int]

proc matchType*(data: CssData, val: CssValue, typeName: string): bool =
  if val.isVarOrEnvCall:
    return true
  # calc()/min()/max()/clamp() etc. can produce any numeric type
  if val.isCalcLikeCall:
    case typeName
    of "number", "integer", "length", "angle", "time", "frequency",
       "percentage", "flex", "resolution", "length-percentage",
       "angle-percentage", "time-percentage", "frequency-percentage",
       "number-percentage", "alpha-value", "opacity-value", "dimension":
      return true
    else: discard
  case typeName
  of "number": val.kind == cvkNumber
  of "integer": val.kind == cvkNumber and '.' notin val.numValue
  of "length":
    val.kind == cvkDimension and isLengthUnit(val.dimUnit) or val.isZeroLength
  of "angle": val.kind == cvkDimension and isAngleUnit(val.dimUnit)
  of "time": val.kind == cvkDimension and isTimeUnit(val.dimUnit)
  of "frequency": val.kind == cvkDimension and isFreqUnit(val.dimUnit)
  of "flex": val.kind == cvkDimension and isFlexUnit(val.dimUnit)
  of "resolution": val.kind == cvkDimension and isResolutionUnit(val.dimUnit)
  of "percentage": val.kind == cvkPercentage
  of "length-percentage":
    val.isZeroLength or
    val.kind == cvkPercentage or
    (val.kind == cvkDimension and isLengthUnit(val.dimUnit))
  of "angle-percentage":
    val.kind == cvkPercentage or (val.kind == cvkDimension and isAngleUnit(val.dimUnit))
  of "time-percentage":
    val.kind == cvkPercentage or (val.kind == cvkDimension and isTimeUnit(val.dimUnit))
  of "frequency-percentage":
    val.kind == cvkPercentage or (val.kind == cvkDimension and isFreqUnit(val.dimUnit))
  of "number-percentage", "alpha-value", "opacity-value":
    val.kind == cvkNumber or val.kind == cvkPercentage
  of "color":
    val.kind == cvkHash or val.kind == cvkIdent or
    (val.kind == cvkFunction and val.funcName in [
      "rgb", "rgba", "hsl", "hsla", "hwb", "lab", "lch",
      "oklab", "oklch", "color", "color-mix", "light-dark",
      "device-cmyk"
    ])
  of "string": val.kind == cvkString
  of "url":
    val.kind == cvkUrl or
    (val.kind == cvkFunction and val.funcName.cmpIgnoreCase("url") == 0)
  of "image":
    val.kind == cvkUrl or
    (val.kind == cvkFunction and val.funcName in [
      "linear-gradient", "repeating-linear-gradient",
      "radial-gradient", "repeating-radial-gradient",
      "conic-gradient", "repeating-conic-gradient",
      "image", "image-set", "cross-fade", "element", "paint"
    ])
  of "custom-ident": val.kind == cvkIdent
  of "dashed-ident": val.kind == cvkIdent and val.identValue.startsWith("--")
  of "ident": val.kind == cvkIdent
  of "dimension": val.kind == cvkDimension
  of "declaration-value", "any-value": true
  of "ratio":
    val.kind == cvkNumber or
    (val.kind == cvkDimension and val.dimUnit == "/") or
    (val.kind == cvkPreserved and val.preservedValue == "/")
  else:
    let name = typeName.strip()
    if data.syntaxes.hasKey(name):
      let syn = data.getSyntax(name)
      if syn != nil: matchValue(data, val, syn)
      else: false
    elif name.endsWith(")") and data.syntaxes.hasKey(name[0..^2]):
      let syn = data.getSyntax(name[0..^2])
      if syn != nil: matchValue(data, val, syn)
      else: false
    else: false

proc matchValue(data: CssData, val: CssValue, syn: SyntaxNode, depth: int = 0): bool =
  if syn == nil: return false
  if depth > MaxRecursionDepth: return false
  # CSS-wide keywords and var()/env() are universally valid
  if val.isVarOrEnvCall:
    return true
  if val.kind == cvkIdent and val.identValue.toLowerAscii in CssWideKeywords:
    return true
  case syn.kind
  of skKeyword:
    val.kind == cvkIdent and
      (val.identValue.cmpIgnoreCase(syn.kw) == 0 or
       stripVendorPrefix(val.identValue).cmpIgnoreCase(syn.kw) == 0)
  of skType:
    matchType(data, val, syn.cssType)
  of skFunction:
    val.kind == cvkFunction and val.funcName.cmpIgnoreCase(syn.cssFunc) == 0
  of skPropertyRef:
    let propSyn = data.getPropertySyntax(syn.propRef)
    if propSyn != nil: matchValue(data, val, propSyn, depth + 1)
    else: false
  of skString: val.kind == cvkIdent and val.identValue == syn.str
  of skNumeric: val.kind == cvkNumber and val.numValue == syn.numeric
  of skGroup: matchValue(data, val, syn.group, depth + 1)
  of skAlternatives:
    for alt in syn.alternatives:
      if matchValue(data, val, alt, depth + 1): return true
    false
  of skAtLeastOne:
    for opt in syn.options:
      if matchValue(data, val, opt, depth + 1): return true
    false
  of skAll:
    # At single-value level, treat && like "any of" — at least one must match
    for req in syn.required:
      if matchValue(data, val, req, depth + 1): return true
    false
  of skJuxtapose:
    for item in syn.sequence:
      if matchValue(data, val, item, depth + 1): return true
    false
  of skOptional: matchValue(data, val, syn.optionalInner, depth + 1)
  of skZeroOrMore:
    matchValue(data, val, syn.starInner, depth + 1)
  of skOneOrMore, skCommaSep, skRequired:
    let inner = case syn.kind
      of skOneOrMore: syn.plusInner
      of skCommaSep: syn.hashInner
      else: syn.bangInner
    matchValue(data, val, inner, depth + 1)
  of skMulti: matchValue(data, val, syn.multiInner, depth + 1)
  of skDelim:
    val.kind == cvkPreserved and val.preservedValue == syn.delim
  of skTokenRef:
    case syn.tokenType
    of "ident": val.kind == cvkIdent
    of "number": val.kind == cvkNumber
    of "dimension": val.kind == cvkDimension
    of "percentage": val.kind == cvkPercentage
    of "string": val.kind == cvkString
    of "url": val.kind == cvkUrl
    of "hash": val.kind == cvkHash
    else: false

proc matchSequence(data: CssData, vals: seq[CssValue], syn: SyntaxNode, depth: int = 0): tuple[matched: bool, consumed: int] =
  if syn == nil or vals.len == 0:
    return (false, 0)
  if depth > MaxRecursionDepth:
    return (false, 0)
  # CSS-wide keywords and var()/env() anywhere match anything at the sequence level
  if vals.len == 1 and (vals[0].isVarOrEnvCall or
     (vals[0].kind == cvkIdent and vals[0].identValue.toLowerAscii in CssWideKeywords)):
    return (true, 1)

  case syn.kind
  of skType:
    let resolved = data.resolveType(syn.cssType)
    if resolved != nil:
      let res = matchSequence(data, vals, resolved, depth + 1)
      if res.matched: return res
    if matchValue(data, vals[0], syn):
      return (true, 1)
    (false, 0)
  of skKeyword, skFunction, skPropertyRef, skString, skNumeric, skDelim, skTokenRef:
    if matchValue(data, vals[0], syn):
      return (true, 1)
    (false, 0)

  of skGroup:
    matchSequence(data, vals, syn.group, depth + 1)

  of skAlternatives:
    var best: tuple[matched: bool, consumed: int] = (false, 0)
    for alt in syn.alternatives:
      let res = matchSequence(data, vals, alt, depth + 1)
      if res.matched and res.consumed > best.consumed:
        best = res
    if best.matched: return best
    (false, 0)

  of skJuxtapose:
    type Bp = object
      itemIdx: int
      posBefore: int
    var pos = 0
    var backtrack: seq[Bp] = @[]
    var i = 0
    while i < syn.sequence.len:
      let item = syn.sequence[i]
      if pos >= vals.len:
        if item.kind in {skOptional, skZeroOrMore, skCommaSep} or
           (item.kind == skDelim and item.delim == ","):
          inc i
          continue
        # Backtrack: try last optional with zero consumption
        if backtrack.len > 0:
          let bp = backtrack.pop()
          i = bp.itemIdx + 1
          pos = bp.posBefore
          continue
        return (false, 0)
      let res = matchSequence(data, vals[pos..^1], item, depth + 1)
      if res.matched:
        if res.consumed > 0 and item.kind in {skOptional, skZeroOrMore}:
          backtrack.add(Bp(itemIdx: i, posBefore: pos))
        pos += res.consumed
        inc i
      else:
        # Item didn't match
        if item.kind == skDelim and item.delim == ",":
          inc i
          continue
        if item.kind in {skOptional, skZeroOrMore}:
          inc i
          continue
        # Backtrack
        var backtracked = false
        while backtrack.len > 0:
          let bp = backtrack.pop()
          i = bp.itemIdx + 1
          pos = bp.posBefore
          backtracked = true
          break
        if not backtracked:
          return (false, 0)
    (true, pos)

  of skAtLeastOne:
    var matchedAny = false
    var pos = 0
    let remaining = vals
    var used = newSeq[bool](syn.options.len)
    while true:
      var progress = false
      for i, opt in syn.options:
        if used[i]: continue
        let res = matchSequence(data, remaining[pos..^1], opt, depth + 1)
        if res.matched and res.consumed > 0:
          used[i] = true
          pos += res.consumed
          matchedAny = true
          progress = true
          if pos >= remaining.len: break
      if not progress: break
    (matchedAny, pos)

  of skAll:
    # && means all required in any order, at most once each.
    # Greedy longest-match: for each item, pick the position that matches
    # the most values. This handles ambiguity like center matching both
    # horizontal and vertical groups, without exponential backtracking.
    var remainingVals = vals
    for req in syn.required:
      var bestPos = -1
      var bestConsumed = 0
      for i in 0..<remainingVals.len:
        let res = matchSequence(data, remainingVals[i..^1], req, depth + 1)
        if res.matched and res.consumed > bestConsumed:
          bestPos = i
          bestConsumed = res.consumed
      if bestPos >= 0:
        var newRemaining: seq[CssValue] = @[]
        for j in 0..<bestPos:
          newRemaining.add(remainingVals[j])
        for j in (bestPos + bestConsumed)..<remainingVals.len:
          newRemaining.add(remainingVals[j])
        remainingVals = newRemaining
      elif req.kind == skOptional:
        continue
      else:
        return (false, 0)
    (true, vals.len - remainingVals.len)

  of skOptional:
    let res = matchSequence(data, vals, syn.optionalInner, depth + 1)
    if res.matched: (true, res.consumed)
    else: (true, 0)

  of skZeroOrMore:
    # Zero or more: try to match as many as possible, but succeed even if 0
    var pos = 0
    while pos < vals.len:
      let res = matchSequence(data, vals[pos..^1], syn.starInner, depth + 1)
      if not res.matched: break
      pos += res.consumed
    (true, pos)

  of skOneOrMore:
    var pos = 0
    var count = 0
    while pos < vals.len:
      let res = matchSequence(data, vals[pos..^1], syn.plusInner, depth + 1)
      if not res.matched: break
      pos += res.consumed
      inc count
    (count > 0, pos)

  of skCommaSep:
    var pos = 0
    var count = 0
    while pos < vals.len:
      let res = matchSequence(data, vals[pos..^1], syn.hashInner, depth + 1)
      if not res.matched: break
      pos += res.consumed
      inc count
      if pos >= vals.len: break
      if vals[pos].kind == cvkPreserved and vals[pos].preservedValue == ",":
        pos += 1
      else:
        break
    (count > 0, pos)

  of skRequired:
    let res = matchSequence(data, vals, syn.bangInner, depth + 1)
    if res.matched and res.consumed > 0: res
    else: (false, 0)

  of skMulti:
    var pos = 0
    var count = 0
    while pos < vals.len and count < syn.multiMax:
      let res = matchSequence(data, vals[pos..^1], syn.multiInner, depth + 1)
      if not res.matched: break
      pos += res.consumed
      inc count
    (count >= syn.multiMin, pos)

proc validate*(data: CssData, property: string, values: seq[CssValue]): ValidationResult =
  let syn = data.getPropertySyntax(property)
  if syn == nil:
    return ValidationResult(valid: true)
  let cleaned = values.stripWhitespace
  if cleaned.len == 0:
    return ValidationResult(valid: false,
      errors: @[ValidationError(message: "Empty value", property: property)])
  let res = matchSequence(data, cleaned, syn)
  if not res.matched or res.consumed < cleaned.len:
    result.valid = false
    result.errors.add(ValidationError(
      message: "Value does not match property syntax",
      property: property,
      value: valueListToString(cleaned)
    ))
  else:
    result.valid = true

proc validate*(data: CssData, property: string, rawValue: string,
               components: seq[CssValue]): ValidationResult =
  validate(data, property, components)

proc validateDeclaration*(data: CssData, node: CssNode): ValidationResult =
  if node.kind != cssDeclaration:
    return ValidationResult(valid: true)
  validate(data, node.property, node.valueComponents)

proc validateRuleSet*(data: CssData, node: CssNode): ValidationResult =
  if node.kind != cssRuleSet:
    return ValidationResult(valid: true)
  for decl in node.declarations:
    let res = validateDeclaration(data, decl)
    if not res.valid:
      result.errors.add(res.errors)
  result.valid = result.errors.len == 0

proc validateAtRule*(data: CssData, node: CssNode): ValidationResult =
  if node.kind != cssAtRule:
    return ValidationResult(valid: true)
  for child in node.atRules:
    let res = case child.kind
      of cssDeclaration: validateDeclaration(data, child)
      of cssRuleSet: validateRuleSet(data, child)
      of cssAtRule: validateAtRule(data, child)
      else: ValidationResult(valid: true)
    if not res.valid:
      result.errors.add(res.errors)
  result.valid = result.errors.len == 0

proc validateStyleSheet*(data: CssData, style: CssStyleSheet): seq[ValidationResult] =
  for n in style.nodes:
    let res = case n.kind
      of cssRuleSet: validateRuleSet(data, n)
      of cssAtRule: validateAtRule(data, n)
      else: ValidationResult(valid: true)
    if not res.valid:
      result.add(res)
