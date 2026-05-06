import std/[unittest, os, envvars, strutils, tables]
import ../src/openparser/dotenv

suite "Dotenv parser and loader":

  test "Basic key=value parsing":
    let content = """
    # Comment
    FOO=bar
    BAR = baz # inline comment
    """.unindent
    let entries = parseEnv(content)
    check entries.len == 2
    check entries[0].key == "FOO"
    check entries[0].value == "bar"
    check entries[1].key == "BAR"
    check entries[1].value == "baz"

  test "Quoted and multiline values":
    let content = """
    MULTI="hello
    world"
    SINGLE='single quoted
    value'
    """.unindent
    let entries = parseEnv(content)
    check entries[0].key == "MULTI"
    check entries[0].value == "hello\nworld"
    check entries[1].key == "SINGLE"
    check entries[1].value == "single quoted\nvalue"

  test "Variable expansion":
    putEnv("USER", "testuser")
    let content = """
    NAME=$USER
    GREETING="Hello, ${USER}!"
    """.unindent
    let entries = parseEnv(content)
    var local = initTable[string, string]()
    var cmdCache = initTable[string, string]()
    check expandValue(entries[0].value, local, cmdCache) == "testuser"
    check expandValue(entries[1].value, local, cmdCache) == "Hello, testuser!"

  test "Command substitution":
    let content = """
    WHOAMI=$(whoami)
    """.unindent
    let entries = parseEnv(content)
    var local = initTable[string, string]()
    var cmdCache = initTable[string, string]()
    let whoami = expandValue(entries[0].value, local, cmdCache)
    check whoami.len > 0

  test "loadDotenvFile sets env vars":
    let tmp = getTempDir() / "test.env"
    writeFile(tmp, "FOO=bar\nBAR=baz")
    discard loadDotenvFile(tmp, override=true)
    check getEnv("FOO") == "bar"
    check getEnv("BAR") == "baz"
    removeFile(tmp)

  test "loadDotenvFiles keeps profiles isolated":
    let d = getTempDir() / "openparser_dotenv_profiles"
    createDir(d)

    let localFile = d / ".env.local"
    let prodFile = d / ".env.production"

    writeFile(localFile, "OPENPARSER_MODE=local\nOPENPARSER_URL=http://localhost")
    writeFile(prodFile, "OPENPARSER_MODE=production\nOPENPARSER_URL=https://example.com")

    let profiles = loadDotenvFiles([localFile, prodFile], override=true)

    check profiles.hasKey("local")
    check profiles.hasKey("production")
    check profiles["local"]["OPENPARSER_MODE"].value == "local"
    check profiles["production"]["OPENPARSER_MODE"].value == "production"

    # Not applied yet:
    check getEnv("OPENPARSER_MODE", "") == ""

    discard applyDotenvProfile(profiles, "production", override=true)
    check getEnv("OPENPARSER_MODE") == "production"
    check getEnv("OPENPARSER_URL") == "https://example.com"

    removeFile(localFile)
    removeFile(prodFile)