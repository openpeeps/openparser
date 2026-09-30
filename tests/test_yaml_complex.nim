import std/[unittest, strutils, tables, options, sets, critbits]
import ../src/openparser/[yaml, json]

type Tag = enum
  tgA, tgB, tgC, tgD

suite "YAML: complex real-world documents":
  test "kubernetes-style manifest":
    let src = """
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-deployment
  labels:
    app: nginx
    app.kubernetes.io/version: "1.14.2"
  annotations:
    description: |
      A multi-line annotation
      with a second line.
spec:
  replicas: 3
  selector:
    matchLabels:
      app: nginx
  template:
    metadata:
      labels:
        app: nginx
    spec:
      containers:
        - name: nginx
          image: nginx:1.14.2
          ports:
            - containerPort: 80
          env:
            - name: MODE
              value: "production"
            - name: DEBUG
              value: "false"
          resources:
            limits: {cpu: 500m, memory: 128Mi}
      tolerations: []
      nodeSelector: {}
"""
    let n = parseYAMLNode(src)
    check n.get("apiVersion").getStr == "apps/v1"
    check n.get("spec.replicas").getInt == 3
    check n.get("metadata.annotations.description").getStr ==
      "A multi-line annotation\nwith a second line.\n"
    check n.get("spec.template.spec.containers").getArray().len == 1
    let c0 = n.get("spec.template.spec.containers").getArray()[0]
    check c0.get("image").getStr == "nginx:1.14.2"
    check c0.get("ports").getArray()[0].get("containerPort").getInt == 80
    check c0.get("env").getArray()[0].get("value").getStr == "production"
    check c0.get("env").getArray()[1].get("value").getStr == "false"
    check c0.get("resources.limits.cpu").getStr == "500m"
    check n.get("spec.template.spec.tolerations").getArray().len == 0
    check n.get("spec.template.spec.nodeSelector").kind == yamlObject

  test "github-actions workflow with expressions and anchors":
    let src = """
name: CI
on:
  push:
    branches: [main]
  pull_request:
env:
  NODE_ENV: test
jobs:
  build: &build
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: |
          npm ci
          npm run build
  test:
    runs-on: ubuntu-latest
    needs: build
    steps:
      - run: npm test
"""
    let n = parseYAMLNode(src)
    check n.get("name").getStr == "CI"
    check n.get("on.push.branches").getArray()[0].getStr == "main"
    check n.get("env.NODE_ENV").getStr == "test"
    check n.get("jobs").objValue.len == 2
    check n.get("jobs.build.steps").getArray().len == 2
    check n.get("jobs.build.steps").getArray()[1].get("run").getStr ==
      "npm ci\nnpm run build\n"
    check n.get("jobs.test.needs").getStr == "build"

  test "anchors, aliases and merge keys":
    let src = """
defaults: &defaults
  adapter: postgres
  host: localhost
development:
  <<: *defaults
  database: dev
test:
  <<: *defaults
  database: test
"""
    let n = parseYAMLNode(src)
    check n.get("development.adapter").getStr == "postgres"
    check n.get("development.host").getStr == "localhost"
    check n.get("development.database").getStr == "dev"
    check n.get("test.adapter").getStr == "postgres"
    check n.get("test.database").getStr == "test"

  test "docker-compose with nested lists and empty values":
    let src = """
version: "3.9"
services:
  web:
    build: .
    ports:
      - "8080:80"
      - "8443:443"
    environment:
      - DEBUG=1
    depends_on:
      - db
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost"]
      interval: 30s
  db:
    image: postgres:15
    volumes:
      - db_data:/var/lib/postgresql/data
    environment:
      POSTGRES_PASSWORD:
volumes:
  db_data: {}
"""
    let n = parseYAMLNode(src)
    check n.get("version").getStr == "3.9"
    check n.get("services.web.ports").getArray().len == 2
    check n.get("services.web.ports").getArray()[0].getStr == "8080:80"
    check n.get("services.web.environment").getArray()[0].getStr == "DEBUG=1"
    check n.get("services.web.depends_on").getArray()[0].getStr == "db"
    check n.get("services.web.healthcheck.test").getArray()[0].getStr == "CMD"
    check n.get("services.db.image").getStr == "postgres:15"
    check n.get("services.db.environment.POSTGRES_PASSWORD").kind == yamlNull
    check n.get("volumes.db_data").kind == yamlObject

  test "openapi document with quoted keys and numbers":
    let src = """
openapi: 3.0.0
info:
  title: "Sample API"
  version: 1.0.0
paths:
  /users/{id}:
    get:
      parameters:
        - name: id
          in: path
          required: true
          schema:
            type: string
      responses:
        "200":
          description: OK
          content:
            application/json:
              schema:
                type: object
"""
    let n = parseYAMLNode(src)
    check n.get("openapi").getStr == "3.0.0"
    check n.get("info.title").getStr == "Sample API"
    check n.get("paths").objValue.hasKey("/users/{id}")
    check n.get("paths./users/{id}.get.parameters").getArray()[0].get("required").getBool
    check n.get("paths./users/{id}.get.responses").objValue.hasKey("200")

  test "typed: round-trip through a Nim object graph":
    type Env = object
      name: string
      value: string
    type Container = object
      name: string
      image: string
      ports: seq[int]
      env: seq[Env]
    type Pod = object
      containers: seq[Container]
    type Manifest = object
      name: string
      replicas: int
      labels: Table[string, string]
      spec: Pod
    let src = """
name: demo
replicas: 2
labels:
  app: demo
  tier: web
spec:
  containers:
    - name: api
      image: api:1
      ports: [8080, 8081]
      env:
        - name: A
          value: "1"
        - name: B
          value: "2"
"""
    let m = parseYAML(src, Manifest)
    check m.name == "demo"
    check m.replicas == 2
    check m.labels["tier"] == "web"
    check m.spec.containers.len == 1
    check m.spec.containers[0].ports == @[8080, 8081]
    check m.spec.containers[0].env.len == 2
    check m.spec.containers[0].env[1].value == "2"

  test "typed: deep nesting, sets, enums and tuples":
    type Level = enum
      lvDebug, lvInfo, lvError
    type Cfg = object
      level: Level
      tags: set[Tag]
      coords: tuple[x: int, y: int]
      thresholds: Table[string, float]
      matrix: array[2, seq[int]]
    let src = """
level: lvInfo
tags: [tgA, tgB, tgC]
coords: {x: 3, y: 4}
thresholds:
  cpu: 0.75
  mem: 1.5
matrix:
  - [1, 2]
  - [3, 4]
"""
    let c = parseYAML(src, Cfg)
    check c.level == lvInfo
    check tgB in c.tags
    check tgD notin c.tags
    check c.coords.x == 3
    check c.thresholds["cpu"] == 0.75
    check c.matrix[1] == @[3, 4]

  test "dumper reproduces the manifest shape":
    let src = """
name: demo
items:
  - a: 1
    b: [x, y]
  - a: 2
    b: []
empty: {}
nothing:
flag: true
ratio: 0.5
text: |
  line one
  line two
"""
    let n = parseYAMLNode(src)
    let dumped = dump(n)
    # Every document the dumper writes must read back identically.
    let back = parseYAMLNode(dumped)
    check back.get("name").getStr == "demo"
    check back.get("items").getArray().len == 2
    check back.get("items").getArray()[0].get("b").getArray().len == 2
    check back.get("items").getArray()[1].get("b").getArray().len == 0
    check back.get("empty").kind == yamlObject
    check back.get("nothing").kind == yamlNull
    check back.get("flag").getBool
    check back.get("ratio").getFloat == 0.5
    check back.get("text").getStr == "line one\nline two\n"
    # Block scalars are emitted as block style rather than quoted text, so the
    # output stays readable for the common "text with newlines" case.
    check dumped.contains("text: |")
    check not dumped.contains("folded")
    check not dumped.contains("\t")
    # No line may carry trailing whitespace.
    for line in dumped.splitLines:
      check line.len == 0 or line[^1] notin {' ', '\t'}
