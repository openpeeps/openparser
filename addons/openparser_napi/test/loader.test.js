'use strict';
const { describe, it } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const addon = require('../index.js');

describe('loader', () => {
  it('exposes all 18 namespaces', () => {
    for (const ns of ['yaml', 'toml', 'xml', 'csv', 'bson', 'plist',
        'rss', 'atom', 'dotenv', 'ical', 'vcard', 'sql', 'gettext',
        'qr', 'svg', 'colors', 'css', 'uuid', 'path']) {
      assert.equal(typeof addon[ns], 'object', ns);
    }
  });

  it('reports the loaded binary', () => {
    assert.match(addon.nativePair, /^(darwin|linux|win32)-(arm64|x64)$/);
    assert.ok(fs.existsSync(addon.binaryPath));
  });

  it('propagates Nim errors as JS errors', () => {
    assert.throws(() => addon.yaml.parse('key: [unclosed'), Error);
  });
});
