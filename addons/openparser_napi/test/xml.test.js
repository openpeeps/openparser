'use strict';
const { describe, it } = require('node:test');
const assert = require('node:assert/strict');
const { xml } = require('../index.js');

describe('xml', () => {
  it('parses elements, attributes and children', () => {
    const node = xml.parse('<person name="Ada"><email>a@ex.org</email></person>');
    assert.equal(node.kind, 'element');
    assert.equal(node.tag, 'person');
    assert.equal(node.attrs.name, 'Ada');
    assert.equal(node.children[0].tag, 'email');
    assert.equal(node.children[0].children[0].kind, 'text');
  });

  it('normalizes via round-trip', () => {
    assert.equal(xml.normalize('<p><q>hi</q></p>'), '<p><q>hi</q></p>');
  });

  it('throws on malformed input', () => {
    assert.throws(() => xml.parse('<p><q></p>'), Error);
  });
});
