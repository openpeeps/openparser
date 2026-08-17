import std/[unittest, strutils]
import ../src/openparser/sql

doAssert $parseSql("""
SELECT
  CustomerName,
  ContactName,
  Address,
  City,
  PostalCode,
  Country,
  CustomerName,
  ContactName,
  Address,
  City,
  PostalCode,
  Country
FROM table;""") == "select CustomerName, ContactName, Address, City, PostalCode, Country, CustomerName, ContactName, Address, City, PostalCode, Country from table;"

doAssert $parseSql("SELECT foo FROM table limit 10") == "select foo from table limit 10;"
doAssert $parseSql("SELECT foo, bar, baz FROM table limit 10") == "select foo, bar, baz from table limit 10;"
doAssert $parseSql("SELECT foo AS bar FROM table") == "select foo as bar from table;"
doAssert $parseSql("SELECT foo AS foo_prime, bar AS bar_prime, baz AS baz_prime FROM table") == "select foo as foo_prime, bar as bar_prime, baz as baz_prime from table;"
doAssert $parseSql("SELECT * FROM table") == "select * from table;"
doAssert $parseSql("SELECT count(*) FROM table") == "select count(*) from table;"
doAssert $parseSql("SELECT count(*) as 'Total' FROM table") == "select count(*) as 'Total' from table;"
doAssert $parseSql("SELECT count(*) as 'Total', sum(a) as 'Aggr' FROM table") == "select count(*) as 'Total', sum(a) as 'Aggr' from table;"


doAssert $parseSql("""
SELECT * FROM table
WHERE a = b and c = d
""") == "select * from table where a = b and c = d;"

doAssert $parseSql("""
SELECT * FROM table
WHERE not b
""") == "select * from table where not b;"

doAssert $parseSql("""
SELECT
  *
FROM
  table
WHERE
  a and not b
""") == "select * from table where a and not b;"

doAssert $parseSql("""
SELECT * FROM table
ORDER BY 1
""") == "select * from table order by 1;"

doAssert $parseSql("""
SELECT * FROM table
GROUP BY 1
ORDER BY 1
""") == "select * from table group by 1 order by 1;"

doAssert $parseSql("""
SELECT * FROM table
ORDER BY 1
LIMIT 100
""") == "select * from table order by 1 limit 100;"


doAssert $parseSql("""
SELECT * FROM table
WHERE a = b and c = d or n is null and not b + 1 = 3
""") == "select * from table where a = b and c = d or n is null and not b + 1 = 3;"

doAssert $parseSql("""
SELECT * FROM table
WHERE (a = b and c = d) or (n is null and not b + 1 = 3)
""") == "select * from table where (a = b and c = d) or (n is null and not b + 1 = 3);"

doAssert $parseSql("""
SELECT * FROM table
HAVING a = b and c = d
""") == "select * from table having a = b and c = d;"

doAssert $parseSql("""
SELECT a, b FROM table
GROUP BY a
""") == "select a, b from table group by a;"

doAssert $parseSql("""
SELECT a, b FROM table
GROUP BY 1, 2
""") == "select a, b from table group by 1, 2;"

doAssert $parseSql("SELECT t.a FROM t as t") == "select t.a from t as t;"

doAssert $parseSql("""
SELECT a, b FROM (
  SELECT * FROM t
)
""") == "select a, b from(select * from t);"

doAssert $parseSql("""
SELECT a, b FROM (
  SELECT * FROM t
) as foo
""") == "select a, b from(select * from t) as foo;"

doAssert $parseSql("""
SELECT a, b FROM (
  SELECT * FROM (
    SELECT * FROM (
      SELECT * FROM (
        SELECT * FROM innerTable as inner1
      ) as inner2
    ) as inner3
  ) as inner4
) as inner5
""") == "select a, b from(select * from(select * from(select * from(select * from innerTable as inner1) as inner2) as inner3) as inner4) as inner5;"

doAssert $parseSql("""
SELECT a, b FROM
  (SELECT * FROM a),
  (SELECT * FROM b),
  (SELECT * FROM c)
""") == "select a, b from(select * from a), (select * from b), (select * from c);"

doAssert $parseSql("""
SELECT * FROM Products
WHERE Price BETWEEN 10 AND 20;
""") == "select * from Products where Price between 10 and 20;"

doAssert $parseSql("""
SELECT id FROM a
JOIN b
ON a.id == b.id
""") == "select id from a join b on a.id == b.id;"

doAssert $parseSql("""
SELECT id FROM a
JOIN (SELECT id from c) as b
ON a.id == b.id
""") == "select id from a join(select id from c) as b on a.id == b.id;"

doAssert $parseSql("""
SELECT id FROM a
INNER JOIN b
ON a.id == b.id
""") == "select id from a inner join b on a.id == b.id;"

# JOIN should parse as part of FROM, other fromItems may follow
doAssert $parseSql("""
SELECT id
FROM
    a JOIN b ON a.id = b.id,
    c
""") == "select id from a join b on a.id = b.id, c;"

# LEFT JOIN should parse
doAssert $parseSql("""
SELECT id FROM a
LEFT JOIN b
ON a.id = b.id
""") == "select id from a left join b on a.id = b.id;"

# NATURAL JOIN should parse
doAssert $parseSql("""
SELECT id FROM a
NATURAL JOIN b
""") == "select id from a natural join b;"

# USING should parse
doAssert $parseSql("""
SELECT id FROM a
JOIN b
USING (id)
""") == "select id from a join b using(id);"

# Multiple JOINs should parse
doAssert $parseSql("""
SELECT id FROM a
JOIN b
ON a.id = b.id
LEFT JOIN c
USING (id)
""") == "select id from a join b on a.id = b.id left join c using(id);"

# Parenthesized JOIN expressions should parse
doAssert $parseSql("""
SELECT id
FROM a JOIN (b JOIN c USING (id)) ON a.id = b.id
""") == "select id from a join(b join c using(id)) on a.id = b.id;"

# Left-side parenthesized JOIN expressions should parse

doAssert $parseSql("""
SELECT id
FROM (b JOIN c USING (id)) JOIN a ON a.id = b.id
""") == "select id from(b join c using(id)) join a on a.id = b.id;"