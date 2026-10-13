// SPL-1018 (spec 044 FR-OS-017, owner t1 dee4081d msg e9ec66fa): the WUI half
// of the per-agent sender allow-list. Decision 5: the hub's 403
// sender_not_allowed reads as its own line naming the agent (CONTROL: any
// other token keeps its line and names nobody). The editor's rules: no list =
// every member, [] = nobody, a save drops or puts exactly what changed. The
// mock hub keeps the hub's shapes.
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { test } from 'node:test'

import { sendFailureKey, sendFailureParams } from '../../src/utils/send-failure.mjs'
import { senderAgents, senderListsOf, senderSave, senderSummary } from '../../src/utils/sender-allow.mjs'
import { createMockSenderAllow } from '../../src/utils/sender-allow-mock.mjs'

const refusal = Object.assign(new Error('c-007 does not take messages from you'), { token: 'sender_not_allowed', status: 403, agent: 'c-007' })

test('a sender_not_allowed refusal names the agent', () => {
  assert.equal(sendFailureKey(refusal), 'composer.send_failed_not_allowed')
  assert.deepEqual(sendFailureParams(refusal), { agent: 'c-007' })
  // CONTROL: another refusal keeps its own line, and names nobody
  const inactive = { token: 'unknown_agent', status: 404 }
  assert.equal(sendFailureKey(inactive), 'composer.send_failed_agent_inactive')
  assert.deepEqual(sendFailureParams(inactive), { agent: '' })
  assert.deepEqual(sendFailureParams(null), { agent: '' })
})

test('every locale says it, with the agent in it', () => {
  for (const loc of ['bg', 'el', 'en', 'es', 'et', 'fi', 'he', 'lt', 'lv', 'mk', 'nl', 'pl', 'ro', 'ru', 'sk', 'sr', 'sv', 'tr', 'uk']) {
    const d = JSON.parse(readFileSync(new URL(`../../i18n/locales/${loc}.json`, import.meta.url), 'utf8'))
    assert.match(d.composer.send_failed_not_allowed, /\{agent\}/, loc)
    for (const k of ['title', 'hint', 'everyone', 'nobody', 'some', 'edit', 'mode_all', 'mode_list', 'none_ticked', 'cancel']) {
      assert.ok(d.tenant_settings.senders[k], `${loc} tenant_settings.senders.${k}`)
      /* vue-i18n reads a bare @ as a linked message: the catalogue build fails */
      assert.doesNotMatch(d.tenant_settings.senders[k], /@/, `${loc} tenant_settings.senders.${k}`)
    }
    assert.match(d.tenant_settings.senders.some, /\{n\}/, loc)
  }
})

test('no list is every member, an empty list is nobody', () => {
  const lists = senderListsOf({ lists: [{ agent: 'c-008', members: ['HUM-9', 'HUM-3'] }, { agent: 'c-009', members: [] }, { members: ['HUM-1'] }] })
  assert.deepEqual(lists, { 'c-008': ['HUM-3', 'HUM-9'], 'c-009': [] })
  assert.deepEqual(senderSummary(lists['c-007']), { state: 'all', n: 0 })
  assert.deepEqual(senderSummary(lists['c-008']), { state: 'some', n: 2 })
  assert.deepEqual(senderSummary(lists['c-009']), { state: 'none', n: 0 })
  assert.deepEqual(senderListsOf(null), {})
  assert.deepEqual(senderAgents([{ id: 'c-008' }, { id: 'c-001' }, { id: 'c-008' }]), ['c-001', 'c-008'])
})

test('a save drops or puts only what changed', () => {
  assert.deepEqual(senderSave(['HUM-3'], 'all', []), { op: 'drop' })
  assert.equal(senderSave(undefined, 'all', ['HUM-3']), null)
  assert.deepEqual(senderSave(undefined, 'list', []), { op: 'put', members: [] })
  assert.deepEqual(senderSave(['HUM-3'], 'list', ['HUM-9', 'HUM-3', 'HUM-9']), { op: 'put', members: ['HUM-3', 'HUM-9'] })
  assert.equal(senderSave(['HUM-3', 'HUM-9'], 'list', ['HUM-9', 'HUM-3']), null)
})

test('the mock hub keeps the hub shapes', () => {
  const m = createMockSenderAllow({ now: () => '2026-10-13T09:00:00Z' })
  assert.deepEqual(m.list(), { tenant_id: 'mock', lists: [] })
  assert.deepEqual(m.put('C-008@sat', ['HUM-9', 'HUM-3']), { agent: 'c-008', members: ['HUM-3', 'HUM-9'], updated_by: 'HUM-1', updated_at: '2026-10-13T09:00:00Z' })
  assert.equal(m.list().lists.length, 1)
  assert.throws(() => m.put('c-008', ['c-001']), (e) => e.token === 'bad_members')
  assert.throws(() => m.put('HUM-3', []), (e) => e.token === 'bad_agent')
  assert.equal(m.drop('c-008'), null)
  assert.deepEqual(m.list().lists, [])
})
