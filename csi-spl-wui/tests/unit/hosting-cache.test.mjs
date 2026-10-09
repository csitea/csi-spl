// Firebase Hosting Cache-Control (CLE-35076, perf lane P3): which URL gets
// which caching, read from the header block the deploy render writes
// (csi-spl-orc/src/bash/scripts/render-wui-firebase-json.sh) and from the
// checked-in firebase.json, which must say the same.
//
// Hosting applies every matching `headers` rule in order, so for one key the
// LAST matching rule wins; `effective()` below resolves it the same way.
import { describe, it, before, after } from 'node:test'
import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { mkdtempSync, readFileSync, rmSync, readdirSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join, relative } from 'node:path'
import { fileURLToPath } from 'node:url'


// Every scratch dir this file makes is removed when it ends: run on every
// pre-push and CI job, the leaked dirs filled the box's shared /tmp inodes.
const scratchDirs = []
const scratch = (prefix) => { const d = mkdtempSync(join(tmpdir(), prefix)); scratchDirs.push(d); return d }
after(() => { for (const d of scratchDirs) rmSync(d, { recursive: true, force: true }) })
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

/** The Cache-Control (or `key`) a path is served with: the last matching rule's. */
function effective(doc, path, key = 'Cache-Control') {
  let v = ''
  for (const rule of doc.hosting.headers) {
    if (!globRe(rule.source.startsWith('/') ? rule.source : '/' + rule.source).test(path)) continue
    const h = rule.headers.find((x) => x.key === key)
    if (h) v = h.value
  }
  return v
}

function rendered(env = 'dev') {
  const pub = scratch('cache-bundle-')
  writeFileSync(join(pub, '200.html'), '<!doctype html><html><head></head><body><div id="__nuxt"></div></body></html>')
  const out = join(scratch('cache-out-'), 'firebase.json')
  const r = spawnSync('bash', [RENDER], { env: { ...process.env, ENV: env, OUT: out, PUBLIC_DIR: pub }, encoding: 'utf8' })
  assert.equal(r.status, 0, r.stderr)
  return JSON.parse(readFileSync(out, 'utf8'))
}

const walk = (d) => readdirSync(d, { withFileTypes: true }).flatMap((e) => e.isDirectory() ? walk(join(d, e.name)) : [join(d, e.name)])
const MEDIA = 'public, max-age=3600, stale-while-revalidate=86400'
const IMMUTABLE = 'public, max-age=31536000, immutable'
const REVALIDATE = 'public, max-age=0, must-revalidate'

/* spec 116 T7: the served X-Robots-Tag follows cnf env.wui.seo_index - prd
   indexes the public pages (every locale copy), dev indexes nothing */
describe('Hosting X-Robots-Tag (spec 116 T7)', () => {
  const PUBLIC_PAGES = ['/login', '/fi/login', '/help', '/help/agents', '/blog', '/blog/page/2', '/blog/2026-10-09-x', '/fi/blog/2026-10-09-x']
  const APP = ['/', '/fi', '/lobby', '/channel/general', '/dm/x', '/t/abc', '/settings', '/fi/help', '/api/v1/auth/login', '/help-md/index.md', '/200.html']
  it('prd: the public pages are index, follow; every app path stays noindex', () => {
    const doc = rendered('prd')
    for (const p of PUBLIC_PAGES) assert.equal(effective(doc, p, 'X-Robots-Tag'), 'index, follow', p)
    for (const p of APP) assert.equal(effective(doc, p, 'X-Robots-Tag'), 'noindex, nofollow', p)
  })
  it('dev: nothing is indexable, the blog included', () => {
    const doc = rendered('dev')
    for (const p of [...PUBLIC_PAGES, ...APP]) assert.equal(effective(doc, p, 'X-Robots-Tag'), 'noindex, nofollow', p)
  })
})

for (const [name, load] of [['render (deploy)', () => rendered()], ['checked-in firebase.json', () => JSON.parse(readFileSync(join(WUI, 'firebase.json'), 'utf8'))]]) {
  describe(`Hosting Cache-Control: ${name}`, () => {
    let doc
    before(() => { doc = load() })

    it('every unhashed picture, icon and the manifest in src/public is fresh for an hour, then stale-while-revalidate', () => {
      /* the help pages (047 W14, /help-md), the blog copy (spec 111, /blog-md), the public calendar's data (HUM-10, /pub-cal), the public docs copy (owner HUM-10 e3ce4c34, /docs-public) and the static .html pages (049 /privacy, /terms) are text a deploy changes: they revalidate, below */
      const media = walk(PUBLIC).map((f) => '/' + relative(PUBLIC, f)).filter((p) => !p.endsWith('.js') && !p.endsWith('.html') && !p.startsWith('/help-md/') && !p.startsWith('/blog-md/') && !p.startsWith('/pub-cal/') && !p.startsWith('/docs-public/'))
      assert.ok(media.length >= 10, media.join(' '))
      for (const p of media) assert.equal(effective(doc, p), MEDIA, p)
    })

    it('the service worker, build.json and every page still revalidate on each load (a deploy is seen at once)', () => {
      for (const p of ['/sw.js', '/build.json', '/200.html', '/login', '/', '/lobby', '/help-md/index.md', '/help-md/pages.json', '/blog-md/index.json', '/blog-md/en/x.html', '/pub-cal/events.json', '/privacy.html', '/terms.html']) assert.equal(effective(doc, p), REVALIDATE, p)
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
