import std/[unittest, strformat, os, times]
import ../src/openparser/fbe

suite "FBE header wiring":
  test "root header round-trip and field read" :
    var b = initBuffer()
    b.reset()
    # write root struct with one int32 field (id=1, value=12345)
    beginRootStruct(b, 1'u32)
    writeField(b, 1'u16, proc (bb: var Buffer) =
      bb.writeInt32LE(12345'i32)
    )
    endRootStruct(b)

    b.pos = 0
    let ver = beginReadRootStruct(b)
    check ver == 1'u32
    var fid: uint16
    var fsz: int
    check readFieldHeader(b, fid, fsz)
    check fid == 1'u16
    let v = readFieldValue[int32](b, fsz, proc (bb: var Buffer): int32 =
      bb.readInt32LE()
    )
    check v == 12345'i32
    endReadRootStruct(b)

  test "inner struct header wiring" :
    var b = initBuffer()
    b.reset()
    beginRootStruct(b, 2'u32)
    # write inner struct as a field (fieldId = 10)
    writeField(b, 10'u16, proc (bb: var Buffer) =
      beginInnerStruct(bb, 7'u32)
      writeField(bb, 5'u16, proc (bbb: var Buffer) =
        bbb.writeInt16LE(32000'i16)
      )
      endInnerStruct(bb)
    )
    endRootStruct(b)

    b.pos = 0
    let vroot = beginReadRootStruct(b)
    check vroot == 2'u32
    var fid: uint16
    var fsz: int
    check readFieldHeader(b, fid, fsz)
    check fid == 10'u16
    # read inner struct from field payload
    let innerVer = beginReadInnerStruct(b)
    check innerVer == 7'u32
    check readFieldHeader(b, fid, fsz)
    check fid == 5'u16
    let innerVal = readFieldValue[int16](b, fsz, proc (bb: var Buffer): int16 =
      bb.readInt16LE()
    )
    check innerVal == 32000'i16
    endReadInnerStruct(b)
    endReadRootStruct(b)

proc bufferToFile(b: Buffer; path: string) =
  let n = b.data.len
  var s = newStringOfCap(n)
  s.setLen(n)
  if n > 0:
    copyMem(cast[ptr uint8](addr s[0]), addr b.data[0], n)
  writeFile(path, s)

proc fileToBuffer(path: string): Buffer =
  let s = readFile(path)
  let n = s.len
  result.data = newSeq[uint8](n)
  if n > 0:
    copyMem(addr result.data[0], cast[ptr uint8](addr s[0]), n)
  result.pos = 0

suite "FBE additional features and disk IO":
  test "complex types and disk round-trip":
    var b = initBuffer()
    b.reset()

    # build root struct with a handful of fields
    beginRootStruct(b, 42'u32)
    # int32 field
    writeField(b, 1'u16, proc (bb: var Buffer) = bb.writeInt32LE(2021'i32))
    # string field
    writeField(b, 2'u16, proc (bb: var Buffer) = bb.writeString("hello"))
    # uuid field (16 bytes)
    writeField(b, 3'u16, proc (bb: var Buffer) =
      var u = newSeq[uint8](16)
      for i in 0..<16: u[i] = uint8(i + 1)
      bb.writeUUID(u)
    )
    # timestamp
    writeField(b, 4'u16, proc (bb: var Buffer) = bb.writeTimestamp(123456789012345'u64))
    # vector<int32>
    writeField(b, 5'u16, proc (bb: var Buffer) =
      let items = @[10'i32, 20'i32, 30'i32]
      writeVector[int32](bb, items, proc (bbb: var Buffer; v: int32) = bbb.writeInt32LE(v))
    )
    # decimal (16 bytes)
    writeField(b, 6'u16, proc (bb: var Buffer) =
      var dec = newSeq[uint8](16)
      for i in 0..<16: dec[i] = 0xAB'u8
      bb.writeDecimal(dec)
    )
    endRootStruct(b)

    # save to disk
    let path = "tests/data/fbe_test.bin"
    if fileExists(path): removeFile(path)
    bufferToFile(b, path)
    check fileExists(path)

    # read back into a fresh buffer
    var b2 = fileToBuffer(path)
    b2.pos = 0

    let ver = beginReadRootStruct(b2)
    check ver == 42'u32

    var fid: uint16
    var fsz: int

    # int32
    check readFieldHeader(b2, fid, fsz)
    check fid == 1'u16
    let i32v = readFieldValue[int32](b2, fsz, proc (bb: var Buffer): int32 = bb.readInt32LE())
    check i32v == 2021'i32

    # string
    check readFieldHeader(b2, fid, fsz)
    check fid == 2'u16
    let s = readFieldValue[string](b2, fsz, proc (bb: var Buffer): string = bb.readString())
    check s == "hello"

    # uuid
    check readFieldHeader(b2, fid, fsz)
    check fid == 3'u16
    let u = readFieldValue[seq[uint8]](b2, fsz, proc (bb: var Buffer): seq[uint8] = bb.readUUID())
    check u.len == 16
    check u[0] == 1'u8 and u[15] == 16'u8

    # timestamp
    check readFieldHeader(b2, fid, fsz)
    check fid == 4'u16
    let ts = readFieldValue[uint64](b2, fsz, proc (bb: var Buffer): uint64 = bb.readTimestamp())
    check ts == 123456789012345'u64

    # vector
    check readFieldHeader(b2, fid, fsz)
    check fid == 5'u16
    let vec = readFieldValue[seq[int32]](b2, fsz, proc (bb: var Buffer): seq[int32] =
      readVector[int32](bb, proc (bbb: var Buffer): int32 = bbb.readInt32LE())
    )
    check vec.len == 3 and vec[0] == 10 and vec[2] == 30

    # decimal
    check readFieldHeader(b2, fid, fsz)
    check fid == 6'u16
    let dec = readFieldValue[seq[uint8]](b2, fsz, proc (bb: var Buffer): seq[uint8] = bb.readDecimal())
    check dec.len == 16
    for by in dec: check by == 0xAB'u8

    endReadRootStruct(b2)

  test "readFieldHeader returns false when no fields left":
    var b3 = initBuffer()
    b3.reset()
    beginRootStruct(b3, 1'u32)
    endRootStruct(b3)
    b3.pos = 0
    discard beginReadRootStruct(b3)
    var fid2: uint16
    var fsz2: int
    check not readFieldHeader(b3, fid2, fsz2)
    endReadRootStruct(b3)

  test "readFieldHeader returns false when no fields left":
    var b3 = initBuffer()
    b3.reset()
    beginRootStruct(b3, 1'u32)
    endRootStruct(b3)
    b3.pos = 0
    discard beginReadRootStruct(b3)
    var fid2: uint16
    var fsz2: int
    check not readFieldHeader(b3, fid2, fsz2)
    endReadRootStruct(b3)

  test "utf8 multi-byte string round-trip (emoji)" :
    var b = initBuffer()
    b.reset()
    let utf8s = "hello 🌍🌟 — 🚀"
    beginRootStruct(b, 100'u32)
    writeField(b, 1'u16, proc (bb: var Buffer) =
      bb.writeString(utf8s)
    )
    endRootStruct(b)

    let path = "tests/data/fbe_utf8_test.bin"
    if fileExists(path): removeFile(path)
    bufferToFile(b, path)
    check fileExists(path)

    var b2 = fileToBuffer(path)
    b2.pos = 0
    discard beginReadRootStruct(b2)
    var fid: uint16
    var fsz: int
    check readFieldHeader(b2, fid, fsz)
    check fid == 1'u16
    let outp = readFieldValue[string](b2, fsz, proc (bb: var Buffer): string =
      bb.readString()
    )
    check outp == utf8s
    endReadRootStruct(b2)

type
  Person* = object
    name*: string
    age*: int32
    bioEmojis*: string

# Writer: emits fields for a Person using writeField(...)
proc writePersonFields(b: var Buffer; p: Person) =
  writeField(b, 1'u16, proc (bb: var Buffer) = bb.writeString(p.name))
  writeField(b, 2'u16, proc (bb: var Buffer) = bb.writeInt32LE(p.age))
  writeField(b, 3'u16, proc (bb: var Buffer) = bb.writeString(p.bioEmojis))

# Reader handler: assign fields into Person via decodeRootInto
proc handlePersonField(fieldId: uint16; fieldSize: int; b: var Buffer; p: var Person) =
  case fieldId:
  of 1'u16:
    p.name = readFieldValue[string](b, fieldSize, proc (bb: var Buffer): string = bb.readString())
  of 2'u16:
    p.age = readFieldValue[int32](b, fieldSize, proc (bb: var Buffer): int32 = bb.readInt32LE())
  of 3'u16:
    p.bioEmojis = readFieldValue[string](b, fieldSize, proc (bb: var Buffer): string = bb.readString())
  else:
    # unknown field -> do nothing (decodeRootInto will skip unread bytes)
    discard

suite "FBE encode/decode helpers":
  test "encodeRootFrom + decodeRootInto round-trip (in-memory)":
    var p = Person(name: "Alice", age: 30'i32, bioEmojis: "hello 🌍🌟 — 🚀")
    var b = initBuffer()
    b.reset()
    encodeRootFrom(b, p, writePersonFields, 7'u32)

    # decode into fresh object
    var pers = Person()
    b.pos = 0
    var ver: uint32 = 0
    decodeRootInto(b, pers, handlePersonField, ver)
    check ver == 7'u32
    check pers.name == p.name
    check pers.age == p.age
    check pers.bioEmojis == p.bioEmojis

  test "encodeRootFrom -> write file -> decodeRootInto (disk round-trip)":
    var p = Person(name: "Bob", age: 45'i32, bioEmojis: "🙂🚀👍")
    var b = initBuffer()
    b.reset()
    encodeRootFrom(b, p, writePersonFields, 2'u32)

    let path = "tests/data/fbe_person_test.bin"
    if fileExists(path): removeFile(path)
    bufferToFile(b, path)
    check fileExists(path)

    var b2 = fileToBuffer(path)
    b2.pos = 0
    var out2 = Person()
    var ver2: uint32 = 0
    fbe.decode(b2, out2, ver2)
    check ver2 == 2'u32
    check out2.name == p.name
    check out2.age == p.age
    check out2.bioEmojis == p.bioEmojis

proc personFieldId(name: string): uint16 =
  if name == "name": 1'u16
  elif name == "age": 2'u16
  elif name == "bioEmojis": 3'u16
  else: 0'u16

proc personFieldIdSkipBio(name: string): uint16 =
  if name == "name": 1'u16
  elif name == "age": 2'u16
  else: 0'u16

suite "FBE high-level encode API":
  test "encode(obj, mapper) -> decodeRootInto (in-memory)":
    var p = Person(name: "Alice", age: 30'i32, bioEmojis: "hello 🌍🌟 — 🚀")
    let buf = encode(p, 7'u32, personFieldId)
    check buf.data.len > 0

    var pers = Person()
    var tmp = buf
    tmp.pos = 0
    var ver: uint32 = 0
    decodeRootInto(tmp, pers, handlePersonField, ver)
    check ver == 7'u32
    check pers.name == p.name
    check pers.age == p.age
    check pers.bioEmojis == p.bioEmojis

  test "encodeAuto(obj) -> field ids 1..n and values match":
    var p2 = Person(name: "Bob", age: 45'i32, bioEmojis: "🙂🚀👍")
    let buf2 = fbe.encode(p2, 2'u32)
    check buf2.data.len > 0

    var r = buf2
    r.pos = 0
    let ver2 = beginReadRootStruct(r)
    check ver2 == 2'u32

    var fid: uint16
    var fsz: int

    # id 1 -> name
    check readFieldHeader(r, fid, fsz)
    check fid == 1'u16
    let name = readFieldValue[string](r, fsz, proc (bb: var Buffer): string = bb.readString())
    check name == p2.name

    # id 2 -> age
    check readFieldHeader(r, fid, fsz)
    check fid == 2'u16
    let age = readFieldValue[int32](r, fsz, proc (bb: var Buffer): int32 = bb.readInt32LE())
    check age == p2.age

    # id 3 -> bioEmojis
    check readFieldHeader(r, fid, fsz)
    check fid == 3'u16
    let bio = readFieldValue[string](r, fsz, proc (bb: var Buffer): string = bb.readString())
    check bio == p2.bioEmojis

    endReadRootStruct(r)

  test "encode(obj, mapper) skips unmapped fields (disk round-trip)":
    var p3 = Person(name: "Carol", age: 28'i32, bioEmojis: "✨")
    let path = "tests/data/fbe_highlevel_skip.bin"
    if fileExists(path): removeFile(path)

    let buf3 = encode(p3, 3'u32, personFieldIdSkipBio)
    bufferToFile(buf3, path)
    check fileExists(path)

    var b4 = fileToBuffer(path)
    b4.pos = 0
    var out3 = Person()
    var ver3: uint32 = 0
    decodeRootInto(b4, out3, handlePersonField, ver3)
    check ver3 == 3'u32
    check out3.name == p3.name
    check out3.age == p3.age
    # bioEmojis was skipped -> default empty
    check out3.bioEmojis == ""

suite "Benchmark encode/decode performance":
  let count = 10000
  var people = newSeq[Person](count)
  var start: float
  for i in 0..<count:
    people[i] = Person(name: fmt"Person {i}", age: int32(20 + i mod 50), bioEmojis: "🙂🚀")
  
  test "encode and decode a large number of objects" :
    # benchmark encoding
    start = cpuTime()
    let buf = encode(people, 1'u32, proc (fieldName: string): uint16 =
      if fieldName == "name": 1'u16
      elif fieldName == "age": 2'u16
      elif fieldName == "bioEmojis": 3'u16
      else: 0'u16
    )
    var encodeTime = cpuTime() - start
    echo fmt"Encoded {count} people in {encodeTime:.3f} seconds, size={buf.data.len} bytes"

    # benchmark decoding
    start = cpuTime()
    var decodedPeople = newSeq[Person](count)
    var tmp = buf
    tmp.pos = 0
    let ver = beginReadRootStruct(tmp)
    check ver == 1'u32

    var fid: uint16
    var fsz: int

    for i in 0..<count:
      var p = Person()
      while readFieldHeader(tmp, fid, fsz):
        handlePersonField(fid, fsz, tmp, p)
      decodedPeople[i] = p

    endReadRootStruct(tmp)
    var decodeTime = cpuTime() - start
    echo fmt"Decoded {count} people in {decodeTime:.3f} seconds"
  
  test "encode and decode a large number of objects (disk)":
    let path = "tests/data/fbe_benchmark.bin"
    if fileExists(path): removeFile(path)

    # benchmark encoding to disk
    var start = cpuTime()
    let buf = encode(people, 1'u32, proc (fieldName: string): uint16 =
      if fieldName == "name": 1'u16
      elif fieldName == "age": 2'u16
      elif fieldName == "bioEmojis": 3'u16
      else: 0'u16
    )
    bufferToFile(buf, path)
    var encodeTime = cpuTime() - start
    echo fmt"Encoded {count} people to disk in {encodeTime} seconds, size={buf.data.len} bytes"

    # benchmark decoding from disk
    start = cpuTime()
    var b2 = fileToBuffer(path)
    b2.pos = 0
    let ver = beginReadRootStruct(b2)
    check ver == 1'u32

    var fid: uint16
    var fsz: int

    for i in 0..<count:
      var p = Person()
      while readFieldHeader(b2, fid, fsz):
        handlePersonField(fid, fsz, b2, p)
      # optionally store decoded people in a sequence to verify correctness
      # decodedPeople[i] = p

    endReadRootStruct(b2)
    var decodeTime = cpuTime() - start
    echo fmt"Decoded {count} people from disk in {decodeTime} seconds"

suite "FBE final/compact API":
  type
    PersonFinal = object
      name*: string
      age*: int32
      bioEmojis*: string

  proc makePerson(n: string; a: int32; b: string): PersonFinal =
    PersonFinal(name: n, age: a, bioEmojis: b)

  test "final root header patched and object round-trip (encodeFinal/decodeFinal)":
    var p = makePerson("Alice", 30'i32, "🙂🚀")
    let buf = encodeFinal(p)
    check buf.data.len > 0

    # totalSize is written LE at offset 0; should equal buffer length
    let hdr = uint32(buf.data[0]) or (uint32(buf.data[1]) shl 8) or (uint32(buf.data[2]) shl 16) or (uint32(buf.data[3]) shl 24)
    check hdr == uint32(buf.data.len)

    var decoded = PersonFinal()
    var tmp = buf
    tmp.pos = 0
    decodeFinal(tmp, decoded)
    check decoded.name == p.name
    check decoded.age == p.age
    check decoded.bioEmojis == p.bioEmojis

  test "encodeFinal/decodeFinal for sequence of compact structs":
    var people = @[
      makePerson("P1", 10'i32, "🙂"),
      makePerson("P2", 20'i32, "🚀"),
      makePerson("P3", 30'i32, "👍")
    ]
    let buf = encodeFinal(people)
    check buf.data.len > FINAL_ROOT_HEADER_SIZE

    # verify header totalSize
    let hdr = uint32(buf.data[0]) or (uint32(buf.data[1]) shl 8) or (uint32(buf.data[2]) shl 16) or (uint32(buf.data[3]) shl 24)
    check hdr == uint32(buf.data.len)

    var pers: seq[PersonFinal]
    var tmp = buf
    tmp.pos = 0
    decodeFinal(tmp, pers)
    check pers.len == people.len
    for i in 0..<pers.len:
      check pers[i].name == people[i].name
      check pers[i].age == people[i].age
      check pers[i].bioEmojis == people[i].bioEmojis
