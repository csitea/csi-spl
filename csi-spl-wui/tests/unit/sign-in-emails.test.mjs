// t1 f265541a (owner HUM-10; hub 153e6c359): a member's sign-in emails. The
// state mapping of the hub's list, the "Confirm with <provider>" links, the
// add answer and the refusals as catalogue keys, and the mock hub's rules.
// The browser half is tests/e2e/settings-modal.test.mjs step S.
// Run: node tests/unit/sign-in-emails.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  SIGN_IN_EMAIL_PROVIDERS,
  addSignInEmail,
  loadSignInEmails,
  normalizeSignInEmail,
  removeSignInEmail,
  signInEmailAddedKey,
  signInEmailAddress,
  signInEmailConfirmHref,
  signInEmailConfirmProviders,
  signInEmailErrorKey,
  signInEmailProviderName,
  signInEmailRows,
} from '../../src/utils/sign-in-emails.mjs'
import { createSignInEmailsMock } from '../../src/utils/sign-in-emails-mock.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const en = JSON.parse(readFileSync(join(WUI, 'i18n/locales/en.json'), 'utf8'))

describe('normalizeSignInEmail: the state mapping', () => {
  it('keeps active and pending as the hub says', () => {
    assert.equal(normalizeSignInEmail({ email: 'a@example.com', state: 'active' }).state, 'active')
    assert.equal(normalizeSignInEmail({ email: 'a@example.com', state: 'pending' }).state, 'pending')
  })
  it('an unknown or missing state reads pending, never active', () => {
    for (const state of ['', 'ACTIVE', 'verified', undefined, null, 1]) {
      assert.equal(normalizeSignInEmail({ email: 'a@example.com', state }).state, 'pending', String(state))
    }
  })
  it('main only for a literal true', () => {
    assert.equal(normalizeSignInEmail({ email: 'a@example.com', main: true }).main, true)
    assert.equal(normalizeSignInEmail({ email: 'a@example.com', main: 'true' }).main, false)
  })
  it('lower-cases the address and the providers, drops blanks and repeats', () => {
    const r = normalizeSignInEmail({ email: ' A@Example.COM ', providers: ['Google', 'google', '', 3, 'password'] })
    assert.deepEqual(r, { email: 'a@example.com', state: 'pending', providers: ['google', 'password'], main: false })
  })
  it('garbage gives an empty row', () => {
    assert.deepEqual(normalizeSignInEmail(null), { email: '', state: 'pending', providers: [], main: false })
  })
})

describe('signInEmailRows', () => {
  it('main first, then active, then pending, each by address; rows without an address dropped', () => {
    const rows = signInEmailRows({
      emails: [
        { email: 'z-pending@example.com', state: 'pending' },
        { email: 'b-active@example.com', state: 'active', providers: ['google'] },
        { email: 'main@example.com', state: 'active', main: true },
        { email: 'a-pending@example.com', state: 'pending' },
        { state: 'active' },
      ],
    })
    assert.deepEqual(rows.map((r) => r.email), ['main@example.com', 'b-active@example.com', 'a-pending@example.com', 'z-pending@example.com'])
  })
  it('no list is no rows', () => {
    assert.deepEqual(signInEmailRows(null), [])
    assert.deepEqual(signInEmailRows({ emails: 'x' }), [])
  })
})

describe('the confirm buttons', () => {
  it('only providers the hub enables, in button order; password is never one', () => {
    assert.deepEqual(signInEmailConfirmProviders(['microsoft', 'password', 'google']), ['google', 'microsoft'])
    assert.deepEqual(signInEmailConfirmProviders([]), [])
    assert.deepEqual(signInEmailConfirmProviders(null), [])
    assert.deepEqual(SIGN_IN_EMAIL_PROVIDERS, ['google', 'facebook', 'linkedin', 'microsoft'])
  })
  it('the href is a link sign-in: link=1, the redirect, the address as hint, the tenant', () => {
    const href = signInEmailConfirmHref('google', 'w@example.com', '/channel/general?settings=security', 't1', 'https://api.example.com')
    const u = new URL(href)
    assert.equal(u.origin + u.pathname, 'https://api.example.com/api/v1/auth/google/start')
    assert.equal(u.searchParams.get('link'), '1')
    assert.equal(u.searchParams.get('redirect'), '/channel/general?settings=security')
    assert.equal(u.searchParams.get('login_hint'), 'w@example.com')
    assert.equal(u.searchParams.get('tenant'), 't1')
  })
  it('CONTROL: a foreign redirect is refused to /', () => {
    const u = new URL(signInEmailConfirmHref('google', 'w@example.com', '//evil.example.com/x', '', 'https://api.example.com'))
    assert.equal(u.searchParams.get('redirect'), '/')
  })
  it('brand names; password has none (the catalogue words it)', () => {
    assert.equal(signInEmailProviderName('linkedin'), 'LinkedIn')
    assert.equal(signInEmailProviderName('MICROSOFT'), 'Microsoft')
    assert.equal(signInEmailProviderName('password'), '')
  })
})

describe('add answer and refusals as catalogue keys', () => {
  it('pending_until_provider_sign_in -> the owner\'s explanation; already_active -> active', () => {
    assert.equal(signInEmailAddedKey({ state: 'pending', reason: 'pending_until_provider_sign_in' }), 'signin_emails.added_pending')
    assert.equal(signInEmailAddedKey({ state: 'active', reason: 'already_active' }), 'signin_emails.added_active')
    assert.equal(signInEmailAddedKey(null), 'signin_emails.added_pending')
  })
  it('the two 409s of a remove and the taken address are plain messages', () => {
    assert.equal(signInEmailErrorKey({ status: 409, token: 'last_sign_in' }), 'signin_emails.error_last_sign_in')
    assert.equal(signInEmailErrorKey({ status: 409, token: 'main_email' }), 'signin_emails.error_main_email')
    assert.equal(signInEmailErrorKey({ status: 409, token: 'email_taken' }), 'signin_emails.error_taken')
    assert.equal(signInEmailErrorKey({ status: 403, token: 'forbidden' }), 'signin_emails.error_forbidden')
    assert.equal(signInEmailErrorKey({ status: 500, token: 'toString' }), 'signin_emails.error_failed')
    assert.equal(signInEmailErrorKey(new Error('network')), 'signin_emails.error_failed')
  })
  it('every key the helpers name exists in en', () => {
    const keys = [
      signInEmailAddedKey({ reason: 'already_active' }), signInEmailAddedKey({}),
      ...['email_taken', 'last_sign_in', 'main_email', 'bad_email', 'act_as', 'not_found', 'x'].map((token) => signInEmailErrorKey({ token })),
      signInEmailErrorKey({ status: 403 }),
    ]
    for (const k of keys) assert.equal(typeof en.signin_emails[k.split('.')[1]], 'string', k)
  })
  it('the explanation says what the owner said: works once signed in with it at the provider while signed in here', () => {
    assert.match(en.signin_emails.added_pending, /works once you sign in with it at \{providers\} while signed in here/)
  })
})

describe('signInEmailAddress', () => {
  it('a plain address, lower-cased; anything else is empty', () => {
    assert.equal(signInEmailAddress(' New@Example.com '), 'new@example.com')
    for (const v of ['', 'x', 'a@b', 'Name <a@example.com>', 'a@example.com, b@example.com', 'a b@example.com']) {
      assert.equal(signInEmailAddress(v), '', v)
    }
  })
})

describe('the mock hub', () => {
  it('HUM-1 starts with one active main and one pending address', () => {
    const rows = signInEmailRows(createSignInEmailsMock().list('HUM-1'))
    assert.deepEqual(rows.map((r) => [r.state, r.main]), [['active', true], ['pending', false]])
  })
  it('add is pending with the provider reason; again on the same member answers its state', () => {
    const m = createSignInEmailsMock()
    assert.deepEqual(m.add('HUM-1', 'New@example.com'), { human_id: 'HUM-1', email: 'new@example.com', state: 'pending', reason: 'pending_until_provider_sign_in' })
    assert.equal(m.add('HUM-1', 'member@example.com').reason, 'already_active')
  })
  it('a taken address is 409 email_taken and never says whose', () => {
    const m = createSignInEmailsMock()
    assert.throws(() => m.add('HUM-1', 'taken@example.com'), (e) => e.status === 409 && e.token === 'email_taken' && !/HUM-/.test(e.message))
    m.add('HUM-2', 'only-mine@example.com')
    assert.throws(() => m.add('HUM-1', 'only-mine@example.com'), (e) => e.token === 'email_taken')
  })
  it('the main address and the last sign-in stay; a pending one goes', () => {
    const m = createSignInEmailsMock()
    assert.throws(() => m.remove('HUM-1', 'member@example.com'), (e) => e.status === 409 && e.token === 'main_email')
    m.remove('HUM-1', 'member.work@example.com')
    assert.deepEqual(m.list('HUM-1').emails.map((r) => r.email), ['member@example.com'])
  })
  it('the api functions route to the mock when the client is the mock', async () => {
    const api = { mock: true, base: '' }
    const before = signInEmailRows(await loadSignInEmails(api, 'HUM-7'))
    assert.equal(before.length, 1)
    const added = await addSignInEmail(api, 'HUM-7', 'extra@example.com')
    assert.equal(added.state, 'pending')
    assert.equal(await removeSignInEmail(api, 'HUM-7', 'extra@example.com'), null)
    assert.equal(signInEmailRows(await loadSignInEmails(api, 'HUM-7')).length, 1)
  })
})

describe('the live calls', () => {
  it('GET, POST and DELETE the member route with the session credentials; a refusal carries status + token', async () => {
    const seen = []
    const real = globalThis.fetch
    globalThis.fetch = async (url, init = {}) => {
      seen.push([init.method || 'GET', url, init.credentials, init.body || ''])
      if ((init.method || 'GET') === 'DELETE') return new Response(JSON.stringify({ error: 'last_sign_in' }), { status: 409 })
      return new Response(JSON.stringify({ emails: [] }), { status: 200, headers: { 'content-type': 'application/json' } })
    }
    try {
      const api = { base: 'https://api.example.com/', credentials: 'include', mock: false }
      await loadSignInEmails(api, 'HUM-4')
      await addSignInEmail(api, 'HUM-4', 'x@example.com')
      await assert.rejects(removeSignInEmail(api, 'HUM-4', 'x+1@example.com'), (e) => e.status === 409 && e.token === 'last_sign_in')
    } finally {
      globalThis.fetch = real
    }
    assert.deepEqual(seen, [
      ['GET', 'https://api.example.com/v1/members/HUM-4/emails', 'include', ''],
      ['POST', 'https://api.example.com/v1/members/HUM-4/emails', 'include', '{"email":"x@example.com"}'],
      ['DELETE', 'https://api.example.com/v1/members/HUM-4/emails?email=x%2B1%40example.com', 'include', ''],
    ])
  })
})
