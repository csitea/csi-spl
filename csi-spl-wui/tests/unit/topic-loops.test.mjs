// Spec 182 row L3 (SPL-6034; HUM-10, t1 f08c0c58 msg 19acb8f9): a topic
// card's Discussion loops… entry, its lock (answer 5 A: the archive
// setting), the form's at-least-one-trigger rule (answer 3 B) and the mock
// twin of the routes of section 7.1.2.
// Run: node tests/unit/topic-loops.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { topicCardMenuOpts, topicMenuLocks } from '../../src/utils/topic-menu.mjs'
import { msgMenuItems } from '../../src/utils/msg-menu.mjs'
import {
  LOOP_TRIGGERS, emptyLoopForm, loopBody, loopErrorKey, loopFirstLine, loopForm, loopFormError, loopRowState, loopsFromFrame, loopTriggerLabels,
} from '../../src/utils/topic-loops.mjs'
import { mockAddTopicLoop, mockDeleteTopicLoop, mockEditTopicLoop, mockTopicLoops } from '../../src/utils/spool-client-mock.mjs'

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..')
const WHY = 'feed.msg_menu.why.'
const KEY = 'feed.topic_loops.'
const card = { msg_id: 'm1', task_id: 't1', is_parent: 1, channel: 'dev', from: 'HUM-1', from_box: 'box-wui' }
const member = { role: 'member', tenantOwner: false, topicArchivePolicy: 'everyone' }
const loopsItem = (items) => items.find((i) => i.id === 'topic-loops')

describe('the Discussion loops… entry and its lock (answer 5 A)', () => {
  it('a topic card lists it right before Archive, enabled when the archive setting allows', () => {
    const items = msgMenuItems(topicCardMenuOpts(card, 'HUM-2', member))
    const ids = items.map((i) => i.id)
    assert.equal(ids.indexOf('topic-loops') + 1, ids.indexOf('archive'))
    const it = loopsItem(items)
    assert.equal(it.labelKey, 'feed.msg_menu.topic_loops')
    assert.equal(it.disabled, undefined)
  })

  it('a viewer the setting does not allow sees it disabled with the matching reason', () => {
    const starter = { ...member, topicArchivePolicy: 'starter' }
    const admins = { ...member, topicArchivePolicy: 'admins' }
    assert.equal(topicMenuLocks(card, 'HUM-2', starter).loops, WHY + 'loops_starter')
    assert.equal(topicMenuLocks(card, 'HUM-2', admins).loops, WHY + 'loops_admins')
    const it = loopsItem(msgMenuItems(topicCardMenuOpts(card, 'HUM-2', admins)))
    assert.equal(it.disabled, true)
    assert.equal(it.hintKey, WHY + 'loops_admins')
    assert.equal(topicMenuLocks(card, 'HUM-1', starter).loops, '', 'the starter may')
  })

  it('a reply, the phone sheet and a menu without the flag have no entry', () => {
    assert.equal(topicMenuLocks({ ...card, is_parent: 0 }, 'HUM-2', member).loops, '')
    assert.equal(loopsItem(msgMenuItems({ editable: true })), undefined)
    assert.equal(loopsItem(msgMenuItems({ ...topicCardMenuOpts(card, 'HUM-1', member), touch: true })), undefined)
  })

  it('the menu emits it and the card mounts the dialog on it', () => {
    const menu = readFileSync(join(root, 'src/components/MessageMenu.vue'), 'utf8')
    assert.match(menu, /id === 'topic-loops'\) emit\('topic-loops'\)/)
    const cardSrc = readFileSync(join(root, 'src/components/MessageCard.vue'), 'utf8')
    assert.match(cardSrc, /@topic-loops="loopsOpen = true"/)
    assert.match(cardSrc, /<LazyTopicLoopsDialog\s+v-if="loopsOpen"/)
  })
})

describe('the loop form (4.1 step 2)', () => {
  const ok = { prompt: 'Export this discussion as a PDF.', triggers: ['after_agent_reply'], interval: 30 }

  it('the twelve triggers of section 1.2 (v0.4), in order', () => {
    assert.deepEqual([...LOOP_TRIGGERS], ['after_agent_reply', 'before_agent_reply', 'after_human_reply', 'before_human_reply', 'every_hour', 'every_n_minutes',
      'post_has_keyword', 'post_has_file', 'blocker_posted', 'no_reply_after_human', 'issue_status_changed', 'daily_at'])
  })

  it('at least one trigger: none checked is refused, any one is enough', () => {
    assert.equal(loopFormError({ ...ok, triggers: [] }), KEY + 'err_trigger')
    assert.equal(loopFormError(emptyLoopForm()), KEY + 'err_prompt')
    const full = { ...ok, keyword: 'pdf', idle: 15, dailyAt: '08:00', dailyTz: 'UTC' }
    for (const k of LOOP_TRIGGERS) assert.equal(loopFormError({ ...full, triggers: [k] }), '', k)
    assert.equal(loopFormError({ ...ok, triggers: ['nonsense'] }), KEY + 'err_trigger')
  })

  it('a prompt of 1..4000 characters', () => {
    assert.equal(loopFormError({ ...ok, prompt: '   ' }), KEY + 'err_prompt')
    assert.equal(loopFormError({ ...ok, prompt: 'x'.repeat(4000) }), '')
    assert.equal(loopFormError({ ...ok, prompt: 'x'.repeat(4001) }), KEY + 'err_prompt_long')
  })

  it('n of 5..1440 only with each n minutes, and only then in the body', () => {
    const n = (interval) => loopFormError({ ...ok, triggers: ['every_n_minutes'], interval })
    assert.equal(n(4), KEY + 'err_interval')
    assert.equal(n(1441), KEY + 'err_interval')
    assert.equal(n(5), '')
    assert.equal(n(1440), '')
    assert.equal(loopFormError({ ...ok, interval: 1 }), '', 'n is not read without the box')
    assert.deepEqual(loopBody({ ...ok, interval: 1 }), { prompt: ok.prompt, triggers: ['after_agent_reply'] })
    assert.deepEqual(loopBody({ prompt: ' p ', triggers: ['every_n_minutes', 'after_human_reply', 'every_n_minutes'], interval: 30 }),
      { prompt: 'p', triggers: ['after_human_reply', 'every_n_minutes'], interval_min: 30 })
  })

  it('the v0.4 fields: each required exactly with its box (keyword, idle n, time and zone)', () => {
    const one = (k, extra) => loopFormError({ ...ok, triggers: [k], ...extra })
    assert.equal(one('post_has_keyword', { keyword: '  ' }), KEY + 'err_keyword')
    assert.equal(one('post_has_keyword', { keyword: 'x'.repeat(201) }), KEY + 'err_keyword')
    assert.equal(one('post_has_keyword', { keyword: 'pdf' }), '')
    assert.equal(one('no_reply_after_human', { idle: 4 }), KEY + 'err_interval')
    assert.equal(one('no_reply_after_human', { idle: 1440 }), '')
    assert.equal(one('daily_at', { dailyAt: '24:00', dailyTz: 'UTC' }), KEY + 'err_daily_at')
    assert.equal(one('daily_at', { dailyAt: '8:00', dailyTz: 'UTC' }), KEY + 'err_daily_at')
    assert.equal(one('daily_at', { dailyAt: '08:00', dailyTz: 'Nowhere/Atlantis' }), KEY + 'err_daily_tz')
    assert.equal(one('daily_at', { dailyAt: '08:00', dailyTz: 'Europe/Helsinki' }), '')
    /* a field without its box is neither checked nor sent */
    assert.equal(loopFormError({ ...ok, keyword: '', idle: 0, dailyAt: 'x', dailyTz: 'x' }), '')
    assert.deepEqual(loopBody({ ...ok, keyword: 'pdf', idle: 15, dailyAt: '08:00', dailyTz: 'UTC' }), { prompt: ok.prompt, triggers: ['after_agent_reply'] })
    assert.deepEqual(loopBody({ prompt: 'p', triggers: ['daily_at', 'no_reply_after_human', 'post_has_keyword'], keyword: ' pdf ', idle: 15, dailyAt: '08:00', dailyTz: 'Europe/Helsinki' }),
      { prompt: 'p', triggers: ['post_has_keyword', 'no_reply_after_human', 'daily_at'], keyword: 'pdf', idle_min: 15, daily_at: '08:00', daily_tz: 'Europe/Helsinki' })
    assert.equal(emptyLoopForm('Europe/Helsinki').dailyTz, 'Europe/Helsinki', 'a new loop starts in the browser zone')
  })

  it('the list row names each box, with its value', () => {
    const labels = loopTriggerLabels({ triggers: ['daily_at', 'post_has_keyword', 'no_reply_after_human', 'every_n_minutes', 'blocker_posted'],
      keyword: 'pdf', idle_min: 15, interval_min: 30, daily_at: '08:00', daily_tz: 'Europe/Helsinki' })
    assert.deepEqual(labels, [
      [KEY + 'every_n', { n: 30 }],
      [KEY + 'keyword_row', { keyword: 'pdf' }],
      [KEY + 'trigger.blocker_posted', {}],
      [KEY + 'idle_row', { n: 15 }],
      [KEY + 'daily_row', { time: '08:00', tz: 'Europe/Helsinki' }],
    ])
  })

  it('Edit starts from the loop JSON', () => {
    const f = loopForm({ prompt: 'a\nb', triggers: ['every_n_minutes', 'x'], interval_min: 45 })
    assert.deepEqual(f, { prompt: 'a\nb', triggers: ['every_n_minutes'], interval: 45, keyword: '', idle: 30, dailyAt: '09:00', dailyTz: 'UTC' })
    const g = loopForm({ prompt: 'p', triggers: ['daily_at', 'post_has_keyword'], keyword: 'pdf', daily_at: '07:30', daily_tz: 'Europe/Helsinki' }, 'UTC')
    assert.deepEqual([g.keyword, g.dailyAt, g.dailyTz], ['pdf', '07:30', 'Europe/Helsinki'])
    assert.equal(loopFirstLine('\n  first \nsecond'), 'first')
  })
})

describe('the list row and the refusals (7.1.2)', () => {
  it('paused, idle, held and on', () => {
    assert.equal(loopRowState({ state: 'paused', held_until: 'x' }).state, 'paused')
    assert.deepEqual(loopRowState({ state: 'on', idle: 'author_left' }), { state: 'idle', until: '', why: KEY + 'idle_author_left' })
    assert.deepEqual(loopRowState({ state: 'on', idle: '', held_until: '2026-11-20T10:12:00Z' }), { state: 'held', until: '2026-11-20T10:12:00Z', why: '' })
    assert.equal(loopRowState({ state: 'on', idle: '' }).state, 'on')
  })

  it('each refusal token has its own words; anything else is the generic one', () => {
    assert.equal(loopErrorKey({ status: 400, token: 'bad_loop' }), KEY + 'err_bad_loop')
    assert.equal(loopErrorKey({ status: 403, token: 'not_allowed' }), KEY + 'err_not_allowed')
    assert.equal(loopErrorKey({ status: 409, token: 'topic_archived' }), KEY + 'err_archived')
    assert.equal(loopErrorKey({ status: 501 }), KEY + 'err_not_implemented')
    assert.equal(loopErrorKey(new Error('x')), KEY + 'err_failed')
  })

  it('a topic_loops frame for this topic only', () => {
    assert.deepEqual(loopsFromFrame({ type: 'topic_loops', task_id: 't1', loops: [{ loop_id: 'a' }] }, 't1'), [{ loop_id: 'a' }])
    assert.equal(loopsFromFrame({ type: 'topic_loops', task_id: 't2', loops: [] }, 't1'), null)
    assert.equal(loopsFromFrame({ type: 'topic_priority', task_id: 't1' }, 't1'), null)
  })

  it('every key the dialog and the utils name is in en.json', () => {
    const en = JSON.parse(readFileSync(join(root, 'i18n/locales/en.json'), 'utf8'))
    const dialog = readFileSync(join(root, 'src/components/TopicLoopsDialog.vue'), 'utf8')
    const utils = readFileSync(join(root, 'src/utils/topic-loops.mjs'), 'utf8')
    const keys = new Set([...dialog.matchAll(/'feed\.topic_loops\.([a-z_]+)'/g)].map((m) => m[1]))
    /* a prefix such as KEY + 'idle_' + reason is covered by the idle_* line below */
    for (const m of utils.matchAll(/KEY \+ '([a-z_]+)'(?! \+)/g)) keys.add(m[1])
    for (const m of utils.matchAll(/: '(err_[a-z_]+)'/g)) keys.add(m[1])
    for (const k of keys) assert.equal(typeof en.feed.topic_loops[k], 'string', k)
    for (const k of LOOP_TRIGGERS) assert.equal(typeof en.feed.topic_loops.trigger[k], 'string', k)
    for (const k of ['idle_author_left', 'idle_author_no_right', 'every_n', 'keyword_row', 'idle_row', 'daily_row']) assert.equal(typeof en.feed.topic_loops[k], 'string', k)
    assert.equal(typeof en.feed.msg_menu.topic_loops, 'string')
  })
})

describe('the mock routes (7.1.2), before the hub serves them', () => {
  const state = () => ({ me: { id: 'HUM-1' }, messages: [] })

  it('add, list, edit, pause, delete', () => {
    const s = state()
    assert.deepEqual(mockTopicLoops(s, 't1'), { task_id: 't1', may_edit: true, loops: [] })
    const a = mockAddTopicLoop(s, 't1', { prompt: 'p', triggers: ['every_n_minutes'], interval_min: 30 })
    assert.equal(a.state, 'on')
    assert.equal(a.interval_min, 30)
    assert.ok(a.next_due_at, 'a time trigger has a next fire')
    assert.equal(a.set_by, 'HUM-1')
    assert.equal(mockTopicLoops(s, 't1').loops.length, 1)
    const e = mockEditTopicLoop(s, 't1', a.loop_id, { triggers: ['after_human_reply'] })
    assert.deepEqual(e.triggers, ['after_human_reply'])
    assert.equal(e.interval_min, undefined, 'interval_min leaves with its trigger')
    assert.equal(e.next_due_at, undefined)
    assert.equal(mockEditTopicLoop(s, 't1', a.loop_id, { state: 'paused' }).state, 'paused')
    const d = mockEditTopicLoop(s, 't1', a.loop_id, { triggers: ['daily_at', 'post_has_keyword'], keyword: 'pdf', daily_at: '08:00', daily_tz: 'Europe/Helsinki', state: 'on' })
    assert.deepEqual([d.keyword, d.daily_at, d.daily_tz, Boolean(d.daily_due_at)], ['pdf', '08:00', 'Europe/Helsinki', true])
    assert.throws(() => mockEditTopicLoop(s, 't1', a.loop_id, { triggers: ['no_reply_after_human'] }), (e) => e.status === 400, 'idle n missing')
    const i = mockEditTopicLoop(s, 't1', a.loop_id, { triggers: ['no_reply_after_human'], idle_min: 20 })
    assert.equal(i.idle_min, 20)
    assert.equal(i.keyword, undefined, 'the keyword leaves with its box')
    assert.equal(i.daily_due_at, undefined)
    assert.deepEqual(mockDeleteTopicLoop(s, 't1', a.loop_id), { loop_id: a.loop_id, deleted: true })
    assert.deepEqual(mockDeleteTopicLoop(s, 't1', a.loop_id), { loop_id: a.loop_id, deleted: false }, 'idempotent')
  })

  it('refuses a loop with no trigger (400 bad_loop) and a missing loop (404)', () => {
    const s = state()
    assert.throws(() => mockAddTopicLoop(s, 't1', { prompt: 'p', triggers: [] }), (e) => e.status === 400 && e.token === 'bad_loop')
    assert.throws(() => mockEditTopicLoop(s, 't1', 'nope', { state: 'paused' }), (e) => e.status === 404)
  })
})
