import std/unittest
import ../src/openparser/uuid

test "v3 matches RFC 4122 test vector":
  check $newUuidV3(nsDNS, "www.example.com") ==
    "5df41881-3aed-3515-88a7-2f4a814cf09e"

test "v5 matches RFC 4122 test vector":
  check $newUuidV5(nsDNS, "www.example.com") ==
    "2ed6657d-e927-568b-95e1-2665a8aea6a2"

test "v5 with explicit namespace UUID equals named alias":
  let a = newUuidV5(parseUuid("6ba7b810-9dad-11d1-80b4-00c04fd430c8"),
                    "www.example.com")
  check $a == $newUuidV5(nsDNS, "www.example.com")

test "v1, v2, v6 versions and variants":
  check version(newUuidV1()) == 1
  check version(newUuidV6()) == 6
  check version(newUuidV2(0, 1000)) == 2
  check variant(newUuidV4()) == variantRFC4122

test "v4, v7, v8 and nil":
  check isValidUuid($newUuidV4())
  check version(newUuidV7()) == 7
  let v8 = newUuidV8(parseUuid("0123456789abcdef0123456789abcdef").bytes)
  check version(v8) == 8
  check variant(v8) == variantRFC4122
  check isNil(nilUuid())
  check $nilUuid() == "00000000-0000-0000-0000-000000000000"

test "parse rejects garbage":
  check isValidUuid("6ba7b810-9dad-11d1-80b4-00c04fd430c8")
  check not isValidUuid("nope")
  expect UuidError:
    discard parseUuid("nope")
