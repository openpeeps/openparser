import unittest, tables, strutils
import ../src/openparser/yaml

suite "YAML Deserialization":
  test "simple scalars":
    let yaml = """
      foo: bar
      num: 42
      pi: 3.14
      yes: true
      no: false
      nothing: null
    """
    let obj = parseYAML(yaml)
    check obj["foo"].strValue == "bar"
    check obj["num"].intValue == 42
    check obj["pi"].floatValue == 3.14
    check obj["yes"].boolValue == true
    check obj["no"].boolValue == false
    check obj["nothing"].kind == yamlNull

  test "simple sequence":
    let yaml = """
      items:
        - apple
        - banana
        - cherry
    """
    let obj = parseYAML(yaml)
    let arr = obj["items"].arrValue
    check arr.len == 3
    check arr[0].strValue == "apple"
    check arr[1].strValue == "banana"
    check arr[2].strValue == "cherry"

  test "nested mapping":
    let yaml = """
      person:
        name: Alice
        age: 30
        address:
          city: Wonderland
          zip: 12345
    """
    let obj = parseYAML(yaml)
    let person = obj["person"].objValue
    check person["name"].strValue == "Alice"
    check person["age"].intValue == 30
    let pers = person["address"].objValue
    check pers["city"].strValue == "Wonderland"
    check pers["zip"].intValue == 12345

  test "sequence of mappings":
    let yaml = """
      users:
        - name: Bob
          age: 25
        - name: Carol
          age: 28
    """
    let obj = parseYAML(yaml)
    let users = obj["users"].arrValue
    check users.len == 2
    check users[0].objValue["name"].strValue == "Bob"
    check users[0].objValue["age"].intValue == 25
    check users[1].objValue["name"].strValue == "Carol"
    check users[1].objValue["age"].intValue == 28

  test "block string":
    let yaml = """
      desc: |
        This is a
        multi-line
        string.
    """
    let obj = parseYAML(yaml)
    check obj["desc"].strValue.contains("multi-line")

  test "inline array and object":
    let yaml = """
      arr: [1, 2, 3]
      obj: {a: 1, b: 2}
    """
    let obj = parseYAML(yaml)
    let arr = obj["arr"].arrValue
    check arr[0].intValue == 1
    check arr[1].intValue == 2
    check arr[2].intValue == 3
    let o = obj["obj"].objValue
    check o["a"].intValue == 1
    check o["b"].intValue == 2

  # test "booleans and nulls":
  #   let yaml = """
  #     t: true
  #     f: false
  #     n: null
  #     tilde: ~
  #   """
  #   let obj = parseYAML(yaml)
  #   check obj["t"].boolValue == true
  #   check obj["f"].boolValue == false
  #   check obj["n"].kind == yamlNull
  #   check obj["tilde"].kind == yamlNull

  test "with comments":
    let yaml = """
      # This is a comment
      foo: bar # Inline comment
      # Another comment
      num: 123
    """
    let obj = parseYAML(yaml)
    check obj["foo"].strValue == "bar"
    check obj["num"].intValue == 123

  test "complex nested structure":
    let yaml = """
      config:
        enabled: true
        items:
          - name: X
            value: 1
          - name: Y
            value: 2
        meta:
          tags: [a, b, c]
          info: {author: George, year: 2026}
    """
    let obj = parseYAML(yaml)
    let cfg = obj["config"].objValue
    check cfg["enabled"].boolValue == true
    let items = cfg["items"].arrValue
    check items[0].objValue["name"].strValue == "X"
    check items[1].objValue["value"].intValue == 2
    let meta = cfg["meta"].objValue
    check meta["tags"].arrValue[2].strValue == "c"
    check meta["info"].objValue["author"].strValue == "George"

  test "unquoted keys with slashes and dots":
    let yaml = """
      server:
        port: 8000
        threads: 1
        routes:
          /: "index"
          /error: "error"
        api.v1:
          endpoint: "test"
    """
    let obj = parseYAML(yaml)
    let routes = obj["server"].objValue["routes"].objValue
    check routes["/"].strValue == "index"
    check routes["/error"].strValue == "error"
    check obj["server"].objValue["api.v1"].objValue["endpoint"].strValue == "test"

type DeployTarget = object
  os: string
  arch: string

type DeployRelease = object
  repo: string
  workflow: string
  artifactName: string
  targets: seq[DeployTarget]

suite "YAML typed deserialization":
  test "plain scalar starting with a dot":
    let yaml = """
      repo: openpeeps/clue
      workflow: .github/workflows/release.yml
      artifactName: "{{project}}_{{os}}-{{arch}}"
      targets:
        - {os: ubuntu-latest, arch: x86_64}
        - {os: macos-14, arch: arm64}
    """
    let rel = parseYAML(yaml, DeployRelease)
    check rel.repo == "openpeeps/clue"
    check rel.workflow == ".github/workflows/release.yml"
    check rel.artifactName == "{{project}}_{{os}}-{{arch}}"
    check rel.targets.len == 2
    check rel.targets[0].os == "ubuntu-latest"
    check rel.targets[1].arch == "arm64"

  test "lone dot scalar":
    let yaml = """
      marker: .
    """
    let obj = parseYAML(yaml)
    check obj["marker"].strValue == "."

type DeployServer = object
  host: string
  sshKey: string
  welcome: string
  nothing: string

suite "YAML plain scalars":
  test "tilde-led path and lone tilde null":
    let yaml = """
      host: example.com
      sshKey: ~/.ssh/id_ed25519
    """
    let srv = parseYAML(yaml, DeployServer)
    check srv.host == "example.com"
    check srv.sshKey == "~/.ssh/id_ed25519"
    let obj = parseYAML(yaml)
    check obj["sshKey"].strValue == "~/.ssh/id_ed25519"

  test "unquoted unicode values":
    let yaml = """
      welcome: café au lait 日本語
      city: München
    """
    let obj = parseYAML(yaml)
    check obj["welcome"].strValue == "café au lait 日本語"
    check obj["city"].strValue == "München"
    # typed hook consumes the full plain line, not a single token
    let srv = parseYAML("welcome: café au lait 日本語\nsshKey: ~/.ssh/x\n", DeployServer)
    check srv.welcome == "café au lait 日本語"
    check srv.sshKey == "~/.ssh/x"

type Recipe = object
  name: string
  description: string

suite "YAML unquoted plain scalars":
  test "multi-word with slashes (reported bug)":
    let yaml = """
      name: myrecipe
      description: JWT/JWS auth via nimbase/jose
    """
    let obj = parseYAML(yaml)
    check obj["description"].strValue == "JWT/JWS auth via nimbase/jose"
    let r = parseYAML(yaml, Recipe)
    check r.name == "myrecipe"
    check r.description == "JWT/JWS auth via nimbase/jose"

  test "typed multi-word unicode":
    let yaml = """
      welcome: café au lait
      city: München Stadt
    """
    let obj = parseYAML(yaml)
    check obj["welcome"].strValue == "café au lait"
    let srv = parseYAML("welcome: café au lait\ncity: x\nsshKey: y\nnothing: z\n", DeployServer)
    check srv.welcome == "café au lait"

  test "emoji unquoted":
    let yaml = """
      title: 🚀 deploy now
      status: ✅ done 🌍
      single: 🎉
    """
    let obj = parseYAML(yaml)
    check obj["title"].strValue == "🚀 deploy now"
    check obj["status"].strValue == "✅ done 🌍"
    check obj["single"].strValue == "🎉"
    type EmojiRec = object
      title: string
      status: string
    let e = parseYAML(yaml, EmojiRec)
    check e.title == "🚀 deploy now"
    check e.status == "✅ done 🌍"

  test "japanese unquoted":
    let yaml = """
      title: 日本語テスト
      desc: こんにちは 世界
      mixed: JWT認証 via テスト 🚀
    """
    let obj = parseYAML(yaml)
    check obj["title"].strValue == "日本語テスト"
    check obj["desc"].strValue == "こんにちは 世界"
    check obj["mixed"].strValue == "JWT認証 via テスト 🚀"
    type JpRec = object
      title: string
      desc: string
      mixed: string
    let j = parseYAML(yaml, JpRec)
    check j.title == "日本語テスト"
    check j.desc == "こんにちは 世界"
    check j.mixed == "JWT認証 via テスト 🚀"

  test "russian unquoted":
    let yaml = """
      title: Привет
      desc: Привет мир тест
      mixed: описание Тестовая строка café 🌍
    """
    let obj = parseYAML(yaml)
    check obj["title"].strValue == "Привет"
    check obj["desc"].strValue == "Привет мир тест"
    check obj["mixed"].strValue == "описание Тестовая строка café 🌍"
    type RuRec = object
      title: string
      desc: string
      mixed: string
    let r = parseYAML(yaml, RuRec)
    check r.title == "Привет"
    check r.desc == "Привет мир тест"
    check r.mixed == "описание Тестовая строка café 🌍"

  test "mixed everything with comment":
    let yaml = """
      description: JWT/JWS auth via nimbase/jose 🚀 日本語 Привет café # trailing comment
    """
    let obj = parseYAML(yaml)
    check obj["description"].strValue == "JWT/JWS auth via nimbase/jose 🚀 日本語 Привет café"
    let rec = parseYAML("name: x\ndescription: JWT/JWS auth via nimbase/jose 🚀 日本語 Привет café # c\n", Recipe)
    check rec.description == "JWT/JWS auth via nimbase/jose 🚀 日本語 Привет café"

  test "block sequence of unquoted strings":
    let yaml = """
      items:
        - hello world
        - café au lait
        - こんにちは 世界
        - Привет мир
        - hello 🌍 world
    """
    let obj = parseYAML(yaml)
    let arr = obj["items"].arrValue
    check arr.len == 5
    check arr[0].strValue == "hello world"
    check arr[1].strValue == "café au lait"
    check arr[2].strValue == "こんにちは 世界"
    check arr[3].strValue == "Привет мир"
    check arr[4].strValue == "hello 🌍 world"
    type SeqRec = object
      items: seq[string]
    let s = parseYAML(yaml, SeqRec)
    check s.items.len == 5
    check s.items[0] == "hello world"
    check s.items[1] == "café au lait"
    check s.items[2] == "こんにちは 世界"
    check s.items[3] == "Привет мир"
    check s.items[4] == "hello 🌍 world"

  test "inline flow with multi-word strings":
    let yaml = """
      obj: {greeting: hello world, city: München Stadt}
      arr: [hello world, café au lait]
    """
    let obj = parseYAML(yaml)
    check obj["obj"].objValue["greeting"].strValue == "hello world"
    check obj["obj"].objValue["city"].strValue == "München Stadt"
    check obj["arr"].arrValue[0].strValue == "hello world"
    check obj["arr"].arrValue[1].strValue == "café au lait"
    type FlowRec = object
      arr: seq[string]
    let f = parseYAML("arr: [hello world, café au lait]\n", FlowRec)
    check f.arr.len == 2
    check f.arr[0] == "hello world"
    check f.arr[1] == "café au lait"

  test "empty string value stays empty":
    let yaml = """
      name: filled
      description:
      other: next
    """
    type EmptyRec = object
      name: string
      description: string
      other: string
    let e = parseYAML(yaml, EmptyRec)
    check e.name == "filled"
    check e.description == ""
    check e.other == "next"

suite "YAML top-level sequences":
  test "sequence of scalars at document root":
    let yaml = "- apple\n- banana\n- cherry\n"
    let node = parseYAMLNode(yaml)
    check node.kind == yamlArray
    check node.arrValue.len == 3
    check node.arrValue[0].strValue == "apple"
    check node.arrValue[1].strValue == "banana"
    check node.arrValue[2].strValue == "cherry"

  test "sequence of mappings at document root":
    let yaml = """
      - name: ALPHA BANK
        city: NEW YORK,NY
        swift: ABNKUS33
      - name: BETA BANK
        city: BOSTON,MA
        swift: BTBKUS31
    """
    let node = parseYAMLNode(yaml)
    check node.kind == yamlArray
    check node.arrValue.len == 2
    check node.arrValue[0].objValue["name"].strValue == "ALPHA BANK"
    check node.arrValue[0].objValue["city"].strValue == "NEW YORK,NY"
    check node.arrValue[0].objValue["swift"].strValue == "ABNKUS33"
    check node.arrValue[1].objValue["name"].strValue == "BETA BANK"
    check node.arrValue[1].objValue["swift"].strValue == "BTBKUS31"

  test "sequence of mappings with explicit nulls":
    let yaml = "- name: ALPHA BANK\n  branch: null\n  swift: ABNKUS33\n"
    let node = parseYAMLNode(yaml)
    check node.kind == yamlArray
    check node.arrValue.len == 1
    check node.arrValue[0].objValue["branch"].kind == yamlNull
    check node.arrValue[0].objValue["swift"].strValue == "ABNKUS33"

  test "nested mapping root is unaffected":
    let node = parseYAMLNode("key: value\n")
    check node.kind == yamlObject
    check node.objValue["key"].strValue == "value"

  test "scalar roots":
    check parseYAMLNode("42").intValue == 42
    check parseYAMLNode("hello world").strValue == "hello world"
    check parseYAMLNode("null").kind == yamlNull
    check parseYAMLNode("").kind == yamlNull

  test "typed deserialization from a root sequence":
    type Bank = object
      name: string
      swift: string
    let banks = parseYAML("""
      - name: ALPHA BANK
        swift: ABNKUS33
      - name: BETA BANK
        swift: BTBKUS31
    """, seq[Bank])
    check banks.len == 2
    check banks[0].name == "ALPHA BANK"
    check banks[0].swift == "ABNKUS33"
    check banks[1].name == "BETA BANK"
    check banks[1].swift == "BTBKUS31"

suite "YAML scalar mapping keys":
  test "numeric keys in a block mapping":
    let obj = parseYAML("02: Canillo\n7: Escaldes-Engordany\n")
    check obj["02"].strValue == "Canillo"
    check obj["7"].strValue == "Escaldes-Engordany"

  test "numeric keys via typed table hook":
    type Region = object
      states: Table[string, string]
    let obj = parseYAML("states:\n  02: Canillo\n  A: Any\n", Region)
    check obj.states["02"] == "Canillo"
    check obj.states["A"] == "Any"

  test "numeric keys in an inline mapping":
    let obj = parseYAML("obj: {1: one, 2.5: two}\n")
    check obj["obj"].objValue["1"].strValue == "one"
    check obj["obj"].objValue["2.5"].strValue == "two"

  test "plain scalar keys that begin with digits":
    let obj = parseYAML("040s: Izola\n12abc: Mixed\n1.0.0: Version\n")
    check obj["040s"].strValue == "Izola"
    check obj["12abc"].strValue == "Mixed"
    check obj["1.0.0"].strValue == "Version"
    type Codes = object
      states: Table[string, string]
    let typed = parseYAML("states:\n  040s: Izola\n  07: Piran\n", Codes)
    check typed.states["040s"] == "Izola"
    check typed.states["07"] == "Piran"

  test "apostrophe inside a plain scalar is not a quote":
    let obj = parseYAML("name: SWEDISH BANKERS' ASSOCIATION\nbranch: STANDBY LC'S\n")
    check obj["name"].strValue == "SWEDISH BANKERS' ASSOCIATION"
    check obj["branch"].strValue == "STANDBY LC'S"

  test "apostrophe inside a plain scalar in a root sequence":
    type Bank = object
      name, city, branch: string
    let banks = parseYAML("""
      - name: MEYDAN SA'AT
        city: TEHRAN
        branch: HEAD OFFICE
    """, seq[Bank])
    check banks.len == 1
    check banks[0].name == "MEYDAN SA'AT"
    check banks[0].branch == "HEAD OFFICE"

suite "YAML empty and null values":
  type Optionals = object
    codes: seq[string]
    name: seq[string]
    lengths: seq[string]
    prefixes: seq[int]
    regex: string
    charset: string

  test "omitted and null sequence fields become empty":
    let o = parseYAML("""
      codes:
        - EUR
      name:
      lengths: []
      prefixes:
      regex: null
      charset: varchar
    """, Optionals)
    check o.codes == @["EUR"]
    check o.name.len == 0
    check o.lengths.len == 0
    check o.prefixes.len == 0
    check o.regex == ""
    check o.charset == "varchar"

  test "quoted null is kept as text":
    let o = parseYAML("""
      regex: "null"
      charset: 'null'
    """, Optionals)
    check o.regex == "null"
    check o.charset == "null"

  test "tilde is also null":
    let o = parseYAML("regex: ~\ncharset: varchar\n", Optionals)
    check o.regex == ""
    check o.charset == "varchar"

  test "sequence still parses after an omitted sibling":
    let o = parseYAML("""
      name:
      codes:
        - USD
        - EUR
      charset: varchar
    """, Optionals)
    check o.name.len == 0
    check o.codes == @["USD", "EUR"]
    check o.charset == "varchar"

  test "multi-document streams keep sequence and scalar roots":
    let docs = parseYAMLStreamNodes("- name: ALPHA\n---\nkey: value\n---\n42\n")
    check docs.len == 3
    check docs[0].kind == yamlArray
    check docs[0].arrValue[0].objValue["name"].strValue == "ALPHA"
    check docs[1].kind == yamlObject
    check docs[1].objValue["key"].strValue == "value"
    check docs[2].kind == yamlInteger
    check docs[2].intValue == 42
