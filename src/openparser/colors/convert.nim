# A collection of tiny parsers and dumpers
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/openparser
import std/math
import ./types
import ./constants

# forward helpers
proc hue2rgb(p, q, t: float): float =
  var tt = t
  if tt < 0: tt += 1
  if tt > 1: tt -= 1
  if tt < 1.0/6.0: return p + (q - p)*6.0*tt
  if tt < 0.5: return q
  if tt < 2.0/3.0: return p + (q - p)*(2.0/3.0 - tt)*6.0
  return p

# RGB -> HSL
proc toHsl*(c: Color): Hsl =
  let r = c.r
  let g = c.g
  let b = c.b
  let maxc = max(r, max(g, b))
  let minc = min(r, min(g, b))
  let l = (maxc + minc)/2.0
  var h, s: float
  if maxc == minc:
    h = 0.0
    s = 0.0
  else:
    let d = maxc - minc
    s = if l > 0.5: d / (2.0 - maxc - minc) else: d / (maxc + minc)
    if maxc == r:
      h = (g - b)/d + (if g < b: 6.0 else: 0.0)
    elif maxc == g:
      h = (b - r)/d + 2.0
    else:
      h = (r - g)/d + 4.0
    h = h / 6.0
  Hsl(h: hueMod(h*360.0), s: clamp01(s), l: clamp01(l), a: c.a)

proc fromHsl*(hsl: Hsl): Color =
  let h = hueMod(hsl.h) / 360.0
  let s = clamp01(hsl.s)
  let l = clamp01(hsl.l)
  var r, g, b: float
  if s == 0.0:
    r = l; g = l; b = l
  else:
    let q = if l < 0.5: l*(1+s) else: l + s - l*s
    let p = 2*l - q
    r = hue2rgb(p, q, h + 1.0/3.0)
    g = hue2rgb(p, q, h)
    b = hue2rgb(p, q, h - 1.0/3.0)
  Color(r: clamp01(r), g: clamp01(g), b: clamp01(b), a: clamp01(hsl.a), format: cfHsl, valid: true)

# RGB -> HSV
proc toHsv*(c: Color): Hsv =
  let r = c.r; let g = c.g; let b = c.b
  let maxc = max(r, max(g, b))
  let minc = min(r, min(g, b))
  let d = maxc - minc
  var h: float
  let s = if maxc == 0: 0.0 else: d / maxc
  let v = maxc
  if maxc == minc:
    h = 0.0
  else:
    if maxc == r:
      h = (g - b)/d + (if g < b: 6.0 else: 0.0)
    elif maxc == g:
      h = (b - r)/d + 2.0
    else:
      h = (r - g)/d + 4.0
    h = h / 6.0
  Hsv(h: hueMod(h*360.0), s: clamp01(s), v: clamp01(v), a: c.a)

proc fromHsv*(hsv: Hsv): Color =
  let h = hueMod(hsv.h) / 360.0
  let s = clamp01(hsv.s)
  let v = clamp01(hsv.v)
  let i = int(floor(h*6.0))
  let f = h*6.0 - float(i)
  let p = v*(1 - s)
  let q = v*(1 - f*s)
  let t = v*(1 - (1 - f)*s)
  var r,g,b: float
  case i mod 6
  of 0: r=v; g=t; b=p
  of 1: r=q; g=v; b=p
  of 2: r=p; g=v; b=t
  of 3: r=p; g=q; b=v
  of 4: r=t; g=p; b=v
  else: r=v; g=p; b=q
  Color(r: clamp01(r), g: clamp01(g), b: clamp01(b), a: clamp01(hsv.a), format: cfHsv, valid: true)

proc toHsb*(c: Color): Hsb = c.toHsv()
proc fromHsb*(hsb: Hsb): Color = fromHsv(hsb)

proc toHwb*(c: Color): Hwb =
  let hsv = c.toHsv()
  let w = (1.0 - hsv.s)*hsv.v
  let b = 1.0 - hsv.v
  Hwb(h: hsv.h, w: clamp01(w), b: clamp01(b), a: c.a)

proc fromHwb*(hwb: Hwb): Color =
  let h = hueMod(hwb.h)
  var w = clamp01(hwb.w)
  var bv = clamp01(hwb.b)
  if w + bv >= 1.0:
    let gray = w / (w + bv)
    return Color(r: gray, g: gray, b: gray, a: clamp01(hwb.a), format: cfHwb, valid: true)
  # convert via hsv
  let v = 1.0 - bv
  let s = if v == 0: 0.0 else: 1.0 - w/v
  fromHsv(Hsv(h: h, s: clamp01(s), v: clamp01(v), a: hwb.a))

# CMYK
proc toCmyk*(c: Color): Cmyk =
  let r = c.r; let g = c.g; let b = c.b
  let k = 1.0 - max(r, max(g,b))
  if k >= 1.0 - 1e-10:
    return Cmyk(c: 0, m: 0, y: 0, k: 1, a: c.a)
  let denom = 1.0 - k
  Cmyk(c: (1-r-k)/denom, m: (1-g-k)/denom, y: (1-b-k)/denom, k: k, a: c.a)

proc fromCmyk*(cmyk: Cmyk): Color =
  let c = clamp01(cmyk.c); let m = clamp01(cmyk.m); let y = clamp01(cmyk.y); let k = clamp01(cmyk.k)
  Color(r: clamp01((1-c)*(1-k)), g: clamp01((1-m)*(1-k)), b: clamp01((1-y)*(1-k)), a: clamp01(cmyk.a), format: cfCmyk, valid: true)

# LAB / LCH helpers
proc toLab*(c: Color): Lab =
  let r = c.r; let g = c.g; let b = c.b
  proc lin(v: float): float =
    if v <= 0.04045: v/12.92 else: pow((v+0.055)/1.055, 2.4)
  let rl = lin(r); let gl = lin(g); let bl = lin(b)
  let x = (rl*0.4124564 + gl*0.3575761 + bl*0.1804375)*100.0
  let y = (rl*0.2126729 + gl*0.7151522 + bl*0.0721750)*100.0
  let z = (rl*0.0193339 + gl*0.1191920 + bl*0.9503041)*100.0
  proc f(t: float): float =
    if t > 0.008856: pow(t, 1.0/3.0) else: 7.787*t + 16.0/116.0
  let fx = f(x / Xn)
  let fy = f(y / Yn)
  let fz = f(z / Zn)
  Lab(l: 116.0*fy - 16.0, a: 500.0*(fx - fy), b: 200.0*(fy - fz), alpha: c.a)

proc fromLab*(lab: Lab): Color =
  proc finv(t: float): float =
    let t3 = t*t*t
    if t3 > 0.008856: t3 else: (t - 16.0/116.0)/7.787
  let fy = (lab.l + 16.0)/116.0
  let fx = lab.a/500.0 + fy
  let fz = fy - lab.b/200.0
  let x = Xn * finv(fx)
  let y = Yn * finv(fy)
  let z = Zn * finv(fz)
  let xn = x/100.0; let yn = y/100.0; let zn = z/100.0
  var rl = xn*3.2404542 + yn*(-1.5371385) + zn*(-0.4985314)
  var gl = xn*(-0.9692660) + yn*1.8760108 + zn*0.0415560
  var bl = xn*0.0556434 + yn*(-0.2040259) + zn*1.0572252
  proc delin(v: float): float =
    if v <= 0.0031308: 12.92*v else: 1.055*pow(v, 1.0/2.4) - 0.055
  rl = clamp01(delin(rl))
  gl = clamp01(delin(gl))
  bl = clamp01(delin(bl))
  Color(r: rl, g: gl, b: bl, a: clamp01(lab.alpha), format: cfLab, valid: true)

proc toLch*(c: Color): Lch =
  let lab = c.toLab()
  let ch = sqrt(lab.a*lab.a + lab.b*lab.b)
  var h = radToDeg(arctan2(lab.b, lab.a))
  h = hueMod(h)
  Lch(l: lab.l, c: ch, h: h, alpha: lab.alpha)

proc fromLch*(lch: Lch): Color =
  let a = lch.c * cos(degToRad(lch.h))
  let b = lch.c * sin(degToRad(lch.h))
  fromLab(Lab(l: lch.l, a: a, b: b, alpha: lch.alpha))

# OKLAB / OKLCH
proc toOklab*(c: Color): Oklab =
  proc lin(v: float): float =
    if v <= 0.04045: v/12.92 else: pow((v+0.055)/1.055, 2.4)
  let rl = lin(c.r); let gl = lin(c.g); let bl = lin(c.b)
  var l = OklabM1[0][0]*rl + OklabM1[0][1]*gl + OklabM1[0][2]*bl
  var m = OklabM1[1][0]*rl + OklabM1[1][1]*gl + OklabM1[1][2]*bl
  var s = OklabM1[2][0]*rl + OklabM1[2][1]*gl + OklabM1[2][2]*bl
  l = pow(l, 1.0/3.0)
  m = pow(m, 1.0/3.0)
  s = pow(s, 1.0/3.0)
  let L = OklabM2[0][0]*l + OklabM2[0][1]*m + OklabM2[0][2]*s
  let A = OklabM2[1][0]*l + OklabM2[1][1]*m + OklabM2[1][2]*s
  let B = OklabM2[2][0]*l + OklabM2[2][1]*m + OklabM2[2][2]*s
  Oklab(l: L, a: A, b: B, alpha: c.a)

proc fromOklab*(ok: Oklab): Color =
  var l1 = ok.l + ok.a*0.3963377774 + ok.b*0.2158037573
  var m1 = ok.l + ok.a*(-0.1055613458) + ok.b*(-0.0638541728)
  var s1 = ok.l + ok.a*(-0.0894841775) + ok.b*(-1.2914855480)
  l1 = l1*l1*l1
  m1 = m1*m1*m1
  s1 = s1*s1*s1
  var rl = OklabM1Inv[0][0]*l1 + OklabM1Inv[0][1]*m1 + OklabM1Inv[0][2]*s1
  var gl = OklabM1Inv[1][0]*l1 + OklabM1Inv[1][1]*m1 + OklabM1Inv[1][2]*s1
  var bl = OklabM1Inv[2][0]*l1 + OklabM1Inv[2][1]*m1 + OklabM1Inv[2][2]*s1
  proc delin(v: float): float =
    if v <= 0.0031308: 12.92*v else: 1.055*pow(v, 1.0/2.4) - 0.055
  rl = clamp01(delin(rl))
  gl = clamp01(delin(gl))
  bl = clamp01(delin(bl))
  Color(r: rl, g: gl, b: bl, a: clamp01(ok.alpha), format: cfOklab, valid: true)

proc toOklch*(c: Color): Oklch =
  let lab = c.toOklab()
  let ch = sqrt(lab.a*lab.a + lab.b*lab.b)
  var h = radToDeg(arctan2(lab.b, lab.a))
  h = hueMod(h)
  Oklch(l: lab.l, c: ch, h: h, alpha: lab.alpha)

proc fromOklchToColor*(oklch: Oklch): Color =
  let a = oklch.c * cos(degToRad(oklch.h))
  let b = oklch.c * sin(degToRad(oklch.h))
  fromOklab(Oklab(l: oklch.l, a: a, b: b, alpha: oklch.alpha))

proc toRgb*(c: Color): Rgb =
  Rgb(r: int(round(clamp01(c.r)*255.0)), g: int(round(clamp01(c.g)*255.0)), b: int(round(clamp01(c.b)*255.0)), a: clamp01(c.a))
proc fromRgb*(rgb: Rgb): Color =
  Color(r: clamp01(float(rgb.r)/255.0), g: clamp01(float(rgb.g)/255.0), b: clamp01(float(rgb.b)/255.0), a: clamp01(rgb.a), format: cfRgb, valid: true)

