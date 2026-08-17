import std/[unittest, tables, os, strutils]
import ../src/openparser/gettext/[po, mo]

proc writeTempPo(content: string): string =
  let tmp = getTempDir() / "test_gettext.po"
  writeFile(tmp, content)
  tmp

suite "gettext .po parser and compiler":

  test "PO headers are parsed":
    let po = """
  msgid ""
  msgstr ""
  "Project-Id-Version: Lingohub 1.0.1\n"
  "Report-Msgid-Bugs-To: support@lingohub.com \n"
  "Last-Translator: Marko Bošković <marko@lingohub.com>\n"
  "Language: de\n"
  "MIME-Version: 1.0\n"
  "Content-Type: text/plain; charset=UTF-8\n"
  "Content-Transfer-Encoding: 8bit\n"
  "Plural-Forms: nplurals=2; plural=(n != 1);\n"
  """
    let path = writeTempPo(po)
    let cat = openPoCatalog(path)
    let h = parsePoHeaders(cat)
    check h.hasKey("Language")
    check h["Language"] == "de"
    check h.hasKey("Plural-Forms")
    close(cat)
    removeFile(path)

  test "English plural (n != 1)":
    let po = """
msgid ""
msgstr ""
"Plural-Forms: nplurals=2; plural=(n != 1);\n"

msgid "apple"
msgid_plural "apples"
msgstr[0] "apple"
msgstr[1] "apples"
"""
    let path = writeTempPo(po)
    let cat = openPoCatalog(path)
    let cc = compilePo(cat)
    check cc.nplurals == 2
    check cc.pluralIndex(1) == 0
    check cc.pluralIndex(2) == 1
    check cc.ntranslate("apple", "apples", 1) == "apple"
    check cc.ntranslate("apple", "apples", 2) == "apples"
    close(cat)
    removeFile(path)

  test "French plural (n > 1)":
    let po = """
msgid ""
msgstr ""
"Plural-Forms: nplurals=2; plural=(n > 1);\n"

msgid "voiture"
msgid_plural "voitures"
msgstr[0] "voiture"
msgstr[1] "voitures"
"""
    let path = writeTempPo(po)
    let cat = openPoCatalog(path)
    let cc = compilePo(cat)
    check cc.nplurals == 2
    check cc.pluralIndex(1) == 0
    check cc.pluralIndex(2) == 1
    check cc.ntranslate("voiture", "voitures", 1) == "voiture"
    check cc.ntranslate("voiture", "voitures", 2) == "voitures"
    close(cat)
    removeFile(path)

  test "Russian plural (complex logic)":
    let po = """
msgid ""
msgstr ""
"Plural-Forms: nplurals=3; plural=(n%10==1 && n%100!=11 ? 0 : n%10>=2 && n%10<=4 && (n%100<10 || n%100>=20) ? 1 : 2);\n"

msgid "товар"
msgid_plural "товара"
msgstr[0] "товар"
msgstr[1] "товара"
msgstr[2] "товаров"
"""
    let path = writeTempPo(po)
    let cat = openPoCatalog(path)
    let cc = compilePo(cat)
    check cc.nplurals == 3
    check cc.pluralIndex(1) == 0
    check cc.pluralIndex(2) == 1
    check cc.pluralIndex(5) == 2
    check cc.ntranslate("товар", "товара", 1) == "товар"
    check cc.ntranslate("товар", "товара", 2) == "товара"
    check cc.ntranslate("товар", "товара", 5) == "товаров"
    close(cat)
    removeFile(path)

  test "Slovenian plural (arithmetic, logic, ternary)":
    let po = """
msgid ""
msgstr ""
"Plural-Forms: nplurals=4; plural=(n%100==1 ? 0 : n%100==2 ? 1 : n%100==3 || n%100==4 ? 2 : 3);\n"

msgid "dan"
msgid_plural "dni"
msgstr[0] "dan"
msgstr[1] "dneva"
msgstr[2] "dnevi"
msgstr[3] "dni"
"""
    let path = writeTempPo(po)
    let cat = openPoCatalog(path)
    let cc = compilePo(cat)
    check cc.nplurals == 4
    check cc.pluralIndex(1) == 0
    check cc.pluralIndex(2) == 1
    check cc.pluralIndex(3) == 2
    check cc.pluralIndex(5) == 3
    check cc.ntranslate("dan", "dni", 1) == "dan"
    check cc.ntranslate("dan", "dni", 2) == "dneva"
    check cc.ntranslate("dan", "dni", 3) == "dnevi"
    check cc.ntranslate("dan", "dni", 5) == "dni"
    close(cat)
    removeFile(path)

  test "Fuzzy and obsolete entries are skipped":
    let po = """
msgid ""
msgstr ""
"Plural-Forms: nplurals=2; plural=(n != 1);\n"

#~ msgid "old"
#~ msgstr "alt"

#, fuzzy
msgid "fuzzy"
msgstr "fuzzy-translation"

msgid "ok"
msgstr "fine"
"""
    let path = writeTempPo(po)
    let cat = openPoCatalog(path)
    let cc = compilePo(cat)
    check cc.translate("ok") == "fine"
    check cc.translate("old") == "old"
    check cc.translate("fuzzy") == "fuzzy"
    close(cat)
    removeFile(path)

  test "compile po to mo and read back":
    let po = """
  msgid ""
  msgstr ""
  "Language: en\n"
  "Plural-Forms: nplurals=2; plural=(n != 1);\n"

  msgid "cat"
  msgid_plural "cats"
  msgstr[0] "cat"
  msgstr[1] "cats"

  msgctxt "menu"
  msgid "File"
  msgstr "Datei"
  """
    let popath = writeTempPo(po)
    let cat = openPoCatalog(popath)
    let cc = compilePo(cat)
    let mopath = getTempDir() / "test_gettext_out.mo"
    writeMoFile(cc, mopath)
    close(cat)

    # Now read back with mo parser
    var mocat = openMoCatalog(mopath)
    check mocat.headers.hasKey("Language")
    check mocat.headers["Language"] == "en"
    check mocat.nStrings == 3
    check mocat.translate("cat") == "cat"
    check mocat.form("cat", 1) == "cats"
    check mocat.translate("File", "menu") == "Datei"
    close(mocat)
    removeFile(popath)
    removeFile(mopath)

type
  MoPair = tuple[orig: string, trans: string]

proc putU32Le(buf: var string; v: uint32) =
  buf.add char(v and 0xFF)
  buf.add char((v shr 8) and 0xFF)
  buf.add char((v shr 16) and 0xFF)
  buf.add char((v shr 24) and 0xFF)

proc buildMoLe(pairs: seq[MoPair]): string =
  ## Minimal GNU MO (little-endian), no hash table.
  let n = pairs.len
  let headerSize = 7 * 4
  let offOrig = headerSize
  let offTrans = offOrig + n * 8
  let poolStart = offTrans + n * 8

  var origLens = newSeq[int](n)
  var transLens = newSeq[int](n)
  var origOffs = newSeq[int](n)
  var transOffs = newSeq[int](n)

  var pool = newStringOfCap(1024)
  var p = poolStart

  for i, it in pairs:
    origLens[i] = it.orig.len
    origOffs[i] = p
    pool.add it.orig
    p += it.orig.len

  for i, it in pairs:
    transLens[i] = it.trans.len
    transOffs[i] = p
    pool.add it.trans
    p += it.trans.len

  result = newStringOfCap(poolStart + pool.len)
  # header
  putU32Le(result, 0x950412DE'u32)           # magic LE
  putU32Le(result, 0'u32)                    # revision
  putU32Le(result, uint32(n))                # nstrings
  putU32Le(result, uint32(offOrig))          # orig table offset
  putU32Le(result, uint32(offTrans))         # trans table offset
  putU32Le(result, 0'u32)                    # hash size
  putU32Le(result, 0'u32)                    # hash offset

  # orig table
  for i in 0 ..< n:
    putU32Le(result, uint32(origLens[i]))
    putU32Le(result, uint32(origOffs[i]))

  # trans table
  for i in 0 ..< n:
    putU32Le(result, uint32(transLens[i]))
    putU32Le(result, uint32(transOffs[i]))

  result.add pool

proc writeTempMo(bytes: string; name = "test_gettext.mo"): string =
  let path = getTempDir() / name
  writeFile(path, bytes)
  path

suite ".mo parser and compiler":

  test "parse headers + simple translate":
    let hdr =
      "Project-Id-Version: test\n" &
      "Language: de\n" &
      "Plural-Forms: nplurals=2; plural=(n != 1);\n"

    let bytes = buildMoLe(@[
      (orig: "", trans: hdr),
      (orig: "hello", trans: "hallo")
    ])

    let path = writeTempMo(bytes, "mo_basic.mo")
    var cat = openMoCatalog(path)
    check cat.headers.hasKey("Language")
    check cat.headers["Language"] == "de"
    check cat.translate("hello") == "hallo"
    check cat.translate("missing") == "missing"
    close(cat)
    removeFile(path)

  test "context and plural forms":
    let hdr =
      "Language: en\n" &
      "Plural-Forms: nplurals=2; plural=(n != 1);\n"

    let bytes = buildMoLe(@[
      (orig: "", trans: hdr),
      (orig: "menu" & '\x04' & "File", trans: "Datei"),
      (orig: "apple" & '\0' & "apples", trans: "apple" & '\0' & "apples")
    ])

    let path = writeTempMo(bytes, "mo_ctx_plural.mo")
    var cat = openMoCatalog(path)
    check cat.translate("File", "menu") == "Datei"
    check cat.form("apple", 0) == "apple"
    check cat.form("apple", 1) == "apples"

    let cc = compileMo(cat)
    check cc.nplurals == 2
    check cc.pluralIndex(1) == 0
    check cc.pluralIndex(2) == 1
    check cc.ntranslate("apple", "apples", 1) == "apple"
    check cc.ntranslate("apple", "apples", 2) == "apples"
    close(cat)
    removeFile(path)

  test "complex plural formula (Russian)":
    let hdr =
      "Language: ru\n" &
      "Plural-Forms: nplurals=3; plural=(n%10==1 && n%100!=11 ? 0 : n%10>=2 && n%10<=4 && (n%100<10 || n%100>=20) ? 1 : 2);\n"

    let bytes = buildMoLe(@[
      (orig: "", trans: hdr),
      (orig: "товар" & '\0' & "товара", trans: "товар" & '\0' & "товара" & '\0' & "товаров")
    ])

    let path = writeTempMo(bytes, "mo_ru.mo")
    var cat = openMoCatalog(path)
    let cc = compileMo(cat)
    check cc.nplurals == 3
    check cc.pluralIndex(1) == 0
    check cc.pluralIndex(2) == 1
    check cc.pluralIndex(5) == 2
    check cc.ntranslate("товар", "товара", 1) == "товар"
    check cc.ntranslate("товар", "товара", 2) == "товара"
    check cc.ntranslate("товар", "товара", 5) == "товаров"
    close(cat)
    removeFile(path)

  test "reject invalid magic":
    var bad = newString(28)
    # keep all zeros => invalid magic, valid length
    let path = writeTempMo(bad, "mo_bad_magic.mo")
    expect MoParseError:
      discard openMoCatalog(path)
    removeFile(path)