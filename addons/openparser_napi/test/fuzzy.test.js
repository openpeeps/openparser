'use strict';
const { describe, it } = require('node:test');
const assert = require('node:assert/strict');
const { fuzzy } = require('../index.js');

const approx = (a, b) => Math.abs(a - b) < 0.001;

describe('fuzzy', () => {
  it('scores an exact consecutive match', () => {
    const r = fuzzy.score('abc', 'abc', false);
    assert.equal(r.matched, true);
    assert.deepEqual(r.positions, [0, 1, 2]);
    assert.ok(approx(r.score, 82 / 3));
  });

  it('prefers consecutive over gapped matches', () => {
    const tight = fuzzy.score('abc', 'abc', false);
    const loose = fuzzy.score('abc', 'axbyc', false);
    assert.equal(loose.matched, true);
    assert.deepEqual(loose.positions, [0, 2, 4]);
    assert.ok(tight.score > loose.score);
  });

  it('is case-insensitive by default, exact on demand', () => {
    assert.equal(fuzzy.score('abc', 'ABC', false).matched, true);
    assert.equal(fuzzy.score('A', 'a', true).matched, false);
    assert.equal(fuzzy.score('A', 'A', true).matched, true);
  });

  it('reports no match for missing subsequences', () => {
    assert.equal(fuzzy.score('z', 'abc', false).matched, false);
    assert.equal(fuzzy.score('', 'abc', false).matched, false);
  });

  it('ranks candidates best-first with limit', () => {
    const words = ['application', 'apple', 'pineapple', 'app', 'append', 'banana', 'grape'];
    const res = fuzzy.search('app', JSON.stringify(words), false, 2, '0');
    assert.equal(res.length, 2);
    assert.equal(res[0].text, 'app');
    assert.ok(res[0].score >= res[1].score);
    assert.ok(Array.isArray(res[0].positions));
  });

  it('applies minScore filtering', () => {
    const words = ['app', 'apple', 'application', 'banana'];
    const all = fuzzy.search('app', JSON.stringify(words), false, 0, '0');
    const strict = fuzzy.search('app', JSON.stringify(words), false, 0, '20');
    assert.ok(strict.length < all.length);
    for (const m of strict) assert.ok(m.score >= 20);
  });
});
