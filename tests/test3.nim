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
