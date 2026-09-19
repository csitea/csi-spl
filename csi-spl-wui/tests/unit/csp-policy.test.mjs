// The WUI has TWO copies of its CSP and they must not drift (pattern from the
// donor WUI's csp-policy test):
//   * csi-spl-orc/src/bash/scripts/render-wui-firebase-json.sh — authoritative
//     in every deployed env (static files on Firebase Hosting, no Nitro).
//   * csi-spl-wui/nuxt.config.ts CSP_PROD — what `nuxt preview` serves.
// Every directive must match; connect-src differs only in WHERE the hub
// origin comes from (cnf fqdn vs NUXT_PUBLIC_API_BASE), so it is compared by
// scheme set.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const REPO = join(WUI, '..')

/** @returns {Map<string, string>} directive -> value */
function parse(policy) {
  const out = new Map()
  for (const part of policy.split(';').map((s) => s.trim()).filter(Boolean)) {
    const [name, ...rest] = part.split(/\s+/)
    out.set(name, rest.join(' '))
  }
  return out
}

function nuxtProdPolicy() {
  const src = readFileSync(join(WUI, 'nuxt.config.ts'), 'utf8')
  const block = /const CSP_PROD = \[([\s\S]*?)\]\.join/.exec(src)
  assert.ok(block, 'CSP_PROD literal in nuxt.config.ts')
  const items = [...block[1].matchAll(/["`]([^"`]+)["`]/g)].map((m) => m[1])
  return parse(items.join('; '))
}

function hostingPolicy() {
  const src = readFileSync(join(REPO, 'csi-spl-orc/src/bash/scripts/render-wui-firebase-json.sh'), 'utf8')
  const line = /"key": "Content-Security-Policy",\s*"value": ([^\n]+)/.exec(src)
  assert.ok(line, 'CSP value in render-wui-firebase-json.sh')
  // `"a" + fqdn + "b"` -> `a*.example.testb`: the fqdn is a cnf value.
  const policy = line[1].replace(/"\s*\+\s*fqdn\s*\+\s*"/g, 'example.test').replace(/^"|",?\s*$/g, '')
  return parse(policy)
}

describe('CSP: nuxt.config CSP_PROD matches the Hosting render script', () => {
  it('same directive set', () => {
    assert.deepEqual([...nuxtProdPolicy().keys()].sort(), [...hostingPolicy().keys()].sort())
  })

  it('same value for every directive except connect-src', () => {
    const a = nuxtProdPolicy()
    const b = hostingPolicy()
    for (const [k, v] of b) {
      if (k === 'connect-src') continue
      assert.equal(a.get(k), v, k)
    }
  })

  it("connect-src: 'self' plus the hub host over http(s) and ws(s)", () => {
    const b = hostingPolicy().get('connect-src').split(' ')
    assert.deepEqual(b.map((s) => s.split(':')[0]), ["'self'", 'https', 'wss'])
    const a = nuxtProdPolicy().get('connect-src')
    assert.ok(a.startsWith("'self'"), a)
    assert.ok(a.includes('${HUB_SOURCES}'), 'hub origin comes from NUXT_PUBLIC_API_BASE')
  })

  it('never an https: wildcard (anti-exfiltration)', () => {
    for (const p of [nuxtProdPolicy(), hostingPolicy()]) {
      for (const [k, v] of p) assert.equal(/(^|\s)https?:(\s|$)/.test(v), false, k)
    }
  })
})
