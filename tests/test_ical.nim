import std/[unittest, options, os, strutils, sequtils]
import openparser/ical

suite "iCal parsing - minimal":

  test "minimal calendar with one event":
    let src = "BEGIN:VCALENDAR\r\nPRODID:-//Test//EN\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nUID:1@example.com\r\nDTSTAMP:20240115T120000Z\r\nDTSTART:20240115T130000Z\r\nSUMMARY:Hello\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"
    let cal = parseIcal(src)
    check cal.prodId.get == "-//Test//EN"
    check cal.version.get == "2.0"
    check cal.components.len == 1
    check cal.components[0].kind == cckEvent
    let ev = cal.components[0].event
    check ev.uid == "1@example.com"
    check ev.summary.get == "Hello"
    check ev.dtStart.get.dt.year == 2024
    check ev.dtStart.get.dt.isUtc == true

  test "LF endings accepted (lenient)":
    let src = "BEGIN:VCALENDAR\nPRODID:-//Test//EN\nVERSION:2.0\nBEGIN:VEVENT\nUID:a@b\nDTSTAMP:20240115T120000Z\nDTSTART:20240116\nSUMMARY:LF test\nEND:VEVENT\nEND:VCALENDAR\n"
    let cal = parseIcal(src)
    check cal.components[0].event.summary.get == "LF test"
    check cal.components[0].event.dtStart.get.dt.hasTime == false

  test "DATE vs DATE-TIME distinction":
    let src = "BEGIN:VCALENDAR\r\nPRODID:-//x//EN\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nUID:2@x\r\nDTSTAMP:20240115T120000Z\r\nDTSTART;VALUE=DATE:20240120\r\nDTEND;VALUE=DATE:20240121\r\nSUMMARY:All day\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"
    let cal = parseIcal(src)
    let ev = cal.components[0].event
    check ev.dtStart.get.dt.hasTime == false
    check ev.dtEnd.get.dt.hasTime == false
    check ev.dtEnd.get.dt.day == 21

  test "TZID param preserved":
    let src = "BEGIN:VCALENDAR\r\nPRODID:-//x//EN\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nUID:3@x\r\nDTSTAMP:20240115T120000Z\r\nDTSTART;TZID=America/New_York:20240115T090000\r\nSUMMARY:TZ test\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"
    let cal = parseIcal(src)
    check cal.components[0].event.dtStart.get.tzid.get == "America/New_York"

  test "escaping TEXT ; , \\n \\":
    let src = "BEGIN:VCALENDAR\r\nPRODID:-//x//EN\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nUID:4@x\r\nDTSTAMP:20240115T120000Z\r\nDTSTART:20240115T130000Z\r\nSUMMARY:Comma\\, semicolon\\; newline\\n backslash\\\\\r\nDESCRIPTION:Line1\\nLine2\\, with\\; escapes\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"
    let cal = parseIcal(src)
    check cal.components[0].event.summary.get == "Comma, semicolon; newline\n backslash\\"
    # description contains newline char 10
    check '\n' in cal.components[0].event.description.get

  test "attendee/organizer with CN quoted containing comma":
    let src = "BEGIN:VCALENDAR\r\nPRODID:-//x//EN\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nUID:5@x\r\nDTSTAMP:20240115T120000Z\r\nDTSTART:20240115T130000Z\r\nORGANIZER;CN=\"Doe, John\":mailto:john@example.com\r\nATTENDEE;CN=\"Smith, Jane\";PARTSTAT=ACCEPTED:mailto:jane@example.com\r\nATTENDEE:mailto:bob@example.com\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"
    let cal = parseIcal(src)
    let ev = cal.components[0].event
    check ev.organizer.get.cn.get == "Doe, John"
    check ev.attendees.len == 2
    check ev.attendees[0].cn.get == "Smith, Jane"
    var hasPart = false
    for pr in ev.attendees[0].params:
      if pr.name.toUpperAscii() == "PARTSTAT": hasPart = true
    check hasPart

  test "categories comma-separated":
    let src = "BEGIN:VCALENDAR\r\nPRODID:-//x//EN\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nUID:6@x\r\nDTSTAMP:20240115T120000Z\r\nDTSTART:20240115T130000Z\r\nCATEGORIES:MEETING,WORK,PERSONAL\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"
    let cal = parseIcal(src)
    check cal.components[0].event.categories == @["MEETING","WORK","PERSONAL"]

  test "RRULE raw preserved":
    let src = "BEGIN:VCALENDAR\r\nPRODID:-//x//EN\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nUID:7@x\r\nDTSTAMP:20240115T120000Z\r\nDTSTART:20240115T090000Z\r\nRRULE:FREQ=WEEKLY;COUNT=10;BYDAY=MO,WE,FR\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"
    let cal = parseIcal(src)
    check cal.components[0].event.rrule.get == "FREQ=WEEKLY;COUNT=10;BYDAY=MO,WE,FR"

  test "DURATION weeks and negative":
    let src = "BEGIN:VCALENDAR\r\nPRODID:-//x//EN\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nUID:8@x\r\nDTSTAMP:20240115T120000Z\r\nDTSTART:20240115T090000Z\r\nDURATION:P1W\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"
    let cal = parseIcal(src)
    check cal.components[0].event.duration.get.weeks == 1
    check parseIcalDuration("-P1DT2H").negative == true
    check parseIcalDuration("-P1DT2H").hours == 2

  test "VALARM nested":
    let src = "BEGIN:VCALENDAR\r\nPRODID:-//x//EN\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nUID:9@x\r\nDTSTAMP:20240115T120000Z\r\nDTSTART:20240115T130000Z\r\nBEGIN:VALARM\r\nACTION:DISPLAY\r\nDESCRIPTION:Reminder\r\nTRIGGER:-PT15M\r\nEND:VALARM\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"
    let cal = parseIcal(src)
    check cal.components[0].event.alarms.len == 1
    check cal.components[0].event.alarms[0].action == "DISPLAY"
    check cal.components[0].event.alarms[0].trigger.get.kind == trkRelative

  test "VTODO":
    let src = "BEGIN:VCALENDAR\r\nPRODID:-//x//EN\r\nVERSION:2.0\r\nBEGIN:VTODO\r\nUID:todo1@x\r\nDTSTAMP:20240115T120000Z\r\nDUE:20240120T120000Z\r\nSUMMARY:Buy milk\r\nPERCENT-COMPLETE:50\r\nEND:VTODO\r\nEND:VCALENDAR\r\n"
    let cal = parseIcal(src)
    check cal.components[0].kind == cckTodo
    check cal.components[0].todo.summary.get == "Buy milk"
    check cal.components[0].todo.percentComplete.get == 50

  test "VJOURNAL":
    let src = "BEGIN:VCALENDAR\r\nPRODID:-//x//EN\r\nVERSION:2.0\r\nBEGIN:VJOURNAL\r\nUID:j1@x\r\nDTSTAMP:20240115T120000Z\r\nSUMMARY:Daily note\r\nDESCRIPTION:Did stuff\r\nEND:VJOURNAL\r\nEND:VCALENDAR\r\n"
    let cal = parseIcal(src)
    check cal.components[0].kind == cckJournal
    check cal.components[0].journal.summary.get == "Daily note"

  test "VTIMEZONE with STANDARD/DAYLIGHT":
    let src = "BEGIN:VCALENDAR\r\nPRODID:-//x//EN\r\nVERSION:2.0\r\nBEGIN:VTIMEZONE\r\nTZID:America/New_York\r\nBEGIN:STANDARD\r\nDTSTART:19701101T020000\r\nTZOFFSETFROM:-0400\r\nTZOFFSETTO:-0500\r\nTZNAME:EST\r\nEND:STANDARD\r\nBEGIN:DAYLIGHT\r\nDTSTART:19700308T020000\r\nTZOFFSETFROM:-0500\r\nTZOFFSETTO:-0400\r\nTZNAME:EDT\r\nEND:DAYLIGHT\r\nEND:VTIMEZONE\r\nEND:VCALENDAR\r\n"
    let cal = parseIcal(src)
    check cal.components[0].kind == cckTimezone
    check cal.components[0].timezone.tzid == "America/New_York"
    check cal.components[0].timezone.standard.len == 1
    check cal.components[0].timezone.daylight.len == 1
    check cal.components[0].timezone.standard[0].offsetTo.get == "-0500"

  test "X-prop on calendar":
    let src = "BEGIN:VCALENDAR\r\nPRODID:-//x//EN\r\nVERSION:2.0\r\nX-WR-CALNAME:My Calendar\r\nX-APPLE-CALENDAR-COLOR:#FF0000\r\nBEGIN:VEVENT\r\nUID:10@x\r\nDTSTAMP:20240115T120000Z\r\nDTSTART:20240115T130000Z\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"
    let cal = parseIcal(src)
    check cal.extraProps.len >= 2
    let names = cal.extraProps.mapIt(norm(it.name))
    check "X-WR-CALNAME" in names

suite "iCal writing":

  test "round-trip toIcal -> parseIcal identity":
    let src = "BEGIN:VCALENDAR\r\nPRODID:-//Test//EN\r\nVERSION:2.0\r\nCALSCALE:GREGORIAN\r\nBEGIN:VEVENT\r\nUID:rt@x\r\nDTSTAMP:20240115T120000Z\r\nDTSTART:20240120T090000Z\r\nDTEND:20240120T100000Z\r\nSUMMARY:Round trip\r\nDESCRIPTION:With\\n newline and comma\\, etc\r\nLOCATION:Room 1\r\nCATEGORIES:A,B,C\r\nATTENDEE;CN=\"Doe, Jane\":mailto:jane@example.com\r\nBEGIN:VALARM\r\nACTION:DISPLAY\r\nDESCRIPTION:Reminder\r\nTRIGGER:-PT10M\r\nEND:VALARM\r\nEND:VEVENT\r\nBEGIN:VTODO\r\nUID:todo-rt@x\r\nDTSTAMP:20240115T120000Z\r\nDUE:20240125T120000Z\r\nSUMMARY:Todo rt\r\nEND:VTODO\r\nEND:VCALENDAR\r\n"
    let cal = parseIcal(src)
    let outStr = toIcal(cal)
    let cal2 = parseIcal(outStr)
    check cal2.components.len == cal.components.len
    check cal2.components[0].event.summary.get == cal.components[0].event.summary.get
    check cal2.components[0].event.description.get == cal.components[0].event.description.get
    check cal2.components[0].event.categories == cal.components[0].event.categories
    check cal2.components[1].todo.summary.get == "Todo rt"

  test "folding long description (75 octets)":
    let longDesc = "A".repeat(300)
    var cal = IcalCalendar(prodId: some("-//t//EN"), version: some("2.0"))
    var ev = IcalEvent(uid: "long@x", description: some(longDesc))
    ev.dtstamp = some(IcalDt(dt: parseIcalDateTime("20240115T120000Z")))
    ev.dtStart = some(IcalDt(dt: parseIcalDateTime("20240115T130000Z")))
    cal.components.add(IcalComponent(kind: cckEvent, event: ev))
    let txt = toIcal(cal)
    for line in txt.split("\r\n"):
      if line.len == 0: continue
      if line[0] == ' ': continue # continuation
      # unfolded logical lines check? Actually folded physical lines each must be <=75
      # Our split already gives physical lines
      check line.len <= 75
    let cal2 = parseIcal(txt)
    check cal2.components[0].event.description.get == longDesc

  test "UTF-8 not split inside fold":
    let emoji = "🎉".repeat(80) # 4 bytes each -> 320 bytes
    var cal = IcalCalendar(prodId: some("-//t//EN"), version: some("2.0"))
    var ev = IcalEvent(uid: "utf8@x", summary: some(emoji))
    ev.dtstamp = some(IcalDt(dt: parseIcalDateTime("20240115T120000Z")))
    ev.dtStart = some(IcalDt(dt: parseIcalDateTime("20240115T130000Z")))
    cal.components.add(IcalComponent(kind: cckEvent, event: ev))
    let txt = toIcal(cal)
    # all bytes must be valid utf8; parse back
    let cal2 = parseIcal(txt)
    check cal2.components[0].event.summary.get == emoji

  test "unfolding continuation":
    # folded description: lines folded at 75 with leading space
    let src = "BEGIN:VCALENDAR\r\nPRODID:-//x//EN\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nUID:fold@x\r\nDTSTAMP:20240115T120000Z\r\nDTSTART:20240115T130000Z\r\nDESCRIPTION:This is a very long description that definitely exceeds seventy five characters\r\n and continues here with more text.\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"
    let cal = parseIcal(src)
    check cal.components[0].event.description.get == "This is a very long description that definitely exceeds seventy five charactersand continues here with more text."

  test "EXDATE multi value and TZID":
    let src = "BEGIN:VCALENDAR\r\nPRODID:-//x//EN\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nUID:ex@x\r\nDTSTAMP:20240115T120000Z\r\nDTSTART;TZID=Europe/Berlin:20240115T090000\r\nEXDATE;TZID=Europe/Berlin:20240116T090000,20240117T090000\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"
    let cal = parseIcal(src)
    check cal.components[0].event.exdates.len == 2
    check cal.components[0].event.exdates[0].tzid.get == "Europe/Berlin"

  test "parseIcalFile round-trip file":
    let tmp = getTempDir() / "openparser_ical_test.ics"
    let src = "BEGIN:VCALENDAR\r\nPRODID:-//file//EN\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nUID:file@x\r\nDTSTAMP:20240115T120000Z\r\nDTSTART:20240115T130000Z\r\nSUMMARY:File test\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"
    writeFile(tmp, src)
    let cal = parseIcalFile(tmp)
    check cal.components[0].event.summary.get == "File test"
    removeFile(tmp)

  test "from objects toIcal emits escapes":
    var cal = IcalCalendar(prodId: some("-//obj//EN"), version: some("2.0"), calscale: some("GREGORIAN"))
    var ev = IcalEvent(uid: "obj1@x")
    ev.dtstamp = some(IcalDt(dt: parseIcalDateTime("20240115T120000Z")))
    ev.dtStart = some(IcalDt(dt: parseIcalDateTime("20240115T130000Z")))
    ev.summary = some("Hello, world; test\nnewline")
    ev.categories = @["A,B", "C;D"]
    ev.attendees.add(IcalPerson(uri: "mailto:att@example.com", cn: some("Att, One")))
    cal.components.add(IcalComponent(kind: cckEvent, event: ev))
    let txt = toIcal(cal)
    # escapes present
    check "\\," in txt
    check "\\;" in txt
    check "\\n" in txt
    let cal2 = parseIcal(txt)
    check cal2.components[0].event.summary.get == "Hello, world; test\nnewline"
    check cal2.components[0].event.categories == @["A,B", "C;D"]

suite "iCal errors":
  test "mismatched END raises":
    let src = "BEGIN:VCALENDAR\r\nPRODID:-//x//EN\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nUID:a@b\r\nEND:VTODO\r\nEND:VCALENDAR\r\n"
    expect(OpenParserIcalError): discard parseIcal(src)

  test "unclosed component raises":
    let src = "BEGIN:VCALENDAR\r\nPRODID:-//x//EN\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nUID:a@b\r\nEND:VCALENDAR\r\n"
    expect(OpenParserIcalError): discard parseIcal(src)

  test "invalid DATE-TIME raises":
    let src = "BEGIN:VCALENDAR\r\nPRODID:-//x//EN\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nUID:a@b\r\nDTSTAMP:20240115T120000Z\r\nDTSTART:2024-01-15\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"
    expect(OpenParserIcalError): discard parseIcal(src)

  test "invalid DURATION raises":
    expect(OpenParserIcalError): discard parseIcalDuration("P")
    expect(OpenParserIcalError): discard parseIcalDuration("PT")

  test "unterminated quoted param raises":
    let src = "BEGIN:VCALENDAR\r\nPRODID:-//x//EN\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nUID:a@b\r\nDTSTAMP:20240115T120000Z\r\nATTENDEE;CN=\"unclosed:mailto:a@b\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"
    expect(OpenParserIcalError): discard parseIcal(src)
