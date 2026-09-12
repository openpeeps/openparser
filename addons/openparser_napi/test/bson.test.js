'use strict';
const { describe, it } = require('node:test');
const assert = require('node:assert/strict');
const { bson } = require('../index.js');

describe('bson', () => {
  it('round-trips JSON through base64 BSON', () => {
    const b64 = bson.fromJson('{"name":"Alice","age":30,"tags":["a"]}');
    assert.match(b64, /^[A-Za-z0-9+/=]+$/);
    const back = bson.toJson(b64);
    assert.equal(back.name, 'Alice');
    assert.equal(back.age, 30);
    assert.deepEqual(back.tags, ['a']);
  });

  it('throws on invalid base64', () => {
    assert.throws(() => bson.toJson('!!!not-base64!!!'), Error);
  });
});
