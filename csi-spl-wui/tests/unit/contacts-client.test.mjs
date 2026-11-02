// SPL-4661: contacts-client.mjs against the hub's real answers. The golden file
// is generated from the hub's handlers (hub/contacts_answers_golden_test.go),
// so this fails when the client reads a shape the hub does not send, which the
// mock bundle's e2e cannot see. The mock is held to the same answers below.
import { describe, it, beforeEach, afterEach } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { contactCreate, contactDelete, contactErrorKey, contactGet, contactPatch, contactReread, contactsList } from '../../src/utils/contacts-client.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const ANSWERS = JSON.parse(readFileSync(join(WUI, '../csi-spl-api/src/go/spool-hub-api/internal/hub/testdata/contacts_answers.golden.json'), 'utf8'))
const HUB = { base: 'http://hub.example.com', tenant: 't1', credentials: 'include' }
const MOCK = { mock: true, tenant: 't1' }
const VALUES = { first_name: 'FirstName', last_name: 'LastName', email: null, phone: null }

const realFetch = globalThis.fetch
const realStorage = Object.getOwnPropertyDescriptor(globalThis, 'localStorage')
let sent

/** The next fetch answers what the hub answered for `name`. */
function hubAnswers(name) {
  const { status, body } = ANSWERS[name]
  globalThis.fetch = async (url, init) => {
    sent.push({ url: String(url), method: init.method, body: init.body ? JSON.parse(init.body) : undefined })
    return new Response(body === null ? null : JSON.stringify(body), { status })
  }
}

beforeEach(() => {
  sent = []
  const kept = new Map()
  Object.defineProperty(globalThis, 'localStorage', {
    configurable: true,
    value: { getItem: (k) => kept.get(k) ?? null, setItem: (k, v) => kept.set(k, v) },
  })
})

afterEach(() => {
  globalThis.fetch = realFetch
  if (realStorage) Object.defineProperty(globalThis, 'localStorage', realStorage)
  else delete globalThis.localStorage
})

describe('the client reads what the hub answers', () => {
  it('create returns the row, with its contact_id', async () => {
    hubAnswers('create')
    const row = await contactCreate(HUB, VALUES)
    assert.equal(ANSWERS.create.status, 201)
    assert.deepEqual(row, ANSWERS.create.body)
    assert.equal(row.contact_id, '<contact_id>')
  })

  it('get returns the row, with the member the card needs', async () => {
    hubAnswers('member_get')
    const row = await contactGet(HUB, 'k1')
    assert.deepEqual(row, ANSWERS.member_get.body)
    assert.equal(row.member_id, '<member_id>')
  })

  it('patch returns the row', async () => {
    hubAnswers('patch')
    const row = await contactPatch(HUB, 'k1', VALUES)
    assert.deepEqual(row, ANSWERS.patch.body)
    assert.equal(row.first_name, 'Changed')
  })

  it('delete resolves on the 204', async () => {
    hubAnswers('delete')
    assert.equal(ANSWERS.delete.status, 204)
    await contactDelete(HUB, 'k1')
    assert.equal(sent[0].method, 'DELETE')
  })

  it('a deleted contact is a refusal, not an empty row', async () => {
    hubAnswers('get_deleted')
    await assert.rejects(contactGet(HUB, 'k1'), (e) => e.status === 404 && e.error === 'not_found')
  })

  it('a refused save names its error', async () => {
    hubAnswers('refused_bad_email')
    await assert.rejects(contactCreate(HUB, VALUES), (e) => contactErrorKey(e) === 'contacts.error_bad_email')
  })

  it('the list reads every row of the page', async () => {
    globalThis.fetch = async () => new Response(JSON.stringify({ contacts: [ANSWERS.get.body], next: null }), { status: 200 })
    assert.deepEqual(await contactsList(HUB, 'HUM-1'), [ANSWERS.get.body])
  })
})

describe('an edit that empties a field clears it', () => {
  it('the hub keeps a field sent as null and clears one sent as ""', () => {
    assert.equal(ANSWERS.patch_email_null.body.email, ANSWERS.patch.body.email)
    assert.equal(ANSWERS.patch_email_empty.body.email, null)
  })

  it('each of the four clears alone, the names to "", email and phone to null', () => {
    assert.equal(ANSWERS.patch_phone_empty.body.phone, null)
    assert.equal(ANSWERS.patch_first_empty.body.first_name, '')
    assert.equal(ANSWERS.patch_last_empty.body.last_name, '')
  })

  it('clearing all four is refused, and the form says why', () => {
    const { status, body } = ANSWERS.refused_all_empty
    assert.equal(status, 400)
    assert.equal(contactErrorKey({ status, error: body.error }), 'contacts.error_contact_empty')
  })

  it('patch sends the emptied field as ""', async () => {
    hubAnswers('patch_email_empty')
    await contactPatch(HUB, 'k1', VALUES)
    assert.deepEqual(sent[0].body, { first_name: 'FirstName', last_name: 'LastName', email: '', phone: '' })
  })
})

describe('a failed re-read after a save', () => {
  const before = { ...ANSWERS.member_get.body }
  const row = { ...ANSWERS.member_patch.body }
  beforeEach(() => {
    globalThis.fetch = async () => new Response('{}', { status: 500 })
  })

  it('the card keeps the member it showed, so Message stays and Invite stays away', async () => {
    assert.equal(row.member_id, null)
    assert.equal((await contactReread(HUB, 'k1', row, before)).member_id, before.member_id)
  })

  it('a changed email drops the member: the match follows the email', async () => {
    const changed = await contactReread(HUB, 'k1', { ...row, email: 'other@example.com' }, before)
    assert.equal(changed.member_id, null)
  })

  it('the read that works is the card', async () => {
    hubAnswers('member_get')
    assert.equal((await contactReread(HUB, 'k1', row, { member_id: null })).member_id, before.member_id)
  })
})

describe('the mock answers in the hub\'s shape', () => {
  const keys = (row) => Object.keys(row).sort()

  it('create, get and patch carry the hub\'s keys', async () => {
    const made = await contactCreate(MOCK, { ...VALUES, email: 'first.last@example.com' })
    assert.deepEqual(keys(made), keys(ANSWERS.create.body))
    assert.deepEqual(keys(await contactGet(MOCK, made.contact_id)), keys(ANSWERS.get.body))
    assert.deepEqual(keys(await contactPatch(MOCK, made.contact_id, VALUES)), keys(ANSWERS.patch.body))
  })

  it('an emptied field reads back null, as the hub answers it', async () => {
    const made = await contactCreate(MOCK, { ...VALUES, email: 'first.last@example.com' })
    const row = await contactPatch(MOCK, made.contact_id, VALUES)
    assert.equal(row.email, ANSWERS.patch_email_empty.body.email)
  })

  it('a patch\'s answer names no member, the card\'s read does', async () => {
    assert.equal(ANSWERS.member_patch.body.member_id, null)
    assert.equal(ANSWERS.member_get.body.member_id, '<member_id>')
    localStorage.setItem('spool.mock.contacts', JSON.stringify([{ contact_id: 'k-in', first_name: 'FirstName', last_name: '', email: null, phone: null, google: false, member_id: 'HUM-2' }]))
    assert.equal((await contactPatch(MOCK, 'k-in', VALUES)).member_id, null)
    assert.equal((await contactGet(MOCK, 'k-in')).member_id, 'HUM-2')
  })
})
