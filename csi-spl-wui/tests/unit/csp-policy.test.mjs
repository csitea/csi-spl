// The WUI's Content-Security-Policy (spec 017 FR-SEC-005, T013/T014).
//
// The AUTHORITATIVE policy is the Firebase Hosting header written by
// csi-spl-orc/src/bash/scripts/render-wui-firebase-json.sh — the WUI is static
// files, so nuxt.config.ts routeRules never run in a deployed env. That script
// hashes the inline <script>/<style> blocks of the GENERATED bundle, so this
// suite renders it against a fixture bundle and reads the header it emits,
// rather than grepping the source.
//
// nuxt.config.ts CSP_PROD is what `nuxt preview` (lde) serves. It keeps
// 'unsafe-inline' — there is no render step to hash there — and otherwise
// matches the Hosting policy directive for directive.
import { describe, it, before } from 'node:test'
import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const REPO = join(WUI, '..')
const RENDER = join(REPO, 'csi-spl-orc/src/bash/scripts/render-wui-firebase-json.sh')

const INLINE_JS = 'window.__NUXT__={};window.__NUXT__.config={public:{}}'
const INLINE_CSS = '.layout[data-v-1]{max-width:100%}'
const sha = (s) => `'sha256-${createHash('sha256').update(s, 'utf8').digest('base64')}'`

/** @returns {Map<string, string>} directive -> value */
function parse(policy) {
  const out = new Map()
  for (const part of policy.split(';').map((s) => s.trim()).filter(Boolean)) {
    const [name, ...rest] = part.split(/\s+/)
    out.set(name, rest.join(' '))
  }
  return out
}

/** A generated-bundle look-alike: .output/public with 200.html (+ extra files). */
function bundle(page200, extra = {}) {
  const dir = mkdtempSync(join(tmpdir(), 'csp-bundle-'))
  writeFileSync(join(dir, '200.html'), page200)
  for (const [rel, body] of Object.entries(extra)) {
    mkdirSync(dirname(join(dir, rel)), { recursive: true })
    writeFileSync(join(dir, rel), body)
  }
  return dir
}

function render(env, publicDir) {
  const out = join(mkdtempSync(join(tmpdir(), 'csp-out-')), 'firebase.json')
  const r = spawnSync('bash', [RENDER], { env: { ...process.env, ENV: env, OUT: out, PUBLIC_DIR: publicDir }, encoding: 'utf8' })
  return { status: r.status, stderr: r.stderr, out }
}

function hostingPolicy(env, publicDir) {
  const r = render(env, publicDir)
  assert.equal(r.status, 0, r.stderr)
  const doc = JSON.parse(readFileSync(r.out, 'utf8'))
  const h = doc.hosting.headers.find((b) => b.source === '**').headers.find((x) => x.key === 'Content-Security-Policy')
  return parse(h.value)
}

function nuxtProdPolicy() {
  const src = readFileSync(join(WUI, 'nuxt.config.ts'), 'utf8')
  const block = /const CSP_PROD = \[([\s\S]*?)\]\.join/.exec(src)
  assert.ok(block, 'CSP_PROD literal in nuxt.config.ts')
  const items = [...block[1].matchAll(/["`]([^"`]+)["`]/g)].map((m) => m[1])
  return parse(items.join('; '))
}

const cnf = (env) => JSON.parse(readFileSync(join(REPO, `csi-spl-cnf/csi-spl/${env}.env.json`), 'utf8')).env

const PAGE = [
  '<!DOCTYPE html><html><head>',
  `<style>${INLINE_CSS}</style>`,
  '<link rel="stylesheet" href="/_nuxt/entry.css">',
  '<script type="module" src="/_nuxt/entry.js" crossorigin></script>',
  '<script id="unhead:payload" type="application/json">{"title":"Spool"}</script>',
  `<script>${INLINE_JS}</script>`,
  '<script type="application/json" data-nuxt-data="nuxt-app">[{}]</script>',
  '</head><body><div id="__nuxt"></div></body></html>',
].join('')

for (const env of ['dev', 'prd']) {
  describe(`CSP (${env}): Hosting header rendered from the bundle`, () => {
    let p
    before(() => {
      p = hostingPolicy(env, bundle(PAGE, { 'login/index.html': PAGE }))
    })

    it("script-src is 'self' plus the hash of the one executable inline script", () => {
      assert.equal(p.get('script-src'), `'self' ${sha(INLINE_JS)}`)
    })

    it("style-src is 'self' plus the hash of the inline <style> block", () => {
      assert.equal(p.get('style-src'), `'self' ${sha(INLINE_CSS)}`)
    })

    it("no 'unsafe-inline' / 'unsafe-eval' anywhere", () => {
      for (const [k, v] of p) assert.equal(/'unsafe-(inline|eval|hashes)'/.test(v), false, `${k}: ${v}`)
    })

    it('the locked-down directives', () => {
      assert.equal(p.get('default-src'), "'self'")
      assert.equal(p.get('frame-ancestors'), "'none'")
      assert.equal(p.get('base-uri'), "'self'")
      assert.equal(p.get('object-src'), "'none'")
      assert.equal(p.get('form-action'), "'self'")
    })

    it("connect-src: 'self' plus the cnf hub hosts, each over https and wss, and nothing else", () => {
      const e = cnf(env)
      const [self, ...rest] = p.get('connect-src').split(' ')
      assert.equal(self, "'self'")
      assert.equal(rest.length % 2, 0, rest.join(' '))
      const hosts = []
      for (let i = 0; i < rest.length; i += 2) {
        const [a, b] = [rest[i], rest[i + 1]]
        assert.match(a, /^https:\/\/[^/\s]+$/)
        assert.equal(b, a.replace(/^https:/, 'wss:'))
        hosts.push(a.slice('https://'.length))
      }
      const base = e.dns.BASE_DOMAIN
      for (const h of hosts) assert.ok(h === base || h.endsWith(`.${base}`), `${h} is outside ${base}`)
      // the api host of this env (<label>.<BASE_DOMAIN>) and the tenant host(s)
      const s = e.steps ?? {}
      const labels = [...(s['031-gcp-hub-ingress']?.extra_host_labels ?? [])]
      if (s['032-gcp-cloud-run-domain-mapping']?.api_host_label) labels.push(s['032-gcp-cloud-run-domain-mapping'].api_host_label)
      for (const l of labels) assert.ok(hosts.includes(`${l}.${base}`), `api host ${l}.${base}`)
      const tenants = e.dns.mapped_tenants
      const tenantHosts = tenants?.length ? tenants.map((t) => `${t}.${e.dns.fqdn}`) : [`*.${e.dns.fqdn}`]
      for (const t of tenantHosts) assert.ok(hosts.includes(t), `tenant host ${t}`)
    })

    it('never a bare scheme (anti-exfiltration)', () => {
      for (const [k, v] of p) {
        for (const tok of v.split(' ')) {
          assert.equal(/^(\*|https?:|wss?:|blob:)$/.test(tok), false, `${k}: ${tok}`)
          if (tok === 'data:') assert.ok(['img-src', 'font-src'].includes(k), `${k}: data:`)
        }
      }
    })
  })
}

describe('CSP: the render refuses what a hash cannot allow (CONTROLS)', () => {
  it('no generated bundle -> refuses, never falls back to unsafe-inline', () => {
    const r = render('dev', mkdtempSync(join(tmpdir(), 'csp-empty-')))
    assert.notEqual(r.status, 0)
    assert.match(r.stderr, /nuxt generate/)
  })

  it('an inline event handler -> refuses', () => {
    const r = render('dev', bundle(PAGE.replace('<div id="__nuxt">', '<div id="__nuxt" onclick="x()">')))
    assert.notEqual(r.status, 0)
    assert.match(r.stderr, /onclick=/)
  })

  it('a style="" attribute -> refuses', () => {
    const r = render('dev', bundle(PAGE.replace('<div id="__nuxt">', '<div id="__nuxt" style="color:red">')))
    assert.notEqual(r.status, 0)
    assert.match(r.stderr, /style=/)
  })

  it('a changed inline script changes the hash (it is taken from the build, not written down)', () => {
    const a = hostingPolicy('dev', bundle(PAGE)).get('script-src')
    const b = hostingPolicy('dev', bundle(PAGE.replace(INLINE_JS, `${INLINE_JS};1`))).get('script-src')
    assert.notEqual(a, b)
  })
})

describe('CSP: nuxt.config CSP_PROD (nuxt preview) matches the Hosting policy', () => {
  it('same directive set', () => {
    const h = hostingPolicy('dev', bundle(PAGE))
    assert.deepEqual([...nuxtProdPolicy().keys()].sort(), [...h.keys()].sort())
  })

  it('same value for every directive except the hashed ones and connect-src', () => {
    const a = nuxtProdPolicy()
    for (const [k, v] of hostingPolicy('dev', bundle(PAGE))) {
      if (['script-src', 'style-src', 'connect-src'].includes(k)) continue
      assert.equal(a.get(k), v, k)
    }
  })

  it("preview: 'self' 'unsafe-inline' for script/style (no render step to hash), hub origin from NUXT_PUBLIC_API_BASE", () => {
    const a = nuxtProdPolicy()
    assert.equal(a.get('script-src'), "'self' 'unsafe-inline'")
    assert.equal(a.get('style-src'), "'self' 'unsafe-inline'")
    assert.ok(a.get('connect-src').startsWith("'self'"))
    assert.ok(a.get('connect-src').includes('${HUB_SOURCES}'))
  })
})
