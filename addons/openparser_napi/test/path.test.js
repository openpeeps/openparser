'use strict';
const { describe, it } = require('node:test');
const assert = require('node:assert/strict');
const { path } = require('../index.js');

describe('path', () => {
  it('parses URLs', () => {
    const p = path.parse('https://user:pw@example.com:8080/a/b?x=1#frag');
    assert.equal(p.isLocal, false);
    assert.equal(p.host, 'example.com');
    assert.equal(p.port, 8080);
    assert.equal(p.auth.user, 'user');
    assert.equal(p.query[0].key, 'x');
    assert.equal(p.fragment, 'frag');
  });

  it('parses local paths', () => {
    const p = path.parse('/tmp/a/b.txt');
    assert.equal(p.isLocal, true);
    assert.deepEqual(p.segments, ['tmp', 'a', 'b.txt']);
    assert.equal(p.ext, 'txt');
  });

  it('normalizes via round-trip', () => {
    assert.ok(path.normalize('https://example.com/a?x=1').includes('example.com'));
  });
});
