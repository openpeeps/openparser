'use strict';
const { describe, it } = require('node:test');
const assert = require('node:assert/strict');
const { qr } = require('../index.js');

describe('qr', () => {
  it('builds payload strings', () => {
    assert.equal(qr.makeWifi('net', 'secret1234', 'WPA', false),
      'WIFI:T:WPA;S:net;P:secret1234;;');
    assert.equal(qr.makeMecard('John', '+100', '', ''),
      'MECARD:N:John;TEL:+100;;');
    assert.equal(qr.makeUrl('example.org'), 'https://example.org');
    assert.equal(qr.makeSms('+100', 'hi'), 'SMSTO:+100:hi');
    assert.equal(qr.makeEmail('a@b.org', 'Hi', 'Body'),
      'mailto:a@b.org?subject=Hi&body=Body');
  });

  it('encodes SVG symbols', () => {
    const svg = qr.encodeSvg('hello');
    assert.ok(svg.startsWith('<svg'));
    assert.ok(svg.trimEnd().endsWith('</svg>'));
  });

  it('encodes every symbology family', () => {
    assert.ok(qr.encodeModel2('hello model2', 'M', 0).startsWith('<svg'));
    assert.ok(qr.encodeModel2('hi', 'H', 1).startsWith('<svg'));
    assert.ok(qr.encodeMicro('12345', 'L', 0).startsWith('<svg'));
    assert.ok(qr.encodeRmqr('hello rmqr', 'M', '').startsWith('<svg'));
    assert.ok(qr.encodeModel1('HELLO', 'M', 0).startsWith('<svg'));
    assert.ok(qr.encodeAqr('main payload', 'ring', 'M', 0).startsWith('<svg'));
    assert.throws(() => qr.encodeModel2('x', 'Z', 0), Error);
    assert.throws(() => qr.encodeMicro('x', 'L', 9), Error);
  });

  it('round-trips SQRC payloads', () => {
    const key = '0123456789abcdef';
    const wrongKey = 'fedcba9876543210';
    const payload = qr.makeSqrc('public area', 'secret area', key, false);
    assert.equal(typeof payload, 'string');
    const split = qr.splitSqrc(payload);
    assert.equal(split.extended, false);
    assert.equal(split.publicData, 'public area');
    assert.ok(split.blobBase64.length > 0);
    const opened = qr.decodeSqrc(payload, key);
    assert.equal(opened.ok, true);
    assert.equal(opened.publicText, 'public area');
    assert.equal(opened.privateText, 'secret area');
    const denied = qr.decodeSqrc(payload, wrongKey);
    assert.equal(denied.publicText, 'public area');
    assert.equal(denied.privateText, '');
    const svg = qr.encodeSqrc('public area', 'secret area', key);
    assert.ok(svg.startsWith('<svg'));
    const ext = qr.splitSqrc(qr.makeSqrc('pub', 'priv', key, true));
    assert.equal(ext.extended, true);
    assert.throws(() => qr.splitSqrc('not a sqrc payload'), Error);
  });
});
