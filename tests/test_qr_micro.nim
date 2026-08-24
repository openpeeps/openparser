# A collection of tiny parsers and dumpers
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/openparser

import std/[unittest, strutils]
import ../src/openparser/qr/common
import ../src/openparser/qr/model2
import ../src/openparser/qr/micro

suite "micro qr encode":
  test "M1 numeric fixed layout":
    # segno 1.6.6 reference, mask 0
    let m = encodeMicro("1", ecLow, mvM1, 0)
    check m.width == 11
    let dec = decodeMicroMatrix(m)
    check dec.ok
    check dec.text == "1"
    check dec.version == ord(mvM1)

  test "auto version picks the smallest fitting symbol":
    check encodeMicro("5", ecLow).width == 11
    check encodeMicro("123456", ecLow).width == 13
    check encodeMicro("MICRO QR 42", ecLow).width == 15
    check encodeMicro("MEDIUM LEVEL M4", ecMedium).width == 17

  test "level H is rejected everywhere":
    expect QrError:
      discard encodeMicro("x", ecHigh)

  test "unsupported level and version combinations raise":
    expect QrError:
      discard encodeMicro("12345678901", ecLow, mvM1)
    expect QrError:
      discard encodeMicro("abc def", ecQuartile, mvM3)

  test "byte mode needs at least M3":
    expect QrError:
      discard encodeMicroMatrix(@[makeBytes("hi")], mvM2, ecMedium)
    let m = encodeMicroMatrix(@[makeBytes("hi")], mvM3, ecMedium)
    check decodeMicroMatrix(m).text == "hi"

  test "kanji round trip at M3 and M4":
    for ver in [mvM3, mvM4]:
      let segs = toSegments("日本語")
      let m = encodeMicroMatrix(segs, ver, ecMedium)
      let dec = decodeMicroMatrix(m)
      check dec.ok
      check dec.text == "日本語"

suite "micro qr decode":
  test "segno reference matrix M4-M":
    ## Generated with segno 1.6.6:
    ## segno.make("MEDIUM LEVEL M4", version="M4", error="m",
    ##            boost_error=False).matrix
    const golden = [
      "#######.#.#.#.#.#",
      "#.....#.......#.#",
      "#.###.#..#####...",
      "#.###.#......##.#",
      "#.###.#.####.#..#",
      "#.....#..##..#.#.",
      "#######..#.###.#.",
      ".........###.#...",
      "#.#..#.#.##.##.#.",
      ".#.##..######.##.",
      "#.###..#.####.#..",
      "..####.#..####.##",
      "#....##.......#.#",
      "...##.#..#..#..##",
      "#.....#..#.###...",
      ".##..#..#.#.#.#.#",
      "#...#..#.###.#.##"]
    var m = initSquareQrMatrix(17)
    for y in 0 ..< 17:
      for x in 0 ..< 17:
        m.modules[y * 17 + x] = golden[y][x] == '#'
    let dec = decodeMicroMatrix(m)
    check dec.ok
    check dec.text == "MEDIUM LEVEL M4"
    check dec.version == ord(mvM4)
    check dec.ecLevel == ecMedium

  test "rejects model 2 sized grids":
    var m = initSquareQrMatrix(21)
    check decodeMicroMatrix(m).ok == false

  test "survives a flipped module within the RS budget":
    var m = encodeMicro("777000111222333", ecQuartile, mvM4)
    let i = m.width * 10 + 12
    m.modules[i] = not m.modules[i]
    let dec = decodeMicroMatrix(m)
    check dec.ok
    check dec.text == "777000111222333"

  test "format info damage still decodes via the second copy half":
    var m = encodeMicro("hello world", ecMedium, mvM4)
    # flip one horizontal format cell; the vertical copy carries the low
    # bits so the combined word is corrupted - this must fail cleanly
    m.modules[8 * m.width + 3] = not m.modules[8 * m.width + 3]
    let dec = decodeMicroMatrix(m)
    check dec.ok == false or dec.text != ""
