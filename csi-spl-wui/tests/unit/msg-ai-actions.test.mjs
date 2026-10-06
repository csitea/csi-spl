// t1 b6c742f0 (HUM-10): the AI actions group in the menu of a message a
// PERSON wrote - never on an agent's - and what each action sends: the
// instruction post (same topic, quoting the source), the issue body, and the
// calendar event body (POST /v1/calendar/events, spec 089 6.1.2).
// Run: node tests/unit/msg-ai-actions.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  AI_ACTIONS, aiActionPost, aiCalendarRoute, aiEventBody, aiIssueBody, aiIssueRoute, aiMenuItems, aiPostTarget, createCalendarEvent, offersAiActions,
} from '../../src/utils/msg-ai-actions.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const src = (rel) => readFileSync(join(WUI, rel), 'utf8')
const TASK = 'b6c742f0-163c-4833-b369-b918a2d56c34'
const person = { msg_id: 'm-1', task_id: TASK, from: 'HUM-24', from_box: 'box-wui', channel: 'general', body: 'Ship the export\nby Friday', is_parent: 0 }
const agent = { ...person, msg_id: 'm-2', from: 'c-002', from_box: 'box-a' }
const where = { workspace: 'acme', link: 'https://example.com/t/' + TASK + '#m-1' }

describe('people only, never agents', () => {
  it('offers the group on a person\'s message, a guest\'s, and a line a person typed at an agent', () => {
    assert.equal(offersAiActions(person), true)
    assert.equal(offersAiActions({ ...person, from: 'GST-3' }), true)
    assert.equal(offersAiActions({ ...agent, typed_by: 'HUM-10' }), true)
  })
  it('never on an agent\'s message, legacy id or new', () => {
    assert.equal(offersAiActions(agent), false)
    assert.equal(offersAiActions({ ...person, from: 'CLE-77' }), false)
    assert.deepEqual(aiMenuItems(agent), [])
  })
  it('never on an unknown sender, a pending row or a row with no topic', () => {
    assert.equal(offersAiActions({ ...person, from: '' }), false)
    assert.equal(offersAiActions({ ...person, pending: true }), false)
    assert.equal(offersAiActions({ ...person, task_id: '', parent_task_id: '' }), false)
    assert.equal(offersAiActions(null), false)
  })
  it('lists the seven actions in order, the group heading on the first', () => {
    const items = aiMenuItems(person)
    assert.deepEqual(items.map((i) => i.id), ['ai-debate', 'ai-spec', 'ai-implement', 'ai-analyse', 'ai-issue', 'ai-risks', 'ai-calendar'])
    assert.equal(items[0].groupKey, 'feed.msg_menu.ai.group')
    assert.equal(items.filter((i) => i.groupKey).length, 1)
    for (const i of items) assert.match(i.labelKey, /^feed\.msg_menu\.ai\.[a-z]+$/)
  })
  it('every label and the heading exist in every locale', () => {
    for (const loc of ['en', 'bg', 'fi', 'he', 'uk']) {
      const ai = JSON.parse(src(`i18n/locales/${loc}.json`)).feed.msg_menu.ai
      for (const a of AI_ACTIONS) assert.ok(ai[a.key], `${loc} ${a.key}`)
      assert.ok(ai.group && ai.failed, loc)
    }
    assert.equal(JSON.parse(src('i18n/locales/en.json')).feed.msg_menu.ai.issue, 'Turn into an issue')
  })
  it('MessageCard passes the message only when it is not an agent\'s', () => {
    assert.match(src('src/components/MessageCard.vue'), /:ai-msg="ai \? undefined : msg"/)
  })
})

describe('the post', () => {
  it('Analyse quotes the source and carries the instruction', () => {
    const text = aiActionPost(person, 'ai-analyse', where)
    assert.match(text, /^\*\*AI action: Analyse\*\* \(ai-action=analyse\): reply with an analysis of this message\./)
    assert.match(text, new RegExp(`Source: workspace \\*\\*acme\\*\\*, topic \`${TASK}\`, msg \`m-1\`, by HUM-24@box-wui - https://example\\.com/t/${TASK}#m-1`))
    assert.match(text, /\n\n> Ship the export\n> by Friday$/)
  })
  it('each post action has its own instruction; issue and calendar are not posts', () => {
    assert.match(aiActionPost(person, 'ai-debate'), /run an agent panel debate on this message/)
    assert.match(aiActionPost(person, 'ai-spec'), /write a spec from this message/)
    assert.match(aiActionPost(person, 'ai-implement'), /build what this message asks for \(a lane\)/)
    assert.match(aiActionPost(person, 'ai-risks'), /reply with the risks of this message/)
    assert.equal(aiActionPost(person, 'ai-issue'), '')
    assert.equal(aiActionPost(person, 'ai-calendar'), '')
    assert.equal(aiActionPost(person, 'nope'), '')
  })
  it('a long body is cut in the quote', () => {
    const text = aiActionPost({ ...person, body: 'x'.repeat(2000) }, 'ai-analyse')
    assert.ok(text.length < 900, String(text.length))
    assert.match(text, /…$/)
  })
  it('goes to the same topic, as a reply, in the message\'s channel', () => {
    assert.deepEqual(aiPostTarget(person), { taskId: TASK, channel: 'general' })
    assert.deepEqual(aiPostTarget({ ...person, channel: '#ops' }), { taskId: TASK, channel: 'ops' })
    assert.deepEqual(aiPostTarget({ ...person, channel: null }), { taskId: TASK, channel: '' })
  })
})

describe('Turn into an issue', () => {
  it('titles the issue with the first line and links the source', () => {
    const b = aiIssueBody({ ...person, body: '## Ship the export\nby Friday' }, where)
    assert.equal(b.title, 'Ship the export')
    assert.match(b.description, /^## Ship the export\nby Friday\n\n---\n\nSource: workspace \*\*acme\*\*/)
    assert.equal(aiIssueBody({ ...person, body: '' }).title, 'Message m-1')
    assert.deepEqual(aiIssueRoute('SPL-12'), { path: '/issues', query: { issue: 'SPL-12' } })
  })
})

describe('Add to calendar', () => {
  const now = Date.parse('2026-10-06T14:35:12Z')
  it('creates a one-hour event at the next whole hour, linked to the topic', () => {
    const b = aiEventBody(person, where, now)
    assert.deepEqual(Object.keys(b).sort(), ['description', 'ends_at', 'starts_at', 'title', 'topic_id'])
    assert.equal(b.title, 'Ship the export')
    assert.equal(b.starts_at, '2026-10-06T15:00:00Z')
    assert.equal(b.ends_at, '2026-10-06T16:00:00Z')
    assert.equal(b.topic_id, TASK)
    assert.match(b.description, /Source: workspace \*\*acme\*\*, topic/)
  })
  it('keeps the description inside rdb 0125\'s 4000 characters', () => {
    assert.ok(aiEventBody({ ...person, body: 'y'.repeat(9000) }, where, now).description.length <= 4000)
  })
  it('opens the event\'s week on /calendar', () => {
    assert.deepEqual(aiCalendarRoute({ starts_at: '2026-10-06T15:00:00Z' }), { path: '/calendar', query: { d: '2026-10-06' } })
    assert.deepEqual(aiCalendarRoute(null), { path: '/calendar', query: {} })
  })
  it('POSTs the body to /v1/calendar/events with the session', async () => {
    const seen = []
    const prev = globalThis.fetch
    globalThis.fetch = async (url, init) => {
      seen.push({ url, init })
      return { ok: true, status: 201, json: async () => ({ event: { id: 'e-1', starts_at: '2026-10-06T15:00:00Z' } }) }
    }
    try {
      const ev = await createCalendarEvent({ base: 'https://hub.example.com', token: 'tok', credentials: 'include' }, aiEventBody(person, where, now))
      assert.equal(ev.id, 'e-1')
    } finally {
      globalThis.fetch = prev
    }
    assert.equal(seen.length, 1)
    assert.equal(seen[0].url, 'https://hub.example.com/v1/calendar/events')
    assert.equal(seen[0].init.method, 'POST')
    assert.equal(seen[0].init.headers.authorization, 'Bearer tok')
    assert.equal(JSON.parse(seen[0].init.body).topic_id, TASK)
  })
  it('a refusal is an error, not a silent success', async () => {
    const prev = globalThis.fetch
    globalThis.fetch = async () => ({ ok: false, status: 403, json: async () => ({}) })
    try {
      await assert.rejects(createCalendarEvent({ base: 'x' }, aiEventBody(person, where, now)), /403/)
    } finally {
      globalThis.fetch = prev
    }
  })
})
