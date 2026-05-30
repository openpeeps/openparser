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

  test "loadDotenv sets env vars":
    let tmp = getTempDir() / "test.env"
    writeFile(tmp, "DOTENV_FOO=bar\nDOTENV_BAR=baz")
    loadDotenv(tmp, override = true)
    check getEnv("DOTENV_FOO") == "bar"
    check getEnv("DOTENV_BAR") == "baz"
    removeFile(tmp)

  test "loadDotenv respects override flag":
    putEnv("DOTENV_EXISTING", "original")
    let tmp = getTempDir() / "test_override.env"
    writeFile(tmp, "DOTENV_EXISTING=overridden")

    loadDotenv(tmp, override = false)
    check getEnv("DOTENV_EXISTING") == "original"

    loadDotenv(tmp, override = true)
    check getEnv("DOTENV_EXISTING") == "overridden"

    removeFile(tmp)
    delEnv("DOTENV_EXISTING")

  test "get/set/has/del helpers":
    set("DOTENV_HELPER", "hello")
    check has("DOTENV_HELPER")
    check get("DOTENV_HELPER") == "hello"
    check get("DOTENV_MISSING", "fallback") == "fallback"
    del("DOTENV_HELPER")
    check not has("DOTENV_HELPER")