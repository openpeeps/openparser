import std/[unittest, options, strutils]
import ../src/openparser/path

test "parse http url with auth, query and fragment":
  let raw = "https://user:pass@example.com:8080/path/to/file.html?q=1&page=2#section"
  let p = parsePath(raw)
  check p.kind == pkWeb
  check p.scheme == "https"
  check p.auth.isSome
  let a = p.auth.get()
  check a.user == "user"
  check a.password.isSome and a.password.get() == "pass"
  check p.host == "example.com"
  check p.port.isSome and p.port.get() == 8080
  check p.pathSegments.len == 3
  check p.pathSegments[^1] == "file.html"
  check p.ext.isSome and p.ext.get() == "html"
  check p.query.len == 2
  check p.query[0].key == "q" and p.query[0].value == "1"
  check p.query[1].key == "page" and p.query[1].value == "2"
  check p.fragment.isSome and p.fragment.get() == "section"
  check $p == raw

test "parse ssh url":
  let p = parsePath("ssh://deploy@192.168.1.1:22/var/www")
  check p.kind == pkSSH
  check p.scheme == "ssh"
  check p.auth.isSome and p.auth.get().user == "deploy"
  check p.host == "192.168.1.1"
  check p.port.isSome and p.port.get() == 22
  check p.pathSegments == @["var", "www"]
  check p.ext.isNone

test "parse git+ssh url":
  let p = parsePath("git+ssh://git@github.com/user/repo.git")
  check p.kind == pkGit
  check p.scheme == "git+ssh"
  check p.host == "github.com"
  check p.auth.isSome and p.auth.get().user == "git"
  check p.pathSegments[^1] == "repo.git"
  check p.ext.isSome and p.ext.get() == "git"

test "parse mailto":
  let p = parsePath("mailto:hello@example.com")
  check p.kind == pkMail
  check p.scheme == "mailto"
  check p.host == "hello@example.com"
  check p.path == ""

test "local absolute path parsing":
  let p = parsePath("/home/user/docs/file.txt")
  check p.isLocal
  check p.isAbsolute
  check p.segments == @["home", "user", "docs", "file.txt"]
  check p.localExt.isSome and p.localExt.get() == "txt"
  check $p == "/home/user/docs/file.txt"

test "windows path parsing and normalization":
  let p = parsePath("C:\\Users\\George\\file.nim")
  check p.isLocal
  check p.drive.isSome and p.drive.get() == "C"
  check p.segments[^1] == "file.nim"
  check p.localExt.isSome and p.localExt.get() == "nim"
  check $p == "C:/Users/George/file.nim"

test "ipv6 host with port":
  let p = parsePath("http://[2001:db8::1]:8080/path")
  check p.kind == pkWeb
  check p.host == "2001:db8::1"
  check p.port.isSome and p.port.get() == 8080
  check p.pathSegments == @["path"]

test "file scheme with host":
  let p = parsePath("file://localhost/etc/hosts")
  check p.kind == pkLocal
  check p.scheme == "file"
  check p.host == "localhost"
  check p.pathSegments == @["etc", "hosts"]
  check p.ext.isNone

test "scp-style treated as local (no scheme)":
  let p = parsePath("git@github.com:user/repo.git")
  check p.isLocal
  check p.segments.len >= 2
  check p.segments[0].contains("git@github.com:user")
  check p.segments[^1] == "repo.git"

test "query parsing multiple pairs":
  let p = parsePath("http://example.com/path?x=1&y=two")
  check p.kind == pkWeb
  check p.query.len == 2
  check p.query[0] == ("x", "1")
  check p.query[1] == ("y", "two")