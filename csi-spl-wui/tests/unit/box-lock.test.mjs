// Spec 025 box owner lock, row B8 (SPL-3015): the WUI half. The hub refuses
// a non-owner's send to a locked box's agent with 403 box_locked (B3); the
// composer must say THAT, not the generic "did not reach the hub" line.
// CONTROL: before B8 sendFailureKey answers 'composer.send_failed' for it.
// The lock pane takes `spool lock create`'s output as is and maps each lock
// route refusal (B2, 6.2) to its own line. The mock hook
// `spool.mock.box-lock` stands in for a hub with that lock; with no hook
// nothing is refused (the e2e's red control).
import assert from 'node:assert/strict'
import { readFileSync, readdirSync } from 'node:fs'
import { test } from 'node:test'

import { sendFailureKey } from '../../src/utils/send-failure.mjs'
import {
  BOX_LOCK_MOCK_KEY, createMockBoxLock, lockLoadOf, lockRefusalKey, lockViewOf, mockBoxSendRefusal, parseLockCreate,
} from '../../src/utils/box-lock.mjs'

const mem = new Map()
globalThis.localStorage = {
  getItem: (k) => (mem.has(k) ? mem.get(k) : null),
  setItem: (k, v) => mem.set(k, String(v)),
  removeItem: (k) => mem.delete(k),
}
const hook = (v) => (v ? localStorage.setItem(BOX_LOCK_MOCK_KEY, JSON.stringify(v)) : localStorage.removeItem(BOX_LOCK_MOCK_KEY))

const body = (box, owners, peers = []) => JSON.stringify({
  tenant_id: 't', box_id: box, lock_pubkey: 'K', box_pubkey: 'B', owners, peer_boxes: peers, hide_posts: true, version: 1,
})
const created = (box, owners) => JSON.stringify({ signed_body: body(box, owners), signature: 'c2ln', box_signature: 'Ym94' })

test('a box_locked refusal reads as its own line', () => {
  const err = Object.assign(new Error("this box's agents are reachable only by its lock's owners"), { token: 'box_locked', status: 403 })
  assert.equal(sendFailureKey(err), 'composer.send_failed_box_locked')
  // CONTROL: another 403 keeps its own line
  assert.equal(sendFailureKey({ token: 'sender_not_allowed', status: 403 }), 'composer.send_failed_not_allowed')
  assert.equal(sendFailureKey({ token: 'forbidden', status: 403 }), 'composer.send_failed')
})

test('the mock refuses a non-owner only, and only with the hook', () => {
  hook(null)
  assert.doesNotThrow(() => mockBoxSendRefusal('HUM-1', 'box-desk'))
  hook({ box: 'box-desk', owners: ['HUM-9'] })
  assert.throws(() => mockBoxSendRefusal('HUM-1', 'box-desk'), (e) => e.token === 'box_locked' && e.status === 403)
  assert.doesNotThrow(() => mockBoxSendRefusal('HUM-9', 'box-desk'))
  assert.doesNotThrow(() => mockBoxSendRefusal('HUM-1', 'box-a'))
  assert.doesNotThrow(() => mockBoxSendRefusal('HUM-1', ''))
  hook(null)
})

test('the pasted create output is checked before it is sent', () => {
  const ok = parseLockCreate(created('box-desk', ['HUM-1']), 'box-desk')
  assert.deepEqual(ok.owners, ['HUM-1'])
  assert.deepEqual(Object.keys(ok.req).sort(), ['box_signature', 'signature', 'signed_body'])
  assert.equal(parseLockCreate('not json', 'box-desk').error, 'box_lock.paste_bad')
  assert.equal(parseLockCreate('{"signed_body":"{}"}', 'box-desk').error, 'box_lock.paste_bad')
  assert.equal(parseLockCreate(created('box-a', ['HUM-1']), 'box-desk').error, 'box_lock.paste_other_box')
  assert.equal(parseLockCreate(created('box-desk', []), 'box-desk').error, 'box_lock.paste_bad')
  // a valid body with a missing or empty signature is refused before any POST
  const req = JSON.parse(created('box-desk', ['HUM-1']))
  for (const k of ['signature', 'box_signature']) {
    assert.equal(parseLockCreate(JSON.stringify({ ...req, [k]: '' }), 'box-desk').error, 'box_lock.paste_bad', `${k} empty`)
    const { [k]: _drop, ...rest } = req
    assert.equal(parseLockCreate(JSON.stringify(rest), 'box-desk').error, 'box_lock.paste_bad', `${k} missing`)
  }
})

test('each lock route refusal has its own line', () => {
  for (const [token, key] of [['not_owner', 'err_not_owner'], ['bad_box_sig', 'err_bad_box_sig'], ['bad_sig', 'err_bad_sig'],
    ['box_locked', 'err_already'], ['bad_body', 'err_bad_body'], ['not_found', 'err_no_box'], ['internal', 'err_failed']]) {
    assert.equal(lockRefusalKey({ token }), `box_lock.${key}`, token)
  }
  assert.equal(lockRefusalKey(null), 'box_lock.err_failed')
})

test('the mock lock routes answer an owner only, as the hub does', () => {
  hook({ box: 'box-desk', owners: ['HUM-1'] })
  const m = createMockBoxLock()
  const v = lockViewOf(m.get('box-desk', 'HUM-1'))
  assert.deepEqual(v.owners, ['HUM-1'])
  assert.equal(v.audit[0].verdict, 'refused')
  /* SPL-4516: a lock the viewer does not own and an open box both read 204 (null), never a 404 */
  assert.equal(m.get('box-desk', 'HUM-2'), null)
  assert.equal(m.get('box-a', 'HUM-1'), null)
  assert.throws(() => m.create('box-desk', JSON.parse(created('box-desk', ['HUM-1'])), 'HUM-1'), (e) => e.token === 'box_locked')
  hook(null)
  assert.throws(() => m.create('box-a', JSON.parse(created('box-a', ['HUM-9'])), 'HUM-1'), (e) => e.token === 'not_owner')
  assert.equal(m.create('box-a', JSON.parse(created('box-a', ['HUM-1'])), 'HUM-1').version, 1)
  assert.deepEqual(lockViewOf(m.get('box-a', 'HUM-1')).owners, ['HUM-1'])
})

// SPL-4516 (console errors round 2, row 9): the hub answers GET .../lock
// with 204 (the client reads null) for an open box or a lock the viewer does
// not own; the pane reads that as open, never as a lock with no owners. A
// 404 (an older hub) still reads open. RED CONTROL (master): no lockLoadOf.
test('the pane reads a 204 (null) lock answer as an open box', () => {
  assert.equal(typeof lockLoadOf, 'function')
  assert.deepEqual(lockLoadOf(null), { state: 'none', lock: null })
  assert.deepEqual(lockLoadOf(undefined), { state: 'none', lock: null })
  const l = lockLoadOf({ owners: ['HUM-1'], peer_boxes: [], version: 2, audit: [] })
  assert.equal(l.state, 'locked')
  assert.deepEqual(l.lock.owners, ['HUM-1'])
  assert.equal(lockLoadOf(null, { status: 404 }).state, 'none')
  assert.equal(lockLoadOf(null, { status: 501 }).state, 'unsupported')
  assert.equal(lockLoadOf(null, { status: 500 }).state, 'failed')
  assert.equal(lockLoadOf(null, new Error('offline')).state, 'failed')
})

test('every locale carries every box lock string', () => {
  const dir = new URL('../../i18n/locales/', import.meta.url)
  const en = JSON.parse(readFileSync(new URL('en.json', dir), 'utf8'))
  const keys = Object.keys(en.box_lock)
  assert.ok(keys.length >= 20, `box_lock keys: ${keys.length}`)
  for (const f of readdirSync(dir).filter((x) => x.endsWith('.json'))) {
    const d = JSON.parse(readFileSync(new URL(f, dir), 'utf8'))
    assert.ok(d.composer.send_failed_box_locked, `${f} composer.send_failed_box_locked`)
    for (const k of keys) {
      assert.ok(d.box_lock && d.box_lock[k], `${f} box_lock.${k}`)
      /* vue-i18n reads a bare @ as a linked message: the catalogue build fails */
      assert.doesNotMatch(d.box_lock[k], /@|<[a-z]/i, `${f} box_lock.${k}`)
      for (const p of en.box_lock[k].match(/\{[a-z]+\}/g) || []) assert.ok(d.box_lock[k].includes(p), `${f} box_lock.${k} ${p}`)
    }
  }
})
