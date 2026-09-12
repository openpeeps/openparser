'use strict';
const { describe, it } = require('node:test');
const assert = require('node:assert/strict');
const { vcard } = require('../index.js');

const VCF = 'BEGIN:VCARD\r\nVERSION:4.0\r\nFN:Ada Lovelace\r\n' +
  'N:Lovelace;Ada;;;\r\nORG:OpenPeeps\r\n' +
  'TEL;PREF=1;TYPE=cell:+100\r\nEMAIL:ada@example.org\r\n' +
  'ADR:;;street;city;reg;zip;ctry\r\nEND:VCARD\r\n';

describe('vcard', () => {
  it('parses structured contact fields', () => {
    const cards = vcard.parse(VCF);
    assert.equal(cards.length, 1);
    const c = cards[0];
    assert.equal(c.version, '4.0');
    assert.equal(c.fn, 'Ada Lovelace');
    assert.equal(c.n.family, 'Lovelace');
    assert.equal(c.org.name, 'OpenPeeps');
    assert.equal(c.tels[0].value, '+100');
    assert.equal(c.tels[0].pref, 1);
    assert.equal(c.emails[0].value, 'ada@example.org');
    assert.equal(c.adrs[0].locality, 'city');
  });

  it('parses multiple cards', () => {
    const cards = vcard.parse(
      'BEGIN:VCARD\r\nVERSION:4.0\r\nFN:A\r\nEND:VCARD\r\n' +
      'BEGIN:VCARD\r\nVERSION:4.0\r\nFN:B\r\nEND:VCARD\r\n');
    assert.deepEqual(cards.map((c) => c.fn), ['A', 'B']);
  });

  it('normalizes to 4.0', () => {
    assert.ok(vcard.normalize(VCF).includes('VERSION:4.0'));
  });

  it('builds QR payloads by index', () => {
    const q = vcard.qrPayload(VCF, 0);
    assert.ok(q.includes('FN:Ada Lovelace'));
    assert.ok(q.includes('VERSION:3.0'));
  });

  it('rejects out-of-range card index', () => {
    assert.throws(() => vcard.qrPayload(VCF, 7), Error);
  });

  it('requires FN', () => {
    assert.throws(() => vcard.parse('BEGIN:VCARD\r\nVERSION:4.0\r\nEND:VCARD\r\n'), Error);
  });
});
