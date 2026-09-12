'use strict';
const { describe, it } = require('node:test');
const assert = require('node:assert/strict');
const { toml } = require('../index.js');

describe('toml', () => {
  it('parses tables, values and datetimes', () => {
    const doc = toml.parse('[server]\nhost = "localhost"\nport = 8080\nd = 1979-05-27T07:32:00\n');
    assert.equal(doc.server.host, 'localhost');
    assert.equal(doc.server.port, 8080);
    assert.equal(doc.server.d, '1979-05-27T07:32:00');
  });

  it('serializes a JSON document', () => {
    const out = toml.dump('{"s":{"p":1}}');
    assert.ok(out.includes('[s]'));
    assert.ok(out.includes('p = 1'));
  });

  it('round-trips parse/dump', () => {
    const doc = toml.parse(toml.dump('{"a":{"b":true}}'));
    assert.equal(doc.a.b, true);
  });

  it('rejects JSON null', () => {
    assert.throws(() => toml.dump('{"a":null}'), Error);
  });
});
