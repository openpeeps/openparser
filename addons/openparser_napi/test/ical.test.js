'use strict';
const { describe, it } = require('node:test');
const assert = require('node:assert/strict');
const { ical } = require('../index.js');

const ICS = 'BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//x//EN\r\n' +
  'BEGIN:VEVENT\r\nUID:1@x\r\nDTSTAMP:20240115T120000Z\r\n' +
  'DTSTART:20240115T130000Z\r\nDTEND:20240115T140000Z\r\n' +
  'SUMMARY:Hi\r\nCATEGORIES:A,B\r\n' +
  'ATTENDEE;CN="Doe, Jane":mailto:jane@example.com\r\n' +
  'BEGIN:VALARM\r\nACTION:DISPLAY\r\nDESCRIPTION:Ping\r\nTRIGGER:-PT15M\r\nEND:VALARM\r\n' +
  'END:VEVENT\r\nEND:VCALENDAR\r\n';

describe('ical', () => {
  it('parses typed components', () => {
    const cal = ical.parse(ICS);
    assert.equal(cal.version, '2.0');
    assert.equal(cal.components.length, 1);
    const ev = cal.components[0];
    assert.equal(ev.kind, 'event');
    assert.equal(ev.summary, 'Hi');
    assert.equal(ev.dtstart.value, '20240115T130000Z');
    assert.deepEqual(ev.categories, ['A', 'B']);
    assert.equal(ev.attendees[0].cn, 'Doe, Jane');
    assert.equal(ev.alarms[0].action, 'DISPLAY');
    assert.equal(ev.alarms[0].trigger.kind, 'relative');
  });

  it('normalizes via round-trip', () => {
    assert.ok(ical.normalize(ICS).includes('SUMMARY:Hi'));
  });

  it('throws on mismatched END', () => {
    assert.throws(() => ical.parse('BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nUID:a@b\r\nEND:VTODO\r\nEND:VCALENDAR\r\n'), Error);
  });
});
