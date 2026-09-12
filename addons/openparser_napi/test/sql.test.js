'use strict';
const { describe, it } = require('node:test');
const assert = require('node:assert/strict');
const { sql } = require('../index.js');

describe('sql', () => {
  it('parses to an AST', () => {
    const node = sql.parse('SELECT a FROM t WHERE b = 1', 'generic');
    assert.ok(node.kind.startsWith('nk'));
    assert.ok(Array.isArray(node.children));
  });

  it('supports dialect selection', () => {
    const node = sql.parse('SELECT a FROM t', 'pgsql');
    assert.ok(node.kind.startsWith('nk'));
  });

  it('normalizes via render round-trip', () => {
    assert.equal(sql.normalize('select a from t', 'generic'), 'select a from t;');
  });
});
