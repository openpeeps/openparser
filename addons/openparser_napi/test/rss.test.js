'use strict';
const { describe, it } = require('node:test');
const assert = require('node:assert/strict');
const { rss } = require('../index.js');

const FEED = '<rss version="2.0"><channel><title>T</title><link>L</link>' +
  '<description>D</description>' +
  '<item><title>I1</title><link>http://ex.org/1</link></item>' +
  '<item><title>I2</title></item></channel></rss>';

describe('rss', () => {
  it('parses feeds and items', () => {
    const feed = rss.parse(FEED);
    assert.equal(feed.title, 'T');
    assert.equal(feed.items.length, 2);
    assert.equal(feed.items[0].title, 'I1');
    assert.equal(feed.items[0].link, 'http://ex.org/1');
    assert.equal(feed.items[1].link, null);
  });

  it('normalizes via round-trip', () => {
    assert.ok(rss.normalize(FEED).includes('<title>T</title>'));
  });
});
