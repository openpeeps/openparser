import std/[unittest]
import ../src/openparser/sql

template rejects(driver: SqlDriver, q: string) =
  var failed = false
  try:
    discard parseSql(q, driver)
  except SqlParseError:
    failed = true
  check failed

suite "sql drivers: placeholders":
  test "pgsql $n ok, others rejected":
    check $parseSql("SELECT a FROM t WHERE b = $1", pgsql) ==
      "select a from t where b = $1;"
    rejects(pgsql, "SELECT a FROM t WHERE b = ?")
    rejects(pgsql, "SELECT a FROM t WHERE b = :name")
    rejects(pgsql, "SELECT a FROM t WHERE b = @name")
  test "mysql ? ok, pg/sqlite-named rejected":
    check $parseSql("SELECT a FROM t WHERE b = ?", mysql) ==
      "select a from t where b = ?;"
    rejects(mysql, "SELECT a FROM t WHERE b = $1")
    rejects(mysql, "SELECT a FROM t WHERE b = :name")
    rejects(mysql, "SELECT a FROM t WHERE b = @x")
  test "sqlite named + qmark ok, pg positional rejected":
    check $parseSql("SELECT a FROM t WHERE b = ?1", sqlite) ==
      "select a from t where b = ?1;"
    check $parseSql("SELECT a FROM t WHERE b = :n", sqlite) ==
      "select a from t where b = :n;"
    check $parseSql("SELECT a FROM t WHERE b = @n", sqlite) ==
      "select a from t where b = @n;"
    check $parseSql("SELECT a FROM t WHERE b = $n", sqlite) ==
      "select a from t where b = $n;"
    rejects(sqlite, "SELECT a FROM t WHERE b = $1")
  test "generic accepts everything":
    check $parseSql("SELECT $1", generic) == "select $1;"
    check $parseSql("SELECT ?", generic) == "select ?;"
    check $parseSql("SELECT :n", generic) == "select :n;"

suite "sql drivers: quotes and comments":
  test "pgsql rejects backticks, accepts dollar-quote":
    rejects(pgsql, "SELECT `a` FROM t")
    check $parseSql("SELECT $$hello$$", pgsql) == "select 'hello';"
    check $parseSql("SELECT $tag$x$tag$", pgsql) == "select 'x';"
  test "mysql hash comment + backticks":
    check $parseSql("SELECT a # hello\nFROM t", mysql) ==
      "select a from t;"
    check $parseSql("SELECT `a` FROM t", mysql) ==
      "select `a` from t;"
  test "pgsql rejects hash comments":
    rejects(pgsql, "SELECT a # hello\nFROM t")
    rejects(sqlite, "SELECT a # hello\nFROM t")
  test "sqlite bracket quoting":
    check $parseSql("SELECT [a] FROM t", sqlite) == "select [a] from t;"
  test "cast operator strict":
    check $parseSql("SELECT a::int FROM t", pgsql) ==
      "select a :: int from t;"
    rejects(mysql, "SELECT a::int FROM t")
    rejects(sqlite, "SELECT a::int FROM t")
    check $parseSql("SELECT CAST(a AS INT) FROM t", mysql) ==
      "select cast(a as INT) from t;"

suite "sql drivers: expressions and select":
  test "ilike pg only":
    check $parseSql("SELECT * FROM t WHERE x ILIKE 'a%'", pgsql) ==
      "select * from t where x ilike 'a%';"
    rejects(mysql, "SELECT * FROM t WHERE x ILIKE 'a%'")
    rejects(sqlite, "SELECT * FROM t WHERE x ILIKE 'a%'")
  test "case / cast / exists":
    check $parseSql("SELECT CASE WHEN a=1 THEN 2 ELSE 3 END FROM t", generic) ==
      "select case when a = 1 then 2 else 3 end from t;"
    check $parseSql("SELECT CAST(a AS INT) FROM t", generic) ==
      "select cast(a as INT) from t;"
    check $parseSql("SELECT * FROM t WHERE EXISTS (SELECT 1 FROM u)", generic) ==
      "select * from t where exists((select 1 from u));"
  test "with / union":
    check $parseSql("WITH c AS (SELECT 1) SELECT * FROM c", generic) ==
      "with c as (select 1) select * from c;"
    check $parseSql("SELECT a FROM t UNION ALL SELECT a FROM u", generic) ==
      "select a from t union all select a from u;"
    check $parseSql("SELECT a FROM t INTERSECT SELECT a FROM u", generic) ==
      "select a from t intersect select a from u;"
  test "distinct on + fetch pg only":
    check $parseSql("SELECT DISTINCT ON (a) a, b FROM t", pgsql) ==
      "select distinct on (a) a, b from t;"
    rejects(mysql, "SELECT DISTINCT ON (a) a FROM t")
    check $parseSql("SELECT a FROM t ORDER BY a FETCH FIRST 5 ROWS ONLY", pgsql) ==
      "select a from t order by a fetch first 5 rows only;"
    rejects(mysql, "SELECT a FROM t FETCH FIRST 5 ROWS ONLY")
  test "limit comma strictness":
    check $parseSql("SELECT a FROM t LIMIT 5, 10", mysql) ==
      "select a from t limit 5, 10;"
    check $parseSql("SELECT a FROM t LIMIT 5, 10", sqlite) ==
      "select a from t limit 5, 10;"
    rejects(pgsql, "SELECT a FROM t LIMIT 5, 10")
  test "window pg/sqlite only":
    check $parseSql("SELECT row_number() OVER (PARTITION BY a ORDER BY b) FROM t", pgsql) ==
      "select row_number() over (partition by, a, order by, b) from t;"
    rejects(mysql, "SELECT row_number() OVER (PARTITION BY a) FROM t")

suite "sql drivers: dml":
  test "returning pg/sqlite only":
    check $parseSql("SELECT a FROM t RETURNING a", pgsql) ==
      "select a from t returning a;"
    check $parseSql("SELECT a FROM t RETURNING a", sqlite) ==
      "select a from t returning a;"
    rejects(mysql, "SELECT a FROM t RETURNING a")
    rejects(mysql, "UPDATE t SET a = 1 RETURNING a")
    rejects(mysql, "DELETE FROM t RETURNING a")
  test "upserts":
    check $parseSql("INSERT INTO t (a) VALUES (1) ON CONFLICT (a) DO NOTHING", pgsql) ==
      "insert into t (a) values (1) on conflict (a) do nothing;"
    check $parseSql("INSERT INTO t (a) VALUES (1) ON CONFLICT (a) DO UPDATE SET a = 2", sqlite) ==
      "insert into t (a) values (1) on conflict (a) do update set a = 2;"
    rejects(mysql, "INSERT INTO t (a) VALUES (1) ON CONFLICT (a) DO NOTHING")
    check $parseSql("INSERT INTO t (a) VALUES (1) ON DUPLICATE KEY UPDATE a = 2", mysql) ==
      "insert into t (a) values (1) on duplicate key update a = 2;"
    rejects(pgsql, "INSERT INTO t (a) VALUES (1) ON DUPLICATE KEY UPDATE a = 2")
  test "replace mysql/sqlite only":
    check $parseSql("REPLACE INTO t (a) VALUES (1)", mysql) ==
      "replace into t (a) values (1);"
    check $parseSql("REPLACE INTO t (a) VALUES (1)", sqlite) ==
      "replace into t (a) values (1);"
    rejects(pgsql, "REPLACE INTO t (a) VALUES (1)")
  test "insert select + delete using":
    check $parseSql("INSERT INTO t (a) SELECT a FROM u", generic) ==
      "insert into t (a) select a from u;"
    check $parseSql("DELETE FROM t USING u WHERE t.a = u.a", pgsql) ==
      "delete from t using u where t.a = u.a;"

suite "sql drivers: ddl and utility":
  test "create view / schema":
    check $parseSql("CREATE VIEW v AS SELECT a FROM t", generic) ==
      "create view v as select a from t;"
    check $parseSql("CREATE SCHEMA IF NOT EXISTS s", generic) ==
      "create schema if not exists s;"
  test "sqlite pragma/vacuum":
    check $parseSql("PRAGMA journal_mode = WAL", sqlite) ==
      "pragma journal_mode = WAL;"
    check $parseSql("VACUUM", sqlite) == "vacuum;"
    rejects(pgsql, "PRAGMA journal_mode = WAL")
    rejects(mysql, "VACUUM")
  test "mysql alter modify":
    check $parseSql("ALTER TABLE t MODIFY COLUMN a VARCHAR(10)", mysql) ==
      "alter table t alter column a VARCHAR(10);"
    rejects(pgsql, "ALTER TABLE t MODIFY COLUMN a VARCHAR(10)")
  test "bit/hex literals":
    check $parseSql("SELECT B'01', X'1F' FROM t", generic) ==
      "select B'01', X'1F' from t;"
