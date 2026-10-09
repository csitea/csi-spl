// specs/077 T020: GET /v1/demo read for the sign-in page's demo intro. A 200
// with a workspace is "on"; a 404 (flag off), the SPA fallback's HTML, a
// network error or a body without a valid workspace are all "off".
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { DEMO_PATH, DEMO_PROVIDERS, demoProviders, loadDemo, parseDemo } from '../../src/utils/demo-info.mjs'

const reply = (status, body) => async () => ({ status, json: async () => (typeof body === 'string' ? JSON.parse(body) : body) })

describe('parseDemo', () => {
  it('reads the workspace and max_live of the hub answer', () => {
    assert.deepEqual(parseDemo({ workspace: 'demo', max_live: 9, max_stay: '3h' }), { workspace: 'demo', maxLive: 9 })
  })
  it('drops a limit that is not a positive integer (never states a made-up one)', () => {
    for (const v of [0, -1, 2.5, '9', null, undefined]) assert.equal(parseDemo({ workspace: 'demo', max_live: v }).maxLive, 0, String(v))
  })
  it('refuses a body without a DNS-label workspace', () => {
    for (const b of [null, {}, { workspace: '' }, { workspace: 'Demo' }, { workspace: 'a/b' }, { workspace: '-x' }]) assert.equal(parseDemo(b), null, JSON.stringify(b))
  })
})

describe('loadDemo', () => {
  it('asks <base>/v1/demo without cookies', async () => {
    let seen
    const out = await loadDemo('https://api.example.com/', async (url, opts) => { seen = { url, opts }; return reply(200, { workspace: 'demo', max_live: 9 })() })
    assert.equal(seen.url, `https://api.example.com${DEMO_PATH}`)
    assert.equal(seen.opts.credentials, 'omit')
    assert.ok(seen.opts.signal instanceof AbortSignal, 'a hung connection times out (refactor r4-03)')
    assert.deepEqual(out, { workspace: 'demo', maxLive: 9 })
  })
  it('is null for a 404 (flag off), HTML, or a network error', async () => {
    assert.equal(await loadDemo('', reply(404, { error: 'not_found' })), null)
    assert.equal(await loadDemo('', reply(200, '<!doctype html>')), null)
    assert.equal(await loadDemo('', async () => { throw new TypeError('offline') }), null)
  })
})

describe('demoProviders', () => {
  it('keeps the registry order and only the sign-ins the demo admits', () => {
    assert.deepEqual(DEMO_PROVIDERS, ['google', 'facebook', 'linkedin'])
    assert.deepEqual(demoProviders(['microsoft', 'facebook', 'google', 'linkedin', 'xai']), ['facebook', 'google', 'linkedin'])
    assert.deepEqual(demoProviders(undefined), [])
  })
})
