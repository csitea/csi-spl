// SPL-985 (spec 042 §3): who a stored text pokes, what the DM says, and who
// may not be told.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'

import {
  EXCERPT_MAX,
  cardLink,
  channelAccess,
  issueLink,
  pokeBody,
  pokeExcerpt,
  pokeTargets,
  splitByAccess,
  splitPokes,
} from '../../src/utils/mention-poke.mjs'

describe('pokeTargets (K3)', () => {
  it('each mentioned id once, in order', () => {
    assert.deepEqual(pokeTargets({ text: '@CLE-7 and @HUM-2, again @CLE-7' }), ['CLE-7', 'HUM-2'])
  })
  it('a box-qualified tag pokes the bare id', () => {
    assert.deepEqual(pokeTargets({ text: 'ask @CLE-3994@box-desk' }), ['CLE-3994'])
  })
  it('never the author', () => {
    assert.deepEqual(pokeTargets({ text: '@HUM-10 note to self, @CLE-1', selfId: 'HUM-10' }), ['CLE-1'])
  })
  it('never the agent the send already addresses', () => {
    assert.deepEqual(pokeTargets({ text: '@CLE-7 please ask @CLE-8', addressee: 'CLE-7@box-desk' }), ['CLE-8'])
  })
  it('an edit pokes only the new mentions', () => {
    assert.deepEqual(pokeTargets({ text: '@CLE-7 and now @HUM-3', before: '@CLE-7 only' }), ['HUM-3'])
    assert.deepEqual(pokeTargets({ text: '@CLE-7 reworded', before: 'hi @CLE-7' }), [])
  })
  it('no mention, no poke; an email is not a mention', () => {
    assert.deepEqual(pokeTargets({ text: 'plain text a@b.c' }), [])
  })
})

describe('pokeBody (K1)', () => {
  it('names the author by bare id, asks them to act, links and quotes', () => {
    const body = pokeBody({ author: 'HUM-10@box-wui', link: 'https://x.example.com/t/abc', text: 'fix\nthis  @CLE-7' })
    assert.equal(body, 'HUM-10 needs you in https://x.example.com/t/abc: "fix this @CLE-7"')
    assert.ok(!body.startsWith('@'))
  })
  it('the excerpt is one line and capped', () => {
    const e = pokeExcerpt('x'.repeat(EXCERPT_MAX + 50))
    assert.equal(e.length, EXCERPT_MAX)
    assert.ok(e.endsWith('…'))
    assert.equal(pokeExcerpt('a\n\nb'), 'a b')
  })
  it('links are absolute', () => {
    assert.equal(cardLink('https://dev.example.com/', 'a-b'), 'https://dev.example.com/t/a-b')
    assert.equal(issueLink('https://dev.example.com', 'SPL-985'), 'https://dev.example.com/issues?issue=SPL-985')
  })
})

describe('splitByAccess (K4)', () => {
  it('open: everyone', () => {
    assert.deepEqual(splitByAccess(['HUM-1', 'CLE-2'], { kind: 'open' }), { ok: ['HUM-1', 'CLE-2'], refused: [] })
  })
  it('a DM: only its ends', () => {
    assert.deepEqual(splitByAccess(['CLE-2', 'HUM-3'], { kind: 'dm', ends: ['HUM-1', 'CLE-2@box-desk'] }), { ok: ['CLE-2'], refused: ['HUM-3'] })
  })
  it('a members-only channel: people by member list, agents by agent list', () => {
    const acc = channelAccess({ default: false, members: ['HUM-1'], agents: [{ id: 'CLE-2', box: 'box-desk' }] })
    assert.deepEqual(splitByAccess(['HUM-1', 'HUM-4', 'CLE-2', 'CLE-5', 'GST-6'], acc), { ok: ['HUM-1', 'CLE-2'], refused: ['HUM-4', 'CLE-5', 'GST-6'] })
  })
  it('a tenant responder is told even when it is not a channel member (CLE-77804)', () => {
    const acc = channelAccess({ default: false, members: ['HUM-1'], agents: [{ id: 'CLE-2', box: 'box-desk' }], responders: ['CLE-001'] })
    assert.deepEqual(splitByAccess(['CLE-001', 'CLE-2', 'CLE-9'], acc), { ok: ['CLE-001', 'CLE-2'], refused: ['CLE-9'] })
  })
  it('a default channel reads as open', () => {
    assert.deepEqual(channelAccess({ default: true, members: [], agents: [] }), { kind: 'open' })
  })
  it('unknown access refuses everyone (never leaks)', () => {
    assert.deepEqual(splitByAccess(['HUM-1'], null), { ok: [], refused: ['HUM-1'] })
    assert.equal(channelAccess(null), null)
  })
})

import { topicWhere } from '../../src/utils/mention-poke.mjs'

describe('topicWhere (K4 for a task-only send)', () => {
  it('one channel', () => {
    assert.deepEqual(topicWhere([{ task_id: 't', channel: 'dev', to: '@channel' }, { task_id: 'u', channel: 'x' }], 't'), { channel: 'dev' })
  })
  it('a DM topic: its ends, even with a channel-tagged reply in it', () => {
    assert.deepEqual(topicWhere([{ task_id: 't', from: 'HUM-1', to: 'CLE-2' }, { task_id: 't', channel: 'dev' }], 't'), { ends: ['HUM-1', 'CLE-2'] })
  })
  it('the lobby: no channel, to @channel', () => {
    assert.deepEqual(topicWhere([{ task_id: 't', from: 'HUM-1', to: '@channel' }], 't'), { channel: '' })
  })
  it('the lobby: old rows without a channel and new rows tagged lobby are one place', () => {
    assert.deepEqual(topicWhere([{ task_id: 't', to: '@channel' }, { task_id: 't', channel: 'lobby', to: '@channel' }], 't'), { channel: '' })
  })
  it('two channels or no rows: unknown', () => {
    assert.equal(topicWhere([{ task_id: 't', channel: 'a' }, { task_id: 't', channel: 'b' }], 't'), null)
    assert.equal(topicWhere([], 't'), null)
  })
})

import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

describe('every store path pokes after the store succeeded (K1, K3)', () => {
  const wui = join(dirname(fileURLToPath(import.meta.url)), '../..')
  const src = (f) => readFileSync(join(wui, f), 'utf8')
  it('channel and DM sends: after the ack, the DM peer / dispatch target skipped', () => {
    const s = src('src/stores/channel.ts')
    assert.ok(s.lastIndexOf('mentionPoke.poke(') > s.indexOf('await sendWithResend(() => client.send(frame))'))
    assert.match(s, /addressee: asDm \? peerId : \(frame\.to \|\| ''\)/)
  })
  it('lobby and topic panes: where comes from the topic rows, unknown tells nobody', () => {
    const s = src('src/stores/live.ts')
    assert.ok(s.indexOf('void poke(') > s.indexOf('await sendWithResend(() => client.send(frame))'))
    assert.match(s, /topicWhere\(/)
    assert.match(s, /\{ unknown: true, taskId: task \}/)
    assert.match(src('src/pages/lobby.vue'), /pokeChannel: ''/)
  })
  it('an edit pokes only what it added', () => {
    const s = src('src/components/MessageCard.vue')
    assert.match(s, /poke\(\{ text: body, before: state\.original, where: editWhere\(\) \}\)/)
    assert.ok(s.indexOf('before: state.original') > s.indexOf('await commit(state.msgId, body)'))
  })
  it('issues: description (with before), new issue, comment, subtask', () => {
    const s = src('src/pages/issues.vue')
    assert.match(s, /poke\(\{ text: value, before, where: \{ issue: true, issueKey: key \} \}\)/)
    assert.match(s, /issueKey: created\.key/)
    assert.match(s, /poke\(\{ text, where: \{ issue: true, issueKey: issue\.key \} \}\)/)
    assert.match(s, /issueKey: sub\.key/)
  })
  it('the mock tenant tells nobody (only the direct notice, CLE-77852); the strings exist', () => {
    const s = src('src/composables/useMentionPoke.ts')
    const mock = (s.match(/if \(api\.mock\) \{[\s\S]*?\n {4}\}/) || [''])[0]
    assert.match(mock, /return none/)
    assert.doesNotMatch(mock, /sendDm|warn\(/)
    const en = JSON.parse(src('i18n/locales/en.json'))
    assert.ok(en.mention.not_told.includes('{ids}'))
    assert.ok(en.mention.poke_failed.includes('{ids}'))
    assert.ok(en.mention.sent_direct.includes('{ids}'))
  })
})

describe('splitPokes (CLE-77852: a seated agent outside the channel)', () => {
  const acc = channelAccess({ default: false, members: ['HUM-1'], agents: [{ id: 'CLE-2', box: 'box-desk' }] })
  const seated = ['CLE-2', 'CLE-001', 'HUM-4']
  it('a member agent is told as before', () => {
    assert.deepEqual(splitPokes(['CLE-2'], acc, seated), { ok: ['CLE-2'], direct: [], refused: [] })
  })
  it('a seated non-member agent is told by DM, not refused', () => {
    assert.deepEqual(splitPokes(['CLE-001'], acc, ['CLE-001@box-desk']), { ok: [], direct: ['CLE-001'], refused: [] })
  })
  it('an agent not seated in the workspace keeps the refusal', () => {
    assert.deepEqual(splitPokes(['CLE-9'], acc, seated), { ok: [], direct: [], refused: ['CLE-9'] })
  })
  it('a person outside the channel keeps the refusal, seated or not', () => {
    assert.deepEqual(splitPokes(['HUM-4', 'GST-6'], acc, seated), { ok: [], direct: [], refused: ['HUM-4', 'GST-6'] })
  })
  it('mixed, in mention order', () => {
    assert.deepEqual(splitPokes(['CLE-001', 'HUM-1', 'CLE-9', 'CLE-2'], acc, seated), { ok: ['HUM-1', 'CLE-2'], direct: ['CLE-001'], refused: ['CLE-9'] })
  })
  it('only a channel: a DM or an unknown place never pokes an outsider', () => {
    assert.deepEqual(splitPokes(['CLE-001'], { kind: 'dm', ends: ['HUM-1', 'CLE-2'] }, seated), { ok: [], direct: [], refused: ['CLE-001'] })
    assert.deepEqual(splitPokes(['CLE-001'], null, seated), { ok: [], direct: [], refused: ['CLE-001'] })
  })
  it('an open channel tells everyone, nobody goes direct', () => {
    assert.deepEqual(splitPokes(['CLE-001', 'CLE-9'], { kind: 'open' }, seated), { ok: ['CLE-001', 'CLE-9'], direct: [], refused: [] })
  })
  it('no roster yet: refused as before', () => {
    assert.deepEqual(splitPokes(['CLE-001'], acc, undefined), { ok: [], direct: [], refused: ['CLE-001'] })
  })
})
