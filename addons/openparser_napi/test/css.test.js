'use strict';
const { describe, it } = require('node:test');
const assert = require('node:assert/strict');
const { css } = require('../index.js');

describe('css', () => {
  it('parses stylesheets to an AST', () => {
    const nodes = css.parse('a { color: red; margin: 0; }');
    assert.equal(nodes.length, 1);
    assert.equal(nodes[0].kind, 'ruleset');
    assert.equal(nodes[0].declarations.length, 2);
    assert.equal(nodes[0].declarations[0].property, 'color');
    assert.equal(nodes[0].declarations[0].value, 'red');
  });

  it('normalizes via round-trip', () => {
    assert.ok(css.normalize('a{color:red}').includes('color'));
  });
});
