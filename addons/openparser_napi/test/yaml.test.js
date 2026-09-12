'use strict';
const { describe, it } = require('node:test');
const assert = require('node:assert/strict');
const { yaml } = require('../index.js');

describe('yaml', () => {
  it('parses mappings, sequences and scalars', () => {
    const doc = yaml.parse('host: localhost\nport: 8080\ndebug: true\ntags: [a, b]\n');
    assert.equal(doc.host, 'localhost');
    assert.equal(doc.port, 8080);
    assert.equal(doc.debug, true);
    assert.deepEqual(doc.tags, ['a', 'b']);
  });

  it('serializes a JSON document', () => {
    const out = yaml.dump('{"a":1,"b":"x"}');
    assert.ok(out.includes('a: 1'));
    assert.ok(out.includes('b: x'));
  });

  it('round-trips parse/dump', () => {
    const doc = yaml.parse(yaml.dump('{"a":[1,2]}'));
    assert.deepEqual(doc.a, [1, 2]);
  });

  it('throws on invalid input', () => {
    assert.throws(() => yaml.parse('key: [unclosed'), Error);
  });
});
