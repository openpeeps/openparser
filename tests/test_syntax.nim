import std/[strutils]
import openparser/css/[syntax, syntaxdata]

proc testParse(desc, input: string) =
  let node = parseSyntax(input)
  if node == nil:
    echo "  ✗ ", desc, " → FAILED (got nil)"
  else:
    echo "  ✓ ", desc, " → ", $node

echo "=== Syntax Parser Tests ==="

testParse("simple keyword", "auto")
testParse("type reference", "<color>")
testParse("alternatives", "auto | none | <custom-ident>")
testParse("optional", "<color>?")
testParse("one or more", "<image>+")
testParse("comma sep", "<color>#")
testParse("juxtaposition", "<length> <color>")
testParse("group", "[ <length> | auto ]")

echo "\n=== Complex Syntax Tests ==="

testParse("bg-position long",
  "[ [ left | center | right | top | bottom | <length-percentage> ] | [ left | center | right | <length-percentage> ] [ top | center | bottom | <length-percentage> ] | [ center | [ left | right ] <length-percentage>? ] && [ center | [ top | bottom ] <length-percentage>? ] ]")

testParse("repeat multi", "[ <length> | auto ]{1,4}")
testParse("at-least-one", "<'animation-duration'> || <easing-function> || <'animation-delay'>")
testParse("all", "<length> && <color>")
testParse("property ref", "<'background-color'>")
testParse("function ref", "<rgb()>")
testParse("string literal", "'<'")
testParse("with important", "<color> | transparent | currentcolor")
testParse("color", "color")
testParse("color-stop-list", "<linear-color-stop> , [ <linear-color-hint>? , <linear-color-stop> ]#?")
testParse("comma-list", "[ <length-percentage> | <number> ]+]#")

echo "\n=== MDN Data Loading ==="

let data = loadCssData()
echo "  Properties loaded"
echo "  Syntaxes loaded"
echo "  Types loaded"

echo "\n  Property syntax check:"
for prop in ["background-color", "color", "display", "margin", "width", "position", "background-position", "border", "flex"]:
  let syn = data.getPropertySyntax(prop)
  if syn != nil:
    echo "    ", prop, " → ", $syn
  else:
    echo "    ", prop, " → ERROR"

echo "\n=== Done ==="
