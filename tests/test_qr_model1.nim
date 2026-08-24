# A collection of tiny parsers and dumpers
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/openparser

import std/[unittest, strutils]
import ../src/openparser/qr/common
import ../src/openparser/qr/model2
import ../src/openparser/qr/model1

suite "model 1 decode":
  test "decodes the ISO reference sample":
    ## QR Code Model 1, version 2, level M, mask 5; grid captured from the
    ## zxing-cpp project's official qr-model-1.png sample.
    const golden = [
      "#######.#######...#######",
      "#.....#..#.##.###.#.....#",
      "#.###.#....###.#..#.###.#",
      "#.###.#.###.###.#.#.###.#",
      "#.###.#.##..#...#.#.###.#",
      "#.....#.#..#..###.#.....#",
      "#######.#.#.#.#.#.#######",
      "........#..#.#...........",
      ".####.#.#.#.##.#.#####..#",
      "...#.#..##..#.##..##.#.##",
      "##.##.##....#.#.#..#..#.#",
      ".##.#...###..#...###..###",
      "#....##...#...####..#.#.#",
      ".##.##....#.#..##.##.##.#",
      ".###..##.#.##.#.#..#.#..#",
      "#......#....#.#.##.#..#.#",
      "###...####..#..#...#....#",
      "........#..#.....####...#",
      "#######..#...#.####.#####",
      "#.....#..#..##....#...###",
      "#.###.#.#...####.....#..#",
      "#.###.#.#.##..#.#####...#",
      "#.###.#.####..##...#.#.##",
      "#.....#.##..#.....##.#...",
      "#######...########..#.#.#"]
    var m = initSquareQrMatrix(25)
    for y in 0 ..< 25:
      for x in 0 ..< 25:
        m.modules[y * 25 + x] = golden[y][x] == '#'
    let dec = decodeModel1Matrix(m)
    check dec.ok
    check dec.text == "QR Code Model 1 "
    check dec.version == 2
    check dec.ecLevel == ecMedium
    check dec.mask == 5
    check dec.family == famModel1

suite "model 1 encode":
  test "reproduces the reference sample exactly":
    const golden = [
      "#######.#######...#######",
      "#.....#..#.##.###.#.....#",
      "#.###.#....###.#..#.###.#",
      "#.###.#.###.###.#.#.###.#",
      "#.###.#.##..#...#.#.###.#",
      "#.....#.#..#..###.#.....#",
      "#######.#.#.#.#.#.#######",
      "........#..#.#...........",
      ".####.#.#.#.##.#.#####..#",
      "...#.#..##..#.##..##.#.##",
      "##.##.##....#.#.#..#..#.#",
      ".##.#...###..#...###..###",
      "#....##...#...####..#.#.#",
      ".##.##....#.#..##.##.##.#",
      ".###..##.#.##.#.#..#.#..#",
      "#......#....#.#.##.#..#.#",
      "###...####..#..#...#....#",
      "........#..#.....####...#",
      "#######..#...#.####.#####",
      "#.....#..#..##....#...###",
      "#.###.#.#...####.....#..#",
      "#.###.#.#.##..#.#####...#",
      "#.###.#.####..##...#.#.##",
      "#.....#.##..#.....##.#...",
      "#######...########..#.#.#"]
    let mine = encodeModel1("QR Code Model 1 ", ecMedium, 2, 5)
    for y in 0 ..< 25:
      for x in 0 ..< 25:
        check mine.modules[y * 25 + x] == (golden[y][x] == '#')

  test "round trips across versions and levels":
    for ver in [1, 2, 5, 8]:
      for ec in [ecLow, ecMedium, ecQuartile, ecHigh]:
        if not model1LayoutOk(ver, ec):
          continue
        let text = $ec & $ver
        let m = encodeModel1(text, ec, ver)
        let dec = decodeModel1Matrix(m)
        check dec.ok
        check dec.text == text

  test "auto version picks smallest fitting symbol":
    check decodeModel1Matrix(encodeModel1("hi", ecLow)).version == 1
    check decodeModel1Matrix(encodeModel1(repeat('x', 40), ecMedium)).version > 2

  test "rejects oversized payloads":
    expect QrError:
      discard encodeModel1(repeat('x', 300), ecHigh)

  test "versions beyond the verified range are refused":
    expect QrError:
      discard encodeModel1("x", ecMedium, 13)
