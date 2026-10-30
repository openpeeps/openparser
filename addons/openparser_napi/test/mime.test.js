'use strict';
const { describe, it } = require('node:test');
const assert = require('node:assert/strict');
const { mime } = require('../index.js');

const SIMPLE = 'From: Boss <boss@example.com>\r\n' +
  'To: team@example.com\r\n' +
  'Subject: hello\r\n' +
  'Date: Wed, 02 Oct 2024 08:00:00 +0200\r\n' +
  'Message-ID: <abc@example.com>\r\n' +
  'MIME-Version: 1.0\r\n' +
  'Content-Type: text/plain; charset=utf-8\r\n' +
  '\r\n' +
  'body text\r\n';

const MULTIPART = 'From: a@example.com\r\n' +
  'Subject: =?UTF-8?B?R3LDvMOfZQ==?=\r\n' +
  'Content-Type: multipart/mixed; boundary=outer\r\n' +
  '\r\n' +
  '--outer\r\n' +
  'Content-Type: text/plain; charset=utf-8\r\n' +
  'Content-Transfer-Encoding: base64\r\n' +
  '\r\n' +
  Buffer.from('Hello, base64 world', 'utf8').toString('base64') + '\r\n' +
  '--outer\r\n' +
  'Content-Type: application/pdf; name="doc.pdf"\r\n' +
  'Content-Transfer-Encoding: base64\r\n' +
  'Content-Disposition: attachment; filename="doc.pdf"\r\n' +
  '\r\n' +
  Buffer.from('%PDF-binary', 'utf8').toString('base64') + '\r\n' +
  '--outer--\r\n';

describe('mime', () => {
  it('parses headers and a text body', () => {
    const m = mime.parse(SIMPLE);
    assert.equal(m.subject, 'hello');
    assert.equal(m.from[0].addrSpec, 'boss@example.com');
    assert.equal(m.from[0].displayName, 'Boss');
    assert.equal(m.to[0].kind, 'mailbox');
    assert.equal(m.messageId, 'abc@example.com');
    assert.equal(m.mimeVersion, '1.0');
    assert.equal(m.date.year, 2024);
    assert.equal(m.date.offsetMinutes, 120);
    assert.equal(m.body.body.kind, 'text');
    assert.equal(m.body.body.text, 'body text\r\n');
  });

  it('decodes encoded-word subjects and base64 parts', () => {
    const m = mime.parse(MULTIPART);
    assert.equal(m.subject, 'Grüße');
    assert.equal(m.body.body.kind, 'multipart');
    assert.equal(m.body.body.parts.length, 2);
    const [text, bin] = m.body.body.parts;
    assert.equal(text.body.kind, 'text');
    assert.equal(text.body.text, 'Hello, base64 world');
    assert.equal(text.transferEncoding, 'base64');
    assert.equal(bin.body.kind, 'data');
    assert.equal(bin.filename, 'doc.pdf');
    assert.equal(
      Buffer.from(bin.body.dataBase64, 'base64').toString('utf8'),
      '%PDF-binary');
  });

  it('normalizes via round-trip', () => {
    const out = mime.normalize(SIMPLE);
    assert.ok(out.includes('Subject: hello'));
    const back = mime.parse(out);
    assert.equal(back.subject, 'hello');
    assert.equal(back.body.body.text, 'body text\r\n');
  });

  it('rejects poorly formed input in strict mode', () => {
    assert.throws(() => mime.parseStrict('Subject: no origination\r\n\r\nx'), Error);
  });

  it('rejects unrecoverable input', () => {
    assert.throws(() => mime.parse(
      'Content-Type: text/plain\r\n' +
      'Content-Transfer-Encoding: base64\r\n\r\n!!!not-base64!!!'), Error);
  });
});
