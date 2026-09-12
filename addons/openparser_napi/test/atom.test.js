'use strict';
const { describe, it } = require('node:test');
const assert = require('node:assert/strict');
const { atom } = require('../index.js');

const FEED = '<feed xmlns="http://www.w3.org/2005/Atom"><id>1</id>' +
  '<title>T</title><updated>2024-01-01</updated>' +
  '<entry><id>e1</id><title>E</title><updated>2024-01-02</updated>' +
  '<author><name>Ann</name></author></entry></feed>';

describe('atom', () => {
  it('parses feeds and entries', () => {
    const feed = atom.parse(FEED);
    assert.equal(feed.id, '1');
    assert.equal(feed.title.value, 'T');
    assert.equal(feed.entries.length, 1);
    assert.equal(feed.entries[0].authors[0].name, 'Ann');
  });

  it('normalizes via round-trip', () => {
    assert.ok(atom.normalize(FEED).includes('<id>1</id>'));
  });
});
