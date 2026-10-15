// compare-entities.js
// Compare decodeHTMLStrict vs entities.decodeHTMLStrict for all 1511 names.
// Usage: cd /opt/csi/csi-spl-wt/m-539/csi-spl-wui && node compare-entities.js

import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

// Resolve paths
const __dirname = dirname(fileURLToPath(import.meta.url));
const namesPath = join(__dirname, '../full-entities-list.txt');
const entitiesBrowserPath = join(__dirname, 'src/utils/entities-browser.mjs');

// Load the full list of entities
const names = readFileSync(namesPath, 'utf8').split('\n').filter(Boolean);

// Load the `entities` package from markdown-it's node_modules
const require = createRequire(import.meta.url);
const entities = require('entities');

// Load decodeHTMLStrict from entities-browser.mjs
const { decodeHTMLStrict } = await import(entitiesBrowserPath);

// Compare results
const mismatches = [];
for (const name of names) {
  const ourResult = decodeHTMLStrict(name);
  const entitiesResult = entities.decodeHTMLStrict(name);
  if (ourResult !== entitiesResult) {
    mismatches.push({ name, ourResult, entitiesResult });
  }
}

// Output results
console.log(`Total entities: ${names.length}`);
console.log(`Mismatches: ${mismatches.length}`);
if (mismatches.length > 0) {
  console.log("\nMismatches:");
  mismatches.forEach(({ name, ourResult, entitiesResult }) => {
    console.log(`- ${name}: our='${ourResult}', entities='${entitiesResult}'`);
  });
} else {
  console.log("\nNo mismatches found.");
}