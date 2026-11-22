// c-834 finding (v6.6.5 99bfa1691, dev, n=4): /releases/<sha> opened cold
// showed the note, but "Back to the list" said "Could not load the release
// notes" - GET /v1/release-notes?limit=30 answered 401. The dialog read the
// list during setup, before the session probe guessed the `session` door,
// so the read went out with credentials 'omit' and nothing armed the door.
// releaseNotesRead is the dialog's read: a 401 from the view door arms the
// session door once and reads again, as every other view read does
// (withSessionRetry).
import { afterEach, describe, it } from 'node:test'
import assert from 'node:assert/strict'

import { createSpoolClient } from '../../src/utils/spool-client.mjs'
import { releaseNotesRead } from '../../src/utils/release-notes-api.mjs'

const realFetch = globalThis.fetch
afterEach(() => { globalThis.fetch = realFetch })

/** A hub that answers the release notes only to the sign-in cookie. */
function hub() {
  const calls = []
  globalThis.fetch = async (url, init) => {
    calls.push({ url: String(url), credentials: init?.credentials })
    if (init?.credentials !== 'include') return new Response(JSON.stringify({ error: 'view_door' }), { status: 401 })
    return new Response(JSON.stringify({ versions: [{ version: 'v1.0.0', notes: [] }], next_before: '' }), { status: 200 })
  }
  return calls
}

const client = () => createSpoolClient({ base: 'https://api.example.com', mock: false, fetchFn: () => { throw new Error('unused') } })

describe('release notes read on a cold load (door not armed yet)', () => {
  it('a 401 arms the session door and the list is read again', async () => {
    const calls = hub()
    const api = client()
    const body = await releaseNotesRead(api, '/v1/release-notes?limit=30', 'v1.0.0')
    assert.equal(body.versions.length, 1)
    assert.deepEqual(calls.map((c) => c.credentials), ['omit', 'include'])
    assert.equal(api.door, 'session')
  })

  it('an armed door reads once, with the cookie', async () => {
    const calls = hub()
    const api = client()
    api.setDoor('session')
    await releaseNotesRead(api, '/v1/release-notes?limit=30', 'v1.0.0')
    assert.deepEqual(calls.map((c) => c.credentials), ['include'])
  })

  it('CONTROL: the bare read still 401s cold, so the retry is what reads it', async () => {
    hub()
    const { releaseNotesGet } = await import('../../src/utils/release-notes-api.mjs')
    await assert.rejects(releaseNotesGet(client(), '/v1/release-notes?limit=30', 'v1.0.0'), (e) => e.status === 401)
  })

  it('a 404 is not a door: no retry, the status reaches the caller', async () => {
    const calls = []
    globalThis.fetch = async (url, init) => { calls.push(init?.credentials); return new Response('{}', { status: 404 }) }
    const api = client()
    api.setDoor('session')
    await assert.rejects(releaseNotesRead(api, '/v1/release-notes/abcdef1', 'v1.0.0'), (e) => e.status === 404)
    assert.equal(calls.length, 1)
  })

  it('the mock tenant answers without the hub', async () => {
    globalThis.fetch = async () => { throw new Error('the mock never fetches') }
    const body = await releaseNotesRead({ mock: true }, '/v1/release-notes?limit=30', 'v1.0.0')
    assert.equal(body.versions.length, 30)
  })
})

// SPL-6274 (owner HUM-10, t1 95c5be35, msgs 315e9644 and 228bbd19): the
// dialog reads the spool's own notes in every workspace, so each of its reads
// names the platform scope. RED CONTROL: drop platformReleasePath from
// releaseNotesRead and both paths go out bare; this test fails.
describe('the dialog reads in the platform scope', () => {
  it('the list and a ref read both carry scope=platform', async () => {
    const urls = []
    globalThis.fetch = async (url) => { urls.push(String(url)); return new Response('{"versions":[]}', { status: 200 }) }
    const api = client()
    await releaseNotesRead(api, '/v1/release-notes?limit=30', 'v1.0.0')
    await releaseNotesRead(api, '/v1/release-notes/abcdef1', 'v1.0.0')
    assert.deepEqual(urls, [
      'https://api.example.com/v1/release-notes?limit=30&scope=platform',
      'https://api.example.com/v1/release-notes/abcdef1?scope=platform',
    ])
  })

  it('the mock still answers a scoped ref', async () => {
    const body = await releaseNotesRead({ mock: true }, `/v1/release-notes/${'00000001'.repeat(5)}`, 'v1.0.0')
    assert.equal(body.note.sha, '00000001'.repeat(5))
  })
})
