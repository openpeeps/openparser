# A collection of tiny parsers and dumpers
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/openparser
import std/math
import ./types
import ./constants
import ./convert

const twentyfiveToSeventh = 6103515625.0 # 25^7

proc myAtan(x, y: float): float =
  if x == 0 and y == 0:
    return 0.0
  elif x >= 0:
    return radToDeg(arctan2(x, y))
  else:
    return radToDeg(arctan2(x, y)) + 360.0

func deltaE00*(c1, c2: Lab, kL, kC, kH: float = 1.0): float =
  let
    C1 = sqrt(c1.a*c1.a + c1.b*c1.b)
    C2 = sqrt(c2.a*c2.a + c2.b*c2.b)
    CM = 0.5 * (C1 + C2)
    CM7 = pow(CM, 7.0)
    G = 0.5 * (1.0 - sqrt(CM7 / (CM7 + twentyfiveToSeventh)))
    aa1 = (1.0 + G) * c1.a
    aa2 = (1.0 + G) * c2.a
    CC1 = sqrt(aa1*aa1 + c1.b*c1.b)
    CC2 = sqrt(aa2*aa2 + c2.b*c2.b)
    h1 = myAtan(c1.b, aa1)
    h2 = myAtan(c2.b, aa2)
    deltaL = c2.l - c1.l
    deltaCC = CC2 - CC1
    deltah =
      if CC1 == 0 or CC2 == 0:
        0.0
      elif abs(h2 - h1) <= 180.0:
        h2 - h1
      elif h2 - h1 > 180.0:
        h2 - h1 - 360.0
      else:
        h2 - h1 + 360.0
    deltaHH = 2.0 * sqrt(CC1 * CC2) * sin(degToRad(0.5 * deltah))
    LM = 0.5 * (c1.l + c2.l)
    CCM = 0.5 * (CC1 + CC2)
    hM =
      if CC1 == 0 or CC2 == 0:
        h1 + h2
      elif abs(h2 - h1) <= 180.0:
        0.5 * (h1 + h2)
      elif h2 - h1 > 180.0:
        0.5 * (h1 + h2 + 360.0)
      else:
        0.5 * (h1 + h2 - 360.0)
    T = 1.0 - 0.17 * cos(degToRad(hM - 30.0)) + 0.24 * cos(degToRad(2.0 * hM)) +
        0.32 * cos(degToRad(3.0 * hM + 6.0)) - 0.20 * cos(degToRad(4.0 * hM - 63.0))
    deltaTheta = 30.0 * exp(-1.0 * pow((hM - 275.0) / 25.0, 2.0))
    RC = 2.0 * sqrt(pow(CCM, 7.0) / (pow(CCM, 7.0) + twentyfiveToSeventh))
    SL = 1.0 + (0.015 * pow(LM - 50.0, 2.0))/sqrt(20.0 + pow(LM - 50.0, 2.0))
    SC = 1.0 + 0.045 * CCM
    SH = 1.0 + 0.015 * CCM * T
    RT = -sin(degToRad(2.0 * deltaTheta)) * RC
  result = sqrt(pow(deltaL/(kL * SL), 2.0) + pow(deltaCC/(kC * SC), 2.0) + pow(deltaHH/(kH * SH), 2.0) + RT * (deltaCC / (kC * SC)) * (deltaHH/(kH * SH)))

proc distance*(a, b: Color): float =
  ## CIEDE2000 distance between two Colors (chroma compat).
  let la = a.toLab()
  let lb = b.toLab()
  deltaE00(la, lb)
