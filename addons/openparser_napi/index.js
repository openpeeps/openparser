'use strict';
// Main entry for the openparser native addon.
//
// This package ships prebuilt `.node` binaries per platform/arch under
// `bin/<platform>-<arch>/openparser.node` (populated by `npm run build`
// on each host — native addons cannot be cross-compiled). At load time
// the binary matching `process.platform`/`process.arch` is selected.
//
// A repository checkout fallback (`../../bin/openparser.node`, produced
// by running `denim build src/openparser.nim --cmake -y` at the repo
// root) keeps the developer flow working without packing binaries.
//
// The native module exposes one namespaced object per parser (`yaml`,
// `toml`, `xml`, …), so this wrapper stays thin: it selects the binary
// and re-exports it unchanged.

const fs = require('fs');
const path = require('path');

const SUPPORTED = {
  darwin: ['arm64', 'x64'],
  linux: ['arm64', 'x64'],
};

function candidates() {
  const list = [];
  const pair = `${process.platform}-${process.arch}`;
  list.push(path.join(__dirname, 'bin', pair, 'openparser.node'));
  // Developer fallback: repo-root build output (not shipped in the
  // published tarball, see package.json `files`).
  list.push(path.join(__dirname, '..', '..', 'bin', 'openparser.node'));
  return { list, pair };
}

let loaded = null;
let loadedFrom = null;
const { list, pair } = candidates();
for (const p of list) {
  if (fs.existsSync(p)) {
    loadedFrom = p;
    loaded = require(p);
    break;
  }
}

if (loaded === null) {
  const supported = Object.entries(SUPPORTED)
    .map(([plat, archs]) => archs.map((a) => `${plat}-${a}`).join(', '))
    .join(', ');
  throw new Error(
    `openparser-napi: no prebuilt binary for ${pair} and no dev fallback found. Tried:\n` +
      list.join('\n') +
      `\nSupported: ${supported}.\n` +
      'Build it with `npm run build` on the target host ' +
      '(requires Nim, denim and cmake-js).'
  );
}

module.exports = loaded;
module.exports.binaryPath = loadedFrom;
module.exports.nativePair = pair;
