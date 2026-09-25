// Owner, 2026-09-25, prd v0.5.5: four "Failed to fetch" in the WUI
// diagnostics that the hub request log cannot match (every /v1/view read at
// those seconds answered 200). A dropped read is now retried once; a write
// never is, and a failure that stays names its request in the journal.
//
// Run: node tests/unit/fetch-retry.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { createSpoolClient } from '../../src/utils/spool-client.mjs'

const ok = (body) => ({
  ok: true,
  status: 200,
  headers: { get: (k) => (k.toLowerCase() === 'content-type' ? 'application/json' : null) },
  json: async () => body,
})
const netErr = () => new TypeError('Failed to fetch')

function counting(plan) {
  const calls = []
  const fn = async (url, init) => {
    calls.push({ url, method: (init && init.method) || 'GET' })
    const step = plan[Math.min(calls.length - 1, plan.length - 1)]
    if (step === 'fail') throw netErr()
    if (step === 'abort') throw Object.assign(new Error('aborted'), { name: 'AbortError' })
    return ok(step)
  }
  return { fn, calls }
}

describe('a dropped read is retried once, a write never', () => {
  it('GET that fails once then answers: one retry, the data comes back', async () => {
    const { fn, calls } = counting(['fail', { status: 'ok' }])
    const c = createSpoolClient({ base: 'http://hub.test', fetchFn: fn, mock: false })
    const out = await c.healthz()
    assert.deepEqual(out, { status: 'ok' })
    assert.equal(calls.length, 2)
    assert.equal(calls[0].url, calls[1].url)
  })

  it('GET that fails twice: the error reaches the caller after exactly one retry', async () => {
    const { fn, calls } = counting(['fail', 'fail'])
    const c = createSpoolClient({ base: 'http://hub.test', fetchFn: fn, mock: false })
    await assert.rejects(() => c.healthz(), /Failed to fetch/)
    assert.equal(calls.length, 2)
  })

  it('DELETE that fails: no retry (a write may have landed)', async () => {
    const { fn, calls } = counting(['fail', { ok: 1 }])
    const c = createSpoolClient({ base: 'http://hub.test', fetchFn: fn, mock: false })
    await assert.rejects(() => c.removeTenantUser('HUM-7'), /Failed to fetch/)
    assert.equal(calls.length, 1)
    assert.equal(calls[0].method, 'DELETE')
  })

  it('an abort is not retried', async () => {
    const { fn, calls } = counting(['abort', { status: 'ok' }])
    const c = createSpoolClient({ base: 'http://hub.test', fetchFn: fn, mock: false })
    await assert.rejects(() => c.healthz(), /aborted/)
    assert.equal(calls.length, 1)
  })

  it('a healthy GET is fetched once', async () => {
    const { fn, calls } = counting([{ status: 'ok' }])
    const c = createSpoolClient({ base: 'http://hub.test', fetchFn: fn, mock: false })
    await c.healthz()
    assert.equal(calls.length, 1)
  })
})
