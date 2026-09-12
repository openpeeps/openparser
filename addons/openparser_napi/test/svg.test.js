'use strict';
const { describe, it } = require('node:test');
const assert = require('node:assert/strict');
const { svg } = require('../index.js');

describe('svg', () => {
  it('normalizes via round-trip', () => {
    const out = svg.normalize('<svg xmlns="http://www.w3.org/2000/svg"><rect width="10"/></svg>');
    assert.ok(out.includes('<rect'));
    assert.ok(out.includes('width="10"'));
  });

  it('parses path data to segments', () => {
    const segs = svg.parsePathData('M10 10 L20 20 Z');
    assert.equal(segs.length, 3);
    assert.equal(segs[0].cmd, 'M');
    assert.deepEqual(segs[0].args, [10, 10]);
    assert.equal(segs[2].cmd, 'Z');
  });
});
