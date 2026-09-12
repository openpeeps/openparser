'use strict';
const { describe, it } = require('node:test');
const assert = require('node:assert/strict');
const { colors } = require('../index.js');

describe('colors', () => {
  it('parses CSS colors to representations', () => {
    const c = colors.parse('red');
    assert.equal(c.hex, '#ff0000');
    assert.ok(c.rgb.includes('255'));
    assert.ok(c.hsl.includes('0'));
    assert.equal(typeof c.name, 'string');
  });

  it('validates color strings', () => {
    assert.equal(colors.isValid('red'), true);
    assert.equal(colors.isValid('oklch(0.7 0.15 180)'), true);
    assert.equal(colors.isValid('nope'), false);
  });

  it('manipulates colors', () => {
    assert.equal(colors.lighten('#800000', '20'), '#e60000');
    assert.equal(colors.darken('#800000', '20'), '#1a0000');
    assert.equal(colors.complement('red'), '#00ffff');
  });

  it('computes WCAG contrast', () => {
    assert.equal(colors.contrastRatio('white', 'black'), 21);
  });

  it('throws on invalid input', () => {
    assert.throws(() => colors.parse('nope'), Error);
  });
});
