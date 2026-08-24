# A collection of tiny parsers and dumpers
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/openparser

## QR Code symbology family for openparser: generators and readers for
##
## - QR Code Model 2 (ISO/IEC 18004), versions 1-40, all EC levels,
##   Numeric / Alphanumeric / Byte / Kanji / ECI / Structured Append
## - Micro QR Code M1-M4
## - rMQR (ISO/IEC 23941), all 32 sizes at levels M and H
## - Model 1 legacy symbols (versions 1-12)
## - SQRC style public/private payloads secured with AES via nimcypher
## - experimental AQR style dual payload symbols with a data ring
##
## plus payload builders (vCard, WiFi, MECARD, mailto, SMSTO) and an SVG
## renderer. Import this module instead of the individual ones.
##
## Unstable API.

import ./qr/common
import ./qr/galois
import ./qr/model2
import ./qr/micro
import ./qr/rmqr
import ./qr/model1
import ./qr/payload
import ./qr/sqrc
import ./qr/aqr
import ./qr/render

export common, galois, model2, micro, rmqr, model1, payload, sqrc, aqr,
  render
