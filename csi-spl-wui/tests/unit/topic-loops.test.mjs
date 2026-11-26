// Spec 182 row L3 (SPL-6034; HUM-10, t1 f08c0c58 msg 19acb8f9): a topic
// card's Discussion loops… entry, its lock (answer 5 A: the archive
// setting), the form's one-trigger rule (v0.11, HUM-10 t1 6e8c1cdb msg
// febf1db4, reversing answer 3 B), the title each trigger gives its loop
// (msgs 543a5bde, a04bba37) and the mock twin of the routes of section 7.1.2.
// Run: node tests/unit/topic-loops.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { topicCardMenuOpts, topicMenuLocks } from '../../src/utils/topic-menu.mjs'
import { msgMenuItems } from '../../src/utils/msg-menu.mjs'
import {
  LOOP_TRIGGERS, emptyLoopForm, formLoop, formOthersLoop, loopBody, loopErrorKey, loopFirstLine, loopForm, loopFormError, loopRowState, loopsFromFrame, loopTitle, loopTriggerLabels,
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
  const ok = { prompt: 'Export this discussion as a PDF.', trigger: 'after_agent_reply', interval: 30 }

  it('the twelve triggers of section 1.2 (v0.6, Q11 C; v0.11 change 9 splits the file one by poster), in order', () => {
    assert.deepEqual([...LOOP_TRIGGERS], ['after_agent_reply', 'before_agent_reply', 'after_human_reply', 'every_hour', 'every_n_minutes',
      'post_has_keyword', 'post_has_file_agent', 'post_has_file_human', 'blocker_posted', 'no_reply_after_human', 'issue_status_changed', 'daily_at'])
  })

  it('the old file trigger (v0.11 change 9): not offered, refused in a save, but a stored loop keeps it and its title', () => {
    assert.equal(loopFormError({ ...ok, trigger: 'post_has_file' }), KEY + 'err_trigger')
    const old = loopForm({ prompt: 'p', triggers: ['post_has_file'] })
    assert.equal(old.trigger, 'post_has_file', 'the Edit form opens on it')
    assert.deepEqual(loopTriggerLabels({ triggers: ['post_has_file'] }), [[KEY + 'trigger.post_has_file', {}]])
  })

  it('exactly one trigger (v0.11): none is refused, each one alone is enough', () => {
    assert.equal(loopFormError({ ...ok, trigger: '' }), KEY + 'err_trigger')
    assert.equal(loopFormError({ ...emptyLoopForm(), prompt: 'p' }), KEY + 'err_trigger', 'a new form has no trigger picked')
    assert.equal(loopFormError(emptyLoopForm()), KEY + 'err_prompt')
    const full = { ...ok, keyword: 'pdf', idle: 15, dailyAt: '08:00', dailyTz: 'UTC' }
    for (const k of LOOP_TRIGGERS) assert.equal(loopFormError({ ...full, trigger: k }), '', k)
    assert.equal(loopFormError({ ...ok, trigger: 'nonsense' }), KEY + 'err_trigger')
    /* the body always carries the one trigger, whatever else the form holds */
    for (const k of LOOP_TRIGGERS) assert.deepEqual(loopBody({ ...full, trigger: k, others: ['blocker_posted'] }).triggers, [k], k)
  })

  it('a prompt of 1..4000 characters', () => {
    assert.equal(loopFormError({ ...ok, prompt: '   ' }), KEY + 'err_prompt')
    assert.equal(loopFormError({ ...ok, prompt: 'x'.repeat(4000) }), '')
    assert.equal(loopFormError({ ...ok, prompt: 'x'.repeat(4001) }), KEY + 'err_prompt_long')
  })

  it('n of 5..1440 only with each n minutes, and only then in the body', () => {
    const n = (interval) => loopFormError({ ...ok, trigger: 'every_n_minutes', interval })
    assert.equal(n(4), KEY + 'err_interval')
    assert.equal(n(1441), KEY + 'err_interval')
    assert.equal(n(5), '')
    assert.equal(n(1440), '')
    assert.equal(loopFormError({ ...ok, interval: 1 }), '', 'n is not read without the box')
    assert.deepEqual(loopBody({ ...ok, interval: 1 }), { prompt: ok.prompt, triggers: ['after_agent_reply'] })
    assert.deepEqual(loopBody({ prompt: ' p ', trigger: 'every_n_minutes', interval: 30 }),
      { prompt: 'p', triggers: ['every_n_minutes'], interval_min: 30 })
  })

  it('the v0.4 fields: each required exactly with its box (keyword, idle n, time and zone)', () => {
    const one = (k, extra) => loopFormError({ ...ok, trigger: k, ...extra })
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
    assert.deepEqual(loopBody({ prompt: 'p', trigger: 'daily_at', keyword: ' pdf ', idle: 15, dailyAt: '08:00', dailyTz: 'Europe/Helsinki' }),
      { prompt: 'p', triggers: ['daily_at'], daily_at: '08:00', daily_tz: 'Europe/Helsinki' })
    assert.deepEqual(loopBody({ prompt: 'p', trigger: 'post_has_keyword', keyword: ' pdf ', idle: 15 }), { prompt: 'p', triggers: ['post_has_keyword'], keyword: 'pdf' })
    assert.deepEqual(loopBody({ prompt: 'p', trigger: 'no_reply_after_human', keyword: 'pdf', idle: 15 }), { prompt: 'p', triggers: ['no_reply_after_human'], idle_min: 15 })
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

  it('Edit starts from the loop JSON; a loop stored with several triggers opens on the first and names the rest', () => {
    const f = loopForm({ prompt: 'a\nb', triggers: ['every_n_minutes', 'x'], interval_min: 45 })
    assert.deepEqual(f, { prompt: 'a\nb', trigger: 'every_n_minutes', others: [], interval: 45, keyword: '', idle: 30, dailyAt: '09:00', dailyTz: 'UTC' })
    const g = loopForm({ prompt: 'p', triggers: ['daily_at', 'post_has_keyword'], keyword: 'pdf', daily_at: '07:30', daily_tz: 'Europe/Helsinki' }, 'UTC')
    assert.deepEqual([g.trigger, g.others, g.keyword, g.dailyAt, g.dailyTz], ['post_has_keyword', ['daily_at'], 'pdf', '07:30', 'Europe/Helsinki'])
    assert.deepEqual(loopBody(g), { prompt: 'p', triggers: ['post_has_keyword'], keyword: 'pdf' }, 'a save keeps the one chosen')
    assert.equal(loopFirstLine('\n  first \nsecond'), 'first')
  })
})

describe('the trigger names the loop (v0.11, change 1)', () => {
  const en = JSON.parse(readFileSync(join(root, 'i18n/locales/en.json'), 'utf8'))
  /* vue-i18n's t over en.json, enough for {name} params */
  const t = (key, params = {}) => String(key.split('.').reduce((o, k) => o?.[k], en)).replace(/\{(\w+)\}/g, (_, k) => String(params[k]))
  const fields = { interval: 30, keyword: 'deploy', idle: 15, dailyAt: '09:00', dailyTz: 'Europe/Amsterdam' }
  const want = {
    after_agent_reply: 'After each agent reply',
    before_agent_reply: 'Before each agent reply',
    after_human_reply: 'After each human reply',
    every_hour: 'Every hour',
    every_n_minutes: 'Every 30 minutes',
    post_has_keyword: 'A post that contains \u201cdeploy\u201d',
    post_has_file_agent: 'After an agent post with one or more files attached',
    post_has_file_human: 'After a human post with one or more files attached',
    blocker_posted: 'A blocker posted in the topic',
    no_reply_after_human: 'No reply for 15 minutes after a human post',
    issue_status_changed: 'An issue linked to the topic changes status',
    daily_at: 'Every day at 09:00 (Europe/Amsterdam)',
  }

  it('each trigger picked in the form is the title at once, with its parameter', () => {
    assert.deepEqual(Object.keys(want), [...LOOP_TRIGGERS], 'every trigger has its title case')
    for (const k of LOOP_TRIGGERS) assert.equal(loopTitle(formLoop({ ...fields, trigger: k }), t, 'en'), want[k], k)
    assert.equal(loopTitle(formLoop({ ...fields, trigger: '' }), t, 'en'), '', 'no pick, no title')
  })

  it('the saved loop has the same title as its form had', () => {
    for (const k of LOOP_TRIGGERS) {
      const form = { ...fields, prompt: 'say hello', trigger: k }
      assert.equal(loopTitle(loopBody(form), t, 'en'), loopTitle(formLoop(form), t, 'en'), k)
    }
  })

  it('the multi-trigger note names each kept trigger with its parameter (R7 N1)', () => {
    const form = loopForm({ triggers: ['after_agent_reply', 'every_n_minutes', 'post_has_keyword', 'daily_at'], interval_min: 10, keyword: 'deploy', daily_at: '21:30', daily_tz: 'UTC' })
    assert.deepEqual(form.others, ['every_n_minutes', 'post_has_keyword', 'daily_at'])
    assert.equal(loopTitle(formOthersLoop(form), t, 'en'), 'Every 10 minutes, a post that contains \u201cdeploy\u201d, every day at 21:30 (UTC)')
  })

  it('a loop stored with several triggers names them all; the first letter follows the locale', () => {
    assert.equal(loopTitle({ triggers: ['every_n_minutes', 'blocker_posted'], interval_min: 10 }, t, 'en'), 'Every 10 minutes, A blocker posted in the topic')
    assert.equal(loopTitle({ triggers: [] }, t, 'en'), '')
    assert.equal(loopTitle({ triggers: ['every_hour'] }, () => 'ilk', 'tr'), '\u0130lk', 'Turkish dotted capital I')
  })

  it('the list row shows the title, then the prompt line', () => {
    const dialog = readFileSync(join(root, 'src/components/TopicLoopsDialog.vue'), 'utf8')
    assert.match(dialog, /data-testid="topic-loops-row-title">\{\{ loopTitle\(l, t, locale\) \}\}/)
    assert.match(dialog, /data-testid="topic-loops-row-prompt">\{\{ loopFirstLine\(l\.prompt\) \}\}/)
    assert.match(dialog, /v-model="form\.trigger" type="radio" name="topic-loops-trigger"/)
    assert.doesNotMatch(dialog, /type="checkbox"/, 'no trigger checkbox is left')
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
    for (const k of [...LOOP_TRIGGERS, 'post_has_file']) assert.equal(typeof en.feed.topic_loops.trigger[k], 'string', k)
    for (const k of ['idle_author_left', 'idle_author_no_right', 'every_n', 'keyword_row', 'idle_row', 'daily_row']) assert.equal(typeof en.feed.topic_loops[k], 'string', k)
    assert.equal(typeof en.feed.msg_menu.topic_loops, 'string')
  })
})

describe('the mock routes (7.1.2), before the hub serves them', () => {
  const state = () => ({ me: { id: 'HUM-1' }, messages: [] })

  it('a loop stored with several triggers keeps them through a pause and a prompt edit (no silent loss)', () => {
    const s = state()
    s.loops = { t1: [{ loop_id: 'old', task_id: 't1', prompt: 'p', triggers: ['blocker_posted', 'post_has_keyword'], keyword: 'pdf', state: 'on', set_by: 'HUM-1', fires_in_hour: 0, idle: '' }] }
    const paused = mockEditTopicLoop(s, 't1', 'old', { state: 'paused' })
    assert.deepEqual([paused.triggers, paused.keyword, paused.state], [['blocker_posted', 'post_has_keyword'], 'pdf', 'paused'])
    const prompt = mockEditTopicLoop(s, 't1', 'old', { prompt: 'q' })
    assert.deepEqual([prompt.triggers, prompt.keyword], [['blocker_posted', 'post_has_keyword'], 'pdf'])
    const one = mockEditTopicLoop(s, 't1', 'old', { triggers: ['blocker_posted'] })
    assert.deepEqual([one.triggers, one.keyword], [['blocker_posted'], undefined], 'a save that sends its one trigger narrows it')
  })

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
    const d = mockEditTopicLoop(s, 't1', a.loop_id, { triggers: ['daily_at'], daily_at: '08:00', daily_tz: 'Europe/Helsinki', state: 'on' })
    assert.deepEqual([d.daily_at, d.daily_tz, Boolean(d.daily_due_at)], ['08:00', 'Europe/Helsinki', true])
    assert.throws(() => mockEditTopicLoop(s, 't1', a.loop_id, { triggers: ['no_reply_after_human'] }), (e) => e.status === 400, 'idle n missing')
    const i = mockEditTopicLoop(s, 't1', a.loop_id, { triggers: ['no_reply_after_human'], idle_min: 20 })
    assert.equal(i.idle_min, 20)
    assert.equal(i.daily_at, undefined, 'the time leaves with its trigger')
    assert.equal(i.daily_due_at, undefined)
    assert.deepEqual(mockDeleteTopicLoop(s, 't1', a.loop_id), { loop_id: a.loop_id, deleted: true })
    assert.deepEqual(mockDeleteTopicLoop(s, 't1', a.loop_id), { loop_id: a.loop_id, deleted: false }, 'idempotent')
  })

  it('refuses a loop with no trigger or several (400 bad_loop, v0.11) and a missing loop (404)', () => {
    const s = state()
    assert.throws(() => mockAddTopicLoop(s, 't1', { prompt: 'p', triggers: [] }), (e) => e.status === 400 && e.token === 'bad_loop')
    assert.throws(() => mockAddTopicLoop(s, 't1', { prompt: 'p', triggers: ['every_hour', 'blocker_posted'] }), (e) => e.status === 400 && e.token === 'bad_loop')
    const a = mockAddTopicLoop(s, 't1', { prompt: 'p', triggers: ['every_hour'] })
    assert.throws(() => mockEditTopicLoop(s, 't1', a.loop_id, { triggers: ['every_hour', 'blocker_posted'] }), (e) => e.status === 400 && e.token === 'bad_loop')
    assert.throws(() => mockEditTopicLoop(s, 't1', 'nope', { state: 'paused' }), (e) => e.status === 404)
  })
})
