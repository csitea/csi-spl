// The diagnostics panel is granted by the HUB, to a named human, and to nobody
// by default (005 T035, 010 auth-v1 §3; hub side: internal/auth/config.go
// SPOOL_HUB_AUTH_DIAGNOSTICS_EMAILS + handler.go diagnosticsGrant).
//
// error-journal.test.mjs already executes the gate's own truth table. This
// suite runs the WHOLE WUI half of the decision against the body the hub
// actually sends — createAuthClient().session() → the claims → the gate — and
// then holds the two properties that are not a happy path:
//
//   1. nothing the browser controls can grant it, and
//   2. with the panel off there is no debug route left to reach.
//
// Run: node tests/unit/diagnostics-claim.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync, readdirSync, statSync } from 'node:fs'
import { dirname, join, relative } from 'node:path'
import { fileURLToPath } from 'node:url'

import { createAuthClient } from '../../src/utils/auth-client.mjs'
import { debugPanelVisibleFor, diagnosticsGranted } from '../../src/composables/debugAudience.mjs'

const __dirname = dirname(fileURLToPath(import.meta.url))
const SRC = join(__dirname, '../../src')

/** A hub answer, verbatim in shape: the fields GET /session sends today. */
function hubSession(extra = {}) {
  return {
    v: 1,
    p: 'google',
    sub: 'sub-123',
    email: 'ops@example.net',
    name: 'FirstName LastName',
    hum: 'HUM-1',
    iat: 1789996349,
    exp: 1790039549,
    preferred_locale: null,
    diagnostics_enabled: false,
    active_tenant: null,
    tenants: [],
    ...extra,
  }
}

function stub(status, body) {
  const calls = []
  const fn = async (url, opts) => {
    calls.push({ url, opts })
    return {
      ok: status >= 200 && status < 300,
      status,
      headers: { get: () => null },
      json: async () => body,
    }
  }
  return { fn, calls }
}

const client = (status, body) => createAuthClient({ fetchFn: stub(status, body).fn })

/**
 * The CODE of a source file: template, block and line comments removed. Every
 * control below reads this and not the raw text — debugAudience.mjs and
 * default.vue both DESCRIBE the browser sources they refuse to read, and a
 * control that cannot tell prose from code fails on its own documentation.
 */
function codeOf(src) {
  return src
    .replace(/<!--[\s\S]*?-->/g, ' ')    // template comments
    .replace(/\/\*[\s\S]*?\*\//g, ' ')   // block comments (incl. jsdoc)
    .replace(/(^|[^:])\/\/.*$/gm, '$1')  // line comments, keeping https://
}

/** Every file under src/, so a control cannot be dodged by adding one. */
function srcFiles(dir = SRC, out = []) {
  for (const e of readdirSync(dir)) {
    const p = join(dir, e)
    if (statSync(p).isDirectory()) srcFiles(p, out)
    else out.push(p)
  }
  return out
}

describe('the grant travels from the hub body to the gate', () => {
  it('a granted session opens the panel', async () => {
    const { state, claims } = await client(200, hubSession({ diagnostics_enabled: true })).session()
    assert.equal(state, 'in')
    // Nothing between the wire and the gate filters the claim out.
    assert.equal(claims.diagnostics_enabled, true)
    assert.equal(debugPanelVisibleFor(claims), true)
  })

  it('the same session without the grant does not', async () => {
    const { state, claims } = await client(200, hubSession()).session()
    assert.equal(state, 'in')
    assert.equal(debugPanelVisibleFor(claims), false)
  })

  it('a hub that sends no such key at all grants nobody', async () => {
    const body = hubSession()
    delete body.diagnostics_enabled
    const { claims } = await client(200, body).session()
    assert.equal(debugPanelVisibleFor(claims), false)
  })

  it('401 and an unreadable answer leave no claims to grant', async () => {
    for (const status of [401, 500, 503]) {
      const { claims } = await client(status, hubSession({ diagnostics_enabled: true })).session()
      assert.equal(claims, null, String(status))
      assert.equal(debugPanelVisibleFor(claims), false, String(status))
    }
  })

  // 015 native-auth-v1 §2: the login answer IS the claims the store adopts,
  // with no second probe, so the grant has to survive that path too.
  it('the native login body carries the same grant', async () => {
    const granted = await client(200, { ...hubSession({ diagnostics_enabled: true }), p: 'password', redirect: '/' })
      .login({ email: 'ops@example.net', password: 'x'.repeat(12) })
    assert.equal(granted.ok, true)
    assert.equal(debugPanelVisibleFor(granted.data), true)

    const plain = await client(200, { ...hubSession(), p: 'password', redirect: '/' })
      .login({ email: 'someone@example.net', password: 'x'.repeat(12) })
    assert.equal(debugPanelVisibleFor(plain.data), false)
  })

  // A hub that has not shipped the field, or a proxy that stringifies JSON,
  // must not read as "everyone is granted".
  it('only the literal boolean true admits', () => {
    for (const v of ['true', 'True', 1, '1', 'yes', {}, [], [true]]) {
      assert.equal(diagnosticsGranted({ diagnostics_enabled: v }), false, JSON.stringify(v))
    }
    assert.equal(diagnosticsGranted({ diagnostics_enabled: true }), true)
  })
})

describe('CONTROL: the claim is not settable from the browser', () => {
  // The gate's ONLY input is the session claims. Were any of these consulted
  // anywhere on the path, a visitor could grant themselves the panel by
  // typing a URL or writing one key — which is exactly what the hub-side
  // control (a validly signed cookie naming the claim) also refuses.
  const BROWSER_SOURCES = [
    'localStorage', 'sessionStorage', 'document.cookie', 'location.search',
    'URLSearchParams', 'useRoute().query', 'import.meta.env', 'process.env',
  ]

  for (const rel of ['composables/debugAudience.mjs', 'composables/useErrorJournal.ts']) {
    it(`${rel} reads none of them`, () => {
      const code = codeOf(readFileSync(join(SRC, rel), 'utf8'))
      for (const s of BROWSER_SOURCES) {
        assert.equal(code.includes(s), false, `${rel} reads ${s}`)
      }
    })
  }

  it('nothing in src/ writes the claim — it is only ever read', () => {
    // A `diagnostics_enabled =` or a `diagnostics_enabled:` OUTSIDE a type
    // declaration would be the WUI minting its own grant. The claims arrive
    // from the hub and are never assembled here.
    const offenders = []
    for (const f of srcFiles()) {
      if (!/\.(mjs|ts|vue)$/.test(f)) continue
      for (const line of codeOf(readFileSync(f, 'utf8')).split('\n')) {
        const code = line.trim()
        if (!code.includes('diagnostics_enabled')) continue
        if (/^diagnostics_enabled\?:\s*boolean$/.test(code)) continue      // the type
        if (/^return user\.diagnostics_enabled === true$/.test(code)) continue // the gate
        offenders.push(`${relative(SRC, f)}: ${code}`)
      }
    }
    assert.deepEqual(offenders, [])
  })
})

describe('CONTROL: with the panel off there is nothing else to reach', () => {
  it('there is no debug route', () => {
    const pages = join(SRC, 'pages')
    const routes = srcFiles(pages).map((f) => relative(pages, f))
    for (const r of routes) {
      assert.equal(/debug|diagnost/i.test(r), false, `page route ${r}`)
    }
    assert.ok(routes.length > 0, 'no pages found — this control would pass vacuously')
  })

  it('the panel is mounted exactly once, in the layout', () => {
    const mounts = srcFiles()
      .filter((f) => f.endsWith('.vue') && !f.endsWith('DebugPanel.vue'))
      .filter((f) => /<DebugPanel\b/.test(readFileSync(f, 'utf8')))
      .map((f) => relative(SRC, f))
    assert.deepEqual(mounts, ['layouts/default.vue'])
  })

  it('the panel itself is behind v-if, never v-show or CSS', () => {
    const src = readFileSync(join(SRC, 'components/common/DebugPanel.vue'), 'utf8')
    assert.match(src, /v-if="visible"/)
    assert.equal(/v-show="visible"/.test(src), false)
  })

  it('the journal composable gates on the session, not on mounting alone', () => {
    const src = readFileSync(join(SRC, 'composables/useErrorJournal.ts'), 'utf8')
    assert.match(src, /debugPanelVisibleFor/)
    assert.match(src, /session\.state === 'in'/)
  })
})
