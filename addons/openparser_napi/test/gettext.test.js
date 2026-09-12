'use strict';
const { describe, it } = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { gettext } = require('../index.js');

const po = path.join(__dirname, 'fixtures', 'test.po');

describe('gettext', () => {
  it('translates from .po files', () => {
    assert.equal(gettext.poTranslate(po, 'Hello', ''), 'Salut');
  });

  it('honors message context', () => {
    assert.equal(gettext.poTranslate(po, 'File', 'menu'), 'Fichier');
  });

  it('falls back to msgid when missing', () => {
    assert.equal(gettext.poTranslate(po, 'Missing', ''), 'Missing');
  });
});
