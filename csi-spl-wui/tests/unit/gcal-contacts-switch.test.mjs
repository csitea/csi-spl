// Spec 154 B18 (SPL-6278): the Contacts switch's client in utils/gcal-client.mjs.
//   view   contactsSyncView maps the GET answer and its refusals to what the
//          section shows (hidden, failed, elsewhere, off, grant, on)
//   hub    GET, PUT {enabled} and POST go to /v1/me/contacts/sync?workspace=,
//          with no bearer (the contacts routes are a person's); the GET's
//          missing fields read as off; a 409 throws its error code
//   want   gcalConnect(api, 'calendar,contacts') sends ?want=, so the grant
//          keeps the calendar scope and adds the contacts one
//   mock   the mock keeps the state in spool.mock.contacts_sync: 'off' is the
//          hub's 404, elsewhere refuses a switch-on with 409, a connect with
//          the contacts want grants the scope
// Red control: contactsSyncView returning 'on' for a binding without the
// contacts scope fails "grant"; a bearer on the contacts routes fails "hub".
import { describe, it, beforeEach, afterEach } from 'node:test'
import assert from 'node:assert/strict'
import {
  GCAL_WANT_CONTACTS, MOCK_CONTACTS_SYNC_KEY, MOCK_GCAL_KEY,
  contactsSyncMove, contactsSyncNow, contactsSyncSet, contactsSyncState, contactsSyncView, gcalConnect,
} from '../../src/utils/gcal-client.mjs'

const HUB = { base: 'http://hub.example.com/', tenant: 't1', credentials: 'include', token: 'tok' }
const MOCK = { mock: true, tenant: 't1' }

const realFetch = globalThis.fetch
const realStorage = Object.getOwnPropertyDescriptor(globalThis, 'localStorage')
let sent
let kept

function hubAnswers(status, body) {
  globalThis.fetch = async (url, init) => {
    sent.push({ url: String(url), method: init.method, headers: init.headers, body: init.body ? JSON.parse(init.body) : undefined })
    return new Response(body === null ? null : JSON.stringify(body), { status })
  }
}

beforeEach(() => {
  sent = []
  kept = new Map()
  Object.defineProperty(globalThis, 'localStorage', {
    configurable: true,
    value: { getItem: (k) => kept.get(k) ?? null, setItem: (k, v) => kept.set(k, v), removeItem: (k) => kept.delete(k) },
  })
})

afterEach(() => {
  globalThis.fetch = realFetch
  if (realStorage) Object.defineProperty(globalThis, 'localStorage', realStorage)
  else delete globalThis.localStorage
})

describe('contactsSyncView', () => {
  it('hides on a 404 (workspace off) and a 403 (not the person\'s session), fails on anything else', () => {
    assert.equal(contactsSyncView(null, { status: 404 }), 'hidden')
    assert.equal(contactsSyncView(null, { status: 403 }), 'hidden')
    assert.equal(contactsSyncView(null, { status: 500 }), 'failed')
    assert.equal(contactsSyncView(null, { status: 0 }), 'failed')
    assert.equal(contactsSyncView(null, null), 'hidden')
  })
  it('elsewhere wins over everything; off; grant; on', () => {
    assert.equal(contactsSyncView({ elsewhere: true, enabled: false, scope_granted: true }, null), 'elsewhere')
    assert.equal(contactsSyncView({ state: 'elsewhere', workspace: 'Workspace One' }, null), 'elsewhere')
    assert.equal(contactsSyncView({ enabled: false, scope_granted: true }, null), 'off')
    assert.equal(contactsSyncView({ enabled: true, scope_granted: false }, null), 'grant')
    assert.equal(contactsSyncView({ enabled: true, scope_granted: true }, null), 'on')
  })
})

describe('the hub routes', () => {
  it('GET reads /v1/me/contacts/sync?workspace= with no bearer; missing fields read as off', async () => {
    hubAnswers(200, { enabled: true })
    const st = await contactsSyncState(HUB)
    assert.equal(sent[0].url, 'http://hub.example.com/v1/me/contacts/sync?workspace=t1')
    assert.equal(sent[0].method, 'GET')
    assert.equal(sent[0].headers.authorization, undefined)
    assert.deepEqual(st, { state: 'off', enabled: true, elsewhere: false, workspace: '', scope_granted: false, status_detail: '', last_synced_at: null })
  })
  it('PUT sends {enabled}; a 409 throws contacts_sync_elsewhere', async () => {
    hubAnswers(204, null)
    await contactsSyncSet(HUB, true)
    assert.equal(sent[0].method, 'PUT')
    assert.deepEqual(sent[0].body, { enabled: true })
    assert.equal(sent[0].headers['content-type'], 'application/json')
    assert.equal(sent[0].headers.authorization, undefined)
    hubAnswers(409, { error: 'contacts_sync_elsewhere' })
    await assert.rejects(contactsSyncSet(HUB, true), (e) => e.status === 409 && e.error === 'contacts_sync_elsewhere')
  })
  it('POST is Sync now; 409 sync_in_progress throws its code', async () => {
    hubAnswers(202, null)
    await contactsSyncNow(HUB)
    assert.equal(sent[0].method, 'POST')
    assert.equal(sent[0].url, 'http://hub.example.com/v1/me/contacts/sync?workspace=t1')
    hubAnswers(409, { error: 'sync_in_progress' })
    await assert.rejects(contactsSyncNow(HUB), (e) => e.error === 'sync_in_progress')
  })
  it('POST /sync/move is Sync from here instead (SPL-6454): the new state; 409 sync_in_progress throws its code', async () => {
    hubAnswers(200, { state: 'here', enabled: true, scope_granted: true })
    const st = await contactsSyncMove(HUB)
    assert.equal(sent[0].method, 'POST')
    assert.equal(sent[0].url, 'http://hub.example.com/v1/me/contacts/sync/move?workspace=t1')
    assert.equal(sent[0].headers.authorization, undefined)
    assert.equal(st.state, 'here')
    assert.equal(contactsSyncView(st, null), 'on')
    hubAnswers(409, { error: 'sync_in_progress' })
    await assert.rejects(contactsSyncMove(HUB), (e) => e.status === 409 && e.error === 'sync_in_progress')
  })
  it('the calendar routes keep their bearer', async () => {
    hubAnswers(200, { authorize_url: 'https://accounts.example.com/o' })
    assert.equal(await gcalConnect(HUB, GCAL_WANT_CONTACTS), 'https://accounts.example.com/o')
    assert.equal(sent[0].headers.authorization, 'Bearer tok')
  })
})

describe('want', () => {
  it('connect with the contacts want asks calendar and contacts', async () => {
    hubAnswers(200, { authorize_url: 'https://accounts.example.com/o' })
    await gcalConnect(HUB, GCAL_WANT_CONTACTS)
    assert.equal(new URL(sent[0].url).searchParams.get('want'), 'calendar,contacts')
    assert.equal(new URL(sent[0].url).pathname, '/v1/me/google-calendar/connect')
  })
  it('a plain connect sends no want, as before B18', async () => {
    hubAnswers(200, { authorize_url: 'https://accounts.example.com/o' })
    await gcalConnect(HUB)
    assert.equal(new URL(sent[0].url).searchParams.has('want'), false)
  })
})

describe('mock', () => {
  it("'off' is the hub's 404", async () => {
    kept.set(MOCK_CONTACTS_SYNC_KEY, 'off')
    await assert.rejects(contactsSyncState(MOCK), (e) => e.status === 404)
  })
  it('on without the scope is grant; a connect with the want grants it; Sync now moves the last sync', async () => {
    kept.set(MOCK_GCAL_KEY, JSON.stringify({ connected: true, status: 'connected' }))
    await contactsSyncSet(MOCK, true)
    assert.equal(contactsSyncView(await contactsSyncState(MOCK), null), 'grant')
    assert.equal(await gcalConnect(MOCK, GCAL_WANT_CONTACTS), '')
    const st = await contactsSyncState(MOCK)
    assert.equal(contactsSyncView(st, null), 'on')
    assert.equal(st.last_synced_at, null)
    await contactsSyncNow(MOCK)
    assert.ok((await contactsSyncState(MOCK)).last_synced_at)
    assert.equal(JSON.parse(kept.get(MOCK_GCAL_KEY)).connected, true, 'the calendar connection is kept')
  })
  it('elsewhere refuses a switch-on with 409 contacts_sync_elsewhere', async () => {
    kept.set(MOCK_CONTACTS_SYNC_KEY, JSON.stringify({ elsewhere: true }))
    await assert.rejects(contactsSyncSet(MOCK, true), (e) => e.status === 409 && e.error === 'contacts_sync_elsewhere')
  })
  it('the move takes it here: on, not elsewhere, kept', async () => {
    kept.set(MOCK_CONTACTS_SYNC_KEY, JSON.stringify({ state: 'elsewhere', elsewhere: true, workspace: 'Workspace One', scope_granted: true }))
    const st = await contactsSyncMove(MOCK)
    assert.equal(contactsSyncView(st, null), 'on')
    assert.equal(contactsSyncView(await contactsSyncState(MOCK), null), 'on')
  })
})
