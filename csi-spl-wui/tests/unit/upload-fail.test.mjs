// SPL-2285 (owner HUM-10, t1 f1ccedf9, 2026-10-17): an upload that cannot
// reach the hub failed silently, so a picture was tried 10 times. These hold
// the three failure shapes (socket down, no connection or no answer, a 4xx /
// 5xx answer) to a named rejection the composer turns into a line + Retry,
// and hold a working upload to exactly what it did before.
// CONTROL: on the pre-fix tree the socket-down, 503 and stall cases are red
// (no 'hub_down' token, no `upload` flag, no stall abort).
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'

import { hubDownError, linkDown, linkUp, mockUploadFetch, postWithStall, uploadStallMs, UPLOAD_LINK_WAIT_MS } from '../../src/utils/upload-fail.mjs'
import { uploadWithFreshToken } from '../../src/utils/upload-retry.mjs'
import { sendFailureKey, sendFailureParams } from '../../src/utils/send-failure.mjs'
import { createSpoolClient } from '../../src/utils/spool-client.mjs'

const BASE = 'http://t1.localhost:58080'
const isHubDown = (e) => e && e.token === 'hub_down' && e.status === 0

/** A live composable whose socket is in `state` (a function, so it can change). */
function fakeLive(state, token = 't-ok') {
  const asked = []
  return {
    asked,
    state: { get value() { return state() } },
    ensure() {},
    async freshUploadToken(force = false) { asked.push(force); return token },
  }
}

function okApi() {
  const calls = []
  return { calls, async uploadFile(file, token) { calls.push(token); return { file_id: 'f', sha256: 's', bytes: 1 } } }
}

describe('upload: socket down (SPL-2285)', () => {
  it('reads only connecting / reconnecting as down', () => {
    for (const s of ['connecting', 'reconnecting']) assert.equal(linkDown(fakeLive(() => s)), true, s)
    for (const s of ['open', 'mock', 'idle', 'closed', 'signed_out', '']) assert.equal(linkDown(fakeLive(() => s)), false, s)
    assert.equal(linkDown({}), false)
  })

  it('a socket still down after the wait is hub_down', async () => {
    await assert.rejects(linkUp(fakeLive(() => 'reconnecting'), 50, 10), isHubDown)
  })

  it('a socket that comes up inside the wait goes on', async () => {
    const t0 = Date.now()
    await linkUp(fakeLive(() => (Date.now() - t0 > 40 ? 'open' : 'reconnecting')), 1000, 10)
  })

  it('the default wait is a few seconds', () => {
    assert.ok(UPLOAD_LINK_WAIT_MS > 0 && UPLOAD_LINK_WAIT_MS <= 5000, String(UPLOAD_LINK_WAIT_MS))
  })

  it('socket down: the upload says hub_down within a few seconds and never POSTs', async () => {
    const api = okApi()
    const live = fakeLive(() => 'reconnecting')
    const t0 = Date.now()
    await assert.rejects(uploadWithFreshToken(api, live, 'file'), isHubDown)
    assert.ok(Date.now() - t0 < UPLOAD_LINK_WAIT_MS + 1000, `took ${Date.now() - t0} ms`)
    assert.deepEqual(api.calls, [])
  })

  it('an open socket uploads at once, as before', async () => {
    const api = okApi()
    const live = fakeLive(() => 'open')
    const t0 = Date.now()
    const out = await uploadWithFreshToken(api, live, 'file')
    assert.equal(out.file_id, 'f')
    assert.deepEqual(api.calls, ['t-ok'])
    assert.deepEqual(live.asked, [false])
    assert.ok(Date.now() - t0 < 100)
  })
})

describe('upload: the POST (SPL-2285)', () => {
  it('a refused connection is hub_down', async () => {
    await assert.rejects(postWithStall(mockUploadFetch('down'), BASE + '/v1/files', {}, 1000), isHubDown)
  })

  it('no answer within the stall limit is aborted as hub_down', async () => {
    const t0 = Date.now()
    await assert.rejects(postWithStall(mockUploadFetch('hang'), BASE + '/v1/files', {}, 30), isHubDown)
    assert.ok(Date.now() - t0 < 1000)
  })

  it('the stall limit grows with the bytes: a 916 KB picture gets ~24 s', () => {
    assert.equal(uploadStallMs(0), 15000)
    assert.equal(uploadStallMs(916 * 1024), 15000 + Math.ceil((916 * 1024) / 100))
    assert.equal(uploadStallMs(Number.NaN), 15000)
  })

  it('uploadFile: 503 from the hub is an upload error naming status and token', async () => {
    const fn = async () => ({ ok: false, status: 503, json: async () => ({ error: 'unavailable' }) })
    const c = createSpoolClient({ base: BASE, fetchFn: fn, mock: false })
    await assert.rejects(c.uploadFile(new Blob([new Uint8Array([1])]), 'tok'), (e) => e.status === 503 && e.token === 'unavailable' && e.upload === true)
  })

  it('uploadFile: a transport failure is hub_down', async () => {
    const fn = async () => { throw new TypeError('Failed to fetch') }
    const c = createSpoolClient({ base: BASE, fetchFn: fn, mock: false })
    await assert.rejects(c.uploadFile(new Blob([new Uint8Array([1])]), 'tok'), isHubDown)
  })

  it('uploadFile: a working upload is unchanged, and carries an abort signal', async () => {
    const calls = []
    const fn = async (url, opts) => { calls.push({ url, opts }); return { ok: true, status: 201, json: async () => ({ file_id: 'f1', sha256: 'f1', bytes: 3 }) } }
    const c = createSpoolClient({ base: BASE, fetchFn: fn, mock: false })
    const up = await c.uploadFile(new Blob([new Uint8Array([1, 2, 3])]), 'up-tok')
    assert.deepEqual(up, { file_id: 'f1', sha256: 'f1', bytes: 3 })
    assert.equal(calls.length, 1)
    assert.equal(calls[0].opts.headers.authorization, 'Bearer up-tok')
    assert.ok(calls[0].opts.signal instanceof AbortSignal)
  })

  it('the mock hook: down / 503 / hang stand in for the hub; anything else keeps the mock', async () => {
    await assert.rejects(mockUploadFetch('down')(), TypeError)
    assert.equal((await mockUploadFetch('503')()).status, 503)
    assert.equal(mockUploadFetch(null), null)
    assert.equal(mockUploadFetch('x'), null)
  })
})

describe('upload: what the composer says (SPL-2285)', () => {
  const en = JSON.parse(readFileSync(new URL('../../i18n/locales/en.json', import.meta.url), 'utf8')).composer

  it('hub_down names the connection to the hub', () => {
    assert.equal(sendFailureKey(hubDownError()), 'composer.send_failed_hub_down')
    assert.match(en.send_failed_hub_down, /connection to the hub is down/)
  })

  it('a 503 upload names its status and token', () => {
    const e = Object.assign(new Error('spool 503 unavailable'), { status: 503, token: 'unavailable', upload: true })
    assert.equal(sendFailureKey(e), 'composer.send_failed_upload')
    assert.deepEqual(sendFailureParams(e), { agent: '', status: '503', error: 'unavailable' })
    assert.match(en.send_failed_upload, /\{status\}/)
    assert.match(en.send_failed_upload, /\{error\}/)
  })

  it('every other failure keeps its line', () => {
    assert.equal(sendFailureKey({ token: 'session_expired', status: 401 }), 'composer.send_failed_session_expired')
    assert.equal(sendFailureKey({ token: 'closed' }), 'composer.send_failed_closed')
    assert.equal(sendFailureKey(new TypeError('x')), 'composer.send_failed')
  })
})
