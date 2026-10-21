// spec 044 FR-OS-003, T020 (SPL-1012): strangers build their own hub on their
// OWN domain. Every variable the web UI build and its container read is listed
// in the repository's example.env.yaml, and the product sources carry no
// estate value (cloud project id, region) a stranger would inherit.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs'
import { join, dirname, relative } from 'node:path'
import { fileURLToPath } from 'node:url'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const ROOT = join(WUI, '..')
const EXAMPLE = join(ROOT, 'example.env.yaml')
const read = (p) => readFileSync(join(WUI, p), 'utf8')

/** the keys a reader takes: NUXT_PUBLIC_* from nuxt.config.ts, SPOOL_* from wui-config.sh */
export function wuiEnvKeys(nuxtConfig, configSh) {
  const keys = new Set()
  for (const m of nuxtConfig.matchAll(/process\.env\.(NUXT_PUBLIC_[A-Z0-9_]+)/g)) keys.add(m[1])
  for (const m of configSh.matchAll(/\$\{(SPOOL_[A-Z0-9_]+)/g)) keys.add(m[1])
  return keys
}

/** the keys example.env.yaml lists: two spaces, KEY: */
export function listedKeys(example) {
  return new Set([...example.matchAll(/^ {2}([A-Z][A-Z0-9_]*):/gm)].map((m) => m[1]))
}

// a cloud project id or region of the hosted estate
const ESTATE = /\bcsi-spl-(dev|prd|all)\b|\beurope-north1\b/

function sources(dir, out = []) {
  for (const name of readdirSync(dir)) {
    const p = join(dir, name)
    if (statSync(p).isDirectory()) sources(p, out)
    else if (/\.(vue|ts|mjs|js|html|md|json)$/.test(name)) out.push(p)
  }
  return out
}

describe('example.env.yaml (spec 044 T020)', { skip: !existsSync(join(ROOT, 'csi-spl-api')) && 'no repository root in this checkout' }, () => {
  it('exists at the repository root', () => {
    assert.ok(existsSync(EXAMPLE), 'the repository root has no example.env.yaml')
  })

  it('lists every variable the web UI build and container read', () => {
    const keys = wuiEnvKeys(read('nuxt.config.ts'), read('src/docker/wui-config.sh'))
    assert.ok(keys.size >= 20, `read only ${keys.size} web UI env keys: the scan lost its readers`)
    const listed = listedKeys(readFileSync(EXAMPLE, 'utf8'))
    const missing = [...keys].filter((k) => !listed.has(k)).sort()
    assert.deepEqual(missing, [], `example.env.yaml lacks ${missing.join(', ')}`)
    // CONTROL: a key the readers take but the file does not name reads as missing
    assert.equal(listedKeys('  NUXT_PUBLIC_API_BASE: ""\n').has('NUXT_PUBLIC_TENANT'), false)
  })

  it('names privacy.html as a per-deployment edit, and the page marks its operator text', () => {
    assert.match(readFileSync(EXAMPLE, 'utf8'), /csi-spl-wui\/src\/public\/privacy\.html/)
    assert.match(read('src/public/privacy.html'), /<!-- The hosted operator's own text[^]*?-->\s*<h2>4\. Where and how long<\/h2>/)
  })

  it('no product source but the operator text in privacy.html names a project id or region', () => {
    const hits = sources(join(WUI, 'src'))
      .filter((p) => !p.endsWith(join('public', 'privacy.html')))
      .filter((p) => ESTATE.test(readFileSync(p, 'utf8')))
      .map((p) => relative(WUI, p))
    assert.deepEqual(hits, [])
    // CONTROL: the pattern catches a mock project id
    assert.ok(ESTATE.test("mockPart('gcp', 'csi-spl-prd', 'cloud_run')"))
  })
})
