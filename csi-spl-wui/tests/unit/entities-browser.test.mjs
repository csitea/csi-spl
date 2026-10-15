// perf round 3 P3-19: the client build aliases `entities` to
// src/utils/entities-browser.mjs (the browser's HTML parser decodes). Node has
// no DOM, so this pins the part that is OURS - the strict rule built on a
// loose decoder - against the real package: with entities' own decodeHTML as
// the loose decoder, strictEntityDecoder must equal entities' decodeHTMLStrict
// on every named reference the package knows, on legacy-prefix names
// (`&ampfoo;`), and on bogus ones. The loose half (textarea vs entities'
// decodeHTML) was compared in Chrome over the same corpus when it landed.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { createRequire } from 'node:module'
import { join, dirname } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { decodeHTML, decodeHTMLStrict } from '../../src/utils/entities-browser.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
// markdown-it's own copy of `entities` (pnpm keeps it out of the root)
const mdReq = createRequire(createRequire(join(WUI, 'package.json')).resolve('markdown-it'))
const entities = await import('entities')

// Fetch all named entities from the `entities` package's generated encode-html.js
const encodeHtmlPath = join(WUI, 'node_modules/entities/dist/generated/encode-html.js')
const encodeHtmlContent = readFileSync(encodeHtmlPath, 'utf8')
const namedEntitiesString = encodeHtmlContent.match(/export default "([^"]+)"/)[1]

// Split the string into individual named entities
const names = []
let current = ''
for (const char of namedEntitiesString) {
  if (char === ';') {
    names.push(`&${current};`)
    current = ''
  } else {
    current += char
  }
}

// Ensure full coverage
assert.ok(names.length > 1000, `Expected >1000 named entities, got ${names.length}`)

// strictEntityDecoder must equal entities.decodeHTMLStrict on every name
for (const name of names) {
  const our = decodeHTMLStrict(name)
  const ref = entities.decodeHTMLStrict(name)
  assert.equal(our, ref, `decodeHTMLStrict(${name}) !== entities.decodeHTMLStrict(${name})`)
}

// decodeHTML must equal entities.decodeHTML on every name (browser-only)
if (typeof document !== 'undefined') {
  for (const name of names) {
    const our = decodeHTML(name)
    const ref = entities.decodeHTML(name)
    assert.equal(our, ref, `decodeHTML(${name}) !== entities.decodeHTML(${name})`)
  }
}

// strictEntityDecoder must preserve legacy-prefix names (e.g. &ampfoo;)
const legacyPrefixes = [
  '&amp;', '&lt;', '&gt;', '&quot;', '&apos;'
]
for (const prefix of legacyPrefixes) {
  const name = `${prefix}foo;`
  const our = decodeHTMLStrict(name)
  const ref = entities.decodeHTMLStrict(name)
  assert.equal(our, ref, `decodeHTMLStrict(${name}) !== entities.decodeHTMLStrict(${name})`)
}

// strictEntityDecoder must preserve bogus names (e.g. &notaname;)
const bogusNames = [
  '&notaname;', '&123;', '&;', '&a;', '&quot;'
]
for (const name of bogusNames) {
  const our = decodeHTMLStrict(name)
  const ref = entities.decodeHTMLStrict(name)
  assert.equal(our, ref, `decodeHTMLStrict(${name}) !== entities.decodeHTMLStrict(${name})`)
}
