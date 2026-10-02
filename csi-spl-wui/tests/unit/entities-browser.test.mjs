// perf round 3 P3-19: the client build aliases `entities` to
// src/utils/entities-browser.mjs (the browser's HTML parser decodes). Node has
// no DOM, so this pins the part that is OURS - the strict rule built on a
// loose decoder - against the real package: with entities' own decodeHTML as
// the loose decoder, strictEntityDecoder must equal entities' decodeHTMLStrict
// on every named reference the package knows, on legacy-prefix names
// (`&ampfoo;`) and on bogus ones. The loose half (textarea vs entities'
// decodeHTML) was compared in Chrome over the same corpus when it landed.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { createRequire } from 'node:module'
import { join, dirname } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { strictEntityDecoder } from '../../src/utils/entities-browser.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
// markdown-it's own copy of `entities` (pnpm keeps it out of the root)
const mdReq = createRequire(createRequire(join(WUI, 'package.json')).resolve('markdown-it'))
const entry = mdReq.resolve('entities')
const entitiesDir = entry.slice(0, entry.lastIndexOf('/entities/') + '/entities'.length)
const entities = await import(pathToFileURL(join(entitiesDir, 'lib/esm/index.js')).href)
const names = [...new Set(readFileSync(join(entitiesDir, 'lib/esm/generated/encode-html.js'), 'utf8')
  .match(/&[A-Za-z][A-Za-z0-9]{1,31};/g))]

describe('entities-browser: the strict rule', () => {
  const strict = strictEntityDecoder(entities.decodeHTML)

  it(`equals entities.decodeHTMLStrict on every known name (${names.length})`, () => {
    assert.ok(names.length > 1000)
    for (const n of names) assert.equal(strict(n), entities.decodeHTMLStrict(n), n)
  })

  it('keeps a legacy-prefix or unknown name as it is, like decodeHTMLStrict', () => {
    for (const n of ['&ampfoo;', '&ltx;', '&copyright;', '&notit;', '&nosuchname;', '&AMPx;', '&semix;']) {
      assert.equal(strict(n), entities.decodeHTMLStrict(n), n)
    }
    assert.equal(strict('&ampfoo;'), '&ampfoo;')
    assert.equal(strict('&amp;'), '&')
    assert.equal(strict('&semi;'), ';')
  })
})

describe('entities-browser: the client alias', () => {
  it('nuxt.config resolves entities to it in the client build only', () => {
    const cfg = readFileSync(join(WUI, 'nuxt.config.ts'), 'utf8')
    assert.match(cfg, /const ENTITIES_BROWSER = fileURLToPath\(new URL\("\.\/src\/utils\/entities-browser\.mjs", import\.meta\.url\)\)/)
    assert.match(cfg, /resolveId\(id\) \{\s*return id === "entities" \? ENTITIES_BROWSER : null\s*\},\s*\}, \{ server: false \}\)/)
    assert.match(cfg, /modules: \[[^\]]*entitiesBrowserModule[^\]]*\]/)
  })
})
