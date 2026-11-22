// spec 149 (SPL-6225): Google Search Console's HTML-file proof that the
// owner holds the domain. NEVER REMOVE the file or its rewrite: Google
// re-checks it, and the domain loses its verified state without it.
//
// Search Console "does not follow redirects when looking for this file", and
// Hosting's cleanUrls 301s any .html file that exists at the asked path
// (/privacy.html -> /privacy). So the file sits in a subdirectory, and one
// exact rewrite answers /google7802cb3c38c5cbf8.html with it, a 200 with
// the owner's bytes.
import { describe, it, after } from 'node:test'
import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const scratchDirs = []
const scratch = (prefix) => { const d = mkdtempSync(join(tmpdir(), prefix)); scratchDirs.push(d); return d }
after(() => { for (const d of scratchDirs) rmSync(d, { recursive: true, force: true }) })
const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const RENDER = join(WUI, '..', 'csi-spl-orc/src/bash/scripts/render-wui-firebase-json.sh')

const ASKED = '/google7802cb3c38c5cbf8.html'
const SERVED = '/google-site-verification/google7802cb3c38c5cbf8.html'
// the owner's download, 53 bytes, no trailing newline
const CONTENT = 'google-site-verification: google7802cb3c38c5cbf8.html'
const SHA256 = '33787ba247e061bea952add31b66b26f111d47cad322d6a4a3f05a00f1668b3f'

function rendered(env) {
  const pub = scratch('gsv-bundle-')
  writeFileSync(join(pub, '200.html'), '<!doctype html><html><head></head><body><div id="__nuxt"></div></body></html>')
  const out = join(scratch('gsv-out-'), 'firebase.json')
  const r = spawnSync('bash', [RENDER], { env: { ...process.env, ENV: env, OUT: out, PUBLIC_DIR: pub }, encoding: 'utf8' })
  assert.equal(r.status, 0, r.stderr)
  return JSON.parse(readFileSync(out, 'utf8'))
}

/** The rewrite Hosting applies to `path`: the first whose source matches. */
function firstRewrite(doc, path) {
  return doc.hosting.rewrites.find((rw) => rw.source === path || rw.source === '**')
}

describe('Google site verification file (spec 149, SPL-6225)', () => {
  it('src/public holds the owner\'s file byte for byte', () => {
    const bytes = readFileSync(join(WUI, 'src/public', SERVED))
    assert.equal(bytes.toString('utf8'), CONTENT)
    assert.equal(createHash('sha256').update(bytes).digest('hex'), SHA256)
  })

  it('no file sits at the asked path, so cleanUrls has nothing to redirect', () => {
    assert.equal(existsSync(join(WUI, 'src/public', ASKED)), false)
  })

  for (const [name, load] of [['render dev', () => rendered('dev')], ['render prd', () => rendered('prd')], ['checked-in firebase.json', () => JSON.parse(readFileSync(join(WUI, 'firebase.json'), 'utf8'))]]) {
    it(`${name}: the asked path rewrites to the file, before the SPA catch-all`, () => {
      const rw = firstRewrite(load(), ASKED)
      assert.deepEqual(rw, { source: ASKED, destination: SERVED })
    })
  }

  // CONTROL: without the rewrite the asked path falls to the SPA shell
  it('control: a doc without the rewrite answers the SPA shell', () => {
    const doc = rendered('prd')
    doc.hosting.rewrites = doc.hosting.rewrites.filter((rw) => rw.source !== ASKED)
    assert.equal(firstRewrite(doc, ASKED).destination, '/200.html')
  })
})
