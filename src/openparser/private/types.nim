import std/[tables, options, macros]

type
  Integers* = int | int8 | int16 | int32 | int64 | uint8 | uint16 | uint32 | uint64 | uint
    ## A union type representing all integer types in Nim,
    ## both signed and unsigned.

  AnyTable*[K, V] =
    Table[K, V] | OrderedTable[K, V] | TableRef[K, V] | OrderedTableRef[K, V]
    ## A union type representing various table types in Nim,
    ## allowing for flexible use of different table implementations.
  
  OpenLexer* = object of RootObj
    ## A base type for lexers, containing common fields for tracking
    ## the input string and the current position in the parsing process.
    len*: int
    pos*, line*, col*: int
    current*: char
    input*: string
  
  OpenToken* = object of RootObj
    ## A base type for tokens produced by the lexer, containing fields
    value*: string
    line*, col*, pos*, wsno*: int


#
# JSONY object variants utility macros
# https://github.com/treeform/jsony
#
proc hasKind*(node: NimNode, kind: NimNodeKind): bool =
  for c in node.children:
    if c.kind == kind:
      return true
  return false

proc `[]`*(node: NimNode, kind: NimNodeKind): NimNode =
  for c in node.children:
    if c.kind == kind:
      return c
  return nil

template fieldPairs*[T: ref object](x: T): untyped =
  x[].fieldPairs

macro isObjectVariant*(v: typed): bool =
  # Is this an object variant?
  var typ = v.getTypeImpl()
  if typ.kind == nnkSym:
    return ident("false")
  while typ.kind != nnkObjectTy:
    typ = typ[0].getTypeImpl()
  if typ[2].hasKind(nnkRecCase):
    ident("true")
  else:
    ident("false")

proc discriminator*(v: NimNode): NimNode =
  var typ = v.getTypeImpl()
  while typ.kind != nnkObjectTy:
    typ = typ[0].getTypeImpl()
  return typ[nnkRecList][nnkRecCase][nnkIdentDefs][nnkSym]

macro discriminatorFieldName*(v: typed): untyped =
  # Turns into the discriminator field.
  return newLit($discriminator(v))

macro discriminatorField*(v: typed): untyped =
  # Turns into the discriminator field.
  let
    fieldName = discriminator(v)
  return quote do:
    `v`.`fieldName`

macro new*(v: typed, d: typed): untyped =
  # Creates a new object variant with the discriminator field.
  let
    typ = v.getTypeInst()
    fieldName = discriminator(v)
  return quote do:
    `v` = `typ`(`fieldName`: `d`)