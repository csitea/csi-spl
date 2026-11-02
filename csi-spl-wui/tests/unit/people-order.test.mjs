// Spec 154 B9: the People panel's order (C24b-C24e) and the contact client's
// wire shape. C24b's red control: today's roster order fails the expected
// sequence, because peopleRows sorts by <id>@<box> and puts nobody online first.
//
// Run: node tests/unit/people-order.test.mjs
import { describe, it, afterEach } from 'node:test'
import assert from 'node:assert/strict'
import { applyPresence, peopleRows } from '../../src/utils/live-follow.mjs'
import { PEOPLE_FILTER_WORKSPACE, contactName, parsePeopleFilter, peopleOrder } from '../../src/utils/people-order.mjs'
import { contactCreate, contactErrorKey, contactInvite, contactsList, onContactsChanged } from '../../src/utils/contacts-client.mjs'
import { runsInUnitSuite } from './lib/in-suite.mjs'

/* names chosen so the id order is the reverse of the name order */
const NAMES = { 'HUM-1': 'Cara', 'HUM-2': 'Bea', 'HUM-3': 'Ana' }
const ROSTER = { 'box-wui': ['HUM-1', 'HUM-2', 'HUM-3'] }
const members = (online) => peopleRows(ROSTER, online, 'HUM-3')
const nameOf = (m) => NAMES[m.id]
const CONTACTS = [
  { contact_id: 'k2', first_name: 'Eve', last_name: 'Zed', email: null, phone: null, member_id: null },
  { contact_id: 'k1', first_name: 'dan', last_name: '', email: null, phone: null, member_id: null },
]
const names = (rows) => rows.map(nameOf)

describe('C24b the order: online A-Z, offline A-Z, contacts A-Z', () => {
  const online = ['HUM-3@box-wui', 'HUM-1@box-wui']
  it('groups and sorts by the name shown', () => {
    const g = peopleOrder(members(online), CONTACTS, { locale: 'en', nameOf })
    assert.deepEqual(names(g.online), ['Ana', 'Cara'])
    assert.deepEqual(names(g.members), ['Bea'])
    assert.deepEqual(g.contacts.map(contactName), ['dan', 'Eve Zed'], 'case-insensitive: dan before Eve')
  })
  it('RED CONTROL: the roster order today fails the expected sequence', () => {
    assert.notDeepEqual(names(members(online)), ['Ana', 'Cara', 'Bea'])
  })
  it('keeps the list it was given', () => {
    const list = [...CONTACTS]
    peopleOrder(members(online), list, { locale: 'en', nameOf })
    assert.deepEqual(list, CONTACTS)
  })
})

describe('C24c a presence frame moves a member between the groups', () => {
  it('B goes online at its A-Z place, and back', () => {
    const was = ['HUM-3@box-wui', 'HUM-1@box-wui']
    const on = applyPresence(was, { type: 'presence', peer: 'HUM-2@box-wui', status: 'online' })
    assert.deepEqual(names(peopleOrder(members(on), [], { locale: 'en', nameOf }).online), ['Ana', 'Bea', 'Cara'])
    const off = applyPresence(on, { type: 'presence', peer: 'HUM-2@box-wui', status: 'offline' })
    const g = peopleOrder(members(off), [], { locale: 'en', nameOf })
    assert.deepEqual(names(g.online), ['Ana', 'Cara'])
    assert.deepEqual(names(g.members), ['Bea'])
  })
})

describe('C24d the filter', () => {
  const matched = { contact_id: 'k3', first_name: 'Ana', last_name: 'Tag', member_id: 'HUM-3' }
  it('In this workspace: members only, and a matched contact stays its member', () => {
    const g = peopleOrder(members([]), [...CONTACTS, matched], { locale: 'en', nameOf, filter: PEOPLE_FILTER_WORKSPACE })
    assert.deepEqual(g.contacts, [])
    assert.equal(g.members.find((m) => m.id === 'HUM-3').contactId, 'k3')
  })
  it('twin: All shows group 3', () => {
    assert.equal(peopleOrder(members([]), CONTACTS, { locale: 'en', nameOf, filter: 'all' }).contacts.length, 2)
  })
  it('anything stored but the one word is All', () => {
    assert.equal(parsePeopleFilter(PEOPLE_FILTER_WORKSPACE), PEOPLE_FILTER_WORKSPACE)
    for (const v of [null, '', 'x', 'WORKSPACE']) assert.equal(parsePeopleFilter(v), 'all')
  })
})

describe('C24e a contact matched to a member is one row', () => {
  it('the member carries the tag, group 3 does not list it', () => {
    const g = peopleOrder(members(['HUM-1@box-wui']), [{ contact_id: 'k9', first_name: 'Cee', last_name: '', member_id: 'HUM-1' }], { locale: 'en', nameOf })
    assert.equal(g.online[0].contactId, 'k9')
    assert.deepEqual(g.contacts, [])
    assert.equal(g.online.length + g.members.length, 3)
  })
  it('twin: a member_id naming nobody listed stays a contact, never lost', () => {
    const g = peopleOrder(members([]), [{ contact_id: 'k8', first_name: 'Far', last_name: '', member_id: 'HUM-99' }], { locale: 'en', nameOf })
    assert.deepEqual(g.contacts.map((c) => c.contact_id), ['k8'])
  })
})

describe('contactName', () => {
  it('first + last, else email, else phone', () => {
    assert.equal(contactName({ first_name: 'A', last_name: 'B', email: 'a@example.com' }), 'A B')
    assert.equal(contactName({ first_name: '', last_name: ' ', email: 'a@example.com', phone: '+1' }), 'a@example.com')
    assert.equal(contactName({ phone: '+1' }), '+1')
  })
})

describe('contacts-client on the wire', () => {
  const realFetch = globalThis.fetch
  afterEach(() => { globalThis.fetch = realFetch })
  const answer = (status, body) => new Response(body === null ? null : JSON.stringify(body), { status })
  const api = (tenant) => ({ base: 'https://hub.example.com/', tenant, credentials: 'include', token: 'view-token' })

  it('reads every page, once, with the workspace and no bearer', async () => {
    const urls = []
    let sent
    globalThis.fetch = async (url, init) => {
      urls.push(String(url))
      sent = init
      return urls.length === 1 ? answer(200, { contacts: [{ contact_id: 'a' }], next: 'c1' }) : answer(200, { contacts: [{ contact_id: 'b' }], next: null })
    }
    const a = api('t-pages')
    const got = await contactsList(a, 'HUM-1')
    assert.deepEqual(got.map((c) => c.contact_id), ['a', 'b'])
    assert.deepEqual(urls, ['https://hub.example.com/v1/me/contacts?workspace=t-pages', 'https://hub.example.com/v1/me/contacts?workspace=t-pages&cursor=c1'])
    assert.equal(sent.headers.authorization, undefined, 'the routes answer 403 person_only to a bearer')
    assert.equal(sent.credentials, 'include')
    await contactsList(a, 'HUM-1')
    assert.equal(urls.length, 2, 'a second reader shares the read')
    await contactsList(a, 'HUM-2')
    assert.equal(urls.length, 3, 'RED CONTROL: another person never gets the held list')
  })

  it('a write forgets the held list and tells the panel', async () => {
    let reads = 0
    globalThis.fetch = async (_url, init) => {
      if (init.method === 'POST') return answer(201, { contact: { contact_id: 'n' } })
      reads++
      return answer(200, { contacts: [], next: null })
    }
    const a = api('t-write')
    let told = 0
    const off = onContactsChanged(() => { told++ })
    await contactsList(a, 'HUM-1')
    await contactCreate(a, { first_name: 'N', last_name: '', email: null, phone: null })
    off()
    assert.equal(told, 1)
    await contactsList(a, 'HUM-1')
    assert.equal(reads, 2)
  })

  it('a refused read throws its status and is not held', async () => {
    globalThis.fetch = async () => answer(404, { error: 'not_found' })
    const a = api('t-off')
    await assert.rejects(contactsList(a, 'HUM-1'), (e) => e.status === 404 && e.error === 'not_found')
    let again = 0
    globalThis.fetch = async () => { again++; return answer(200, { contacts: [], next: null }) }
    await contactsList(a, 'HUM-1')
    assert.equal(again, 1)
  })

  it('Invite is the members route with the address only: the session decides the workspace', async () => {
    const calls = []
    await contactInvite({ inviteTenantUser: async (b) => { calls.push(b) } }, 'a@example.com', 'en')
    assert.deepEqual(calls, [{ email: 'a@example.com', locale: 'en' }])
  })

  it('a refused save names its key', () => {
    assert.equal(contactErrorKey({ error: 'bad_email' }), 'contacts.error_bad_email')
    assert.equal(contactErrorKey({ error: 'other' }), 'contacts.save_failed')
  })
})

describe('in the suite', () => {
  it('pnpm test runs this file', () => {
    const r = runsInUnitSuite(import.meta.url)
    assert.ok(r.ok, r.why)
  })
})
