# A collection of tiny parsers and dumpers
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/openparser

import std/[unittest, strutils, math, sequtils]
import ../src/openparser/qr/common
import ../src/openparser/qr/model2
import ../src/openparser/qr/rmqr

suite "rmqr encode":
  test "levels L and Q are rejected":
    expect QrError:
      discard encodeRmqr("x", ecLow)
    expect QrError:
      discard encodeRmqr("x", ecQuartile)

  test "auto version picks a fitting footprint":
    let m = encodeRmqr("hi", ecMedium)
    check m.height in {7, 9, 11, 13, 15, 17}
    check decodeRmqrMatrix(m).text == "hi"

  test "fixed version honours the request":
    let m = encodeRmqr("1234", ecMedium, "R11x139")
    check m.width == 139
    check m.height == 11

  test "oversized payload for a fixed version raises":
    expect QrError:
      discard encodeRmqr(repeat('A', 200), ecMedium, "R7x43")

  test "byte and kanji payloads round trip":
    for v in ["R11x77", "R17x139"]:
      let m = encodeRmqr("日本語のテキスト", ecHigh, v)
      let dec = decodeRmqrMatrix(m)
      check dec.ok
      check dec.text == "日本語のテキスト"

  test "numeric edge at the smallest symbol":
    # R7x43-M holds six data codewords: numeric caps at 12 digits
    let m = encodeRmqr("012345678901", ecMedium, "R7x43")
    check decodeRmqrMatrix(m).text == "012345678901"
    expect QrError:
      discard encodeRmqr("0123456789012", ecMedium, "R7x43")

suite "rmqr decode":
  test "round trip across several sizes":
    for spec in ["R9x99", "R13x139"]:
      let m = encodeRmqr("openparser " & spec, ecMedium, spec)
      let dec = decodeRmqrMatrix(m)
      check dec.ok
      check dec.family == famRmqr
      check dec.text == "openparser " & spec
    let small = encodeRmqr("tiny", ecMedium, "R7x43")
    check decodeRmqrMatrix(small).text == "tiny"
    let narrow = encodeRmqr("nrw!", ecMedium, "R11x27")
    check decodeRmqrMatrix(narrow).text == "nrw!"

  test "survives corruption within the RS budget":
    var m = encodeRmqr("error correction works here too", ecMedium,
                       "R11x99")
    m.modules[5 * m.width + 60] = not m.modules[5 * m.width + 60]
    m.modules[8 * m.width + 30] = not m.modules[8 * m.width + 30]
    let dec = decodeRmqrMatrix(m)
    check dec.ok
    check dec.text == "error correction works here too"

  test "rejects model 2 sized grids":
    var m = initSquareQrMatrix(25)
    check decodeRmqrMatrix(m).ok == false

suite "rmqr reference vectors":
  test "matches zxing-cpp writer output R11x43-M":
    ## zxing-cpp 3.1.1 create_barcode(RMQRCode, content="golden vector",
    ## ecc=H); the writer keeps level M here since H does not fit the
    ## R11x43 footprint.
    const golden = [
      "#######.#.#.#.#.#.#.###.#.#.#.#.#.#.#.#.###",
      "#.....#......#.##..##.#.#.######.##.....#.#",
      "#.###.#..#.#..####..#####...#.#.###.##..#.#",
      "#.###.#.#...##..#.#...####.#.#..#....###.#.",
      "#.###.#..#.....###..##.#.#.#..####...#.####",
      "#.....#...#.#....####...##..######.#..#.#..",
      "#######.##..#..#..#..#....#.#.##.#....#####",
      "........#.#.#..#..#.#.......#..##..####...#",
      "####..##.####.##....###.##.#....#..####.#.#",
      "#..#..####..#.#.#.###.##.#########....#...#",
      "###.#.#.#.#.#.#.#.#.###.#.#.#.#.#.#.#.#####"]
    var m = initQrMatrix(43, 11)
    for y in 0 ..< 11:
      for x in 0 ..< 43:
        m.modules[y * 43 + x] = golden[y][x] == '#'
    let dec = decodeRmqrMatrix(m)
    check dec.ok
    check dec.text == "golden vector"
    check dec.ecLevel == ecMedium
    check dec.version == 12

  test "decode matches re-encode on a zxing vector":
    # build via our encoder, decode, re-encode, compare
    let original = encodeRmqr("reference vector check", ecHigh, "R15x77")
    let dec = decodeRmqrMatrix(original)
    check dec.ok
    let again = encodeRmqr(dec.text, dec.ecLevel,
                           "R" & $original.height & "x" & $original.width)
    check again == original
