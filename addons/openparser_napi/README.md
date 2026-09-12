<p align="center">
  A tiny collection of high-performance parsers and dumpers<br>
  YAML &bullet; XML &bullet; TOML &bullet; CSV <br>
  BSON &bullet; Plist &bullet; HTML &bullet; CSS &bullet; RSS &bullet; Atom<br>
  DotEnv &bullet; iCal &bullet; vCard &bullet; NIF &bullet; SQL &bullet; Regex &bullet; Gettext &bullet; FBE &bullet; QR &bullet; SVG &bullet; Colors<br>
  Written in Nim language
</p>

<p align="center">
  <code>npm install @openpeeps/openparser</code>
</p>

## About
Node.js native bindings for [openparser](https://github.com/openpeeps/openparser), a collection of fast parsers and serializers written in Nim, exposed to JavaScript through a prebuilt `.node` addon (built with [denim](https://github.com/openpeeps/denim)).

```sh
npm install @openpeeps/openparser
```

```js
const { yaml, vcard, qr, uuid } = require('@openpeeps/openparser');

yaml.parse('name: Ada\nlanguages:\n  - Analytical Engines\n');
// => { name: 'Ada', languages: ['Analytical Engines'] }

uuid.v5('dns', 'www.example.com');
// => '2ed6657d-e927-568b-95e1-2665a8aea6a2'

const [{ fn }] = vcard.parse('BEGIN:VCARD\r\nVERSION:4.0\r\nFN:Ada\r\nEND:VCARD\r\n');
qr.encodeSvg(qr.makeUrl('example.org')); // => '<svg …>…</svg>'
```

No runtime dependencies. Requires Node.js >= 18. TypeScript definitions ship in `index.d.ts`.

## Key features

One namespaced object per parser. `parse` takes a document string and returns live JS objects; `normalize` round-trips through the typed model and returns a canonical string; serializer inputs take a **JSON string** (`JSON.stringify` your object first); binary payloads (BSON, binary plist) cross the boundary as **base64**; parser errors surface as thrown `Error`s.

### Data formats — YAML, TOML, XML, CSV, BSON, Plist

```js
const { yaml, toml, xml, csv, bson, plist } = require('@openpeeps/openparser');

toml.parse('title = "hi"\n[owner]\nname = "Ada"');
// => { title: 'hi', owner: { name: 'Ada' } }

yaml.dump(JSON.stringify({ a: 1 }));          // => 'a: 1\n'
xml.normalize('<a  ><b>x</b></a>');           // canonical XML
csv.parse('a,b\n1,2\n', ',', '"');            // => [['a','b'],['1','2']]
csv.parseFile('./data.csv', ',', '"');       // same, from disk

const bin = bson.fromJson(JSON.stringify({ hello: 'world' })); // base64 BSON
bson.toJson(bin);                             // => { hello: 'world' }

plist.parse('<?xml version="1.0"?>…');        // XML plist to object
plist.parseBase64(base64);                    // XML or binary plist to object
plist.toBplist(JSON.stringify({ a: 1 }));     // binary plist as base64
```

### Feeds — RSS, Atom, DotEnv

```js
const { rss, atom, dotenv } = require('@openpeeps/openparser');

const feed = rss.parse(xmlString);
feed.items[0]; // => { title, link, description, pubDate, guid, media, … }
rss.normalize(xmlString); // canonical RSS

atom.parse(xmlString).entries[0];
// => { id, title: { kind, value }, authors, links, … }

dotenv.parse('DB_HOST=localhost\nDB_PORT=5432\n');
// => [{ key: 'DB_HOST', value: 'localhost', expand: true }, …]
```

### Contacts & calendars — vCard, iCal

```js
const { vcard, ical } = require('@openpeeps/openparser');

const [card] = vcard.parse(vcf);
card.fn;                 // 'Ada Lovelace'
card.n.family;           // 'Lovelace'
card.tels[0];            // { value: '+100', pref: 1, types: ['cell'], … }
card.adrs[0].locality;   // 'city'
vcard.normalize(vcf);    // canonical vCard 4.0
vcard.qrPayload(vcf, 0); // minimal vCard 3.0 payload for QR encoding

const cal = ical.parse(ics);
cal.components[0];
// => { kind: 'event', summary: 'Hi', dtstart: { value, tzid },
//      attendees: [{ uri, cn }], alarms: [{ action, trigger }], … }
```

### SQL, Gettext, CSS, SVG, Colors, Paths

```js
const { sql, gettext, css, svg, colors, path } = require('@openpeeps/openparser');

sql.parse('SELECT a FROM t WHERE b = 1', 'generic'); // AST { kind: 'nk…', children }
sql.normalize('select a from t', 'generic');         // => 'select a from t;'
sql.parse('SELECT a FROM t', 'pgsql');               // dialect selection

gettext.poTranslate('./locale/ro.po', 'Hello', '');  // => 'Salut'
gettext.poTranslate('./locale/ro.po', 'File', 'menu'); // context-aware
gettext.moTranslate('./locale/ro.mo', 'Hello', '');  // compiled catalogs

css.parse('a { color: red; margin: 0; }');
// => [{ kind: 'ruleset', declarations: [{ property: 'color', value: 'red' }, …] }]

svg.parsePathData('M10 10 L20 20'); // => [{ cmd: 'M', args: [10, 10] }, …]

colors.parse('red');                // => { hex: '#ff0000', rgb, hsl, hsv, cmyk, lab, oklch, name }
colors.contrastRatio('white', 'black'); // => 21 (WCAG)
colors.complement('red');           // => '#00ffff'

path.parse('https://example.com/a/b?q=1'); // typed path/URL object
```

### UUID — all 8 versions

```js
const { uuid } = require('@openpeeps/openparser');

uuid.v1(); uuid.v6(); uuid.v4(); uuid.v7();   // time-based / random
uuid.v2(0, 1000);                             // DCE security (domain 0=person,1=group,2=org)
uuid.v3('dns', 'www.example.com');            // => '5df41881-3aed-3515-88a7-2f4a814cf09e'
uuid.v5('dns', 'www.example.com');            // => '2ed6657d-e927-568b-95e1-2665a8aea6a2'
uuid.v8('0123456789abcdef0123456789abcdef');  // custom, version/variant bits stamped
uuid.nil();                                   // => '00000000-0000-0000-0000-000000000000'
uuid.version(id); uuid.variant(id);           // 1-8, 'NCS' | 'RFC4122' | …
// namespaces: 'dns' | 'url' | 'oid' | 'x500' or any UUID string
```

### QR — every symbology family

```js
const { qr } = require('@openpeeps/openparser');

// Payload builders
qr.makeWifi('net', 'secret1234', 'WPA', false); // => 'WIFI:T:WPA;S:net;P:secret1234;;'
qr.makeMecard('John', '+100', '', '');          // => 'MECARD:N:John;TEL:+100;;'
qr.makeSms('+100', 'hi');                       // => 'SMSTO:+100:hi'
qr.makeEmail('a@b.org', 'Hi', 'Body');          // => 'mailto:a@b.org?subject=Hi&body=Body'
qr.makeUrl('example.org');                      // => 'https://example.org'

// Encoders — all return SVG strings. EC is 'L' | 'M' | 'Q' | 'H'.
qr.encodeSvg('hello');                          // Model 2, defaults
qr.encodeModel2('hello', 'M', 0);               // version 0 = auto, 1-40
qr.encodeMicro('12345', 'L', 0);                // 0 = auto, 1-4 = M1-M4
qr.encodeRmqr('hello', 'M', '');                // '' = auto, else e.g. 'R7x43'
qr.encodeModel1('HELLO', 'M', 0);               // legacy Model 1, 0 = auto, 1-12
qr.encodeAqr('main payload', 'ring', 'M', 0);   // dual-payload AQR symbol

// SQRC — public area plus AES-sealed private area
const key = '0123456789abcdef'; // 16 / 24 / 32 bytes
const payload = qr.makeSqrc('public area', 'secret area', key, false);
qr.splitSqrc(payload);          // => { extended, blobBase64, publicData }
qr.decodeSqrc(payload, key);    // => { ok: true, publicText, privateText, scannedText }
qr.encodeSqrc('public area', 'secret area', key); // rendered SVG symbol
```

## Supported platforms

Prebuilt binaries ship under `bin/<platform>-<arch>/openparser.node` and are selected at load time from `process.platform`/`process.arch`:

| OS | Arch |
|---|---|
| darwin | arm64, x64 |
| linux | arm64, x64 |
| win32 | x64 |

`binaryPath` and `nativePair` are exposed on the module so you can inspect which binary was loaded:

```js
const api = require('@openpeeps/openparser');
api.binaryPath; // …/bin/darwin-arm64/openparser.node
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

## Contributions & Support

- Found a bug? [Create a new Issue](https://github.com/openpeeps/openparser/issues)
- Want to help? [Fork it!](https://github.com/openpeeps/openparser/fork)

## License

MIT license. [Made by Humans from OpenPeeps](https://github.com/openpeeps).<br>
Copyright OpenPeeps & Contributors &mdash; All rights reserved.
