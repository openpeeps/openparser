## Shared JsonNode converters for the Node.js addon.
##
## Included from `src/openparser.nim` under `napibuild` only, so the
## library itself is unaffected. NOTE: `import std/json except %*` is
## deliberate — denim exports its own `%*` macro for napi values, and
## using std/json's `%*` here would resolve to denim's and fail to
## compile. Build JsonNode values explicitly with `%`, `newJObject`,
## `newJArray` instead.

import std/json except `%*`
import std/[base64, memfiles, os, strutils, options, tempfiles, times,
  tables]

from ./yaml import parseYAML, YamlNode, YAMLObject, yamlString, yamlInteger,
  yamlFloat, yamlBoolean, yamlNull, yamlObject, yamlArray
from ./toml import parseTOML, TomlNode,
  tvkString, tvkInteger, tvkFloat, tvkBoolean, tvkDateTime, tvkArray, tvkTable,
  newTomlString, newTomlInteger, newTomlFloat, newTomlBoolean,
  newTomlArray, newTomlTable
from ./xml import fromXml, XmlNode,
  xnElement, xnText, xnComment, xnCdata, xnProlog, xnDoctype
from ./csv import parseFile, parseCsv, CsvFieldSlice, CsvOptions,
  defaultCsvOptions, toString
from ./bson import toBson, fromBson
from ./plist import parsePlist, toXmlPlist, toBPlist
from ./rss import RssFeed, RssItem, RssMediaContent
from ./feed import AtomFeed, AtomEntry, AtomPerson, AtomLink, AtomCategory,
  AtomText, AtomContent, AtomGenerator
from ./dotenv import DotenvEntry
from ./ical import IcalCalendar, IcalComponent, IcalEvent, IcalTodo,
  IcalJournal, IcalTimezone, IcalOther, IcalAlarm, IcalDt, IcalDuration,
  IcalPerson, IcalTrigger, IcalTzObservance, IcalProp, IcalParam,
  IcalGenericSub, IcalDateTime, formatIcalDateTime, formatIcalDuration,
  cckEvent, cckTodo, cckJournal, cckTimezone, cckOther, trkRelative
from ./vcard import VCard, vv40, vcardKindStr, VCardProp, VCardParam
from ./sql import SqlNode, SqlDriver, nkIdent, nkQuotedIdent, nkStringLit,
  nkBitStringLit, nkHexStringLit, nkIntegerLit, nkNumericLit, nkPlaceholder,
  nkRaw
from ./qr import QrMatrix
from ./svg import SvgPathSeg
from ./css import CssNode, CssStyleSheet, CssValue,
  cssStyleSheet, cssRuleSet, cssSelector, cssDeclaration, cssComment,
  cssAtRule, cssValue,
  cvkFunction, cvkNumber, cvkDimension, cvkPercentage, cvkString, cvkUrl,
  cvkIdent, cvkHash, cvkImportant, cvkBlock, cvkPreserved, cvkComment
from ./colors import Color, toHex, toHex8, toRgbString, toHslString,
  toHsvString, toCmykString, toLabString, toOklchString, toName
from ./path import Path

template jsParse(node: JsonNode): napi_value =
  ## Bridge a JsonNode to a live JS object via JSON.parse.
  napiCall("JSON.parse", [%* $node])

proc optStr(o: Option[string]): JsonNode =
  if o.isSome: %o.get else: newJNull()

proc optInt(o: Option[int]): JsonNode =
  if o.isSome: %o.get else: newJNull()

# ---------------------------------------------------------------- yaml/toml

proc yamlNodeToJson(y: YamlNode): JsonNode =
  return case y.kind
  of yamlString: %y.strValue
  of yamlInteger: %y.intValue
  of yamlFloat: %y.floatValue
  of yamlBoolean: %y.boolValue
  of yamlNull: newJNull()
  of yamlObject:
    var o = newJObject()
    for k, v in y.objValue: o[k] = yamlNodeToJson(v)
    o
  of yamlArray:
    var a = newJArray()
    for it in y.arrValue: a.add(yamlNodeToJson(it))
    a

proc yamlParseJson(src: string): JsonNode =
  let doc: YAMLObject = parseYAML(src)
  result = newJObject()
  for k, v in doc: result[k] = yamlNodeToJson(v)

proc tomlToJson(n: TomlNode): JsonNode =
  return case n.kind
  of tvkString: %n.strVal
  of tvkInteger: %n.intVal
  of tvkFloat: %n.floatVal
  of tvkBoolean: %n.boolVal
  of tvkDateTime: %n.dateTimeVal.format("yyyy-MM-dd'T'HH:mm:ss")
  of tvkArray:
    var arr = newJArray()
    for it in n.arrayVal: arr.add(tomlToJson(it))
    arr
  of tvkTable:
    var o = newJObject()
    for k, v in n.tableVal: o[k] = tomlToJson(v)
    o

proc tomlFromJson(n: JsonNode): TomlNode =
  return case n.kind
  of JString: newTomlString(n.getStr)
  of JInt: newTomlInteger(n.getInt)
  of JFloat: newTomlFloat(n.getFloat)
  of JBool: newTomlBoolean(n.getBool)
  of JArray:
    var t = newTomlArray()
    for it in n.elems: t.arrayVal.add(tomlFromJson(it))
    t
  of JObject:
    var t = newTomlTable()
    for k, v in n.fields: t.tableVal[k] = tomlFromJson(v)
    t
  of JNull:
    raise newException(ValueError, "TOML has no null value")

# --------------------------------------------------------------------- xml

proc xmlToJson(n: XmlNode): JsonNode =
  result = newJObject()
  case n.kind
  of xnElement:
    result["kind"] = %"element"
    result["tag"] = %n.tag
    var attrs = newJObject()
    for k, v in n.attrs: attrs[k] = %v
    result["attrs"] = attrs
    var ch = newJArray()
    for c in n.children: ch.add(xmlToJson(c))
    result["children"] = ch
  of xnText:
    result["kind"] = %"text"
    result["text"] = %n.text
  of xnComment:
    result["kind"] = %"comment"
    result["text"] = %n.comment
  of xnCdata:
    result["kind"] = %"cdata"
    result["text"] = %n.cdata
  of xnProlog:
    result["kind"] = %"prolog"
    result["text"] = %n.prolog
  of xnDoctype:
    result["kind"] = %"doctype"
    result["text"] = %n.doctype

# --------------------------------------------------------------------- csv

proc csvOpts(delimiter, quote: string): CsvOptions =
  result = defaultCsvOptions()
  if delimiter.len > 0: result.delimiter = delimiter[0]
  if quote.len > 0: result.quote = quote[0]

proc collectCsvRows(path: string, opts: CsvOptions): JsonNode =
  var rows = newJArray()
  if getFileSize(path) <= 0: return rows
  var mf = memfiles.open(path, mode = fmRead)
  defer: mf.close()
  parseCsv(mf, proc(fields: openArray[CsvFieldSlice], row: int): bool {.closure.} =
    var arr = newJArray()
    for f in fields: arr.add(%toString(f))
    rows.add(arr)
    true
  , opts)
  rows

proc csvRowsFromString(src, delimiter, quote: string): JsonNode =
  if src.len == 0: return newJArray()
  let (fh, path) = createTempFile("openparser_csv_", ".csv")
  try:
    fh.write(src)
    fh.close()
    collectCsvRows(path, csvOpts(delimiter, quote))
  finally:
    removeFile(path)

proc csvRowsFromFile(path, delimiter, quote: string): JsonNode =
  collectCsvRows(path, csvOpts(delimiter, quote))

# ------------------------------------------------------------------ base64

proc bytesFromBase64(s: string): seq[byte] =
  let d = decode(s)
  result = newSeq[byte](d.len)
  for i in 0 ..< d.len: result[i] = byte(d[i])

proc base64FromBytes(b: openArray[byte]): string =
  var s = newString(b.len)
  for i in 0 ..< b.len: s[i] = char(b[i])
  encode(s)

# ---------------------------------------------------------------- rss/atom

proc rssMediaToJson(m: RssMediaContent): JsonNode =
  result = newJObject()
  result["url"] = optStr(m.url)
  result["mediaType"] = optStr(m.mediaType)
  result["medium"] = optStr(m.medium)
  result["height"] = optInt(m.height)
  result["width"] = optInt(m.width)

proc rssItemToJson(it: RssItem): JsonNode =
  result = newJObject()
  result["title"] = optStr(it.title)
  result["link"] = optStr(it.link)
  result["description"] = optStr(it.description)
  result["pubDate"] = optStr(it.pubDate)
  result["category"] = optStr(it.category)
  result["guid"] = optStr(it.guid)
  result["source"] = optStr(it.source)
  if it.mediaContent.isSome: result["media"] = rssMediaToJson(it.mediaContent.get)
  else: result["media"] = newJNull()

proc rssToJson(f: RssFeed): JsonNode =
  result = newJObject()
  result["title"] = %f.title
  result["link"] = %f.link
  result["description"] = %f.description
  result["copyright"] = %f.copyright
  result["pubDate"] = %f.pubDate
  result["lastBuildDate"] = %f.lastBuildDate
  result["selfLink"] = optStr(f.atomSelfLink)
  var img = newJObject()
  img["url"] = %f.image.url
  img["title"] = %f.image.title
  img["link"] = %f.image.link
  result["image"] = img
  result["ttl"] = %f.ttl
  var items = newJArray()
  for it in f.items: items.add(rssItemToJson(it))
  result["items"] = items

proc atomTextToJson(t: AtomText): JsonNode =
  result = newJObject()
  result["kind"] = %t.kind
  result["value"] = %t.value

proc atomPersonToJson(p: AtomPerson): JsonNode =
  result = newJObject()
  result["name"] = %p.name
  result["uri"] = optStr(p.uri)
  result["email"] = optStr(p.email)

proc atomLinkToJson(l: AtomLink): JsonNode =
  result = newJObject()
  result["href"] = %l.href
  result["rel"] = optStr(l.rel)
  result["type"] = optStr(l.mimeType)
  result["hreflang"] = optStr(l.hreflang)
  result["title"] = optStr(l.title)
  result["length"] = optInt(l.length)

proc atomCategoryToJson(c: AtomCategory): JsonNode =
  result = newJObject()
  result["term"] = %c.term
  result["scheme"] = optStr(c.scheme)
  result["label"] = optStr(c.label)

proc atomContentToJson(c: AtomContent): JsonNode =
  result = newJObject()
  result["kind"] = optStr(c.kind)
  result["src"] = optStr(c.src)
  result["value"] = optStr(c.value)

proc atomEntryToJson(e: AtomEntry): JsonNode =
  result = newJObject()
  result["id"] = %e.id
  result["title"] = atomTextToJson(e.title)
  result["updated"] = %e.updated
  var authors = newJArray()
  for a in e.authors: authors.add(atomPersonToJson(a))
  result["authors"] = authors
  var links = newJArray()
  for l in e.links: links.add(atomLinkToJson(l))
  result["links"] = links
  var cats = newJArray()
  for c in e.categories: cats.add(atomCategoryToJson(c))
  result["categories"] = cats
  if e.summary.isSome: result["summary"] = atomTextToJson(e.summary.get)
  else: result["summary"] = newJNull()
  if e.content.isSome: result["content"] = atomContentToJson(e.content.get)
  else: result["content"] = newJNull()
  if e.rights.isSome: result["rights"] = atomTextToJson(e.rights.get)
  else: result["rights"] = newJNull()
  result["published"] = optStr(e.published)

proc atomToJson(f: AtomFeed): JsonNode =
  result = newJObject()
  result["id"] = %f.id
  result["title"] = atomTextToJson(f.title)
  result["updated"] = %f.updated
  var authors = newJArray()
  for a in f.authors: authors.add(atomPersonToJson(a))
  result["authors"] = authors
  var links = newJArray()
  for l in f.links: links.add(atomLinkToJson(l))
  result["links"] = links
  var cats = newJArray()
  for c in f.categories: cats.add(atomCategoryToJson(c))
  result["categories"] = cats
  if f.subtitle.isSome: result["subtitle"] = atomTextToJson(f.subtitle.get)
  else: result["subtitle"] = newJNull()
  if f.rights.isSome: result["rights"] = atomTextToJson(f.rights.get)
  else: result["rights"] = newJNull()
  if f.generator.isSome:
    let g = f.generator.get
    var gen = newJObject()
    gen["value"] = %g.value
    gen["uri"] = optStr(g.uri)
    gen["version"] = optStr(g.version)
    result["generator"] = gen
  else: result["generator"] = newJNull()
  result["icon"] = optStr(f.icon)
  result["logo"] = optStr(f.logo)
  var entries = newJArray()
  for e in f.entries: entries.add(atomEntryToJson(e))
  result["entries"] = entries
  result["lang"] = optStr(f.lang)
  result["base"] = optStr(f.base)

# ------------------------------------------------------------------ dotenv

proc dotenvToJson(entries: seq[DotenvEntry]): JsonNode =
  result = newJArray()
  for e in entries:
    var o = newJObject()
    o["key"] = %e.key
    o["value"] = %e.value
    o["expand"] = %e.expand
    result.add(o)

# -------------------------------------------------------------------- ical

proc icalParamsToJson(ps: seq[IcalParam]): JsonNode =
  result = newJArray()
  for p in ps:
    var o = newJObject()
    o["name"] = %p.name
    var vals = newJArray()
    for v in p.values: vals.add(%v)
    o["values"] = vals
    result.add(o)

proc icalPropToJson(p: IcalProp): JsonNode =
  result = newJObject()
  result["name"] = %p.name
  result["params"] = icalParamsToJson(p.params)
  result["value"] = %p.value

proc icalDtToJson(d: IcalDt): JsonNode =
  result = newJObject()
  result["value"] = %formatIcalDateTime(d.dt)
  result["tzid"] = optStr(d.tzid)

proc icalPersonToJson(p: IcalPerson): JsonNode =
  result = newJObject()
  result["uri"] = %p.uri
  result["cn"] = optStr(p.cn)
  result["params"] = icalParamsToJson(p.params)

proc icalTriggerToJson(t: IcalTrigger): JsonNode =
  result = newJObject()
  if t.kind == trkRelative:
    result["kind"] = %"relative"
    result["value"] = %formatIcalDuration(t.dur)
  else:
    result["kind"] = %"absolute"
    result["value"] = %formatIcalDateTime(t.dt)

proc icalAlarmToJson(a: IcalAlarm): JsonNode =
  result = newJObject()
  result["action"] = %a.action
  if a.trigger.isSome: result["trigger"] = icalTriggerToJson(a.trigger.get)
  else: result["trigger"] = newJNull()
  result["description"] = optStr(a.description)
  result["summary"] = optStr(a.summary)
  if a.repeatCount.isSome: result["repeat"] = %a.repeatCount.get
  else: result["repeat"] = newJNull()
  if a.duration.isSome: result["duration"] = %formatIcalDuration(a.duration.get)
  else: result["duration"] = newJNull()
  var att = newJArray()
  for p in a.attendees: att.add(icalPersonToJson(p))
  result["attendees"] = att
  var extra = newJArray()
  for p in a.extraProps: extra.add(icalPropToJson(p))
  result["extraProps"] = extra

proc icalDtOpt(o: Option[IcalDt]): JsonNode =
  if o.isSome: icalDtToJson(o.get) else: newJNull()

proc icalExtraProps(ps: seq[IcalProp]): JsonNode =
  result = newJArray()
  for p in ps: result.add(icalPropToJson(p))

proc icalEventToJson(e: IcalEvent): JsonNode =
  result = newJObject()
  result["uid"] = %e.uid
  result["dtstamp"] = icalDtOpt(e.dtstamp)
  result["dtstart"] = icalDtOpt(e.dtStart)
  result["dtend"] = icalDtOpt(e.dtEnd)
  if e.duration.isSome: result["duration"] = %formatIcalDuration(e.duration.get)
  else: result["duration"] = newJNull()
  result["summary"] = optStr(e.summary)
  result["description"] = optStr(e.description)
  result["location"] = optStr(e.location)
  result["status"] = optStr(e.status)
  result["transparency"] = optStr(e.transparency)
  result["classification"] = optStr(e.classification)
  if e.priority.isSome: result["priority"] = %e.priority.get
  else: result["priority"] = newJNull()
  if e.sequenceNum.isSome: result["sequence"] = %e.sequenceNum.get
  else: result["sequence"] = newJNull()
  result["created"] = icalDtOpt(e.created)
  result["lastModified"] = icalDtOpt(e.lastModified)
  result["url"] = optStr(e.url)
  if e.organizer.isSome: result["organizer"] = icalPersonToJson(e.organizer.get)
  else: result["organizer"] = newJNull()
  var att = newJArray()
  for p in e.attendees: att.add(icalPersonToJson(p))
  result["attendees"] = att
  var cats = newJArray()
  for c in e.categories: cats.add(%c)
  result["categories"] = cats
  result["rrule"] = optStr(e.rrule)
  var exd = newJArray()
  for d in e.exdates: exd.add(icalDtToJson(d))
  result["exdates"] = exd
  var atch = newJArray()
  for a in e.attachments: atch.add(%a)
  result["attachments"] = atch
  result["recurrenceId"] = icalDtOpt(e.recurrenceId)
  var alarms = newJArray()
  for a in e.alarms: alarms.add(icalAlarmToJson(a))
  result["alarms"] = alarms
  result["extraProps"] = icalExtraProps(e.extraProps)

proc icalTodoToJson(t: IcalTodo): JsonNode =
  result = newJObject()
  result["uid"] = %t.uid
  result["dtstamp"] = icalDtOpt(t.dtstamp)
  result["dtstart"] = icalDtOpt(t.dtStart)
  result["due"] = icalDtOpt(t.due)
  result["completed"] = icalDtOpt(t.completed)
  result["summary"] = optStr(t.summary)
  result["description"] = optStr(t.description)
  result["location"] = optStr(t.location)
  result["status"] = optStr(t.status)
  result["classification"] = optStr(t.classification)
  if t.priority.isSome: result["priority"] = %t.priority.get
  else: result["priority"] = newJNull()
  if t.sequenceNum.isSome: result["sequence"] = %t.sequenceNum.get
  else: result["sequence"] = newJNull()
  if t.percentComplete.isSome: result["percentComplete"] = %t.percentComplete.get
  else: result["percentComplete"] = newJNull()
  result["created"] = icalDtOpt(t.created)
  result["lastModified"] = icalDtOpt(t.lastModified)
  result["url"] = optStr(t.url)
  if t.organizer.isSome: result["organizer"] = icalPersonToJson(t.organizer.get)
  else: result["organizer"] = newJNull()
  var att = newJArray()
  for p in t.attendees: att.add(icalPersonToJson(p))
  result["attendees"] = att
  var cats = newJArray()
  for c in t.categories: cats.add(%c)
  result["categories"] = cats
  result["rrule"] = optStr(t.rrule)
  var alarms = newJArray()
  for a in t.alarms: alarms.add(icalAlarmToJson(a))
  result["alarms"] = alarms
  result["extraProps"] = icalExtraProps(t.extraProps)

proc icalJournalToJson(j: IcalJournal): JsonNode =
  result = newJObject()
  result["uid"] = %j.uid
  result["dtstamp"] = icalDtOpt(j.dtstamp)
  result["summary"] = optStr(j.summary)
  result["description"] = optStr(j.description)
  result["status"] = optStr(j.status)
  result["classification"] = optStr(j.classification)
  if j.organizer.isSome: result["organizer"] = icalPersonToJson(j.organizer.get)
  else: result["organizer"] = newJNull()
  var cats = newJArray()
  for c in j.categories: cats.add(%c)
  result["categories"] = cats
  var att = newJArray()
  for p in j.attendees: att.add(icalPersonToJson(p))
  result["attendees"] = att
  result["extraProps"] = icalExtraProps(j.extraProps)

proc icalTzObsToJson(o: IcalTzObservance): JsonNode =
  result = newJObject()
  if o.dtstart.isSome: result["dtstart"] = %formatIcalDateTime(o.dtstart.get)
  else: result["dtstart"] = newJNull()
  result["offsetFrom"] = optStr(o.offsetFrom)
  result["offsetTo"] = optStr(o.offsetTo)
  var names = newJArray()
  for n in o.names: names.add(%n)
  result["names"] = names
  result["rrule"] = optStr(o.rrule)
  result["extraProps"] = icalExtraProps(o.extraProps)

proc icalTimezoneToJson(tz: IcalTimezone): JsonNode =
  result = newJObject()
  result["tzid"] = %tz.tzid
  var std = newJArray()
  for o in tz.standard: std.add(icalTzObsToJson(o))
  result["standard"] = std
  var day = newJArray()
  for o in tz.daylight: day.add(icalTzObsToJson(o))
  result["daylight"] = day
  result["extraProps"] = icalExtraProps(tz.extraProps)

proc icalGenericToJson(name: string, props: seq[IcalProp]): JsonNode =
  result = newJObject()
  result["name"] = %name
  result["props"] = icalExtraProps(props)

proc icalOtherToJson(o: IcalOther): JsonNode =
  result = icalGenericToJson(o.name, o.props)
  var ch = newJArray()
  for c in o.children:
    var co = icalGenericToJson(c.name, c.props)
    var gc = newJArray()
    for g in c.children: gc.add(icalGenericToJson(g.name, g.props))
    co["children"] = gc
    ch.add(co)
  result["children"] = ch

proc icalComponentToJson(c: IcalComponent): JsonNode =
  case c.kind
  of cckEvent:
    result = icalEventToJson(c.event)
    result["kind"] = %"event"
  of cckTodo:
    result = icalTodoToJson(c.todo)
    result["kind"] = %"todo"
  of cckJournal:
    result = icalJournalToJson(c.journal)
    result["kind"] = %"journal"
  of cckTimezone:
    result = icalTimezoneToJson(c.timezone)
    result["kind"] = %"timezone"
  of cckOther:
    result = icalOtherToJson(c.other)
    result["kind"] = %"other"

proc icalToJson(cal: IcalCalendar): JsonNode =
  result = newJObject()
  result["prodId"] = optStr(cal.prodId)
  result["version"] = optStr(cal.version)
  result["calscale"] = optStr(cal.calscale)
  result["method"] = optStr(cal.`method`)
  result["extraProps"] = icalExtraProps(cal.extraProps)
  var comps = newJArray()
  for c in cal.components: comps.add(icalComponentToJson(c))
  result["components"] = comps

# ------------------------------------------------------------------- vcard

proc vcardParamsToJson(ps: seq[VCardParam]): JsonNode =
  result = newJArray()
  for p in ps:
    var o = newJObject()
    o["name"] = %p.name
    var vals = newJArray()
    for v in p.values: vals.add(%v)
    o["values"] = vals
    result.add(o)

proc vcardPropToJson(p: VCardProp): JsonNode =
  result = newJObject()
  result["group"] = %p.group
  result["name"] = %p.name
  result["params"] = vcardParamsToJson(p.params)
  result["value"] = %p.value

proc vcardExtraProps(ps: seq[VCardProp]): JsonNode =
  result = newJArray()
  for p in ps: result.add(vcardPropToJson(p))

proc vcardPrefJson(pref: Option[int]): JsonNode =
  if pref.isSome: %pref.get else: newJNull()

proc vcardTypesJson(types: seq[string]): JsonNode =
  result = newJArray()
  for t in types: result.add(%t)

proc vcardToJson(c: VCard): JsonNode =
  result = newJObject()
  result["version"] = %(if c.version == vv40: "4.0" else: "3.0")
  result["fn"] = %c.fn
  if c.n.isSome:
    let n = c.n.get
    var no = newJObject()
    no["family"] = %n.family
    no["given"] = %n.given
    no["additional"] = %n.additional
    no["prefix"] = %n.prefix
    no["suffix"] = %n.suffix
    result["n"] = no
  else: result["n"] = newJNull()
  var nick = newJArray()
  for s in c.nicknames: nick.add(%s)
  result["nicknames"] = nick
  var photos = newJArray()
  for p in c.photos:
    var o = newJObject()
    o["value"] = %p.value
    o["mediaType"] = optStr(p.mediaType)
    o["types"] = vcardTypesJson(p.types)
    o["pref"] = vcardPrefJson(p.pref)
    o["altId"] = optStr(p.altId)
    photos.add(o)
  result["photos"] = photos
  if c.bday.isSome:
    let b = c.bday.get
    var o = newJObject()
    o["value"] = %b.value
    o["valueType"] = %b.valueType
    result["bday"] = o
  else: result["bday"] = newJNull()
  if c.anniversary.isSome:
    let a = c.anniversary.get
    var o = newJObject()
    o["value"] = %a.value
    o["valueType"] = %a.valueType
    result["anniversary"] = o
  else: result["anniversary"] = newJNull()
  if c.gender.isSome:
    let g = c.gender.get
    var o = newJObject()
    o["sex"] = %g.sex
    o["identity"] = %g.identity
    result["gender"] = o
  else: result["gender"] = newJNull()
  var adrs = newJArray()
  for a in c.adrs:
    var o = newJObject()
    o["poBox"] = %a.poBox
    o["ext"] = %a.ext
    o["street"] = %a.street
    o["locality"] = %a.locality
    o["region"] = %a.region
    o["postal"] = %a.postal
    o["country"] = %a.country
    o["label"] = optStr(a.label)
    o["geo"] = optStr(a.geo)
    o["tz"] = optStr(a.tz)
    o["types"] = vcardTypesJson(a.types)
    o["pref"] = vcardPrefJson(a.pref)
    o["altId"] = optStr(a.altId)
    adrs.add(o)
  result["adrs"] = adrs
  var tels = newJArray()
  for t in c.tels:
    var o = newJObject()
    o["value"] = %t.value
    o["types"] = vcardTypesJson(t.types)
    o["pref"] = vcardPrefJson(t.pref)
    o["altId"] = optStr(t.altId)
    o["label"] = optStr(t.label)
    tels.add(o)
  result["tels"] = tels
  var emails = newJArray()
  for e in c.emails:
    var o = newJObject()
    o["value"] = %e.value
    o["types"] = vcardTypesJson(e.types)
    o["pref"] = vcardPrefJson(e.pref)
    o["altId"] = optStr(e.altId)
    emails.add(o)
  result["emails"] = emails
  var impps = newJArray()
  for i in c.impps:
    var o = newJObject()
    o["value"] = %i.value
    o["types"] = vcardTypesJson(i.types)
    o["pref"] = vcardPrefJson(i.pref)
    o["altId"] = optStr(i.altId)
    impps.add(o)
  result["impps"] = impps
  var langs = newJArray()
  for l in c.langs:
    var o = newJObject()
    o["value"] = %l.value
    o["types"] = vcardTypesJson(l.types)
    o["pref"] = vcardPrefJson(l.pref)
    o["altId"] = optStr(l.altId)
    langs.add(o)
  result["langs"] = langs
  result["tz"] = optStr(c.tz)
  result["geo"] = optStr(c.geo)
  result["title"] = optStr(c.title)
  result["role"] = optStr(c.role)
  result["logo"] = optStr(c.logo)
  if c.org.isSome:
    let o = c.org.get
    var oo = newJObject()
    oo["name"] = %o.name
    var units = newJArray()
    for u in o.units: units.add(%u)
    oo["units"] = units
    result["org"] = oo
  else: result["org"] = newJNull()
  var members = newJArray()
  for m in c.members:
    var o = newJObject()
    o["value"] = %m.value
    o["pref"] = vcardPrefJson(m.pref)
    o["altId"] = optStr(m.altId)
    members.add(o)
  result["members"] = members
  var related = newJArray()
  for r in c.related:
    var o = newJObject()
    o["value"] = %r.value
    o["relType"] = optStr(r.relType)
    o["types"] = vcardTypesJson(r.types)
    o["pref"] = vcardPrefJson(r.pref)
    o["altId"] = optStr(r.altId)
    related.add(o)
  result["related"] = related
  var cats = newJArray()
  for s in c.categories: cats.add(%s)
  result["categories"] = cats
  result["note"] = optStr(c.note)
  result["prodId"] = optStr(c.prodId)
  result["rev"] = optStr(c.rev)
  result["sortString"] = optStr(c.sortString)
  result["sound"] = optStr(c.sound)
  result["uid"] = optStr(c.uid)
  if c.kind.isSome: result["kind"] = %vcardKindStr(c.kind.get)
  else: result["kind"] = newJNull()
  var pidmaps = newJArray()
  for m in c.clientPidMaps:
    var o = newJObject()
    o["pid"] = %m.pid
    o["uri"] = %m.uri
    pidmaps.add(o)
  result["clientPidMaps"] = pidmaps
  var urls = newJArray()
  for u in c.urls:
    var o = newJObject()
    o["value"] = %u.value
    o["types"] = vcardTypesJson(u.types)
    o["pref"] = vcardPrefJson(u.pref)
    o["altId"] = optStr(u.altId)
    o["label"] = optStr(u.label)
    urls.add(o)
  result["urls"] = urls
  result["key"] = optStr(c.key)
  result["fbUrl"] = optStr(c.fbUrl)
  result["calAdrUri"] = optStr(c.calAdrUri)
  result["calUri"] = optStr(c.calUri)
  var xmls = newJArray()
  for x in c.xml: xmls.add(%x)
  result["xml"] = xmls
  result["extraProps"] = vcardExtraProps(c.extraProps)

proc vcardsToJson(cards: seq[VCard]): JsonNode =
  result = newJArray()
  for c in cards: result.add(vcardToJson(c))

# --------------------------------------------------------------------- sql

proc sqlToJson(n: SqlNode): JsonNode =
  result = newJObject()
  result["kind"] = %($n.kind)
  if n.kind in {nkIdent, nkQuotedIdent, nkStringLit, nkBitStringLit,
      nkHexStringLit, nkIntegerLit, nkNumericLit, nkPlaceholder, nkRaw}:
    result["value"] = %n.strVal
  else:
    var ch = newJArray()
    for s in n.sons: ch.add(sqlToJson(s))
    result["children"] = ch

proc sqlDriverFromString(s: string): SqlDriver =
  case s.strip.toLowerAscii
  of "pgsql", "postgres", "postgresql": SqlDriver.pgsql
  of "mysql", "mariadb": SqlDriver.mysql
  of "sqlite": SqlDriver.sqlite
  else: SqlDriver.generic

# --------------------------------------------------------------------- css

proc cssValueToJson(v: CssValue): JsonNode =
  result = newJObject()
  case v.kind
  of cvkFunction:
    result["kind"] = %"function"
    result["name"] = %v.funcName
    var a = newJArray()
    for x in v.args: a.add(cssValueToJson(x))
    result["args"] = a
  of cvkNumber:
    result["kind"] = %"number"
    result["value"] = %v.numValue
  of cvkDimension:
    result["kind"] = %"dimension"
    result["value"] = %v.dimValue
    result["unit"] = %v.dimUnit
  of cvkPercentage:
    result["kind"] = %"percentage"
    result["value"] = %v.pctValue
  of cvkString:
    result["kind"] = %"string"
    result["value"] = %v.strValue
  of cvkUrl:
    result["kind"] = %"url"
    result["value"] = %v.urlValue
  of cvkIdent:
    result["kind"] = %"ident"
    result["value"] = %v.identValue
  of cvkHash:
    result["kind"] = %"hash"
    result["value"] = %v.hashValue
    result["flag"] = %v.hashFlag
  of cvkImportant:
    result["kind"] = %"important"
  of cvkBlock:
    result["kind"] = %"block"
    result["open"] = %($v.blockKind)
    var b = newJArray()
    for x in v.blockValues: b.add(cssValueToJson(x))
    result["values"] = b
  of cvkPreserved:
    result["kind"] = %"preserved"
    result["value"] = %v.preservedValue
  of cvkComment:
    result["kind"] = %"comment"
    result["value"] = %v.commentText

proc cssValuesToJson(vs: seq[CssValue]): JsonNode =
  result = newJArray()
  for v in vs: result.add(cssValueToJson(v))

proc cssNodeToJson(n: CssNode): JsonNode =
  result = newJObject()
  case n.kind
  of cssStyleSheet:
    result["kind"] = %"stylesheet"
    var r = newJArray()
    for x in n.rules: r.add(cssNodeToJson(x))
    result["rules"] = r
  of cssRuleSet:
    result["kind"] = %"ruleset"
    var s = newJArray()
    for x in n.selectors: s.add(cssNodeToJson(x))
    result["selectors"] = s
    var d = newJArray()
    for x in n.declarations: d.add(cssNodeToJson(x))
    result["declarations"] = d
  of cssSelector:
    result["kind"] = %"selector"
    result["selectorKind"] = %($n.selectorKind)
    var p = newJArray()
    for x in n.parts: p.add(%x)
    result["parts"] = p
  of cssDeclaration:
    result["kind"] = %"declaration"
    result["property"] = %n.property
    result["value"] = %n.rawValue
    result["components"] = cssValuesToJson(n.valueComponents)
    result["important"] = %n.important
  of cssComment:
    result["kind"] = %"comment"
    result["text"] = %n.text
  of cssAtRule:
    result["kind"] = %"atrule"
    result["name"] = %n.atName
    result["prelude"] = %n.prelude
    var r = newJArray()
    for x in n.atRules: r.add(cssNodeToJson(x))
    result["rules"] = r
    result["values"] = cssValuesToJson(n.blockValues)
  of cssValue:
    result["kind"] = %"value"
    result["raw"] = %n.raw
    result["components"] = cssValuesToJson(n.components)

proc cssToJson(s: CssStyleSheet): JsonNode =
  result = newJArray()
  for n in s.nodes: result.add(cssNodeToJson(n))

# -------------------------------------------------------------------- path

proc pathToJson(p: Path): JsonNode =
  result = newJObject()
  result["raw"] = %p.raw
  result["kind"] = %($p.kind)
  result["isLocal"] = %p.isLocal
  if p.isLocal:
    result["drive"] = optStr(p.drive)
    result["absolute"] = %p.isAbsolute
    var segs = newJArray()
    for s in p.segments: segs.add(%s)
    result["segments"] = segs
    result["ext"] = optStr(p.localExt)
  else:
    result["scheme"] = %p.scheme
    if p.auth.isSome:
      let a = p.auth.get
      var ao = newJObject()
      ao["user"] = %a.user
      ao["password"] = optStr(a.password)
      result["auth"] = ao
    else: result["auth"] = newJNull()
    result["host"] = %p.host
    result["port"] = optInt(p.port)
    result["path"] = %p.path
    var segs = newJArray()
    for s in p.pathSegments: segs.add(%s)
    result["segments"] = segs
    var q = newJArray()
    for qp in p.query:
      var o = newJObject()
      o["key"] = %qp.key
      o["value"] = %qp.value
      q.add(o)
    result["query"] = q
    result["fragment"] = optStr(p.fragment)
    result["ext"] = optStr(p.ext)

# ------------------------------------------------------------------ colors

proc colorToJson(c: Color): JsonNode =
  result = newJObject()
  result["hex"] = %c.toHex()
  result["hex8"] = %c.toHex8()
  result["rgb"] = %c.toRgbString()
  result["hsl"] = %c.toHslString()
  result["hsv"] = %c.toHsvString()
  result["cmyk"] = %c.toCmykString()
  result["lab"] = %c.toLabString()
  result["oklch"] = %c.toOklchString()
  result["name"] = %c.toName()

# -------------------------------------------------------------- svg paths

proc svgPathToJson(segs: seq[SvgPathSeg]): JsonNode =
  result = newJArray()
  for s in segs:
    var o = newJObject()
    o["cmd"] = %($s.cmd)
    var a = newJArray()
    for f in s.args: a.add(%f)
    o["args"] = a
    result.add(o)
