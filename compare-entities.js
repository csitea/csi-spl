// compare-entities.js
// Compare strictEntityDecoder vs entities.decodeHTMLStrict for all 1511 names.
// Usage: cd /opt/csi/csi-spl-wt/m-539 && node compare-entities.js

import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

// Resolve paths
const __dirname = dirname(fileURLToPath(import.meta.url));
const namesPath = join(__dirname, 'full-entities-list.txt');
const entitiesBrowserPath = join(__dirname, 'csi-spl-wui/src/utils/entities-browser.mjs');

// Load the full list of entities
const names = readFileSync(namesPath, 'utf8').split('\n').filter(Boolean);

// Load the `entities` package from markdown-it's node_modules
const require = createRequire(import.meta.url);
const mdRequire = createRequire(require.resolve('markdown-it'));
const entities = mdRequire('entities');

// Mock the loose decoder for Node (since decodeLoose uses document.createElement)
function decodeLoose(s) {
  return s.replace(/&(amp|lt|gt|quot|apos);/g, (m, e) => {
    switch (e) {
      case 'amp': return '&';
      case 'lt': return '<';
      case 'gt': return '>';
      case 'quot': return '"';
      case 'apos': return "'";
      default: return m;
    }
  });
}

// Load strictEntityDecoder from entities-browser.mjs
const { strictEntityDecoder } = await import(entitiesBrowserPath);
const strictDecoder = strictEntityDecoder(decodeLoose);

// Compare results
const mismatches = [];
for (const name of names) {
  const strictResult = strictDecoder(name);
  const entitiesResult = entities.decodeHTMLStrict(name);
  if (strictResult !== entitiesResult) {
    mismatches.push({ name, strictResult, entitiesResult });
  }
}

// Output results
console.log(`Total entities: ${names.length}`);
console.log(`Mismatches: ${mismatches.length}`);
if (mismatches.length > 0) {
  console.log("\nMismatches:");
  mismatches.forEach(({ name, strictResult, entitiesResult }) => {
    console.log(`- ${name}: strict='${strictResult}', entities='${entitiesResult}'`);
  });
} else {
  console.log("\nNo mismatches found.");
}