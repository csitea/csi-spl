import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  authErrorMessage,
  createAuthClient,
  providerLabel,
  safeRedirect,
  startHref,
} from '../../utils/auth-client.mjs'

function stub(status, body, { throws = false, badJson = false } = {}) {
  const calls = []
  const fn = async (url, opts) => {
    calls.push({ url, opts })
    if (throws) throw new Error('network')
    return {
      ok: status >= 200 && status < 300,
      status,
      json: async () => {
        if (badJson) throw new Error('bad json')
        return body
      },
    }
  }
  return { fn, calls }
}

describe('auth-v1 helpers (spec 010)', () => {
  it('maps every §2 code and falls back for unknown ones', () => {
    for (const c of ['cancelled', 'invalid_state', 'exchange_failed', 'email_unverified', 'not_allowed', 'unavailable']) {
      assert.notEqual(authErrorMessage(c), 'Sign-in failed.', c)
    }
    assert.equal(authErrorMessage('weird'), 'Sign-in failed.')
    assert.equal(authErrorMessage(''), '')
  })

  it('labels providers', () => {
    assert.equal(providerLabel('google'), 'Continue with Google')
    assert.equal(providerLabel('facebook'), 'Continue with Facebook')
  })

  it('keeps redirects same-site', () => {
    assert.equal(safeRedirect('/t/abc?x=1'), '/t/abc?x=1')
    for (const bad of ['https://evil.example', '//evil.example', '/\\evil', 'javascript:alert(1)', '', '/login?x']) {
      assert.equal(safeRedirect(bad), '/', bad)
    }
  })

  it('builds a plain start link with redirect and an optional DNS-label tenant', () => {
    assert.equal(startHref('google', '/t/abc', 't1'), '/api/v1/auth/google/start?redirect=%2Ft%2Fabc&tenant=t1')
    assert.equal(startHref('facebook', 'https://x', 'Not_A_Label'), '/api/v1/auth/facebook/start?redirect=%2F')
  })
})

describe('auth client', () => {
  it('providers: list in order, [] on off / error / network', async () => {
    const ok = stub(200, { providers: ['google', 'facebook'] })
    assert.deepEqual(await createAuthClient({ fetchFn: ok.fn }).providers(), ['google', 'facebook'])
    assert.equal(ok.calls[0].url, '/api/v1/auth/providers')
    assert.equal(ok.calls[0].opts.credentials, 'same-origin')
    assert.deepEqual(await createAuthClient({ fetchFn: stub(200, { providers: [] }).fn }).providers(), [])
    assert.deepEqual(await createAuthClient({ fetchFn: stub(404, {}).fn }).providers(), [])
    assert.deepEqual(await createAuthClient({ fetchFn: stub(0, {}, { throws: true }).fn }).providers(), [])
  })

  it('session: 200 in, 401 out, everything else unknown', async () => {
    const claims = { v: 1, p: 'google', hum: 'HUM-1' }
    assert.deepEqual(await createAuthClient({ fetchFn: stub(200, claims).fn }).session(), { state: 'in', claims })
    assert.equal((await createAuthClient({ fetchFn: stub(401, {}).fn }).session()).state, 'out')
    assert.equal((await createAuthClient({ fetchFn: stub(503, {}).fn }).session()).state, 'unknown')
    assert.equal((await createAuthClient({ fetchFn: stub(0, {}, { throws: true }).fn }).session()).state, 'unknown')
    assert.equal((await createAuthClient({ fetchFn: stub(200, {}, { badJson: true }).fn }).session()).state, 'unknown')
  })

  it('logout POSTs and accepts 204', async () => {
    const s = stub(204, null)
    assert.equal(await createAuthClient({ fetchFn: s.fn }).logout(), true)
    assert.equal(s.calls[0].opts.method, 'POST')
    assert.equal(s.calls[0].url, '/api/v1/auth/logout')
  })
})

describe('Hosting rewrite (spec 010 T016)', () => {
  it('/api/v1/auth/** goes to Cloud Run before the SPA fallback, which stays last', () => {
    const here = dirname(fileURLToPath(import.meta.url))
    const fb = JSON.parse(readFileSync(join(here, '../../firebase.json'), 'utf8'))
    const rw = fb.hosting.rewrites
    const i = rw.findIndex((r) => r.source === '/api/v1/auth/**')
    assert.ok(i >= 0, 'auth rewrite present')
    assert.ok(rw[i].run && rw[i].run.serviceId, 'rewrite targets Cloud Run')
    assert.equal(rw[rw.length - 1].source, '**')
    assert.ok(i < rw.length - 1)
  })
})
