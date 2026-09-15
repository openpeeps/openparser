<p align="center">
  A tiny collection of high-performance parsers and dumpers 👇<br><br>
  YAML &bullet; XML &bullet; TOML &bullet; CSV BSON &bullet; Plist &bullet; HTML &bullet; CSS &bullet; RSS &bullet; Atom<br>
  DotEnv &bullet; iCal &bullet; vCard &bullet; NIF &bullet; SQL &bullet; Regex &bullet; Gettext &bullet; FBE &bullet; QR &bullet; SVG &bullet; Colors<br><br>
  👑 Written in Nim language
</p>

<p align="center">
  <code>npm install @openpeeps/openparser</code>
</p>

## About

Node.js native bindings for [openparser](https://github.com/openpeeps/openparser), a collection of fast parsers and serializers written in Nim, exposed to JavaScript through a prebuilt `.node` addon (built with [denim](https://github.com/openpeeps/denim)).

No runtime dependencies. Requires Node.js >= 18. TypeScript definitions ship in `index.d.ts`.

## Installation

```sh
npm install @openpeeps/openparser
```

## Quick start

```js
const { yaml, vcard, qr, uuid } = require('@openpeeps/openparser');

yaml.parse('name: Ada\nlanguages:\n  - Analytical Engines\n');
// => { name: 'Ada', languages: ['Analytical Engines'] }

uuid.v5('dns', 'www.example.com');
// => '2ed6657d-e927-568b-95e1-2665a8aea6a2'

const [{ fn }] = vcard.parse('BEGIN:VCARD\r\nVERSION:4.0\r\nFN:Ada\r\nEND:VCARD\r\n');
qr.encodeSvg(qr.makeUrl('example.org')); // => '<svg ...>...</svg>'
```

## Conventions

Each parser lives in its own namespace (`yaml`, `toml`, `xml`, and so on).

* `parse` takes a document string and returns live JS objects.
* `normalize` round-trips through the typed model and returns a canonical string.
* Serializer inputs take a JSON string, so call `JSON.stringify` on your object first.
* Binary payloads (BSON, binary plist) cross the boundary as base64 strings.
* Parser errors surface as thrown `Error` objects.

## Modules

* [YAML](#yaml)
* [TOML](#toml)
* [XML](#xml)
* [CSV](#csv)
* [BSON](#bson)
* [Plist](#plist)
* [RSS](#rss)
* [Atom](#atom)
* [DotEnv](#dotenv)
* [vCard](#vcard)
* [iCal](#ical)
* [SQL](#sql)
* [Gettext](#gettext)
* [CSS](#css)
* [SVG](#svg)
* [Colors](#colors)
* [Path and URL](#path-and-url)
* [UUID](#uuid)
* [QR](#qr)
* [Fuzzy search](#fuzzy-search)

### YAML

Parse YAML documents to plain objects, or serialize a JSON document to YAML.

```js
const { yaml } = require('@openpeeps/openparser');

yaml.parse('host: localhost\nport: 8080\ntags: [a, b]\n');
// => { host: 'localhost', port: 8080, tags: ['a', 'b'] }

yaml.dump(JSON.stringify({ a: 1 }));
// => 'a: 1\n'
```

### TOML

Parse TOML documents (datetimes become ISO strings), or serialize a JSON document to TOML. JSON `null` is rejected.

```js
const { toml } = require('@openpeeps/openparser');

toml.parse('title = "hi"\n[owner]\nname = "Ada"');
// => { title: 'hi', owner: { name: 'Ada' } }

toml.dump(JSON.stringify({ server: { port: 8080 } }));
// => '[server]\nport = 8080\n'
```

### XML

Parse XML to a small DOM tree (`element` nodes with `tag`, `attrs` and `children`, plus `text`, `comment`, `cdata`, `prolog` and `doctype` nodes). Use `normalize` for canonical output.

```js
const { xml } = require('@openpeeps/openparser');

xml.parse('<person name="Ada"><email>a@ex.org</email></person>');
// => { kind: 'element', tag: 'person', attrs: { name: 'Ada' }, children: [...] }

xml.normalize('<a  ><b>x</b></a>');
// => '<a><b>x</b></a>'
```

### CSV

Parse CSV text or files to arrays of rows. Pass the delimiter and quote characters explicitly.

```js
const { csv } = require('@openpeeps/openparser');

csv.parse('a,b\n1,2\n', ',', '"');
// => [['a', 'b'], ['1', '2']]

csv.parseFile('./data.csv', ',', '"');
// same shape, read from disk
```

### BSON

Encode a JSON document to BSON (returned as base64), or decode base64 BSON back to an object.

```js
const { bson } = require('@openpeeps/openparser');

const bin = bson.fromJson(JSON.stringify({ hello: 'world' }));
// => base64 BSON string

bson.toJson(bin);
// => { hello: 'world' }
```

### Plist

Parse XML plists, parse XML or binary plists from base64, and serialize JSON documents to XML or binary plist form.

```js
const { plist } = require('@openpeeps/openparser');

plist.parse('<?xml version="1.0"?><plist version="1.0">...</plist>');
// => { A: 'B', N: 3 }

plist.parseBase64(base64); // XML or binary plist to object
plist.toXml(JSON.stringify({ A: 'B' })); // XML plist string
plist.toBplist(JSON.stringify({ A: 'B' })); // binary plist as base64
```

### RSS

Parse an RSS feed to a typed object with channel metadata and `items`, or canonicalize it with `normalize`.

```js
const { rss } = require('@openpeeps/openparser');

const feed = rss.parse(xmlString);
feed.items[0];
// => { title, link, description, pubDate, guid, media, ... }

rss.normalize(xmlString); // canonical RSS string
```

### Atom

Parse an Atom feed to a typed object with `entries`, authors, links and categories, or canonicalize it with `normalize`.

```js
const { atom } = require('@openpeeps/openparser');

const feed = atom.parse(xmlString);
feed.entries[0];
// => { id, title: { kind, value }, authors, links, ... }

atom.normalize(xmlString); // canonical Atom string
```

### DotEnv

Parse `.env` content to an array of `{ key, value, expand }` entries.

```js
const { dotenv } = require('@openpeeps/openparser');

dotenv.parse('DB_HOST=localhost\nDB_PORT=5432\n');
// => [{ key: 'DB_HOST', value: 'localhost', expand: true }, ...]
```

### vCard

Parse vCard 3.0 and 4.0 contacts to structured objects with names, addresses, phones, emails and more. Also canonicalizes to vCard 4.0 and builds minimal QR payloads.

```js
const { vcard } = require('@openpeeps/openparser');

const [card] = vcard.parse(vcf);
card.fn; // 'Ada Lovelace'
card.n.family; // 'Lovelace'
card.tels[0]; // { value: '+100', pref: 1, types: ['cell'], ... }
card.adrs[0].locality; // 'city'

vcard.normalize(vcf); // canonical vCard 4.0 string
vcard.qrPayload(vcf, 0); // minimal vCard 3.0 payload for QR encoding
```

### iCal

Parse iCalendar (RFC 5545) data to a calendar object with typed components (events, todos, journals, timezones), including attendees, alarms and recurrence data.

```js
const { ical } = require('@openpeeps/openparser');

const cal = ical.parse(ics);
cal.components[0];
// => { kind: 'event', summary: 'Hi', dtstart: { value, tzid },
//      attendees: [{ uri, cn }], alarms: [{ action, trigger }], ... }

ical.normalize(ics); // canonical iCalendar string
```

### SQL

Parse SQL to an AST (`{ kind: 'nk...', children }`), or render it back in canonical form. Pass a driver name to select the dialect.

```js
const { sql } = require('@openpeeps/openparser');

sql.parse('SELECT a FROM t WHERE b = 1', 'generic');
// => { kind: 'nkSelect', children: [...] }

sql.normalize('select a from t', 'generic');
// => 'select a from t;'

sql.parse('SELECT a FROM t', 'pgsql'); // postgres dialect
// drivers: 'generic', 'pgsql', 'mysql', 'mariadb', 'sqlite', ...
```

### Gettext

Translate messages with classic `.po` catalogs or compiled `.mo` catalogs. Pass `''` when there is no message context.

```js
const { gettext } = require('@openpeeps/openparser');

gettext.poTranslate('./locale/ro.po', 'Hello', '');
// => 'Salut'

gettext.poTranslate('./locale/ro.po', 'File', 'menu');
// context-aware lookup

gettext.moTranslate('./locale/ro.mo', 'Hello', '');
// same API for compiled catalogs
```

### CSS

Parse a stylesheet to an AST of rulesets and declarations, or canonicalize it with `normalize`.

```js
const { css } = require('@openpeeps/openparser');

css.parse('a { color: red; margin: 0; }');
// => [{ kind: 'ruleset', declarations: [{ property: 'color', value: 'red' }, ...] }]

css.normalize('a{color:red}');
// => canonical CSS string
```

### SVG

Canonicalize SVG documents, or parse SVG path data to command segments.

```js
const { svg } = require('@openpeeps/openparser');

svg.normalize('<svg xmlns="http://www.w3.org/2000/svg"><rect width="10"/></svg>');
// => canonical SVG string

svg.parsePathData('M10 10 L20 20');
// => [{ cmd: 'M', args: [10, 10] }, { cmd: 'L', args: [20, 20] }]
```

### Colors

Parse any CSS color to hex, rgb, hsl, hsv, cmyk, lab and oklch strings, plus validate, adjust and compare colors.

```js
const { colors } = require('@openpeeps/openparser');

colors.parse('red');
// => { hex: '#ff0000', rgb, hsl, hsv, cmyk, lab, oklch, name }

colors.isValid('oklch(0.7 0.15 180)'); // => true
colors.lighten('#800000', '20'); // => '#e60000'
colors.darken('#800000', '20'); // => '#1a0000'
colors.complement('red'); // => '#00ffff'
colors.contrastRatio('white', 'black'); // => 21 (WCAG)
```

### Path and URL

Parse filesystem paths and URLs to typed objects, or canonicalize them with `normalize`.

```js
const { path } = require('@openpeeps/openparser');

path.parse('https://example.com/a/b?q=1');
// => { raw, kind, isLocal: false, host, port, query, ... }

path.parse('/tmp/a/b.txt');
// => { isLocal: true, segments: ['tmp', 'a', 'b.txt'], ext: 'txt', ... }

path.normalize('https://example.com/a?x=1');
// => canonical URL string
```

### UUID

Generate and inspect UUIDs in all 8 versions, plus the nil UUID. Name-based versions accept `dns`, `url`, `oid`, `x500` or any UUID string as namespace.

```js
const { uuid } = require('@openpeeps/openparser');

uuid.v1(); uuid.v6(); uuid.v4(); uuid.v7(); // time-based and random
uuid.v2(0, 1000); // DCE security (domain 0 = person, 1 = group, 2 = org)
uuid.v3('dns', 'www.example.com'); // => '5df41881-3aed-3515-88a7-2f4a814cf09e'
uuid.v5('dns', 'www.example.com'); // => '2ed6657d-e927-568b-95e1-2665a8aea6a2'
uuid.v8('0123456789abcdef0123456789abcdef'); // custom bits, version and variant stamped
uuid.nil(); // => '00000000-0000-0000-0000-000000000000'
uuid.isValid(id); // => true or false
uuid.version(id); // 1 to 8
uuid.variant(id); // 'NCS', 'RFC4122', and others
```

### QR

Build common QR payloads (WiFi, contact, SMS, email, URL) and encode them as SVG symbols across every symbology family: Model 1, Model 2, Micro, rMQR, AQR and SQRC.

```js
const { qr } = require('@openpeeps/openparser');

// Payload builders
qr.makeWifi('net', 'secret1234', 'WPA', false); // => 'WIFI:T:WPA;S:net;P:secret1234;;'
qr.makeMecard('John', '+100', '', ''); // => 'MECARD:N:John;TEL:+100;;'
qr.makeSms('+100', 'hi'); // => 'SMSTO:+100:hi'
qr.makeEmail('a@b.org', 'Hi', 'Body'); // => 'mailto:a@b.org?subject=Hi&body=Body'
qr.makeUrl('example.org'); // => 'https://example.org'

// Encoders (all return SVG strings, EC is 'L', 'M', 'Q' or 'H')
qr.encodeSvg('hello'); // Model 2 with defaults
qr.encodeModel2('hello', 'M', 0); // version 0 = auto, 1 to 40
qr.encodeMicro('12345', 'L', 0); // 0 = auto, 1 to 4 select M1 to M4
qr.encodeRmqr('hello', 'M', ''); // '' = auto, else e.g. 'R7x43'
qr.encodeModel1('HELLO', 'M', 0); // legacy Model 1, 0 = auto, 1 to 12
qr.encodeAqr('main payload', 'ring', 'M', 0); // dual-payload AQR symbol

// SQRC (public area plus AES-sealed private area)
const key = '0123456789abcdef'; // 16, 24 or 32 bytes
const payload = qr.makeSqrc('public area', 'secret area', key, false);
qr.splitSqrc(payload); // => { extended, blobBase64, publicData }
qr.decodeSqrc(payload, key); // => { ok: true, publicText, privateText, scannedText }
qr.encodeSqrc('public area', 'secret area', key); // rendered SVG symbol
```

### Fuzzy search

Score single candidates with SIMD-accelerated fuzzy matching, or rank a list of candidates best-first.

```js
const { fuzzy } = require('@openpeeps/openparser');

// Score one candidate (every query char must appear in order)
fuzzy.score('abc', 'abc', false);
// => { matched: true, score: 27.333, positions: [0, 1, 2] }
fuzzy.score('abc', 'axbyc', false); // gapped match, lower score
fuzzy.score('A', 'a', true); // case-sensitive: { matched: false, ... }

// Rank candidates best-first (`candidates` is a JSON array string,
// `minScore` crosses as string, `limit` 0 means no limit)
const words = ['application', 'apple', 'pineapple', 'app'];
fuzzy.search('app', JSON.stringify(words), false, 2, '0');
// => [{ text: 'app', score: 27.333, positions: [0, 1, 2] },
//     { text: 'apple', score: 16.4, positions: [0, 1, 2] }]
```

## Supported platforms

Prebuilt binaries ship under `bin/<platform>-<arch>/openparser.node` and are selected at load time from `process.platform` and `process.arch`:

| OS | Arch |
|---|---|
| darwin | arm64, x64 |
| linux | arm64, x64 |

`binaryPath` and `nativePair` are exposed on the module so you can inspect which binary was loaded:

```js
const api = require('@openpeeps/openparser');
api.binaryPath; // .../bin/darwin-arm64/openparser.node
api.nativePair; // 'darwin-arm64'
```

## Building from source

Requires Nim, [denim](https://github.com/openpeeps/denim) and cmake-js. From the repository root:

```sh
denim build src/openparser.nim --cmake -y
```

or via the package script (builds, then slots the binary into `bin/<platform>-<arch>/`):

```sh
npm run build --prefix addons/openparser_napi
```

Release binaries are produced per-host by CI (native addons cannot be cross-compiled). Run the suite with `npm test` (Node's built-in runner, 65 tests, no dev dependencies).

## Contributions and Support

* Found a bug? [Create a new Issue](https://github.com/openpeeps/openparser/issues)
* Want to help? [Fork it!](https://github.com/openpeeps/openparser/fork)

## License

MIT license. [Made by Humans from OpenPeeps](https://github.com/openpeeps).<br>
Copyright OpenPeeps and Contributors. All rights reserved.
