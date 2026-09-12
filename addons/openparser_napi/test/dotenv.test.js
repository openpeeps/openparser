'use strict';
const { describe, it } = require('node:test');
const assert = require('node:assert/strict');
const { dotenv } = require('../index.js');

describe('dotenv', () => {
  it('parses entries with keys and values', () => {
    const entries = dotenv.parse('DB_HOST=localhost\nDB_PORT=5432\n# comment\nEMPTY=\n');
    assert.equal(entries[0].key, 'DB_HOST');
    assert.equal(entries[0].value, 'localhost');
    assert.equal(entries[1].value, '5432');
    assert.equal(typeof entries[0].expand, 'boolean');
  });
});
