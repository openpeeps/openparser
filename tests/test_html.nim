import std/[unittest, os, strutils, tables]
import ../src/openparser/html

suite "HTML parser – basic":

  test "parse simple document":
    let doc = parseHtml("<html><head><title>Hi</title></head><body><p>Text</p></body></html>")
    check doc.nodes.len == 1
    check doc.nodes[0].tag == tagHtml

  test "inner text extraction":
    let doc = parseHtml("<div>Hello <b>world</b></div>")
    check doc.nodes[0].innerText() == "Hello world"

  test "attributes parsed":
    let doc = parseHtml("<div id=\"x\" class=\"a b\">ok</div>")
    let attrs = doc.nodes[0].attributes
    check attrs["id"] == "x"
    check attrs["class"] == "a b"

  test "self-closing tags":
    let doc = parseHtml("<br><hr><img src=\"a.png\">")
    check doc.nodes.len == 3
    check doc.nodes[0].tag == tagBr
    check doc.nodes[1].tag == tagHr
    check doc.nodes[2].tag == tagImg

  test "unknown tags become tagUnknown":
    let doc = parseHtml("<foo>bar</foo>")
    check doc.nodes[0].tag == tagUnknown

suite "HTML parser – fault tolerance":

  test "unterminated comment – recoverable":
    let doc = parseHtml("text <!-- unclosed comment")
    check doc.nodes.len >= 1
    # should contain a comment node with partial content
    var foundComment = false
    for n in doc.nodes:
      if n.kind == htmlComment:
        foundComment = true
        check "unclosed comment" in n.comment
    check foundComment

  test "unterminated attribute value – recoverable":
    let doc = parseHtml("<div class=\"foo>text</div>")
    check doc.nodes.len == 1
    let node = doc.nodes[0]
    check node.tag == tagDiv
    check node.attributes["class"] == "foo"

  test "unclosed tag – allowUnclosedTags true":
    let policy = HtmlParserPolicy(
      allowSelfClosingTags: true,
      allowUnclosedTags: true,
      allowComments: true,
      allowDoctype: true,
      allowProcessingInstructions: false,
      allowCdata: false,
      allowScriptAndStyleContent: true,
      allowEntities: true,
      allowRawText: false,
      allowHtmlInAttributes: false,
      allowUnquotedAttributes: false,
      allowDuplicateAttributes: false,
      allowInvalidTags: false,
      allowInvalidAttributeNames: false,
      allowInvalidAttributeValues: false,
      allowInvalidNesting: false,
      allowInvalidSyntax: false
    )
    let doc = parseHtml("<div><p>Text", policy)
    check doc.nodes.len == 1
    check doc.nodes[0].tag == tagDiv

  test "unclosed tag – allowUnclosedTags false raises":
    let policy = HtmlParserPolicy(
      allowSelfClosingTags: true,
      allowUnclosedTags: false,
      allowComments: true,
      allowDoctype: true,
      allowProcessingInstructions: false,
      allowCdata: false,
      allowScriptAndStyleContent: true,
      allowEntities: true,
      allowRawText: false,
      allowHtmlInAttributes: false,
      allowUnquotedAttributes: false,
      allowDuplicateAttributes: false,
      allowInvalidTags: false,
      allowInvalidAttributeNames: false,
      allowInvalidAttributeValues: false,
      allowInvalidNesting: false,
      allowInvalidSyntax: false
    )
    expect HtmlParserError:
      discard parseHtml("<div><p>Text", policy)

  test "mismatched closing tag – skipped, not fatal":
    let doc = parseHtml("<div><p>text</div></p>")
    check doc.nodes.len == 1
    check doc.nodes[0].tag == tagDiv

  test "bare text outside tags":
    let doc = parseHtml("just text")
    check doc.nodes.len == 1
    check doc.nodes[0].kind == htmlInnerText
    check doc.nodes[0].value.text == "just text"

  test "stray > character":
    let doc = parseHtml("<div>ok</div>>extra")
    check doc.nodes.len >= 1

  test "empty input":
    let doc = parseHtml("")
    check doc.nodes.len == 0

  test "only comment":
    let doc = parseHtml("<!-- hello -->")
    check doc.nodes.len == 1
    check doc.nodes[0].kind == htmlComment
    check doc.nodes[0].comment == " hello "

suite "HTML parser – parseHtmlFile":

  test "parseHtmlFile returns HtmlDocument":
    let path = "tests" / "data" / "test_html_sample.html"
    writeFile(path, "<html><body><p>file content</p></body></html>")
    defer: removeFile(path)
    let doc = parseHtmlFile(path)
    check doc.nodes.len == 1
    check doc.nodes[0].tag == tagHtml

  test "parseHtmlFile with custom policy":
    let path = "tests" / "data" / "test_html_custom.html"
    writeFile(path, "<div>unclosed")
    defer: removeFile(path)
    let policy = defaulHtmlParsingPolicy()
    let doc = parseHtmlFile(path, policy)
    check doc.nodes.len == 1

suite "HTML parser – edge cases":

  test "nested elements":
    let doc = parseHtml("<div><span><b>deep</b></span></div>")
    let el = doc.nodes[0]
    check el.tag == tagDiv
    check el.children.len == 1
    check el.children[0].tag == tagSpan
    check el.children[0].children[0].tag == tagB

  test "multiple root nodes":
    let doc = parseHtml("<p>one</p><p>two</p><p>three</p>")
    check doc.nodes.len == 3
    for n in doc.nodes:
      check n.tag == tagP

  test "comments inside elements":
    let doc = parseHtml("<div><!-- inner --></div>")
    let el = doc.nodes[0]
    check el.children.len == 1
    check el.children[0].kind == htmlComment

  test "self-closing inside normal element":
    let doc = parseHtml("<div>before<br>after</div>")
    let el = doc.nodes[0]
    check el.children.len == 3
    check el.children[0].kind == htmlInnerText
    check el.children[1].tag == tagBr
    check el.children[2].kind == htmlInnerText

  test "deeply nested unclosed tags with allowUnclosedTags":
    let doc = parseHtml("<div><span><b>text", defaulHtmlParsingPolicy())
    check doc.nodes.len == 1
    check doc.nodes[0].tag == tagDiv
