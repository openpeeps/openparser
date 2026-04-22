import std/[tables, options]

type
  Integers* = int | int8 | int16 | int32 | int64 | uint8 | uint16 | uint32 | uint64 | uint
    ## A union type representing all integer types in Nim,
    ## both signed and unsigned.

  AnyTable*[K, V] =
    Table[K, V] | OrderedTable[K, V] | TableRef[K, V] | OrderedTableRef[K, V]
    ## A union type representing various table types in Nim,
    ## allowing for flexible use of different table implementations.