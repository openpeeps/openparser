'use strict';
const { describe, it } = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { csv } = require('../index.js');

const fixture = path.join(__dirname, 'fixtures', 'test.csv');

describe('csv', () => {
  it('parses rows with quoted fields', () => {
    const rows = csv.parse('a,b\n1,"x,y"\n', ',', '"');
    assert.deepEqual(rows, [['a', 'b'], ['1', 'x,y']]);
  });

  it('supports custom delimiters', () => {
    assert.deepEqual(csv.parse('a;b\n1;2\n', ';', '"'), [['a', 'b'], ['1', '2']]);
  });

  it('parses files', () => {
    const rows = csv.parseFile(fixture, ',', '"');
    assert.equal(rows.length, 3);
    assert.equal(rows[1][0], 'Alice');
    assert.equal(rows[1][2], 'New York');
  });

  it('returns [] for empty input', () => {
    assert.deepEqual(csv.parse('', ',', '"'), []);
  });
});
