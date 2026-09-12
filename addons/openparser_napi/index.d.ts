/**
 * Type definitions for openparser-napi — Node.js native bindings for
 * openparser (built with denim: `denim build src/openparser.nim --cmake -y`).
 *
 * The package ships prebuilt binaries per platform/arch under
 * `bin/<platform>-<arch>/openparser.node`; `index.js` selects the one
 * matching `process.platform`/`process.arch` at load time.
 *
 * Conventions across namespaces:
 * - `parse` functions take a document string and return live JS objects.
 * - `normalize` functions round-trip through the typed model and return a
 *   canonical string.
 * - `dump`/`toXml`/`toBplist`/`fromJson` functions take a *JSON string*
 *   (call `JSON.stringify` on your object first).
 * - Binary payloads (BSON, binary plist) cross the boundary as base64.
 * - Optional Nim values surface as `| null`.
 * - Nim parser errors surface as thrown `Error`s.
 */

// ---------------------------------------------------------------- yaml
export namespace yaml {
  /** Parse YAML to a plain JS object. */
  function parse(src: string): any;
  /** Serialize a JSON document (as string) to YAML. */
  function dump(doc: string): string;
}

// ---------------------------------------------------------------- toml
export namespace toml {
  /** Parse TOML to a plain JS object (datetimes become ISO strings). */
  function parse(src: string): any;
  /** Serialize a JSON document (as string) to TOML. JSON null is rejected. */
  function dump(doc: string): string;
}

// ----------------------------------------------------------------- xml
export type XmlNode =
  | { kind: 'element'; tag: string; attrs: Record<string, string>; children: XmlNode[] }
  | { kind: 'text' | 'comment' | 'cdata' | 'prolog' | 'doctype'; text: string };

export namespace xml {
  /** Parse XML to a JS DOM tree. */
  function parse(src: string): XmlNode;
  /** Canonicalize XML via parse/serialize round-trip. */
  function normalize(src: string): string;
}

// ----------------------------------------------------------------- csv
export namespace csv {
  /** Parse CSV text to an array of rows (arrays of strings). */
  function parse(src: string, delimiter: string, quote: string): string[][];
  /** Parse a CSV file to an array of rows. */
  function parseFile(path: string, delimiter: string, quote: string): string[][];
}

// ---------------------------------------------------------------- bson
export namespace bson {
  /** Encode a JSON document (as string) to BSON, returned as base64. */
  function fromJson(doc: string): string;
  /** Decode base64 BSON to a JS object (extended JSON v2). */
  function toJson(data: string): any;
}

// --------------------------------------------------------------- plist
export namespace plist {
  /** Parse an XML plist to a JS object. */
  function parse(src: string): any;
  /** Parse a base64 plist (XML or binary bplist00) to a JS object. */
  function parseBase64(data: string): any;
  /** Serialize a JSON document (as string) to XML plist. */
  function toXml(doc: string): string;
  /** Serialize a JSON document (as string) to binary plist, as base64. */
  function toBplist(doc: string): string;
}

// ----------------------------------------------------------------- rss
export interface RssMediaContent {
  url: string | null;
  mediaType: string | null;
  medium: string | null;
  height: number | null;
  width: number | null;
}

export interface RssItem {
  title: string | null;
  link: string | null;
  description: string | null;
  pubDate: string | null;
  category: string | null;
  guid: string | null;
  source: string | null;
  media: RssMediaContent | null;
}

export interface RssFeed {
  title: string;
  link: string;
  description: string;
  copyright: string;
  pubDate: string;
  lastBuildDate: string;
  selfLink: string | null;
  image: { url: string; title: string; link: string };
  ttl: number;
  items: RssItem[];
}

export namespace rss {
  /** Parse an RSS feed to a JS object. */
  function parse(src: string): RssFeed;
  /** Canonicalize RSS via parse/serialize round-trip. */
  function normalize(src: string): string;
}

// ---------------------------------------------------------------- atom
export interface AtomText {
  kind: string;
  value: string;
}

export interface AtomPerson {
  name: string;
  uri: string | null;
  email: string | null;
}

export interface AtomLink {
  href: string;
  rel: string | null;
  type: string | null;
  hreflang: string | null;
  title: string | null;
  length: number | null;
}

export interface AtomCategory {
  term: string;
  scheme: string | null;
  label: string | null;
}

export interface AtomContent {
  kind: string | null;
  src: string | null;
  value: string | null;
}

export interface AtomEntry {
  id: string;
  title: AtomText;
  updated: string;
  authors: AtomPerson[];
  links: AtomLink[];
  categories: AtomCategory[];
  summary: AtomText | null;
  content: AtomContent | null;
  rights: AtomText | null;
  published: string | null;
}

export interface AtomFeed {
  id: string;
  title: AtomText;
  updated: string;
  authors: AtomPerson[];
  links: AtomLink[];
  categories: AtomCategory[];
  subtitle: AtomText | null;
  rights: AtomText | null;
  generator: { value: string; uri: string | null; version: string | null } | null;
  icon: string | null;
  logo: string | null;
  entries: AtomEntry[];
  lang: string | null;
  base: string | null;
}

export namespace atom {
  /** Parse an Atom feed to a JS object. */
  function parse(src: string): AtomFeed;
  /** Canonicalize Atom via parse/serialize round-trip. */
  function normalize(src: string): string;
}

// -------------------------------------------------------------- dotenv
export interface DotenvEntry {
  key: string;
  value: string;
  expand: boolean;
}

export namespace dotenv {
  /** Parse .env content to an array of entries. */
  function parse(src: string): DotenvEntry[];
}

// ---------------------------------------------------------------- ical
export interface IcalParam {
  name: string;
  values: string[];
}

export interface IcalProp {
  name: string;
  params: IcalParam[];
  value: string;
}

export interface IcalDt {
  /** DATE / DATE-TIME value, e.g. `20240115T130000Z`. */
  value: string;
  tzid: string | null;
}

export interface IcalPerson {
  uri: string;
  cn: string | null;
  params: IcalParam[];
}

export interface IcalTrigger {
  kind: 'relative' | 'absolute';
  /** DURATION string or DATE-TIME string, depending on kind. */
  value: string;
}

export interface IcalAlarm {
  action: string;
  trigger: IcalTrigger | null;
  description: string | null;
  summary: string | null;
  repeat: number | null;
  duration: string | null;
  attendees: IcalPerson[];
  extraProps: IcalProp[];
}

export interface IcalEvent {
  kind: 'event';
  uid: string;
  dtstamp: IcalDt | null;
  dtstart: IcalDt | null;
  dtend: IcalDt | null;
  duration: string | null;
  summary: string | null;
  description: string | null;
  location: string | null;
  status: string | null;
  transparency: string | null;
  classification: string | null;
  priority: number | null;
  sequence: number | null;
  created: IcalDt | null;
  lastModified: IcalDt | null;
  url: string | null;
  organizer: IcalPerson | null;
  attendees: IcalPerson[];
  categories: string[];
  rrule: string | null;
  exdates: IcalDt[];
  attachments: string[];
  recurrenceId: IcalDt | null;
  alarms: IcalAlarm[];
  extraProps: IcalProp[];
}

export interface IcalTodo {
  kind: 'todo';
  uid: string;
  dtstamp: IcalDt | null;
  dtstart: IcalDt | null;
  due: IcalDt | null;
  completed: IcalDt | null;
  summary: string | null;
  description: string | null;
  location: string | null;
  status: string | null;
  classification: string | null;
  priority: number | null;
  sequence: number | null;
  percentComplete: number | null;
  created: IcalDt | null;
  lastModified: IcalDt | null;
  url: string | null;
  organizer: IcalPerson | null;
  attendees: IcalPerson[];
  categories: string[];
  rrule: string | null;
  alarms: IcalAlarm[];
  extraProps: IcalProp[];
}

export interface IcalJournal {
  kind: 'journal';
  uid: string;
  dtstamp: IcalDt | null;
  summary: string | null;
  description: string | null;
  status: string | null;
  classification: string | null;
  organizer: IcalPerson | null;
  categories: string[];
  attendees: IcalPerson[];
  extraProps: IcalProp[];
}

export interface IcalTzObservance {
  dtstart: string | null;
  offsetFrom: string | null;
  offsetTo: string | null;
  names: string[];
  rrule: string | null;
  extraProps: IcalProp[];
}

export interface IcalTimezone {
  kind: 'timezone';
  tzid: string;
  standard: IcalTzObservance[];
  daylight: IcalTzObservance[];
  extraProps: IcalProp[];
}

export interface IcalOther {
  kind: 'other';
  name: string;
  props: IcalProp[];
  children?: Array<{ name: string; props: IcalProp[]; children?: unknown }>;
}

export type IcalComponent = IcalEvent | IcalTodo | IcalJournal | IcalTimezone | IcalOther;

export interface IcalCalendar {
  prodId: string | null;
  version: string | null;
  calscale: string | null;
  method: string | null;
  extraProps: IcalProp[];
  components: IcalComponent[];
}

export namespace ical {
  /** Parse iCalendar (RFC 5545) to a JS object. */
  function parse(src: string): IcalCalendar;
  /** Canonicalize iCalendar via parse/serialize round-trip. */
  function normalize(src: string): string;
}

// --------------------------------------------------------------- vcard
export interface VCardParam {
  name: string;
  values: string[];
}

export interface VCardProp {
  group: string;
  name: string;
  params: VCardParam[];
  value: string;
}

export interface VCardName {
  family: string;
  given: string;
  additional: string;
  prefix: string;
  suffix: string;
}

export interface VCardPhoto {
  value: string;
  mediaType: string | null;
  types: string[];
  pref: number | null;
  altId: string | null;
}

export interface VCardDateProp {
  value: string;
  valueType: string;
}

export interface VCardGender {
  sex: string;
  identity: string;
}

export interface VCardAdr {
  poBox: string;
  ext: string;
  street: string;
  locality: string;
  region: string;
  postal: string;
  country: string;
  label: string | null;
  geo: string | null;
  tz: string | null;
  types: string[];
  pref: number | null;
  altId: string | null;
}

export interface VCardTel {
  value: string;
  types: string[];
  pref: number | null;
  altId: string | null;
  label: string | null;
}

export interface VCardEmail {
  value: string;
  types: string[];
  pref: number | null;
  altId: string | null;
}

export interface VCardImpp {
  value: string;
  types: string[];
  pref: number | null;
  altId: string | null;
}

export interface VCardLang {
  value: string;
  types: string[];
  pref: number | null;
  altId: string | null;
}

export interface VCardOrg {
  name: string;
  units: string[];
}

export interface VCardMember {
  value: string;
  pref: number | null;
  altId: string | null;
}

export interface VCardRelated {
  value: string;
  relType: string | null;
  types: string[];
  pref: number | null;
  altId: string | null;
}

export interface VCardUrl {
  value: string;
  types: string[];
  pref: number | null;
  altId: string | null;
  label: string | null;
}

export interface VCard {
  version: string;
  fn: string;
  n: VCardName | null;
  nicknames: string[];
  photos: VCardPhoto[];
  bday: VCardDateProp | null;
  anniversary: VCardDateProp | null;
  gender: VCardGender | null;
  adrs: VCardAdr[];
  tels: VCardTel[];
  emails: VCardEmail[];
  impps: VCardImpp[];
  langs: VCardLang[];
  tz: string | null;
  geo: string | null;
  title: string | null;
  role: string | null;
  logo: string | null;
  org: VCardOrg | null;
  members: VCardMember[];
  related: VCardRelated[];
  categories: string[];
  note: string | null;
  prodId: string | null;
  rev: string | null;
  sortString: string | null;
  sound: string | null;
  uid: string | null;
  /** Registered kind (`individual`, `group`, …) or custom `x-` token. */
  kind: string | null;
  clientPidMaps: Array<{ pid: number; uri: string }>;
  urls: VCardUrl[];
  key: string | null;
  fbUrl: string | null;
  calAdrUri: string | null;
  calUri: string | null;
  xml: string[];
  extraProps: VCardProp[];
}

export namespace vcard {
  /** Parse vCards (3.0/4.0) to a JS array of contacts. */
  function parse(src: string): VCard[];
  /** Canonicalize vCards to 4.0 via parse/serialize round-trip. */
  function normalize(src: string): string;
  /** Minimal vCard 3.0 QR payload for the card at `index`. */
  function qrPayload(src: string, index: number): string;
}

// ----------------------------------------------------------------- sql
export interface SqlNode {
  kind: string;
  value?: string;
  children?: SqlNode[];
}

export type SqlDriver = 'generic' | 'pgsql' | 'postgres' | 'postgresql' | 'mysql' | 'mariadb' | 'sqlite';

export namespace sql {
  /** Parse SQL to a JS AST. */
  function parse(src: string, driver: string): SqlNode;
  /** Canonicalize SQL via parse/render round-trip. */
  function normalize(src: string, driver: string): string;
}

// ------------------------------------------------------------- gettext
export namespace gettext {
  /** Translate `msgid` using a .po file (pass `''` for no context). */
  function poTranslate(path: string, msgid: string, msgctxt: string): string;
  /** Translate `msgid` using a compiled .mo file. */
  function moTranslate(path: string, msgid: string, msgctxt: string): string;
}

// ------------------------------------------------------------------ qr
export namespace qr {
  /** Build a WIFI: QR payload string. */
  function makeWifi(ssid: string, password: string, encryption: string, hidden: boolean): string;
  /** Build a MECARD contact payload string. */
  function makeMecard(name: string, phone: string, email: string, url: string): string;
  /** Normalize a URL payload string. */
  function makeUrl(url: string): string;
  /** Build an SMSTO: payload string. */
  function makeSms(phone: string, message: string): string;
  /** Build a mailto: payload string. */
  function makeEmail(to: string, subject: string, body: string): string;
  /** Encode text as a QR symbol, returned as an SVG string. */
  function encodeSvg(text: string): string;
  /** Encode text as a Model 2 symbol (ec L/M/Q/H, version 0 = auto, 1-40). */
  function encodeModel2(text: string, ec: string, version: number): string;
  /** Encode text as a Micro QR symbol (version 0 = auto, 1-4 = M1-M4). */
  function encodeMicro(text: string, ec: string, version: number): string;
  /** Encode text as an rMQR symbol (version "" = auto, else e.g. "R7x43"). */
  function encodeRmqr(text: string, ec: string, version: string): string;
  /** Encode text as a legacy Model 1 symbol (version 0 = auto, 1-12). */
  function encodeModel1(text: string, ec: string, version: number): string;
  /** Encode an SQRC symbol with a public area and AES-sealed private area. */
  function encodeSqrc(publicData: string, privateData: string, key: string): string;
  /** Encode an AQR dual-payload symbol (core version 0 = auto). */
  function encodeAqr(mainPayload: string, ringPayload: string, ec: string, version: number): string;
  /** Build an SQRC payload string without rendering a symbol. */
  function makeSqrc(publicData: string, privateData: string, key: string, extended: boolean): string;
  /** Open an SQRC payload with its key. */
  function decodeSqrc(text: string, key: string): SqrcDecoded;
  /** Split an SQRC payload without touching cryptography. */
  function splitSqrc(text: string): SqrcSplit;
}

export interface SqrcDecoded {
  ok: boolean;
  publicText: string;
  privateText: string;
  scannedText: string;
}

export interface SqrcSplit {
  extended: boolean;
  blobBase64: string;
  publicData: string;
}

// ----------------------------------------------------------------- svg
export interface SvgPathSeg {
  cmd: string;
  args: number[];
}

export namespace svg {
  /** Canonicalize SVG via parse/serialize round-trip. */
  function normalize(src: string): string;
  /** Parse SVG path data to an array of segments. */
  function parsePathData(d: string): SvgPathSeg[];
}

// -------------------------------------------------------------- colors
export interface ColorInfo {
  hex: string;
  hex8: string;
  rgb: string;
  hsl: string;
  hsv: string;
  cmyk: string;
  lab: string;
  oklch: string;
  name: string;
}

export namespace colors {
  /** Parse any CSS color to its string representations. */
  function parse(src: string): ColorInfo;
  /** Check whether a string is a parseable CSS color. */
  function isValid(src: string): boolean;
  /** Lighten a color by `amount`, returned as hex. */
  function lighten(src: string, amount: string): string;
  /** Darken a color by `amount`, returned as hex. */
  function darken(src: string, amount: string): string;
  /** Complement of a color, returned as hex. */
  function complement(src: string): string;
  /** WCAG contrast ratio between two colors. */
  function contrastRatio(a: string, b: string): number;
}

// ----------------------------------------------------------------- css
export interface CssValue {
  kind: string;
  [key: string]: unknown;
}

export interface CssNode {
  kind: string;
  [key: string]: unknown;
}

export namespace css {
  /** Parse a CSS stylesheet to a JS AST. */
  function parse(src: string): CssNode[];
  /** Canonicalize CSS via parse/serialize round-trip. */
  function normalize(src: string): string;
}

// ---------------------------------------------------------------- uuid
export namespace uuid {
  /** Check whether a string is a valid UUID. */
  function isValid(s: string): boolean;
  /** Generate a time-based v1 UUID string. */
  function v1(): string;
  /** Generate a DCE Security v2 UUID (domain 0=person, 1=group, 2=org). */
  function v2(domain: number, id: number): string;
  /** Generate an MD5 name-based v3 UUID (namespace: dns/url/oid/x500 or UUID). */
  function v3(namespace: string, name: string): string;
  /** Generate a random v4 UUID string. */
  function v4(): string;
  /** Generate a SHA-1 name-based v5 UUID (namespace: dns/url/oid/x500 or UUID). */
  function v5(namespace: string, name: string): string;
  /** Generate a reordered time-based v6 UUID string. */
  function v6(): string;
  /** Generate a time-ordered v7 UUID string. */
  function v7(): string;
  /** Generate a custom v8 UUID from 128 bits of hex (32 hex digits). */
  function v8(data: string): string;
  /** The nil UUID (all zeros). */
  function nil(): string;
  /** Parse a UUID to its canonical string form. */
  function parse(s: string): string;
  /** Extract the version number from a UUID string. */
  function version(s: string): number;
  /** Extract the variant name (NCS, RFC4122, Microsoft, Future). */
  function variant(s: string): string;
}

// ---------------------------------------------------------------- path
export interface PathInfo {
  raw: string;
  kind: string;
  isLocal: boolean;
  [key: string]: unknown;
}

export namespace path {
  /** Parse a filesystem path or URL to a JS object. */
  function parse(s: string): PathInfo;
  /** Canonicalize a path/URL via parse/stringify round-trip. */
  function normalize(s: string): string;
}

/** Filesystem path of the loaded `.node` binary. */
export const binaryPath: string;

/** The `<platform>-<arch>` pair that was loaded. */
export const nativePair: string;
