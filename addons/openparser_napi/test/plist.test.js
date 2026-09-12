'use strict';
const { describe, it } = require('node:test');
const assert = require('node:assert/strict');
const { plist } = require('../index.js');

const XML = '<?xml version="1.0"?><plist version="1.0"><dict><key>A</key><string>B</string><key>N</key><integer>3</integer></dict></plist>';

describe('plist', () => {
  it('parses XML plists', () => {
    const doc = plist.parse(XML);
    assert.equal(doc.A, 'B');
    assert.equal(doc.N, 3);
  });

  it('serializes to XML plist', () => {
    const out = plist.toXml('{"A":"B"}');
    assert.ok(out.includes('<string>B</string>'));
  });

  it('round-trips through binary plist', () => {
    const b64 = plist.toBplist('{"A":"B"}');
    assert.ok(b64.startsWith('YnBsaXN0MD'));
    assert.equal(plist.parseBase64(b64).A, 'B');
  });
});
