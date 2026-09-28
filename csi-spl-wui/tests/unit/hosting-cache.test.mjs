// Firebase Hosting Cache-Control (CLE-35076, perf lane P3): which URL gets
// which caching, read from the header block the deploy render writes
// (csi-spl-orc/src/bash/scripts/render-wui-firebase-json.sh) and from the
// checked-in firebase.json, which must say the same.
//
// Hosting applies every matching `headers` rule in order, so for one key the
// LAST matching rule wins; `effective()` below resolves it the same way.
import { describe, it, before } from 'node:test'
import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { mkdtempSync, readFileSync, readdirSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join, relative } from 'node:path'
import { fileURLToPath } from 'node:url'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const REPO = join(WUI, '..')
const RENDER = join(REPO, 'csi-spl-orc/src/bash/scripts/render-wui-firebase-json.sh')
const PUBLIC = join(WUI, 'src/public')

/** Hosting glob -> RegExp: `**`, `*` and the extglob `@(a|b)`. */
function globRe(glob) {
  let re = ''
  for (let i = 0; i < glob.length; i++) {
    const c = glob[i]
    if (glob.startsWith('**/', i)) { re += '(?:.*/)?'; i += 2 } else if (glob.startsWith('**', i)) { re += '.*'; i += 1 } else if (c === '*') re += '[^/]*'
    else if (glob.startsWith('@(', i)) { const end = glob.indexOf(')', i); re += '(?:' + glob.slice(i + 2, end) + ')'; i = end } else re += c.replace(/[.+?^${}()|[\]\\]/g, '\\$&')
  }
  return new RegExp('^' + re + '$')
}

/** The Cache-Control a path is served with: the last matching rule's. */
function effective(doc, path) {
  let v = ''
  for (const rule of doc.hosting.headers) {
    if (!globRe(rule.source.startsWith('/') ? rule.source : '/' + rule.source).test(path)) continue
    const h = rule.headers.find((x) => x.key === 'Cache-Control')
    if (h) v = h.value
  }
  return v
}

function rendered() {
  const pub = mkdtempSync(join(tmpdir(), 'cache-bundle-'))
  writeFileSync(join(pub, '200.html'), '<!doctype html><html><head></head><body><div id="__nuxt"></div></body></html>')
  const out = join(mkdtempSync(join(tmpdir(), 'cache-out-')), 'firebase.json')
  const r = spawnSync('bash', [RENDER], { env: { ...process.env, ENV: 'dev', OUT: out, PUBLIC_DIR: pub }, encoding: 'utf8' })
  assert.equal(r.status, 0, r.stderr)
  return JSON.parse(readFileSync(out, 'utf8'))
}

const walk = (d) => readdirSync(d, { withFileTypes: true }).flatMap((e) => e.isDirectory() ? walk(join(d, e.name)) : [join(d, e.name)])
const MEDIA = 'public, max-age=3600, stale-while-revalidate=86400'
const IMMUTABLE = 'public, max-age=31536000, immutable'
const REVALIDATE = 'public, max-age=0, must-revalidate'

for (const [name, load] of [['render (deploy)', rendered], ['checked-in firebase.json', () => JSON.parse(readFileSync(join(WUI, 'firebase.json'), 'utf8'))]]) {
  describe(`Hosting Cache-Control: ${name}`, () => {
    let doc
    before(() => { doc = load() })

    it('every unhashed picture, icon and the manifest in src/public is fresh for an hour, then stale-while-revalidate', () => {
      const media = walk(PUBLIC).map((f) => '/' + relative(PUBLIC, f)).filter((p) => !p.endsWith('.js'))
      assert.ok(media.length >= 10, media.join(' '))
      for (const p of media) assert.equal(effective(doc, p), MEDIA, p)
    })

    it('the service worker, build.json and every page still revalidate on each load (a deploy is seen at once)', () => {
      for (const p of ['/sw.js', '/build.json', '/200.html', '/login', '/', '/lobby']) assert.equal(effective(doc, p), REVALIDATE, p)
    })

    it('hashed /_nuxt/ assets stay immutable, pictures included', () => {
      for (const p of ['/_nuxt/entry.CFbJyYrE.css', '/_nuxt/Bx9a1.js', '/_nuxt/logo.B1c2D3.png', '/_nuxt/builds/meta/0b1c.json']) assert.equal(effective(doc, p), IMMUTABLE, p)
    })

    it("Nuxt's /_nuxt/builds/latest.json is never immutable: it names the current build under a fixed URL", () => {
      assert.equal(effective(doc, '/_nuxt/builds/latest.json'), REVALIDATE)
    })
  })
}

describe('globRe (Hosting glob semantics used above)', () => {
  it('matches like Hosting for the forms in use', () => {
    assert.ok(globRe('/**').test('/a/b.png'))
    assert.ok(globRe('/**/_nuxt/**').test('/_nuxt/x.js'))
    assert.ok(!globRe('/**/_nuxt/**').test('/logo.webp'))
    assert.ok(globRe('/**/*.@(png|webp)').test('/icons/favicon-64.png'))
    assert.ok(globRe('/**/*.@(png|webp)').test('/logo.webp'))
    assert.ok(!globRe('/**/*.@(png|webp)').test('/sw.js'))
  })
})
