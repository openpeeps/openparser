'use strict';
const { describe, it } = require('node:test');
const assert = require('node:assert/strict');
const { uuid } = require('../index.js');

describe('uuid', () => {
  it('validates UUID strings', () => {
    assert.equal(uuid.isValid('6ba7b810-9dad-11d1-80b4-00c04fd430c8'), true);
    assert.equal(uuid.isValid('nope'), false);
  });

  it('generates time-based v1, v6 and DCE v2 UUIDs', () => {
    for (const v of [uuid.v1(), uuid.v6()]) {
      assert.ok(uuid.isValid(v));
      assert.equal(uuid.variant(v), 'RFC4122');
    }
    assert.equal(uuid.version(uuid.v1()), 1);
    assert.equal(uuid.version(uuid.v6()), 6);
    const v2 = uuid.v2(0, 1000);
    assert.ok(uuid.isValid(v2));
    assert.equal(uuid.version(v2), 2);
    assert.throws(() => uuid.v2(256, 1), Error);
    assert.throws(() => uuid.v2(0, -1), Error);
  });

  it('matches RFC 4122 v3/v5 test vectors', () => {
    assert.equal(uuid.v3('dns', 'www.example.com'),
      '5df41881-3aed-3515-88a7-2f4a814cf09e');
    assert.equal(uuid.v5('dns', 'www.example.com'),
      '2ed6657d-e927-568b-95e1-2665a8aea6a2');
    // explicit namespace UUID behaves like its named alias
    assert.equal(uuid.v5('6ba7b810-9dad-11d1-80b4-00c04fd430c8', 'www.example.com'),
      uuid.v5('dns', 'www.example.com'));
    assert.throws(() => uuid.v3('bogus-ns', 'x'), Error);
  });

  it('supports v8 custom and nil UUIDs', () => {
    const v8 = uuid.v8('0123456789abcdef0123456789abcdef');
    assert.equal(uuid.version(v8), 8);
    assert.equal(uuid.variant(v8), 'RFC4122');
    assert.equal(uuid.nil(), '00000000-0000-0000-0000-000000000000');
  });

  it('parses to canonical form', () => {
    assert.equal(uuid.parse('6ba7b810-9dad-11d1-80b4-00c04fd430c8'),
      '6ba7b810-9dad-11d1-80b4-00c04fd430c8');
    assert.equal(uuid.version('6ba7b810-9dad-11d1-80b4-00c04fd430c8'), 1);
  });

  it('throws on invalid input', () => {
    assert.throws(() => uuid.parse('nope'), Error);
  });
});
