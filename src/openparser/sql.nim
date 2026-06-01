import std/[strutils, memfiles]
import ./json

## This module implements a high-performance SQL parser that can read from a string or
## memory-mapped file (for large SQL scripts). It supports a wide range of SQL syntax, including complex expressions,
## function calls, and DDL statements. The parser produces an abstract syntax tree (AST) that can be
## used for analysis, transformation, or code generation.
## 
## This implementation is pretty similar with the one from `pkg/parsesql`, except that it has been
## refactored to use `std/strutils` instead of `std/lexbase`, and support memory-mapped files for large SQL scripts.
## 
## Also, this parser is designed to support multiple SQL dialects (PostgreSQL, MySQL, SQLite) with minimal changes,
## and to be easily extensible for additional syntax features.
## 
## This SQL parser handles a wide range of SQL syntax, including:
## - SELECT statements with complex expressions, function calls, and modifiers (DISTINCT, ALL)
## - FROM clauses with joins, subqueries, and table aliases
## - WHERE clauses with logical operators, comparison operators, and nested conditions
## - GROUP BY, HAVING, ORDER BY, LIMIT, OFFSET
## - INSERT, UPDATE, DELETE statements
## - DDL statements like CREATE TABLE, CREATE TYPE, CREATE INDEX, and their IF NOT EXISTS variants
## - DROP statements for tables, types, indexes, and views
## 
## - Support for SQL comments (line comments with -- or #, and block comments with /* */)
## - Support for string literals with proper handling of escape sequences and doubling of quotes
## - Support for numeric literals, including integers, decimals, and scientific notation
## - Support for placeholders in prepared statements (e.g. $1, $2 for PostgreSQL, ? for SQLite)
## - Detailed error reporting with line and column numbers, and a snippet of the SQL code where the error occurred
## - Support for multiple SQL dialects with customizable reserved keywords and syntax rules
## - Support for placeholder syntax specific to different SQL drivers (e.g. $1 for PostgreSQL, ? for SQLite, :name for named placeholders)

type
  SqlTokenKind* = enum
    tkIdentifier,     # table names, column names, aliases, etc.
    tkKeyword,        # SELECT, FROM, WHERE, etc.
    tkOperator,       # + - * / % = < > ! & | ^ ~
    tkStringLiteral,  # 'string', "string", `string`
    tkNumericLiteral, # 123, 3.14, .5, 1e10
    tkColon, tkSemicolon, tkComma, tkDot, # : ; , .
    tkLP, tkRP, tkLB, tkRB, # ( ) [ ]
    tkPlaceholder,    # $1, $2, or SQLite-style ? placeholders
    tkEOF

  SqlLexer* = object
    input: string
    data: ptr UncheckedArray[char]
    len: int
    pos: int
    line, col: int
    current: char

  QuoteKind* = enum
    qkNone, qkSingle, qkDouble, qkBacktick

  SqlToken* = object
    kind: SqlTokenKind
    quote: QuoteKind
    value: string
    pos: int
    line: int
    col: int
  
  SqlDriver* = enum
    generic, pgsql, mysql, sqlite

  SqlParser* = object
    dialect: SqlDriver
    lexer: SqlLexer
    prev, curr, next: SqlToken

  SqlParseError* = object of CatchableError
    ## Raised when a syntax error is encountered during SQL parsing.
    ## Contains details about the error location and message.

const
  invalidToken* = "Invalid token `$1`"
  errorEndOfFile* = "Unexpected EOF while parsing `$1`"
  unexpectedToken* = "Unexpected token `$1`"
  unexpectedTokenExpected* = "Got `$1`, expected $2"
  unexpectedChar* = "Unexpected character `$1`"

const
  constraintKeywords = [
    "not", "null", "primary", "key", "unique", "default",
    "references", "check", "generated", "constraint", "collate",
    "foreign"
  ]

  # expanded reserved keywords (common SQL / Postgres / MySQL / SQLite)
  reservedKeywords = [
    "not", "null", "primary", "key", "unique", "default",
    "references", "check", "generated", "constraint", "collate",
    "foreign",
    "select", "from", "where", "group", "having", "order", "limit", "offset",
    "insert", "update", "delete", "create", "drop", "alter", "truncate", "replace",
    "table", "type", "enum", "view", "index", "into", "values", "set",
    "as", "and", "or", "in", "is", "like", "ilike", "between", "distinct",
    "join", "inner", "left", "right", "full", "cross", "natural", "outer", "using", "on",
    "returning", "if", "exists", "all", "case", "when", "then", "else", "end",
    "union", "intersect", "except", "with", "recursive", "lateral", "for",
    "each", "row", "grant", "revoke", "comment", "analyze", "explain", "cascade",
    "restrict", "by"
  ]

proc isReserved*(s: string): bool =
  ## Case-insensitive reserved keyword check
  let low = s.toLowerAscii
  for kw in reservedKeywords:
    if low == kw: return true
  return false

proc charAt(l: SqlLexer, idx: int): char {.inline.} =
  if idx < 0 or idx >= l.len: return '\0'
  if l.data != nil: l.data[idx] else: l.input[idx]

proc getContext(l: SqlLexer, posOverride: int = -1): string =
  # Show the full current line and place caret at exact token position.
  let rawPos = if posOverride >= 0: posOverride else: l.pos
  let atPos = max(0, min(rawPos, l.len))

  var lineStart = atPos
  while lineStart > 0 and l.charAt(lineStart - 1) != '\n':
    dec lineStart

  var lineEnd = atPos
  while lineEnd < l.len and l.charAt(lineEnd) notin {'\n', '\r'}:
    inc lineEnd

  var snippet: string
  if l.input.len > 0:
    snippet = l.input[lineStart ..< lineEnd]
  else:
    snippet = newStringOfCap(max(0, lineEnd - lineStart))
    for i in lineStart ..< lineEnd:
      snippet.add(l.charAt(i))

  let markerPos = max(0, min(snippet.len, atPos - lineStart))
  result = snippet & "\n" & " ".repeat(markerPos) & "^"

proc error*(l: var SqlLexer, msg: string) =
  ## Raise a lexer error
  let context = getContext(l)
  raise newException(SqlParseError, ("\n" & context & "\n" & "Error ($1:$2) " % [$l.line, $l.col]) & msg)

proc error*(p: var SqlParser, msg: string) =
  # Prefer current token coordinates over lexer cursor (lookahead-safe).
  var atPos = p.lexer.pos
  var atLine = p.lexer.line
  var atCol = p.lexer.col

  atPos = p.curr.pos
  atLine = p.curr.line
  atCol = p.curr.col

  let context = getContext(p.lexer, atPos)
  raise newException(
    SqlParseError,
    ("\n" & context & "\n" & "Error ($1:$2) " % [$atLine, $atCol]) & msg
  )

proc advance(l: var SqlLexer) =
  if l.pos < l.len - 1:
    inc l.pos
    l.current = l.charAt(l.pos)
    inc l.col
  else:
    l.pos = l.len
    l.current = '\0'

proc skipWhitespace(l: var SqlLexer) =
  while true:
    case l.current
    of {' ', '\t', '\n', '\r'}:
      if l.current == '\n':
        inc l.line
        l.col = 0
      advance(l)
    else: break

proc nextToken(p: var SqlParser): SqlToken {.discardable.}

proc readNumber(l: var SqlLexer): string =
  result = ""
  if l.current == '-':
    result.add('-')
    advance(l)
  while l.current in {'0'..'9'}:
    result.add(l.current)
    advance(l)
  if l.current == '.':
    result.add('.')
    advance(l)
    while l.current in {'0'..'9'}:
      result.add(l.current)
      advance(l)
  if l.current in {'e', 'E'}:
    # scientific notation
    result.add(l.current)
    advance(l)
    if l.current in {'+', '-'}:
      result.add(l.current)
      advance(l)
    while l.current in {'0'..'9'}:
      result.add(l.current)
      advance(l)

proc nextToken(p: var SqlParser): SqlToken {.discardable.} =
  skipWhitespace(p.lexer)
  # Skip line and block comments
  # Skip line and block comments
  if p.lexer.current == '-' and p.lexer.charAt(p.lexer.pos + 1) == '-':
    # consume until end of line
    while p.lexer.current != '\0' and p.lexer.current notin {'\n', '\r'}:
      advance(p.lexer)
    return nextToken(p)
  if p.lexer.current == '#':
    while p.lexer.current != '\0' and p.lexer.current notin {'\n', '\r'}:
      advance(p.lexer)
    return nextToken(p)
  if p.lexer.current == '/' and p.lexer.charAt(p.lexer.pos + 1) == '*':
    # consume block comment and account for newlines so lexer.line/col stay correct
    advance(p.lexer); advance(p.lexer) # consume "/*"
    while p.lexer.current != '\0':
      if p.lexer.current == '*' and p.lexer.charAt(p.lexer.pos + 1) == '/':
        advance(p.lexer); advance(p.lexer)
        break
      # update line/col for newlines inside block comments
      if p.lexer.current == '\n':
        inc p.lexer.line
        p.lexer.col = 0
      advance(p.lexer)
    return nextToken(p)

  result = SqlToken(
    line: p.lexer.line,
    col: p.lexer.col,
    pos: p.lexer.pos
  )

  case p.lexer.current
  of '\0':
    result.kind = tkEOF
  of '+', '-', '*', '/', '%', '=', '<', '>', '!', '&', '|', '^', '~':
    # collect contiguous run of operator characters as single operator token
    result.kind = tkOperator
    var buf = newStringOfCap(4)
    while p.lexer.current in {'+', '-', '*', '/', '%', '=', '<', '>', '!', '&', '|', '^', '~', '@', '#'}:
      buf.add(p.lexer.current)
      advance(p.lexer)
    result.value = buf
  of '$':
    # PostgreSQL placeholders: $1, $2, $3, etc.
    result.kind = tkPlaceholder
    var value = newStringOfCap(8)
    value.add('$')
    advance(p.lexer) # consume '$'
    # Must have at least one digit after $
    if p.lexer.current notin {'0'..'9'}:
      p.error(unexpectedChar % $p.lexer.current)
    while p.lexer.current in {'0'..'9'}:
      value.add(p.lexer.current)
      advance(p.lexer)
    result.value = value
  of '?':
    # SQLite-style placeholders: ? or ?NN
    result.kind = tkPlaceholder
    var value = newStringOfCap(4)
    value.add('?')
    advance(p.lexer) # consume '?'
    # optional numeric suffix like ?1, ?123
    while p.lexer.current in {'0'..'9'}:
      value.add(p.lexer.current)
      advance(p.lexer)
    result.value = value
  of ':':
    # Could be a named placeholder like :name, a cast operator ::, or just a colon token.
    if p.lexer.charAt(p.lexer.pos + 1) == ':':
      # PostgreSQL cast operator ::
      result.kind = tkOperator
      result.value = "::"
      advance(p.lexer); advance(p.lexer)
    elif p.lexer.charAt(p.lexer.pos + 1) in {'a'..'z', 'A'..'Z', '_'}:
      result.kind = tkPlaceholder
      var value = newStringOfCap(12)
      value.add(':')
      advance(p.lexer) # consume ':'
      while p.lexer.current in {'a'..'z', 'A'..'Z', '0'..'9', '_'}:
        value.add(p.lexer.current)
        advance(p.lexer)
      result.value = value
    else:
      result.kind = tkColon
      advance(p.lexer)
  of '@':
    # Handle @name style placeholders (common in some DB libs)
    if p.lexer.charAt(p.lexer.pos + 1) in {'a'..'z', 'A'..'Z', '_'}:
      result.kind = tkPlaceholder
      var value = newStringOfCap(12)
      value.add('@')
      advance(p.lexer) # consume '@'
      while p.lexer.current in {'a'..'z', 'A'..'Z', '0'..'9', '_'}:
        value.add(p.lexer.current)
        advance(p.lexer)
      result.value = value
    else:
      # treat as unexpected char for now
      p.error(unexpectedChar % $p.lexer.current)
  of ';':
    result.kind = tkSemicolon
    advance(p.lexer)
  of ',':
    result.kind = tkComma
    advance(p.lexer)
  of '.':
    result.kind = tkDot
    advance(p.lexer)
  of '(', ')', '[', ']':
    case p.lexer.current
    of '(':
      result.kind = tkLP
    of ')':
      result.kind = tkRP
    of '[':
      result.kind = tkLB
    of ']':
      result.kind = tkRB
    else: discard
    advance(p.lexer)
  of '\'', '"', '`':
    let quoteChar = p.lexer.current
    result.kind = tkStringLiteral
    var value = newStringOfCap(16)

    # Determine whether backslash escapes should be processed:
    # - MySQL accepts backslash escapes inside quoted strings
    # - PostgreSQL accepts backslash escapes when the preceding token is an identifier "E" (E'...')
    var escapesEnabled = false
    if p.dialect == SqlDriver.mysql:
      escapesEnabled = true
    elif p.prev.kind == tkIdentifier and cmpIgnoreCase(p.prev.value, "E") == 0 and quoteChar == '\'':
      escapesEnabled = true

    advance(p.lexer) # consume opening quote

    while true:
      if p.lexer.current == '\0':
        p.error(errorEndOfFile % "string literal")

      if p.lexer.current == quoteChar:
        # If the next char is the same quote, that's an escaped quote (SQL doubling).
        let nextc = p.lexer.charAt(p.lexer.pos + 1)
        if nextc == quoteChar:
          # consume the doubled quote and add one instance to the value
          advance(p.lexer) # move to second quote
          value.add(quoteChar)
          advance(p.lexer) # move past second quote
          continue
        else:
          # consume closing quote and finish
          advance(p.lexer)
          break
      elif p.lexer.current == '\\' and escapesEnabled:
        # Handle common backslash escapes (MySQL or E'...' style)
        advance(p.lexer) # move past backslash
        if p.lexer.current == '\0':
          p.error(errorEndOfFile % "string literal")
        case p.lexer.current
        of 'n': value.add('\n')
        of 'r': value.add('\r')
        of 't': value.add('\t')
        of '0': value.add(chr(0))
        of 'b': value.add('\b')
        of 'f': value.add('\f')
        of '\\': value.add('\\')
        of '\'': value.add('\'')
        of '"': value.add('"')
        else:
          # Unknown escape: keep the escaped character literally (MySQL-like behavior)
          value.add(p.lexer.current)
        advance(p.lexer)
        continue
      else:
        value.add(p.lexer.current)
        advance(p.lexer)

    result.value = value

    # Set quote type for downstream handling
    case quoteChar
    of '\'': result.quote = qkSingle
    of '"':  result.quote = qkDouble
    of '`':  result.quote = qkBacktick
    else:    result.quote = qkNone
  of '0'..'9':
    result.kind = tkNumericLiteral
    result.value = readNumber(p.lexer)
  of 'a'..'z', 'A'..'Z', '_':
    result.kind = tkIdentifier
    var value = newStringOfCap(16)
    while p.lexer.current in {'a'..'z', 'A'..'Z', '0'..'9', '_'}:
      value.add(p.lexer.current)
      advance(p.lexer)
    result.value = value
    result.kind = tkKeyword
  else:
    p.error(unexpectedChar % $p.lexer.current)

proc advance*(p: var SqlParser): SqlToken {.discardable.} =
  # Advance to the next token and return it
  p.prev = p.curr
  p.curr = p.next
  p.next = p.nextToken()
  result = p.curr

proc skipSemiColon*(p: var SqlParser) =
  if p.curr.kind == tkSemicolon:
    p.advance()
  elif p.next.kind != tkEOF and p.next.line == p.curr.line:
    # If next token is not EOF and is on the same line, semicolon is expected
    p.error(unexpectedTokenExpected % [$p.curr.kind, ";"])

proc expectSkip*(p: var SqlParser, kind: SqlTokenKind) =
  if p.curr.kind != kind:
    if p.curr.kind == tkEOF:
      p.error(errorEndOfFile % $kind)
    else:
      p.error(unexpectedTokenExpected % [$p.curr.kind, $kind])
  else:
    p.advance()

#
# AST
#
type
  SqlNodeKind* = enum
    nkNone,
    nkIdent,
    nkQuotedIdent,
    nkStringLit,
    nkBitStringLit,
    nkHexStringLit,
    nkIntegerLit,
    nkNumericLit,
    nkRaw, # any other literal node kinds should be added here
    nkPlaceholder,
    nkPrimaryKey,
    nkForeignKey,
    nkNotNull,
    nkNull,

    nkStmtList,
    nkDot,
    nkDotDot,
    nkPrefix,
    nkInfix,
    nkCall,
    nkPrGroup,
    nkColumnReference,
    nkReferences,
    nkDefault,
    nkCheck,
    nkConstraint,
    nkUnique,
    nkIdentity,
    nkColumnDef,      ## name, datatype, constraints
    nkInsert,
    nkUpdate,
    nkDelete,
    nkSelect,
    nkSelectDistinct,
    nkSelectColumns,
    nkSelectPair,
    nkAsgn,
    nkFrom,
    nkFromItemPair,
    nkJoin,
    nkNaturalJoin,
    nkUsing,
    nkGroup,
    nkLimit,
    nkOffset,
    nkHaving,
    nkOrder,
    nkDesc,
    nkUnion,
    nkIntersect,
    nkExcept,
    nkColumnList,
    nkValueList,
    nkWhere,
    nkCreateTable,
    nkCreateTableIfNotExists,
    nkCreateType,
    nkCreateTypeIfNotExists,
    nkCreateIndex,
    nkCreateIndexIfNotExists,
    nkDrop,
    nkDropIfExists,
    nkDropTable,
    nkDropTableIfExists,
    nkDropType,
    nkDropTypeIfExists,
    nkDropIndex,
    nkDropIndexIfExists,
    nkDropView,
    nkDropViewIfExists,
    nkEnumDef,
    nkOnDelete,
    nkOnUpdate,
    nkDeferrable,
    # ALTER TABLE related node kinds
    nkAlterTable,
    nkAlterAddColumn,
    nkAlterDropColumn,
    nkAlterAlterColumn,
    nkAlterRenameColumn,
    nkAlterRenameTable,
    nkAlterAddConstraint,
    nkAlterSetDefault,
    nkAlterDropDefault


const
  LiteralNodes = {nkIdent, nkQuotedIdent, nkStringLit, nkBitStringLit,
          nkHexStringLit, nkIntegerLit, nkNumericLit, nkPlaceholder, nkRaw}

type
  SqlNode* = ref object
    case kind*: SqlNodeKind
    of LiteralNodes:
      strVal*: string
      quote*: QuoteKind
    else:
      sons*: seq[SqlNode]

proc parseExpression(p: var SqlParser; minPrec = 1): SqlNode {.discardable.}
proc parseParenExprList(p: var SqlParser): SqlNode

proc newNode*(k: SqlNodeKind): SqlNode =
  when defined(js): # bug #14117
    case k
    of LiteralNodes:
      result = SqlNode(kind: k, strVal: "")
    else:
      result = SqlNode(kind: k, sons: @[])
  else:
    result = SqlNode(kind: k)

proc newNode*(k: SqlNodeKind, s: string): SqlNode =
  result = SqlNode(kind: k)
  result.strVal = s

proc newNode*(k: SqlNodeKind, s: string, q: QuoteKind): SqlNode =
  result = SqlNode(kind: k)
  result.strVal = s
  result.quote = q

proc newNode*(k: SqlNodeKind, sons: seq[SqlNode]): SqlNode =
  result = SqlNode(kind: k)
  result.sons = sons

proc len*(n: SqlNode): int =
  if n.kind in LiteralNodes:
    result = 0
  else:
    result = n.sons.len

proc `[]`*(n: SqlNode; i: int): SqlNode = n.sons[i]
proc `[]`*(n: SqlNode; i: BackwardsIndex): SqlNode = n.sons[n.len - int(i)]

proc add*(father, n: SqlNode) =
  add(father.sons, n)

#
# Parse handlers
#
proc parseSelect(p: var SqlParser; topLevel = true): SqlNode

proc isKeyw(p: SqlParser, keyw: string): bool =
  p.curr.kind == tkKeyword and cmpIgnoreCase(p.curr.value, keyw) == 0

proc isOpr(p: SqlParser, opr: string): bool =
  p.curr.kind == tkOperator and cmpIgnoreCase(p.curr.value, opr) == 0

proc optKeyw(p: var SqlParser, keyw: string) =
  if p.curr.kind == tkKeyword and cmpIgnoreCase(p.curr.value, keyw) == 0:
    p.advance()

proc parseFunctionCall*(p: var SqlParser; callee: SqlNode): SqlNode {.discardable.} =
  ## Parse a function call: callee(arg, ...) and return nkCall where
  ## first son is the callee node and subsequent sons are arguments.
  ## Supports COUNT(*), DISTINCT/ALL modifiers and ordinary expression args.
  var args: seq[SqlNode] = @[]
  args.add(callee)
  # caller must be positioned at '('
  p.advance() # consume "("

  # support empty arg list: ()
  if p.curr.kind == tkRP:
    p.advance() # consume ")"
    return newNode(nkCall, args)

  # optional DISTINCT / ALL modifier (e.g. COUNT(DISTINCT col))
  if p.isKeyw("distinct") or p.isKeyw("all"):
    args.add(newNode(nkIdent, p.curr.value)) # marker as simple ident node
    p.advance()
    # after DISTINCT/ALL we either get '*' or expression(s)

  while true:
    # special-case '*' argument (COUNT(*))
    if p.curr.kind == tkOperator and p.curr.value == "*":
      args.add(newNode(nkIdent, "*"))
      p.advance()
    else:
      args.add(p.parseExpression())

    if p.curr.kind == tkComma:
      p.advance()
      continue
    elif p.curr.kind == tkRP:
      p.advance()
      break
    else:
      p.error(unexpectedTokenExpected % [$p.curr.value, ", or )"])
  result = newNode(nkCall, args)

proc parsePrimary(p: var SqlParser): SqlNode =
  # Parse a primary expression: identifiers, literals,
  # parenthesized expressions, function calls, etc.
  case p.curr.kind
  of tkLP:
    # parenthesized expression (could be a grouped expr or subquery)
    p.advance() # consume "("
    if p.isKeyw("select"):
      let sub = p.parseSelect(false)
      if p.curr.kind != tkRP:
        p.error(unexpectedTokenExpected % [$p.curr.value, ")"])
      p.advance() # consume ")"
      result = newNode(nkPrGroup, @[sub])
    else:
      # fallback: parenthesized expression/group
      var inner = p.parseExpression()
      if p.curr.kind != tkRP:
        p.error(unexpectedTokenExpected % [$p.curr.value, ")"])
      p.advance() # consume ")"
      result = newNode(nkPrGroup, @[inner])

  of tkIdentifier, tkKeyword:
    # base identifier
    var left = newNode(nkIdent, p.curr.value)
    p.advance()
    # support dotted expressions: a.b.c
    while p.curr.kind == tkDot:
      p.advance()
      if p.curr.kind in {tkIdentifier, tkKeyword}:
        let right = newNode(nkIdent, p.curr.value)
        p.advance()
        left = newNode(nkDot, @[left, right])
        continue
      elif p.curr.kind == tkStringLiteral:
        let right = newNode(nkQuotedIdent, p.curr.value)
        p.advance()
        left = newNode(nkDot, @[left, right])
        continue
      elif p.curr.kind == tkOperator and p.curr.value == "*":
        # allow a.* style projection
        let right = newNode(nkIdent, "*")
        p.advance()
        left = newNode(nkDot, @[left, right])
        continue
      else:
        p.error(unexpectedToken % $p.curr.value)


    # function call: ident(...) or schema.fn(...)
    if p.curr.kind == tkLP:
      result = p.parseFunctionCall(left)
    else:
      result = left

  of tkStringLiteral:
    result = newNode(nkStringLit, p.curr.value, p.curr.quote)
    p.advance()
  of tkNumericLiteral:
    if p.curr.value.contains('.'):
      result = newNode(nkNumericLit, p.curr.value)
    else:
      result = newNode(nkIntegerLit, p.curr.value)
    p.advance()
  of tkPlaceholder:
    result = newNode(nkPlaceholder, p.curr.value)
    p.advance()
  else:
    p.error(unexpectedToken % $p.curr.value)

proc getPrecedence(op: string): int =
  # Simple precedence for SQL operators
  case op.toLowerAscii
  of "or": return 1
  of "and": return 2
  of "=", "<", ">", "<=", ">=", "<>", "!=", "==": return 3
  of "is", "in", "like", "ilike", "between": return 3
  of "+", "-": return 4
  of "*", "/": return 5
  of "->", "->>", "#>", "#>>": return 6  # JSON operators
  of "::": return 7  # PostgreSQL cast
  else: return 0

proc parseExpression(p: var SqlParser; minPrec = 1): SqlNode {.discardable.} =
  ## Expression parser with support for prefix (unary) operators like NOT and unary +/-,
  ## plus the existing infix/keyword operators.
  var left: SqlNode

  # Handle prefix / unary operators before parsing primary.
  # SQL: NOT has high precedence (binds tighter than AND/OR). Treat unary + - ~ similarly.
  if p.isKeyw("not") or (p.curr.kind == tkOperator and (p.curr.value == "+" or p.curr.value == "-" or p.curr.value == "~")):
    var opStr = if p.isKeyw("not"): "not" else: p.curr.value
    p.advance()
    # Choose a precedence higher than binary operators so prefix binds tightly.
    let prefixPrec = 6
    var operand = p.parseExpression(prefixPrec)
    var pref = newNode(nkPrefix)
    pref.add(newNode(nkIdent, opStr))
    pref.add(operand)
    left = pref
  else:
    left = p.parsePrimary()

  while true:
    # Only handle infix operators and keyword operators (and multi-token ops like "IS NOT")
    var op = ""
    var prec = 0
    var tokensToConsume = 0


    if p.curr.kind == tkOperator:
      op = p.curr.value
      prec = getPrecedence(op)
      tokensToConsume = 1
      # Handle PostgreSQL cast operator :: as postfix (right side is a type name, not expression)
      if op == "::" and prec >= minPrec:
        p.advance()
        # read the cast type as a raw identifier/keyword sequence
        var typeName = newStringOfCap(32)
        while p.curr.kind in {tkIdentifier, tkKeyword}:
          if typeName.len > 0: typeName.add(' ')
          typeName.add(p.curr.value)
          p.advance()
          # handle type modifiers like int4, varchar(n) etc.
          if p.curr.kind == tkLP:
            typeName.add('(')
            p.advance()
            while p.curr.kind != tkRP and p.curr.kind != tkEOF:
              typeName.add(p.curr.value)
              p.advance()
            typeName.add(')')
            if p.curr.kind == tkRP: p.advance()
          break
        var castNode = newNode(nkInfix)
        castNode.add(newNode(nkIdent, "::"))
        castNode.add(left)
        castNode.add(newNode(nkIdent, typeName))
        left = castNode
        continue
    elif p.curr.kind == tkKeyword:
      let low = p.curr.value.toLowerAscii
      if low == "is":
        # support "IS" and "IS NOT"
        if p.next.kind == tkKeyword and cmpIgnoreCase(p.next.value, "not") == 0:
          op = "is not"
          prec = getPrecedence("is")
          tokensToConsume = 2
        else:
          op = "is"
          prec = getPrecedence("is")
          tokensToConsume = 1
      elif low == "and" or low == "or":
        op = low
        prec = getPrecedence(op)
        tokensToConsume = 1
      elif low == "in" or low == "like" or low == "ilike" or low == "between":
        op = low
        prec = getPrecedence(op)
        tokensToConsume = 1
      elif low == "not":
        # handle "NOT LIKE", "NOT ILIKE", "NOT IN", "NOT BETWEEN" as combined infix operators
        if p.next.kind == tkKeyword:
          let nextLow = p.next.value.toLowerAscii
          if nextLow == "like" or nextLow == "ilike" or nextLow == "in" or nextLow == "between":
            op = "not " & nextLow
            prec = getPrecedence(nextLow)
            tokensToConsume = 2
          else:
            break
        else:
          break
      else:
        break
    else:
      break

    if prec < minPrec or prec == 0:
      break

    # consume operator tokens (handles multi-token ops like "IS NOT" and "NOT LIKE")
    for i in 0 ..< tokensToConsume:
      p.advance()

    var right = p.parseExpression(prec + 1)
    var infix = newNode(nkInfix)
    infix.add(newNode(nkIdent, op))
    infix.add(left)
    infix.add(right)
    left = infix
  result = left

proc isClauseKeyword(p: SqlParser): bool =
  # Add more clause keywords as needed
  result = p.isKeyw("where") or p.isKeyw("group") or p.isKeyw("having") or
           p.isKeyw("order") or p.isKeyw("limit") or p.isKeyw("offset") or
           p.isKeyw("returning") or p.isKeyw("from") or p.isKeyw("join")


proc readName(p: var SqlParser): SqlNode =
  # Helper: read an identifier or string literal as a name node
  if p.curr.kind in {tkIdentifier, tkKeyword}:
    let n = newNode(nkIdent, p.curr.value)
    p.advance()
    return n
  elif p.curr.kind == tkStringLiteral:
    let n = newNode(nkQuotedIdent, p.curr.value)
    p.advance()
    return n
  else:
    p.error(unexpectedToken % $p.curr.value)

proc parseFromItem(p: var SqlParser): SqlNode =
  # minimal FROM item p: table_name [AS] alias
  var item = newNode(nkFromItemPair)

  # Support subquery / parenthesized source: (SELECT ...) or (...expr...)
  if p.curr.kind == tkLP:
    p.advance() # consume "("
    if p.isKeyw("select"):
      # subquery in parens: (SELECT ...)
      let sub = p.parseSelect(false)
      item.add(newNode(nkPrGroup, @[sub]))
      if p.curr.kind != tkRP:
        p.error(unexpectedTokenExpected % [$p.curr.value, ")"])
      p.advance() # consume ")"
    else:
      # parenthesized table expression: allow inner FROM items and JOIN chains,
      # e.g. (b JOIN c USING (id)) — parse into an inner nkFrom and wrap it.
      var innerFrom = newNode(nkFrom)
      # first inner item
      innerFrom.add(p.parseFromItem())
      while true:
        if p.curr.kind == tkComma:
          p.advance()
          innerFrom.add(p.parseFromItem())
          continue
        elif p.isKeyw("join") or p.isKeyw("inner") or p.isKeyw("left") or p.isKeyw("right") or p.isKeyw("full") or p.isKeyw("cross") or p.isKeyw("natural") or p.isKeyw("outer"):
          var joinKind = newStringOfCap(24)
          while p.curr.kind == tkKeyword and joinKind.len < 80:
            if joinKind.len > 0: joinKind.add(' ')
            joinKind.add(p.curr.value.toLowerAscii)
            if cmpIgnoreCase(p.curr.value, "join") == 0:
              p.advance()
              break
            p.advance()
          if cmpIgnoreCase(joinKind.split(' ')[^1], "join") != 0:
            if not p.isKeyw("join"):
              p.error(unexpectedTokenExpected % [$p.curr.value, "JOIN"])
            else:
              p.advance()
          var joinNode = newNode(nkJoin)
          joinNode.add(newNode(nkIdent, joinKind))
          joinNode.add(p.parseFromItem())
          if p.isKeyw("on"):
            p.advance()
            var onNode = newNode(nkWhere)
            onNode.add(p.parseExpression())
            joinNode.add(onNode)
          elif p.isKeyw("using"):
            p.advance()
            var colList = parseParenExprList(p)
            var usingNode = newNode(nkUsing)
            usingNode.add(colList)
            joinNode.add(usingNode)
          innerFrom.add(joinNode)
          continue
        else:
          break
      if p.curr.kind != tkRP:
        p.error(unexpectedTokenExpected % [$p.curr.value, ")"])
      p.advance() # consume ")"
      # wrap the parsed innerFrom inside a pr-group so rendering keeps the parens
      item.add(newNode(nkPrGroup, @[innerFrom]))

  elif p.curr.kind in {tkIdentifier, tkKeyword}:
    item.add(newNode(nkIdent, p.curr.value))
    p.advance()
  elif p.curr.kind == tkStringLiteral:
    item.add(newNode(nkQuotedIdent, p.curr.value))
    p.advance()
  else:
    p.error(unexpectedToken % $p.curr.value)
  
  # optional AS or implicit alias, but not a clause keyword or reserved keyword
  if p.isKeyw("as"):
    p.advance()
    if (p.curr.kind == tkIdentifier) or (p.curr.kind == tkKeyword and not isReserved(p.curr.value)):
      item.add(newNode(nkIdent, p.curr.value))
      p.advance()
  elif (p.curr.kind == tkIdentifier) or (p.curr.kind == tkKeyword and not isReserved(p.curr.value)):
    # implicit alias
    item.add(newNode(nkIdent, p.curr.value))
    p.advance()
  result = item

proc parseParenExprList(p: var SqlParser): SqlNode =
  # parse a parenthesized comma-separated list of expressions and return
  # a single nkColumnList node (used for column lists, USING(...), REFERENCES(...), etc.)
  if p.curr.kind != tkLP:
    p.error(unexpectedTokenExpected % [$p.curr.value, "("])
  p.advance() # consume "("
  var colList = newNode(nkColumnList)
  while true:
    colList.add(p.parseExpression())
    if p.curr.kind == tkComma:
      p.advance()
      continue
    elif p.curr.kind == tkRP:
      break
    else:
      p.error(unexpectedTokenExpected % [$p.curr.value, ", or )"])
  p.advance() # consume ")"
  result = colList

proc parseColumnConstraints(p: var SqlParser): seq[SqlNode] =
  # Helper: parse a column-level constraint list; returns sequence of constraint nodes
  var constraints: seq[SqlNode] = @[]
  while true:
    if p.isKeyw("not") and p.next.kind == tkKeyword and cmpIgnoreCase(p.next.value, "null") == 0:
      # NOT NULL
      p.advance() # not
      p.advance() # null
      constraints.add(newNode(nkNotNull))
      continue
    elif p.isKeyw("null"):
      p.advance()
      constraints.add(newNode(nkNull))
      continue
    elif p.isKeyw("primary"):
      p.advance()
      if p.isKeyw("key"): p.advance()
      constraints.add(newNode(nkPrimaryKey))
      continue
    elif p.isKeyw("unique"):
      p.advance()
      constraints.add(newNode(nkUnique))
      continue
    elif p.isKeyw("default"):
      p.advance()
      var def = newNode(nkDefault)
      def.add(p.parseExpression())
      constraints.add(def)
      continue
    elif p.isKeyw("references"):
      p.advance()
      var refNode = newNode(nkReferences)
      refNode.add(readName(p)) # referenced table
      if p.curr.kind == tkLP:
        var colList = parseParenExprList(p)
        refNode.add(colList)

      # optional: ON DELETE / ON UPDATE actions
      while p.isKeyw("on"):
        p.advance()
        if p.isKeyw("delete"):
          p.advance()
          var action = ""
          if p.isKeyw("no") and p.next.kind == tkKeyword and cmpIgnoreCase(p.next.value, "action") == 0:
            p.advance(); p.advance()
            action = "no action"
          elif p.isKeyw("restrict"):
            action = "restrict"; p.advance()
          elif p.isKeyw("cascade"):
            action = "cascade"; p.advance()
          elif p.isKeyw("set"):
            p.advance()
            if p.isKeyw("null"):
              action = "set null"; p.advance()
            elif p.isKeyw("default"):
              action = "set default"; p.advance()
            else:
              p.error(unexpectedTokenExpected % [$p.curr.value, "NULL or DEFAULT"])
          else:
            p.error(unexpectedToken % $p.curr.value)
          refNode.add(newNode(nkOnDelete, action))
          continue
        elif p.isKeyw("update"):
          p.advance()
          var action = ""
          if p.isKeyw("no") and p.next.kind == tkKeyword and cmpIgnoreCase(p.next.value, "action") == 0:
            p.advance(); p.advance()
            action = "no action"
          elif p.isKeyw("restrict"):
            action = "restrict"; p.advance()
          elif p.isKeyw("cascade"):
            action = "cascade"; p.advance()
          elif p.isKeyw("set"):
            p.advance()
            if p.isKeyw("null"):
              action = "set null"; p.advance()
            elif p.isKeyw("default"):
              action = "set default"; p.advance()
            else:
              p.error(unexpectedTokenExpected % [$p.curr.value, "NULL or DEFAULT"])
          else:
            p.error(unexpectedToken % $p.curr.value)
          refNode.add(newNode(nkOnUpdate, action))
          continue
        else:
          # "ON" followed by something else — rewind error
          p.error(unexpectedToken % $p.curr.value)

      # optional: DEFERRABLE / NOT DEFERRABLE [INITIALLY DEFERRED|IMMEDIATE]
      if p.isKeyw("not") and p.next.kind == tkKeyword and cmpIgnoreCase(p.next.value, "deferrable") == 0:
        p.advance() # not
        p.advance() # deferrable
        var defNode = newNode(nkDeferrable, "not deferrable")
        # optional initially
        if p.isKeyw("initially"):
          p.advance()
          if p.isKeyw("deferred"):
            defNode.add(newNode(nkIdent, "initially deferred")); p.advance()
          elif p.isKeyw("immediate"):
            defNode.add(newNode(nkIdent, "initially immediate")); p.advance()
        refNode.add(defNode)
      elif p.isKeyw("deferrable"):
        p.advance()
        var defNode = newNode(nkDeferrable, "deferrable")
        if p.isKeyw("initially"):
          p.advance()
          if p.isKeyw("deferred"):
            defNode.add(newNode(nkIdent, "initially deferred")); p.advance()
          elif p.isKeyw("immediate"):
            defNode.add(newNode(nkIdent, "initially immediate")); p.advance()
        refNode.add(defNode)

      constraints.add(refNode)
      continue
    elif p.isKeyw("check"):
      p.advance()
      if p.curr.kind != tkLP: p.error(unexpectedTokenExpected % [$p.curr.value, "("])
      p.advance()
      # parse expression until matching RP; reuse parseExpression but we expect expression then RP
      var expr = p.parseExpression()
      if p.curr.kind != tkRP:
        p.error(unexpectedTokenExpected % [$p.curr.value, ")"])
      p.advance()
      var chk = newNode(nkCheck)
      chk.add(expr)
      constraints.add(chk)
      continue
    elif p.isKeyw("generated"):
      # handle "GENERATED ... AS IDENTITY" (Postgres) or other generated clauses minimally
      p.advance()
      # skip tokens until we see "identity" or "as" then identity
      if p.isKeyw("always") or p.isKeyw("by"):
        p.advance()
      if p.isKeyw("as"):
        p.advance()
      if p.isKeyw("identity"):
        p.advance()
        constraints.add(newNode(nkIdentity))
      else:
        # unknown/generated form; ignore
        continue
    else:
      break
  result = constraints

proc parseSelect(p: var SqlParser; topLevel = true): SqlNode =
  p.advance()
  if p.isKeyw("distinct"):
    result = newNode(nkSelectDistinct)
    p.advance()
  else:
    # "ALL" or default
    if p.isKeyw("all"): p.advance()
    result = newNode(nkSelect)

  # Collect columns
  var columns = newNode(nkSelectColumns)
  while true:
    if p.isOpr("*"):
      columns.add(newNode(nkIdent, "*"))
      p.advance()
    else:
      # pair: expression [AS alias]
      var pair = newNode(nkSelectPair)
      pair.add(p.parseExpression())
      if p.isKeyw("as"):
        p.advance()
        pair.add(p.parseExpression())
      elif (p.curr.kind == tkIdentifier) or (p.curr.kind == tkKeyword and not isReserved(p.curr.value)):
        # allow implicit alias without AS, but avoid treating clause/reserved keywords as aliases
        pair.add(p.parseExpression())
      columns.add(pair)

    if p.curr.kind != tkComma: break
    p.advance()
  result.add(columns)

  # FROM clause
  if p.isKeyw("from"):
    var fromNode = newNode(nkFrom)
    p.advance() # move to first from item
    # first item
    var firstIt = p.parseFromItem()
    if firstIt.kind == nkPrGroup and firstIt.len == 1 and firstIt[0].kind == nkFrom:
      for inner in firstIt[0].sons:
        fromNode.add(inner)
    else:
      fromNode.add(firstIt)

    # parse comma-separated additional tables and JOINs
    while true:
      if p.curr.kind == tkComma:
        p.advance()
        var it = p.parseFromItem()
        if it.kind == nkPrGroup and it.len == 1 and it[0].kind == nkFrom:
          for inner in it[0].sons:
            fromNode.add(inner)
        else:
          fromNode.add(it)
        continue

      # detect join variants: JOIN, INNER JOIN, LEFT [OUTER] JOIN, RIGHT, FULL, CROSS, NATURAL, OUTER ...
      elif p.isKeyw("join") or p.isKeyw("inner") or p.isKeyw("left") or p.isKeyw("right") or p.isKeyw("full") or p.isKeyw("cross") or p.isKeyw("natural") or p.isKeyw("outer"):
        var joinKind = newStringOfCap(24)
        # collect join type words until we reach JOIN
        while p.curr.kind == tkKeyword and joinKind.len < 80:
          if joinKind.len > 0: joinKind.add(' ')
          joinKind.add(p.curr.value.toLowerAscii)
          # stop capturing once we consumed "join"
          if cmpIgnoreCase(p.curr.value, "join") == 0:
            p.advance()
            break
          p.advance()
        # If we left the loop without seeing "join", require it
        if cmpIgnoreCase(joinKind.split(' ')[^1], "join") != 0:
          # if we consumed something like "inner" and next token is "join", handle (should be consumed above),
          # otherwise require explicit JOIN
          if not p.isKeyw("join"):
            p.error(unexpectedTokenExpected % [$p.curr.value, "JOIN"])
          else:
            p.advance()

        var joinNode = newNode(nkJoin)
        # save the join kind (like "join", "left outer join", "inner join")
        joinNode.add(newNode(nkIdent, joinKind))

        # target table for the join
        joinNode.add(p.parseFromItem())

        # optional ON / USING
        if p.isKeyw("on"):
          p.advance()
          var onNode = newNode(nkWhere)
          onNode.add(p.parseExpression())
          joinNode.add(onNode)
        elif p.isKeyw("using"):
          p.advance()
          var colList = parseParenExprList(p)
          var usingNode = newNode(nkUsing)
          usingNode.add(colList)
          joinNode.add(usingNode)
        # attach the join into the from node
        fromNode.add(joinNode)
        continue
      else:
        break

    result.add(fromNode)

  # WHERE
  if p.isKeyw("where"):
    p.advance()
    var whereNode = newNode(nkWhere)
    whereNode.add(p.parseExpression())
    result.add(whereNode)  

  # GROUP BY
  if p.isKeyw("group"):
    p.advance()
    if p.isKeyw("by"): p.advance()
    var groupNode = newNode(nkGroup)
    while true:
      groupNode.add(p.parseExpression())
      if p.curr.kind != tkComma: break
      p.advance()
    result.add(groupNode)

  # HAVING
  if p.isKeyw("having"):
    p.advance()
    var havingNode = newNode(nkHaving)
    havingNode.add(p.parseExpression())
    result.add(havingNode)

  # ORDER BY
  if p.isKeyw("order"):
    p.advance()
    if p.isKeyw("by"): p.advance()
    var orderNode = newNode(nkOrder)
    while true:
      var expr = p.parseExpression()
      if p.isKeyw("desc"):
        var desc = newNode(nkDesc)
        desc.add(expr)
        orderNode.add(desc)
        p.advance()
      else:
        orderNode.add(expr)
      if p.curr.kind != tkComma: break
      p.advance()
    result.add(orderNode)

  # LIMIT / OFFSET (support MySQL, SQLite styles and PostgreSQL)
  if p.isKeyw("limit"):
    p.advance()
    var limitNode = newNode(nkLimit)
    # MySQL: LIMIT offset, count  or LIMIT count [OFFSET offset]
    if p.curr.kind == tkNumericLiteral:
      # read first numeric
      limitNode.add(newNode(nkIntegerLit, p.curr.value))
      p.advance()
      if p.curr.kind == tkComma:
        # LIMIT offset, count
        p.advance()
        if p.curr.kind == tkNumericLiteral:
          limitNode.add(newNode(nkIntegerLit, p.curr.value))
          p.advance()
      elif p.isKeyw("offset"):
        p.advance()
        if p.curr.kind == tkNumericLiteral:
          var offNode = newNode(nkOffset)
          offNode.add(newNode(nkIntegerLit, p.curr.value))
          p.advance()
          result.add(offNode)
    result.add(limitNode)

  elif p.isKeyw("offset"):
    p.advance()
    var offOnly = newNode(nkOffset)
    if p.curr.kind == tkNumericLiteral:
      offOnly.add(newNode(nkIntegerLit, p.curr.value))
      p.advance()
    result.add(offOnly)

  # PostgreSQL RETURNING (consume, attach as raw node)
  if p.dialect == SqlDriver.pgsql and p.isKeyw("returning"):
    p.advance()
    var ret = newNode(nkRaw)
    ret.strVal = "returning"
    ret.add(p.parseExpression())
    result.add(ret)
  if topLevel:
    skipSemiColon(p)

#
# Insert statement
#
proc parseValueList(p: var SqlParser): SqlNode =
  if p.curr.kind != tkKeyword or not p.isKeyw("values"):
    p.error(unexpectedTokenExpected % [$p.curr.value, "VALUES"])
  p.advance() # consume "values"
  result = newNode(nkValueList)
  while true:
    if p.curr.kind != tkLP:
      p.error(unexpectedTokenExpected % [$p.curr.value, "("])
    p.advance() # consume "("
    var values = newNode(nkSelectColumns) # reuse select columns node for value list
    while true:
      values.add(p.parseExpression())
      if p.curr.kind == tkComma:
        p.advance()
        continue
      elif p.curr.kind == tkRP:
        break
      else:
        p.error(unexpectedTokenExpected % [$p.curr.value, ", or )"])
    p.advance() # consume ")"
    result.add(values)

    if p.curr.kind == tkComma:
      p.advance()
      continue
    break

proc parseInsert*(p: var SqlParser): SqlNode =
  # This is a very minimal INSERT parser that only supports the syntax generated by ozark's insert macro.
  # It can be extended in the future to support more complex insert statements if needed.
  p.advance() # consume "insert"
  var insertNode = newNode(nkInsert)
  if not p.isKeyw("into"):
    p.error(unexpectedTokenExpected % [$p.curr.value, "into"])
  p.advance() # consume "into"

  if p.curr.kind in {tkIdentifier, tkKeyword}:
    insertNode.add(newNode(nkIdent, p.curr.value))
    p.advance()
  elif p.curr.kind == tkStringLiteral:
    insertNode.add(newNode(nkQuotedIdent, p.curr.value))
    p.advance()
  else:
    p.error(unexpectedToken % $p.curr.value)

  if p.curr.kind == tkLP:
    p.advance()
    var columns = newNode(nkColumnList)
    while true:
      if p.curr.kind in {tkIdentifier, tkKeyword}:
        columns.add(newNode(nkIdent, p.curr.value))
        p.advance()
      elif p.curr.kind == tkStringLiteral:
        columns.add(newNode(nkQuotedIdent, p.curr.value))
        p.advance()
      else:
        p.error(unexpectedToken % $p.curr.value)
      if p.curr.kind == tkComma:
        p.advance()
        continue
      elif p.curr.kind == tkRP:
        break
      else:
        p.error(unexpectedToken % $p.curr.value)
    p.advance() # consume ")"
    insertNode.add(columns)
    if not p.isKeyw("values"):
      p.error(unexpectedTokenExpected % [$p.curr.value, "VALUES"])
    insertNode.add(p.parseValueList())
  else:
    # No column list, just value list
    insertNode.add(p.parseValueList())
  skipSemiColon(p)
  result = insertNode

#
# Parse DELETE
#
proc parseDelete*(p: var SqlParser): SqlNode =
  # Minimal DELETE parser for syntax generated by ozark's delete macro.
  p.advance() # consume "delete"
  if not p.isKeyw("from"):
    p.error(unexpectedTokenExpected % [$p.curr.value, "from"])
  p.advance() # consume "from"

  var deleteNode = newNode(nkDelete)
  if p.curr.kind in {tkIdentifier, tkKeyword}:
    deleteNode.add(newNode(nkIdent, p.curr.value))
    p.advance()
  elif p.curr.kind == tkStringLiteral:
    deleteNode.add(newNode(nkQuotedIdent, p.curr.value))
    p.advance()
  else:
    p.error(unexpectedToken % $p.curr.value)

  if p.isKeyw("where"):
    p.advance()
    var whereNode = newNode(nkWhere)
    whereNode.add(p.parseExpression())
    deleteNode.add(whereNode)

  skipSemiColon(p)
  result = deleteNode


proc readDataType(p: var SqlParser): SqlNode =
  # Helper: parse a column/datatype token sequence into a single datatype string node.
  var dt = newStringOfCap(32)
  var seen = false
  ## Stop parsing the type when we hit a column constraint / clause keyword.
  while true:
    # If token is an identifier/keyword that is actually a constraint keyword -> stop
    if p.curr.kind in {tkIdentifier, tkKeyword}:
      let low = p.curr.value.toLowerAscii
      if low in constraintKeywords:
        break
      if seen: dt.add(' ')
      dt.add(p.curr.value)
      seen = true
      p.advance()
      continue

    # Balanced parentheses (e.g. VARCHAR(255), NUMERIC(10,2))
    elif p.curr.kind == tkLP:
      var depth = 0
      while true:
        if p.curr.kind == tkLP:
          dt.add('(')
          depth.inc()
          p.advance()
          continue
        elif p.curr.kind == tkRP:
          dt.add(')')
          depth.dec()
          p.advance()
          if depth <= 0:
            break
          continue
        elif p.curr.kind == tkComma:
          dt.add(',')
          p.advance()
          continue
        elif p.curr.kind in {tkNumericLiteral, tkStringLiteral,
                      tkIdentifier, tkKeyword, tkOperator, tkDot}:
          dt.add(p.curr.value)
          p.advance()
          continue
        else:
          # unexpected token inside parentheses -> stop consuming further
          break
      continue
    else:
      break

  if dt.len == 0:
    # No explicit type (allowed in some SQL dialects), return empty ident
    result = newNode(nkIdent, "")
  else:
    result = newNode(nkIdent, dt)

#
# Parse CREATE
#
proc parseCreate*(p: var SqlParser): SqlNode =
  # Implement CREATE statement parsing (tables, types (enums), indexes).
  p.advance() # consume "create"
 
  # Helper: read optional IF NOT EXISTS
  proc readIfNotExists(p: var SqlParser): bool =
    if p.isKeyw("if"):
      p.advance()
      if not p.isKeyw("not"): p.error(unexpectedTokenExpected % [$p.curr.value, "NOT"])
      p.advance()
      if not p.isKeyw("exists"): p.error(unexpectedTokenExpected % [$p.curr.value, "EXISTS"])
      p.advance()
      return true
    return false

  # Start actual CREATE parsing
  if p.isKeyw("table"):
    p.advance()
    var createNode =
      if readIfNotExists(p): newNode(nkCreateTableIfNotExists)
      else: newNode(nkCreateTable)
    # table name
    createNode.add(readName(p))

    # parse column list and table constraints
    if p.curr.kind == tkLP:
      p.advance() # consume "("
      while true:
        # table-level constraint or column definition
        if p.isKeyw("constraint") or p.isKeyw("primary") or p.isKeyw("unique") or p.isKeyw("foreign"):
          # parse table constraint
          var constraintNode = newNode(nkConstraint)
          if p.isKeyw("constraint"):
            p.advance()
            if p.curr.kind in {tkIdentifier, tkKeyword, tkStringLiteral}:
              constraintNode.add(newNode(nkIdent, p.curr.value))
              p.advance()
          
          # now specific constraint
          if p.isKeyw("primary"):
            p.advance()
            if p.isKeyw("key"): p.advance()
            var pk = newNode(nkPrimaryKey)
            if p.curr.kind == tkLP:
              pk.add(parseParenExprList(p))
            constraintNode.add(pk)
          elif p.isKeyw("unique"):
            p.advance()
            var uq = newNode(nkUnique)
            if p.curr.kind == tkLP:
              var colList = parseParenExprList(p)
              uq.add(colList)
            constraintNode.add(uq)
          elif p.isKeyw("foreign") or p.isKeyw("references"):
            if p.isKeyw("foreign"): p.advance()
            if p.isKeyw("key"): p.advance()
            var fk = newNode(nkForeignKey)
            if p.curr.kind == tkLP:
              var colList = parseParenExprList(p)
              fk.add(colList)
            if p.isKeyw("references") == false:
              p.error(unexpectedTokenExpected % [$p.curr.value, "REFERENCES"])
            p.advance()
            fk.add(readName(p))
            if p.curr.kind == tkLP:
              var rcolList = parseParenExprList(p)
              fk.add(rcolList)
            constraintNode.add(fk)
          createNode.add(constraintNode)
        else:
          # column definition
          var colDef = newNode(nkColumnDef)
          # name
          if p.curr.kind in {tkIdentifier, tkKeyword}:
            colDef.add(newNode(nkIdent, p.curr.value))
            p.advance()
          elif p.curr.kind == tkStringLiteral:
            colDef.add(newNode(nkQuotedIdent, p.curr.value))
            p.advance()
          else:
            p.error(unexpectedToken % $p.curr.value)
          
          # datatype (optional)
          if p.curr.kind in {tkIdentifier, tkKeyword, tkLP}:
            colDef.add(readDataType(p))
          
          # constraints
          let cons = parseColumnConstraints(p)
          if cons.len > 0:
            for c in cons: colDef.add(c)
          createNode.add(colDef)
        
        # separator
        if p.curr.kind == tkComma:
          p.advance()
          continue
        elif p.curr.kind == tkRP:
          p.advance()
          break
        else:
          p.error(unexpectedTokenExpected % [$p.curr.value, ", or )"])
    # optional table options (ignored) like WITH (...) or USING ... or PARTITION BY etc.
    # We skip until semicolon or next clause. For now we stop here and add createNode
    skipSemiColon(p)
    result = createNode
    return result
  elif p.isKeyw("type"):
    p.advance()
    let ifNot = readIfNotExists(p)
    var createNode = if ifNot: newNode(nkCreateTypeIfNotExists) else: newNode(nkCreateType)
    createNode.add(readName(p)) # type name
    if not p.isKeyw("as"):
      p.error(unexpectedTokenExpected % [$p.curr.value, "AS"])
    p.advance()
    if not p.isKeyw("enum"):
      p.error(unexpectedTokenExpected % [$p.curr.value, "ENUM"])
    p.advance()
    # parse enum values
    if p.curr.kind != tkLP:
      p.error(unexpectedTokenExpected % [$p.curr.value, "("])
    p.advance()
    var enumNode = newNode(nkEnumDef)
    while true:
      if p.curr.kind != tkStringLiteral:
        p.error(unexpectedTokenExpected % [$p.curr.value, "string literal"])
      enumNode.add(newNode(nkStringLit, p.curr.value, p.curr.quote))
      p.advance()
      if p.curr.kind == tkComma:
        p.advance()
        continue
      elif p.curr.kind == tkRP:
        p.advance()
        break
      else:
        p.error(unexpectedTokenExpected % [$p.curr.value, ", or )"])
    createNode.add(enumNode)
    skipSemiColon(p)
    return createNode

  # Support "CREATE [UNIQUE] INDEX"
  var isUnique = false
  if p.isKeyw("unique"):
    isUnique = true
    p.advance()

  if p.isKeyw("index"):
    p.advance()
    let ifNot = readIfNotExists(p)
    var createNode =
      if ifNot: newNode(nkCreateIndexIfNotExists)
      else: newNode(nkCreateIndex)
    if isUnique:
      # add a unique marker as a child
      createNode.add(newNode(nkUnique))
    # index name
    createNode.add(readName(p))
    # expect ON table
    if not p.isKeyw("on"):
      p.error(unexpectedTokenExpected % [$p.curr.value, "ON"])
    p.advance()
    createNode.add(readName(p)) # target table
    # column list
    if p.curr.kind == tkLP:
      var colList = parseParenExprList(p)
      createNode.add(colList)
    # optional WHERE clause (postgres)
    if p.isKeyw("where"):
      p.advance()
      var whereNode = newNode(nkWhere)
      whereNode.add(p.parseExpression())
      createNode.add(whereNode)
    skipSemiColon(p)
    return createNode

  # Unhandled CREATE variant
  p.error(unexpectedToken % $p.curr.value)

proc parseUpdate*(p: var SqlParser): SqlNode =
  # Parse: UPDATE [ONLY] table [AS alias] SET col = expr [, ...] [FROM ...] [WHERE ...] [RETURNING ...];
  p.advance() # consume "update"
  var updateNode = newNode(nkUpdate)

  # optional ONLY (Postgres)
  if p.isKeyw("only") and p.dialect == SqlDriver.pgsql:
    p.advance()

  # target table
  if p.curr.kind in {tkIdentifier, tkKeyword}:
    updateNode.add(newNode(nkIdent, p.curr.value))
    p.advance()
  elif p.curr.kind == tkStringLiteral:
    updateNode.add(newNode(nkQuotedIdent, p.curr.value))
    p.advance()
  else:
    p.error(unexpectedToken % $p.curr.value)

  # optional alias: accept "AS alias" or implicit
  # alias only when the token is an identifier
  if p.isKeyw("as"):
    p.advance()
    if p.curr.kind == tkIdentifier or (p.curr.kind == tkKeyword and not isReserved(p.curr.value)):
      if p.curr.kind == tkIdentifier:
        updateNode.add(newNode(nkIdent, p.curr.value))
      else:
        updateNode.add(newNode(nkIdent, p.curr.value))
      p.advance()
    elif p.curr.kind == tkStringLiteral:
      updateNode.add(newNode(nkQuotedIdent, p.curr.value))
      p.advance()
  elif p.curr.kind == tkIdentifier or (p.curr.kind == tkKeyword and not isReserved(p.curr.value)):
    # implicit alias (identifier or non-reserved keyword).
    # Do NOT accept bare reserved keywords like SET.
    if p.curr.kind == tkIdentifier:
      updateNode.add(newNode(nkIdent, p.curr.value))
    else:
      updateNode.add(newNode(nkIdent, p.curr.value))
    p.advance()
  # elif p.curr.kind in {tkIdentifier, tkKeyword} and not p.isClauseKeyword():
    # updateNode.add(newNode(nkIdent, p.curr.value))
    # p.advance()

  # require SET
  if not p.isKeyw("set"):
    p.error(unexpectedTokenExpected % [$p.curr.value, "SET"])
  p.advance()

  # parse assignment list
  var assigns = newNode(nkSelectColumns) # reuse comma-separated list behavior
  while true:
    # left-hand side: allow dotted identifiers (use parsePrimary to support dot)
    var left = p.parsePrimary()
    # expect '='
    if not (p.curr.kind == tkOperator and p.curr.value == "="):
      p.error(unexpectedTokenExpected % [$p.curr.value, "="])
    p.advance() # consume '='
    var right = p.parseExpression()
    var asgn = newNode(nkAsgn, @[left, right])
    assigns.add(asgn)

    if p.curr.kind == tkComma:
      p.advance()
      continue
    else:
      break
  updateNode.add(assigns)

  # optional FROM (Postgres-style)
  if p.isKeyw("from"):
    p.advance()
    var fromNode = newNode(nkFrom)
    # first item
    fromNode.add(p.parseFromItem())
    # additional items / joins
    while true:
      if p.curr.kind == tkComma:
        p.advance()
        fromNode.add(p.parseFromItem())
        continue
      # allow simple JOINs here as in SELECT FROM
      elif p.isKeyw("join") or p.isKeyw("inner") or p.isKeyw("left") or p.isKeyw("right") or p.isKeyw("full") or p.isKeyw("cross") or p.isKeyw("natural") or p.isKeyw("outer"):
        # delegate to same handling as in parseSelect: build a join node
        var joinKind = newStringOfCap(24)
        while p.curr.kind == tkKeyword and joinKind.len < 80:
          if joinKind.len > 0: joinKind.add(' ')
          joinKind.add(p.curr.value.toLowerAscii)
          if cmpIgnoreCase(p.curr.value, "join") == 0:
            p.advance()
            break
          p.advance()
        if cmpIgnoreCase(joinKind.split(' ')[^1], "join") != 0:
          if not p.isKeyw("join"):
            p.error(unexpectedTokenExpected % [$p.curr.value, "JOIN"])
          else:
            p.advance()
        var joinNode = newNode(nkJoin)
        joinNode.add(newNode(nkIdent, joinKind))
        joinNode.add(p.parseFromItem())
        if p.isKeyw("on"):
          p.advance()
          var onNode = newNode(nkWhere)
          onNode.add(p.parseExpression())
          joinNode.add(onNode)
        elif p.isKeyw("using"):
          p.advance()
          var colList = parseParenExprList(p)
          var usingNode = newNode(nkUsing)
          usingNode.add(colList)
          joinNode.add(usingNode)
        fromNode.add(joinNode)
        continue
      else:
        break
    updateNode.add(fromNode)

  # WHERE
  if p.isKeyw("where"):
    p.advance()
    var whereNode = newNode(nkWhere)
    whereNode.add(p.parseExpression())
    updateNode.add(whereNode)

  # RETURNING (Postgres-style and generic support)
  if p.isKeyw("returning"):
    p.advance()
    var retCols = newNode(nkSelectColumns)
    while true:
      retCols.add(p.parseExpression())
      if p.curr.kind == tkComma:
        p.advance()
        continue
      else:
        break
    updateNode.add(retCols)

  skipSemiColon(p)
  result = updateNode

proc parseAlterTable*(p: var SqlParser): SqlNode =
  ## Parse ALTER TABLE ... actions:
  ## Supports:
  ##   ADD [COLUMN] column_def
  ##   DROP [COLUMN] colname [CASCADE|RESTRICT]
  ##   ALTER COLUMN colname SET DEFAULT expr | DROP DEFAULT | SET NOT NULL | DROP NOT NULL | TYPE <datatype>
  ##   RENAME [COLUMN] old TO new   (also RENAME TO new_table)
  ##   ADD CONSTRAINT name <constraint>
  p.advance() # consume "alter"
  if not p.isKeyw("table"):
    p.error(unexpectedTokenExpected % [$p.curr.value, "table"])
  p.advance()

  var node = newNode(nkAlterTable)
  node.add(readName(p)) # target table

  # helper to parse a table-level constraint (similar to CREATE)
  proc parseTableConstraint(p: var SqlParser): SqlNode =
    var constraintNode = newNode(nkConstraint)
    if p.isKeyw("constraint"):
      p.advance()
      if p.curr.kind in {tkIdentifier, tkKeyword, tkStringLiteral}:
        constraintNode.add(newNode(nkIdent, p.curr.value))
        p.advance()

    if p.isKeyw("primary"):
      p.advance()
      if p.isKeyw("key"): p.advance()
      var pk = newNode(nkPrimaryKey)
      if p.curr.kind == tkLP:
        pk.add(parseParenExprList(p))
      constraintNode.add(pk)
      return constraintNode
    elif p.isKeyw("unique"):
      p.advance()
      var uq = newNode(nkUnique)
      if p.curr.kind == tkLP:
        uq.add(parseParenExprList(p))
      constraintNode.add(uq)
      return constraintNode
    elif p.isKeyw("foreign") or p.isKeyw("references"):
      if p.isKeyw("foreign"): p.advance()
      if p.isKeyw("key"): p.advance()
      var fk = newNode(nkForeignKey)
      if p.curr.kind == tkLP:
        fk.add(parseParenExprList(p))
      if not p.isKeyw("references"):
        p.error(unexpectedTokenExpected % [$p.curr.value, "REFERENCES"])
      p.advance()
      fk.add(readName(p))
      if p.curr.kind == tkLP:
        var rcolList = parseParenExprList(p)
        fk.add(rcolList)
      constraintNode.add(fk)
      return constraintNode
    elif p.isKeyw("check"):
      p.advance()
      if p.curr.kind != tkLP: p.error(unexpectedTokenExpected % [$p.curr.value, "("])
      p.advance()
      var expr = p.parseExpression()
      if p.curr.kind != tkRP: p.error(unexpectedTokenExpected % [$p.curr.value, ")"])
      p.advance()
      var chk = newNode(nkCheck)
      chk.add(expr)
      constraintNode.add(chk)
      return constraintNode
    else:
      p.error(unexpectedToken % $p.curr.value)

  # parse one or more actions (comma-separated)
  while true:
    if p.isKeyw("add"):
      p.advance()
      if p.isKeyw("constraint"):
        # ADD CONSTRAINT ...
        var addC = newNode(nkAlterAddConstraint)
        addC.add(parseTableConstraint(p))
        node.add(addC)
      else:
        # ADD [COLUMN] column definition
        if p.isKeyw("column"):
          p.advance()
        var colDef = newNode(nkColumnDef)
        if p.curr.kind in {tkIdentifier, tkKeyword}:
          colDef.add(newNode(nkIdent, p.curr.value))
          p.advance()
        elif p.curr.kind == tkStringLiteral:
          colDef.add(newNode(nkQuotedIdent, p.curr.value))
          p.advance()
        else:
          p.error(unexpectedToken % $p.curr.value)
        # datatype (optional)
        if p.curr.kind in {tkIdentifier, tkKeyword, tkLP}:
          colDef.add(readDataType(p))
        # constraints on the column
        let cons = parseColumnConstraints(p)
        if cons.len > 0:
          for c in cons: colDef.add(c)
        var addNode = newNode(nkAlterAddColumn)
        addNode.add(colDef)
        node.add(addNode)

    elif p.isKeyw("drop"):
      p.advance()
      var dropIsColumn = false
      if p.isKeyw("column"):
        dropIsColumn = true
        p.advance()
      if p.curr.kind in {tkIdentifier, tkKeyword, tkStringLiteral}:
        var nameNode: SqlNode
        if p.curr.kind == tkStringLiteral:
          nameNode = newNode(nkQuotedIdent, p.curr.value, p.curr.quote)
        else:
          nameNode = newNode(nkIdent, p.curr.value)
        p.advance()
        var dropNode = newNode(nkAlterDropColumn)
        dropNode.add(nameNode)
        # optional cascade / restrict
        if p.isKeyw("cascade") or p.isKeyw("restrict"):
          # Dialect-level validation: SQLite does not accept CASCADE/RESTRICT on DROP
          if p.dialect == SqlDriver.sqlite:
            p.error("SQLite does not support CASCADE/RESTRICT with DROP")
          dropNode.add(newNode(nkIdent, p.curr.value))
          p.advance()
      else:
        p.error(unexpectedToken % $p.curr.value)

    elif p.isKeyw("alter"):
      # ALTER COLUMN ...
      p.advance()
      if not p.isKeyw("column"):
        p.error(unexpectedTokenExpected % [$p.curr.value, "COLUMN"])
      p.advance()
      if p.curr.kind notin {tkIdentifier, tkKeyword, tkStringLiteral}:
        p.error(unexpectedToken % $p.curr.value)
      var colName =
        if p.curr.kind == tkStringLiteral:
          newNode(nkQuotedIdent, p.curr.value, p.curr.quote)
        else:
          newNode(nkIdent, p.curr.value)
      p.advance()
      # supported actions on column
      if p.isKeyw("set") and p.next.kind == tkKeyword and cmpIgnoreCase(p.next.value, "default") == 0:
        p.advance(); p.advance()
        var setDef = newNode(nkAlterSetDefault)
        setDef.add(colName)
        setDef.add(p.parseExpression())
        node.add(setDef)
      elif p.isKeyw("drop") and p.next.kind == tkKeyword and cmpIgnoreCase(p.next.value, "default") == 0:
        p.advance(); p.advance()
        var dropDef = newNode(nkAlterDropDefault)
        dropDef.add(colName)
        node.add(dropDef)
      elif p.isKeyw("type"):
        # ALTER COLUMN ... TYPE datatype
        p.advance()
        var typeNode = readDataType(p)
        var alt = newNode(nkAlterAlterColumn)
        alt.add(colName)
        alt.add(typeNode)
        node.add(alt)
      elif p.isKeyw("set") and p.next.kind == tkKeyword and cmpIgnoreCase(p.next.value, "not") == 0:
        # SET NOT NULL
        p.advance(); p.advance()
        if not p.isKeyw("null"): p.error(unexpectedTokenExpected % [$p.curr.value, "NULL"])
        p.advance()
        var nn = newNode(nkNotNull)
        var alt = newNode(nkAlterAlterColumn)
        alt.add(colName)
        alt.add(nn)
        node.add(alt)
      elif p.isKeyw("drop") and p.next.kind == tkKeyword and cmpIgnoreCase(p.next.value, "not") == 0:
        # DROP NOT NULL
        p.advance(); p.advance()
        if not p.isKeyw("null"): p.error(unexpectedTokenExpected % [$p.curr.value, "NULL"])
        p.advance()
        var drnn = newNode(nkNull)
        var alt2 = newNode(nkAlterAlterColumn)
        alt2.add(colName)
        alt2.add(drnn)
        node.add(alt2)
      else:
        p.error(unexpectedToken % $p.curr.value)

    elif p.isKeyw("rename"):
      p.advance()
      if p.isKeyw("column"):
        p.advance()
        if p.curr.kind notin {tkIdentifier, tkKeyword, tkStringLiteral}:
          p.error(unexpectedToken % $p.curr.value)
        var oldName =
          if p.curr.kind == tkStringLiteral: newNode(nkQuotedIdent, p.curr.value, p.curr.quote)
          else: newNode(nkIdent, p.curr.value)
        p.advance()
        if not p.isKeyw("to"):
          p.error(unexpectedTokenExpected % [$p.curr.value, "TO"])
        p.advance()
        if p.curr.kind notin {tkIdentifier, tkKeyword, tkStringLiteral}:
          p.error(unexpectedToken % $p.curr.value)
        var newName =
          if p.curr.kind == tkStringLiteral: newNode(nkQuotedIdent, p.curr.value, p.curr.quote)
          else: newNode(nkIdent, p.curr.value)
        p.advance()
        var rn = newNode(nkAlterRenameColumn)
        rn.add(oldName)
        rn.add(newName)
        node.add(rn)
      elif p.isKeyw("to"):
        # RENAME TO <new_table>
        p.advance()
        var newTbl = readName(p)
        var rt = newNode(nkAlterRenameTable)
        rt.add(newTbl)
        node.add(rt)
      else:
        p.error(unexpectedToken % $p.curr.value)

    else:
      p.error(unexpectedToken % $p.curr.value)

    # actions may be comma-separated
    if p.curr.kind == tkComma:
      p.advance()
      continue
    break

  skipSemiColon(p)
  result = node
  return result


proc parseDrop*(p: var SqlParser): SqlNode =
  ## Parse DROP statements:
  ##   DROP TABLE|TYPE|INDEX|VIEW [IF EXISTS] name [, name ...] [CASCADE|RESTRICT];
  p.advance() # consume "drop"

  if not (p.isKeyw("table") or p.isKeyw("type") or p.isKeyw("index") or p.isKeyw("view")):
    p.error(unexpectedTokenExpected % [$p.curr.value, "TABLE/TYPE/INDEX/VIEW"])

  var kindTok = p.curr.value.toLowerAscii
  p.advance()

  # read optional IF EXISTS
  var ifNot = false
  if p.isKeyw("if"):
    p.advance()
    if not p.isKeyw("exists"):
      p.error(unexpectedTokenExpected % [$p.curr.value, "EXISTS"])
    p.advance()
    ifNot = true

  var dropNode: SqlNode
  case kindTok
  of "table": dropNode = if ifNot: newNode(nkDropTableIfExists) else: newNode(nkDropTable)
  of "type":  dropNode = if ifNot: newNode(nkDropTypeIfExists) else: newNode(nkDropType)
  of "index": dropNode = if ifNot: newNode(nkDropIndexIfExists) else: newNode(nkDropIndex)
  of "view":  dropNode = if ifNot: newNode(nkDropViewIfExists) else: newNode(nkDropView)
  else:
    dropNode = newNode(nkDrop)

  # parse comma-separated list of names, each may be quoted/identifier/dotted
  while true:
    dropNode.add(readName(p))
    # optional per-object CASCADE / RESTRICT
    if p.isKeyw("cascade") or p.isKeyw("restrict"):
      if p.dialect == SqlDriver.sqlite:
        p.error("SQLite does not support CASCADE/RESTRICT with DROP")
      dropNode.add(newNode(nkIdent, p.curr.value))
      p.advance()
    if p.curr.kind == tkComma:
      p.advance()
      continue
    break
  skipSemiColon(p)
  result = dropNode


#
# Root parser
#
proc parseRoot(p: var SqlParser): SqlNode =
  result = newNode(nkStmtList)
  while p.curr.kind != tkEOF:
    case p.curr.kind
    of tkKeyword:
      if p.isKeyw("select"):
        result.add(p.parseSelect())
      elif p.isKeyw("insert"):
        result.add(p.parseInsert())
      elif p.isKeyw("create"):
        result.add(p.parseCreate())
      elif p.isKeyw("drop"):
        result.add(p.parseDrop())
      elif p.isKeyw("alter"):
        result.add(p.parseAlterTable())
      elif p.isKeyw("delete"):
        result.add(p.parseDelete())
      elif p.isKeyw("update"):
        result.add(p.parseUpdate())
      else: 
        p.error(unexpectedToken % $p.curr.value)
    else:
      p.error(unexpectedToken % $p.curr.value)

proc fromSqlFile*(path: string, sqlDriver: SqlDriver = SqlDriver.generic): SqlNode =
  ## Parse SQL from a file. The file is read using memfiles for efficiency, and the parser
  ## operates directly on the memory buffer without copying.
  var mf = memfiles.open(path, fmRead)
  defer: mf.close()
  var lexer = SqlLexer(data: cast[ptr UncheckedArray[char]](mf.mem), len: mf.size, pos: 0, line: 1, col: 1)
  lexer.current = lexer.charAt(0)

  var p = SqlParser(lexer: lexer, dialect: sqlDriver)
  p.curr = p.nextToken()
  p.next = p.nextToken()
  p.parseRoot()

proc parseSql*(input: string, sqlDriver: SqlDriver = SqlDriver.generic): SqlNode =
  ## Parse SQL from a string input.
  var lexer = SqlLexer(input: input, len: input.len, pos: 0, line: 1, col: 1)
  lexer.current = lexer.charAt(0)

  var p = SqlParser(lexer: lexer, dialect: sqlDriver)
  p.curr = p.nextToken()
  p.next = p.nextToken()
  p.parseRoot()

type
  SqlWriter = object
    indent: int
    upperCase: bool
    buffer: string

proc add(s: var SqlWriter, thing: char) =
  s.buffer.add(thing)

# proc prepareAdd(s: var SqlWriter) {.inline.} =
#   if s.buffer.len > 0 and s.buffer[^1] notin {' ', '\L', '(', '.', '>', ':'}:
#     s.buffer.add(" ")

proc add(s: var SqlWriter, thing: string) =
  # s.prepareAdd
  s.buffer.add(thing)

proc addKeyw(s: var SqlWriter, thing: string) =
  var keyw = thing
  if s.upperCase:
    keyw = keyw.toUpperAscii()
  s.add(keyw)

proc addIden(s: var SqlWriter, thing: string) =
  var iden = thing
  if iden.toLowerAscii() in reservedKeywords:
    iden = '"' & iden & '"'
  s.add(iden)

proc escape(res: var SqlWriter, s: string) =
  res.add('\'')
  for c in items(s):
    case c
    of '\0'..'\31':
      res.add("\\x")
      res.add(toHex(ord(c), 2))
    of '\'': res.add("''")
    else: res.add(c)
  res.add('\'')

proc ra(n: SqlNode, s: var SqlWriter) {.gcsafe.}

proc rs(n: SqlNode, s: var SqlWriter, prefix = "(", suffix = ")", sep = ", ") =
  if n.len > 0:
    s.add(prefix)
    for i in 0 .. n.len-1:
      if i > 0: s.add(sep)
      ra(n.sons[i], s)
    s.add(suffix)

proc addMulti(s: var SqlWriter, n: SqlNode, sep = ',') =
  if n.len > 0:
    for i in 0 .. n.len-1:
      if i > 0: s.add(sep)
      ra(n.sons[i], s)

proc addMulti(s: var SqlWriter, n: SqlNode, sep = ',', prefix, suffix: char) =
  if n.len > 0:
    s.add(prefix)
    for i in 0 .. n.len-1:
      if i > 0: s.add(sep)
      ra(n.sons[i], s)
    s.add(suffix)

proc ra(n: SqlNode, s: var SqlWriter) {.gcsafe.} =
  case n.kind
  of nkBitStringLit, nkHexStringLit, nkIntegerLit, nkNumericLit, nkRaw, nkIdent:
    s.add(n.strVal)
  of nkStringLit:
    escape(s, n.strVal)
  
  of nkQuotedIdent:
    case n.quote
    of qkSingle:   s.add("'"); s.add(n.strVal); s.add("'")
    of qkDouble:   s.add("\""); s.add(n.strVal); s.add("\"")
    of qkBacktick: s.add("`"); s.add(n.strVal); s.add("`")
    else:          s.add(n.strVal)
  of nkPrefix:
    # render unary/prefix operators: "NOT expr" or "-expr"
    if n.len > 0 and n[0].kind == nkIdent:
      let op = n[0].strVal.toLowerAscii
      if op == "not":
        s.addKeyw("not ")
      else:
        # symbolic unary operators (like - or +) should be printed as-is
        s.add(op & " ")
    if n.len > 1:
      ra(n[1], s)

  of nkInfix:
    ra(n[1], s)
    s.add(" ")
    s.addKeyw(n[0].strVal) # operator may be a keyword like 'and'/'or' or symbol
    s.add(" ")
    ra(n[2], s)
  
  of nkStmtList:
    for i, stmt in n.sons:
      if i > 0: s.add(" ")
      ra(stmt, s)
      s.add(";") # Add semicolon after each statement
  
  of nkSelect:
    s.addKeyw("select ")
    ra(n[0], s) # columns
    # render remaining clauses in any order they appear
    for i in 1 ..< n.len:
      let c = n[i]
      case c.kind
      of nkFrom: ra(c, s)
      of nkWhere: ra(c, s)
      of nkGroup: ra(c, s)
      of nkHaving: ra(c, s)
      of nkOrder: ra(c, s)
      of nkLimit: ra(c, s)
      of nkOffset: ra(c, s)
      of nkSelectColumns:
        # used for RETURNING
        s.addKeyw(" returning ")
        ra(c, s)
      else:
        s.add(" ")
        ra(c, s)
  
  of nkSelectDistinct:
    s.addKeyw("select distinct ")
    ra(n[0], s) # columns
    for i in 1 ..< n.len:
      let c = n[i]
      case c.kind
      of nkFrom: ra(c, s)
      of nkWhere: ra(c, s)
      of nkGroup: ra(c, s)
      of nkHaving: ra(c, s)
      of nkOrder: ra(c, s)
      of nkLimit: ra(c, s)
      of nkOffset: ra(c, s)
      of nkSelectColumns:
        s.addKeyw(" returning ")
        ra(c, s)
      else:
        s.add(" ")
        ra(c, s)
  
  of nkSelectColumns:
    for i, col in n.sons:
      if i > 0: s.add(", ")
      ra(col, s)
  
  of nkSelectPair:
    ra(n[0], s)
    if n.len > 1:
      s.addKeyw(" as ")
      ra(n[1], s)
  
  of nkFrom:
    if n.len == 0:
      s.addKeyw(" from ")
    else:
      let firstItem = n.sons[0]
      var startsWithPrGroup = false
      if firstItem.kind == nkPrGroup:
        startsWithPrGroup = true
      elif firstItem.kind == nkFromItemPair and firstItem.len > 0 and firstItem[0].kind == nkPrGroup:
        startsWithPrGroup = true
      if startsWithPrGroup:
        # no space between "from" and "(" -> "from(select...)"
        s.addKeyw(" from")
        ra(firstItem, s)
      else:
        s.addKeyw(" from ")
        ra(firstItem, s)
      for i, item in n.sons:
        if i == 0: continue
        # When item is a join node we render it directly after previous item (no comma)
        if item.kind == nkJoin or item.kind == nkNaturalJoin:
          s.add(" ")
          ra(item, s)
        else:
          s.add(", ")
          ra(item, s)

  of nkFromItemPair:
    ra(n[0], s)
    if n.len > 1:
      s.addKeyw(" as ")
      ra(n[1], s)
  
  of nkWhere:
    s.addKeyw(" where ")
    ra(n[0], s)
  
  of nkJoin:
    # First child holds join kind (ident) e.g. "join", "left outer join", "inner join"
    var joinStr = "join"
    if n.len > 0 and n[0].kind == nkIdent:
      joinStr = n[0].strVal
    s.add(joinStr)

    # next child is the joined table/item. If it starts with a parenthesized
    # subquery (nkPrGroup) we must NOT add a space so we render "join(select...)".
    if n.len > 1:
      let target = n[1]
      var startsWithPrGroup = false
      if target.kind == nkPrGroup:
        startsWithPrGroup = true
      elif target.kind == nkFromItemPair and target.len > 0 and target[0].kind == nkPrGroup:
        startsWithPrGroup = true

      if not startsWithPrGroup:
        s.add(" ")
      ra(target, s)

    # remaining children may be ON (stored as nkWhere) or USING
    for i in 2 ..< n.len:
      let c = n[i]
      if c.kind == nkWhere:
        s.addKeyw(" on ")
        ra(c[0], s)
      elif c.kind == nkUsing:
        s.addKeyw(" using")
        ra(c, s)
      else:
        s.add(" ")
        ra(c, s)

  of nkDot:
    ra(n[0], s)
    s.add(".")
    ra(n[1], s)

  of nkUsing:
    # Render USING(...) without introducing an extra space.
    # If the child is an nkColumnList, render its sons directly with parentheses.
    s.add("(")
    if n.len == 1 and n[0].kind == nkColumnList:
      for i, col in n[0].sons:
        if i > 0: s.add(", ")
        ra(col, s)
    else:
      for i, col in n.sons:
        if i > 0: s.add(", ")
        ra(col, s)
    s.add(")")

  of nkGroup:
    s.addKeyw(" group by ")
    for i, item in n.sons:
      if i > 0: s.add(", ")
      ra(item, s)
  
  of nkHaving:
    s.addKeyw(" having ")
    ra(n[0], s)
  
  of nkOrder:
    s.addKeyw(" order by ")
    for i, item in n.sons:
      if i > 0: s.add(", ")
      ra(item, s)
  
  of nkDesc:
    ra(n[0], s)
    s.addKeyw(" desc")
  
  of nkInsert:
    s.addKeyw("insert into ")
    ra(n[0], s) # table
    if n.len > 1:
      ra(n[1], s) # columns
    if n.len > 2:
      ra(n[2], s) # values
  
  of nkColumnList:
    s.add(" (")
    for i, col in n.sons:
      if i > 0: s.add(", ")
      ra(col, s)
    s.add(")")
  
  of nkValueList:
    s.addKeyw(" values ")
    s.add("(")
    for i, val in n.sons:
      if i > 0: s.add(", ")
      ra(val, s)
    s.add(")")
  
  of nkDelete:
    s.addKeyw("delete from ")
    ra(n[0], s) # table
    if n.len > 1:
      ra(n[1], s) # where

  of nkCreateTable, nkCreateTableIfNotExists:
    s.addKeyw("create table ")
    if n.kind == nkCreateTableIfNotExists:
      s.addKeyw("if not exists ")
    ra(n[0], s) # table name
    if n.len > 1:
      s.add(" (")
      for i, col in n.sons[1..^1]: # skip table name
        if i > 0: s.add(", ")
        ra(col, s)
      s.add(")")

  of nkCreateType, nkCreateTypeIfNotExists:
    s.addKeyw("create ")
    if n.kind == nkCreateTypeIfNotExists:
      s.addKeyw("if not exists ")
    s.addKeyw("type ")
    ra(n[0], s) # type name
    s.addKeyw(" as enum ")
    if n.len > 1:
      ra(n[1], s) # enum def

  of nkEnumDef:
    s.add("(")
    for i, v in n.sons:
      if i > 0: s.add(", ")
      ra(v, s)
    s.add(")")

  of nkCreateIndex, nkCreateIndexIfNotExists:
    s.addKeyw("create ")
    # Determine if the first child is a unique marker
    var idx = 0
    if n.len > 0 and n[0].kind == nkUnique:
      s.addKeyw("unique ")
      idx = 1
    s.addKeyw("index ")
    if n.kind == nkCreateIndexIfNotExists:
      s.addKeyw("if not exists ")
    if idx < n.len:
      ra(n[idx], s) # index name
      inc idx
    if idx < n.len:
      s.addKeyw(" on ")
      ra(n[idx], s) # table name
      inc idx
    # remaining children: column list, where, etc.
    while idx < n.len:
      s.add(" ")
      ra(n[idx], s)
      inc idx

  of nkAsgn:
    # assignment: left = right
    if n.len >= 1:
      ra(n[0], s)
    s.add(" = ")
    if n.len > 1:
      ra(n[1], s)

  of nkUpdate:
    s.addKeyw("update ")
    if n.len > 0:
      ra(n[0], s) # table (and optional alias if present as child[1])
    # assignments expected as next child (nkSelectColumns of nkAsgn)
    if n.len > 1:
      s.addKeyw(" set ")
      ra(n[1], s)
    # optional FROM/WHERE/RETURNING children follow
    for i in 2 ..< n.len:
      let c = n[i]
      # nkFrom, nkWhere, nkSelectColumns (returning)
      if c.kind == nkFrom:
        ra(c, s)
      elif c.kind == nkWhere:
        ra(c, s)
      elif c.kind == nkSelectColumns:
        s.addKeyw(" returning ")
        ra(c, s)
      else:
        s.add(" ")
        ra(c, s)

  of nkCall:
    # callee is first son, remaining sons are arguments
    if n.len > 0:
      ra(n[0], s)
    s.add("(")
    if n.len > 1:
      for i in 1 ..< n.len:
        if i > 1: s.add(", ")
        ra(n[i], s)
    s.add(")")

  of nkColumnDef:
    ra(n[0], s) # column name
    if n.len > 1:
      s.add(" ")
      ra(n[1], s) # datatype
    for i in 2 ..< n.len:
      s.add(" ")
      ra(n[i], s) # constraints
  of nkConstraint:
    if n.len > 0 and n[0].kind == nkIdent:
      s.addKeyw("constraint ")
      s.add(n[0].strVal & " ")
      for i in 1 ..< n.len:
        ra(n[i], s)
    else:
      for i in 0 ..< n.len:
        ra(n[i], s)
  
  of nkPrimaryKey:
    s.addKeyw("primary key")
    if n.len > 0:
      ra(n[0], s) # column list
  
  of nkUnique:
    s.addKeyw("unique")
    if n.len > 0:
      ra(n[0], s) # column list
  
  of nkForeignKey:
    s.addKeyw("foreign key")
    if n.len > 0:
      ra(n[0], s) # column list
    if n.len > 1:
      s.addKeyw(" references ")
      ra(n[1], s) # referenced table
    if n.len > 2:
      ra(n[2], s) # referenced columns
  of nkNotNull:
    s.addKeyw("not null")
  of nkNull:
    s.addKeyw("null")
  of nkDefault:
    s.addKeyw("default ")
    ra(n[0], s)
  of nkCheck:
    s.addKeyw("check (")
    ra(n[0], s)
    s.add(")")
  of nkIdentity:
    s.addKeyw("generated as identity")
  of nkOnUpdate:
    s.addKeyw("on update ")
    ra(n[0], s)
  of nkOnDelete:
    s.addKeyw("on delete ")
    ra(n[0], s)
  of nkDeferrable:
    s.addKeyw("deferrable")
  of nkDropTable, nkDropTableIfExists:
    s.addKeyw("drop table ")
    if n.kind == nkDropTableIfExists:
      s.addKeyw("if exists ")
    if n.len > 0:
      var idx = 0
      while idx < n.len:
        if idx > 0: s.add(", ")
        ra(n.sons[idx], s)
        # if next child is a cascade/restrict modifier, render it immediately
        if idx + 1 < n.len and n.sons[idx+1].kind == nkIdent:
          let mode = n.sons[idx+1].strVal.toLowerAscii
          if mode == "cascade" or mode == "restrict":
            s.add(" ")
            ra(n.sons[idx+1], s)
            inc idx
        inc idx
  of nkDropType, nkDropTypeIfExists:
    s.addKeyw("drop type ")
    if n.kind == nkDropTypeIfExists:
      s.addKeyw("if exists ")
    if n.len > 0:
      var idx = 0
      while idx < n.len:
        if idx > 0: s.add(", ")
        ra(n.sons[idx], s)
        if idx + 1 < n.len and n.sons[idx+1].kind == nkIdent:
          let mode = n.sons[idx+1].strVal.toLowerAscii
          if mode == "cascade" or mode == "restrict":
            s.add(" ")
            ra(n.sons[idx+1], s)
            inc idx
        inc idx
  of nkDropIndex, nkDropIndexIfExists:
    s.addKeyw("drop index ")
    if n.kind == nkDropIndexIfExists:
      s.addKeyw("if exists ")
    if n.len > 0:
      var idx = 0
      while idx < n.len:
        if idx > 0: s.add(", ")
        ra(n.sons[idx], s)
        if idx + 1 < n.len and n.sons[idx+1].kind == nkIdent:
          let mode = n.sons[idx+1].strVal.toLowerAscii
          if mode == "cascade" or mode == "restrict":
            s.add(" ")
            ra(n.sons[idx+1], s)
            inc idx
        inc idx
  of nkDropView, nkDropViewIfExists:
    s.addKeyw("drop view ")
    if n.kind == nkDropViewIfExists:
      s.addKeyw("if exists ")
    if n.len > 0:
      var idx = 0
      while idx < n.len:
        if idx > 0: s.add(", ")
        ra(n.sons[idx], s)
        if idx + 1 < n.len and n.sons[idx+1].kind == nkIdent:
          let mode = n.sons[idx+1].strVal.toLowerAscii
          if mode == "cascade" or mode == "restrict":
            s.add(" ")
            ra(n.sons[idx+1], s)
            inc idx
        inc idx
  of nkAlterTable:
    s.addKeyw("alter table ")
    if n.len > 0:
      ra(n[0], s) # table name
    for i in 1 ..< n.len:
      let c = n[i]
      if c.kind == nkAlterAddColumn or c.kind == nkAlterAddConstraint:
        s.addKeyw(" add ")
        ra(c[0], s)
      elif c.kind == nkAlterDropColumn:
        s.addKeyw(" drop column ")
        ra(c[0], s)
      elif c.kind == nkAlterAlterColumn:
        s.addKeyw(" alter column ")
        ra(c[0], s)
      elif c.kind == nkAlterRenameColumn:
        s.addKeyw(" rename column ")
        ra(c[0], s)
      elif c.kind == nkAlterRenameTable:
        s.addKeyw(" rename to ")
        ra(c[0], s)
  of nkLimit:
    s.addKeyw(" limit ")
    ra(n[0], s)
  of nkOffset:
    s.addKeyw(" offset ")
    ra(n[0], s)
  of nkPrGroup:
    # handle parenthesized groups (e.g. in expressions, subqueries or parenthesized
    # table expressions). If the child is an nkFrom, render its items without
    # emitting the leading "from" keyword (so "(b join c ...)" not "( from b ...)" )
    s.add("(")
    for i, child in n.sons:
      if i > 0: s.add(" ")
      if child.kind == nkFrom:
        # render inner FROM contents WITHOUT the leading "from" keyword
        if child.len == 0:
          # nothing inside
          continue
        let firstItem = child.sons[0]
        var startsWithPrGroup = false
        if firstItem.kind == nkPrGroup:
          startsWithPrGroup = true
        elif firstItem.kind == nkFromItemPair and
             firstItem.len > 0 and firstItem[0].kind == nkPrGroup:
          startsWithPrGroup = true

        # render first item directly (no "from" prefix)
        ra(firstItem, s)

        # render remaining items / joins similar to nkFrom but without "from"
        for j, item in child.sons:
          if j == 0: continue
          if item.kind == nkJoin or item.kind == nkNaturalJoin:
            s.add(" ")
            ra(item, s)
          else:
            s.add(", ")
            ra(item, s)
      else:
        ra(child, s)
    s.add(")")
  of nkPlaceholder:
    s.add(n.strVal)
  else:
    s.add("/* unhandled node kind: " & $n.kind & " */")

proc renderSql*(n: SqlNode, upperCase = false): string =
  ## Converts an SQL abstract syntax tree to its string representation.
  var s = SqlWriter(buffer: "", upperCase: upperCase)
  ra(n, s)
  return s.buffer

proc `$`*(n: SqlNode): string =
  ## Convert a SQL AST node back into a SQL string. This is primarily for testing/debugging
  ## to verify that parsing and rendering are consistent.
  renderSql(n)

proc treeReprAux(s: SqlNode, level: int, result: var string) =
  result.add('\n')
  for i in 0 ..< level: result.add("  ")

  result.add($s.kind)
  if s.kind in LiteralNodes:
    result.add(' ')
    result.add(s.strVal)
  else:
    for son in s.sons:
      treeReprAux(son, level + 1, result)

proc treeRepr*(s: SqlNode): string =
  ## Return a multi-line string representation of the SQL AST tree structure, for
  ## debugging/visualization.
  result = newStringOfCap(128)
  treeReprAux(s, 0, result)
