// CLE-77803 + SPL-2770: an old tab, still on the previous deploy, asks the
// host for files of its own build: the app manifest
// (/_nuxt/builds/meta/<old-id>.json, /_nuxt/builds/latest.json) and its
// chunks (/_nuxt/<hash>.js). After a WUI deploy those files are gone, so the
// request misses the static layer and falls through to the SPA rewrite
// (** -> /200.html), which answers 200 with the index HTML.
// - The manifest: Nuxt parses HTML as its manifest and logs "Received
//   malformed app manifest" (prd human_events 2026-09-30).
// - A chunk: the module import fails as a MIME error, not a 404, and the tab
//   went white (owner saw it twice, 2026-10-20; measured on prd 2026-10-21:
//   /_nuxt/doesnotexist123.js -> 200 text/html).
// A 404 is the clean signal: Nuxt treats the build as outdated, Vite's
// preload fails, and chunk-reload.client.ts reloads the tab into the live
// build.
//
// Firebase Hosting serves an existing file before any rewrite; rewrites are
// then first-match-wins and terminal, and a rewrite whose destination file
// does not exist answers 404. So a /_nuxt/** rewrite placed BEFORE the SPA
// catch-all, pointing at a path nuxt generate never emits, turns every
// missing /_nuxt/ file into a 404 while the current build's files are still
// served.
//
// The DEPLOYED firebase.json is rendered from cnf by
// csi-spl-orc/src/bash/scripts/render-wui-firebase-json.sh at deploy time (it
// overwrites the checked-in csi-spl-wui/firebase.json). So the render output
// is the source of truth this test must guard; the checked-in file is kept in
// sync as the local `firebase serve` snapshot.
import { describe, it, after } from 'node:test'
import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const REPO = join(WUI, '..')
const RENDER = join(REPO, 'csi-spl-orc/src/bash/scripts/render-wui-firebase-json.sh')
const SPA = '/200.html'

const scratchDirs = []
const scratch = (prefix) => { const d = mkdtempSync(join(tmpdir(), prefix)); scratchDirs.push(d); return d }
after(() => { for (const d of scratchDirs) rmSync(d, { recursive: true, force: true }) })

/** Hosting glob -> RegExp: `**` and `*`. */
function globRe(glob) {
  let re = ''
  for (let i = 0; i < glob.length; i++) {
    if (glob.startsWith('**', i)) { re += '.*'; i += 1 } else if (glob[i] === '*') re += '[^/]*'
    else re += glob[i].replace(/[.+?^${}()|[\]\\]/g, '\\$&')
  }
  return new RegExp('^' + re + '$')
}

/** The bundle files that exist in this probe (the current build). */
const FILES = new Set(['/200.html', '/404.html', '/_nuxt/Bx9a1.js', '/_nuxt/entry.CFbJyYrE.css', '/_nuxt/builds/latest.json', '/_nuxt/builds/meta/b1.json'])

/** What Hosting answers for a path: [status, what]. A file first, then the first matching rewrite. */
function resolve(doc, path) {
  if (FILES.has(path)) return [200, path]
  const r = doc.hosting.rewrites.find((x) => globRe(x.source).test(path))
  if (!r) return [404, '/404.html']
  if (r.run) return [200, 'run']
  return FILES.has(r.destination) ? [200, r.destination] : [404, '/404.html']
}

function rendered() {
  const pub = scratch('fb-nuxt-404-bundle-')
  writeFileSync(join(pub, '200.html'), '<!doctype html><html><head></head><body><div id="__nuxt"></div></body></html>')
  const out = join(scratch('fb-nuxt-404-out-'), 'firebase.json')
  const r = spawnSync('bash', [RENDER], { env: { ...process.env, ENV: 'dev', OUT: out, PUBLIC_DIR: pub }, encoding: 'utf8' })
  assert.equal(r.status, 0, r.stderr)
  return JSON.parse(readFileSync(out, 'utf8'))
}

const DOCS = {
  'the deploy-time render output (the source of truth)': rendered,
  'the checked-in csi-spl-wui/firebase.json snapshot': () => JSON.parse(readFileSync(join(WUI, 'firebase.json'), 'utf8')),
}

for (const [label, load] of Object.entries(DOCS)) {
  describe(`firebase hosting, ${label}: a missing /_nuxt/ file 404s, never the SPA page`, () => {
    const doc = load()
    it('SPL-2770: a missing chunk (/_nuxt/<hash>.js) answers 404, not 200 index HTML', () => {
      assert.deepEqual(resolve(doc, '/_nuxt/doesnotexist123.js'), [404, '/404.html'])
      assert.deepEqual(resolve(doc, '/_nuxt/DtX0889G.js'), [404, '/404.html'])
      assert.deepEqual(resolve(doc, '/_nuxt/entry.old.css'), [404, '/404.html'])
    })
    it('CLE-77803: a stale build manifest answers 404', () => {
      assert.deepEqual(resolve(doc, '/_nuxt/builds/meta/old-id.json'), [404, '/404.html'])
    })
    it("the current build's files are still served", () => {
      for (const p of ['/_nuxt/Bx9a1.js', '/_nuxt/entry.CFbJyYrE.css', '/_nuxt/builds/latest.json', '/_nuxt/builds/meta/b1.json']) {
        assert.deepEqual(resolve(doc, p), [200, p])
      }
    })
    it('CONTROL: an app route still gets the SPA page; the catch-all stays last', () => {
      assert.deepEqual(resolve(doc, '/t/abc'), [200, SPA])
      assert.deepEqual(resolve(doc, '/_nuxtish/x'), [200, SPA])
      const last = doc.hosting.rewrites.at(-1)
      assert.equal(last.source, '**')
      assert.equal(last.destination, SPA)
    })
  })
}
