// SPL-4456 (SPL-4422 row 10): the session probe asks GET /session?signed_out=ok
// and the hub answers a signed-out visitor 200 {"signed_in":false}, not 401,
// so a signed-out page logs no red console line. The client reads that body
// as 'out', exactly as it reads a 401 (still answered to an older hub).
// Run: node --test tests/unit/auth-session-signed-out.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { createAuthClient, sessionProbeUrl } from '../../src/utils/auth-client.mjs'

function stub(status, body) {
  const calls = []
  const fn = async (url, opts) => {
    calls.push({ url, opts })
    return { ok: status >= 200 && status < 300, status, headers: { get: () => null }, json: async () => body }
  }
  return { fn, calls }
}

describe('session probe, signed out (SPL-4456)', () => {
  it('asks with ?signed_out=ok, the same address the head script parks', async () => {
    const s = stub(200, { signed_in: false })
    await createAuthClient({ fetchFn: s.fn, base: 'https://api.example.com' }).session()
    assert.equal(s.calls[0].url, 'https://api.example.com/api/v1/auth/session?signed_out=ok')
    assert.equal(sessionProbeUrl('https://api.example.com'), s.calls[0].url)
    assert.equal(sessionProbeUrl(''), '/api/v1/auth/session?signed_out=ok')
  })

  it('200 {"signed_in":false} is out, with no claims', async () => {
    const out = await createAuthClient({ fetchFn: stub(200, { signed_in: false }).fn }).session()
    assert.deepEqual(out, { state: 'out', claims: null })
  })

  it('the parked head-script answer maps the same way', async () => {
    const parked = Promise.resolve(await stub(200, { signed_in: false }).fn('x'))
    const out = await createAuthClient({ fetchFn: stub(503, {}).fn }).session(parked)
    assert.deepEqual(out, { state: 'out', claims: null })
  })

  it('401 is still out, claims are still in', async () => {
    assert.deepEqual(await createAuthClient({ fetchFn: stub(401, {}).fn }).session(), { state: 'out', claims: null })
    const claims = { v: 1, p: 'google', hum: 'HUM-1' }
    assert.deepEqual(await createAuthClient({ fetchFn: stub(200, claims).fn }).session(), { state: 'in', claims })
  })

  it('only the literal false signs out', async () => {
    for (const v of [true, 'false', 0, null]) {
      const claims = { hum: 'HUM-1', signed_in: v }
      assert.equal((await createAuthClient({ fetchFn: stub(200, claims).fn }).session()).state, 'in', String(v))
    }
  })
})
