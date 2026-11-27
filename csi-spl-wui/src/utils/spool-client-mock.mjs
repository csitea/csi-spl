/**
 * The mock tenant's answers to the client's first-screen reads and its send
 * (NUXT_PUBLIC_USE_MOCK=1: lde and the e2e bundle). spool-client.mjs reaches
 * this module only through import(), so none of it rides the initial JS
 * (ci_initial_gzip_kb, 027 perf-budgets.json; the act-as-mock.mjs pattern).
 * `state` is the client's cloned mock data (mock-data.mjs); each function
 * reads or appends to it exactly as the inline branches did.
 */
import { belongsTo } from './channel-feed.mjs'
import { mockDmPointers } from './dm-pointer.mjs'
import { isAgentId } from './agent-id.mjs'
import { topicMessages, topicsFromMessages } from './view-api.mjs'
import { storageGetJson } from './prefs.mjs'
import { mockReadFault } from './plain-error.mjs'
import { isPublicChannel, normalizeChannelId } from './spool-client.mjs'
import { mentionedIds } from './notify.mjs'
import { mockBoxSendRefusal } from './box-lock.mjs'
import { TOPIC_PRIORITY_DEFAULT } from './topic-list-order.mjs'
import { LOOP_KEYS, loopBody, loopFormError } from './topic-loops.mjs'

/** The priorities set in this mock, over the e2e hook `spool.mock.priorities`
    = { <task_id>: 1..5 } (spec 189 B5: a channel that holds unread P1 cards). */
function mockPriorities(state) {
  const seeded = storageGetJson('spool.mock.priorities', null)
  return { ...(seeded && typeof seeded === 'object' ? seeded : {}), ...(state.priorities || {}) }
}

/** view-v1 §4.3 over the mock messages: one row per topic, no server pages. */
export function mockListTopics(state, { limit = 50, channel, dm, peer } = {}) {
  let rows = state.messages.slice()
  if (channel) rows = rows.filter((m) => m.channel === channel)
  else if (dm) rows = rows.filter((m) => !m.channel)
  if (peer) {
    const [id] = String(peer).split('@')
    rows = rows.filter((m) => m.from === id || m.to === id)
  }
  /* spec 150 B3: each row carries its priority, 3 when nobody set it */
  const prio = mockPriorities(state)
  const topics = topicsFromMessages(rows).slice(0, limit).map((t) => ({ ...t, priority: prio[t.task_id] || TOPIC_PRIORITY_DEFAULT }))
  return { topics, next: null }
}

/** view-v1 §4.4 over the mock messages, `order: 'desc'` paged by `before`. */
export function mockGetTopic(state, id, { limit = 200, after, order, before, viewToken } = {}) {
  mockReadFault('topic') // SPL-1839 e2e hook: `spool.mock.read-fault`
  /* e2e hook (topic-view-door): `spool.mock.view-door` = { detail } stands in
     for a hub whose door this session does not open (view-v1 section 2): a
     401 view_door until a view token is set */
  const door = storageGetJson('spool.mock.view-door', null)
  if (door && !viewToken) throw Object.assign(new Error('spool 401 view_door'), { status: 401, token: 'view_door', detail: String(door.detail || '') })
  /* e2e hook (topic-moved-link): `spool.mock.moved-topics` = { <task_id>: <link> }
     stands in for the hub's 404 topic_moved of a moved channel's topic (spec 169 W5) */
  const moved = storageGetJson('spool.mock.moved-topics', null)
  if (moved && typeof moved[id] === 'string') return { task_id: id, messages: [], next: null, moved_to: moved[id] }
  /* t1 404cd808: the hub's topic read keeps the topic's own archived
     card (only the lobby feed hides archived rows), so the mock does too */
  const all = topicMessages([...state.messages, ...(state.archived || [])], id)
  /* t1 8fb802cd: the hub's archive stamp, as its own rule reads it */
  const arch = (state.archived || []).find((m) => m.archived_at && (m.msg_id === id || m.task_id === id))
  const stamp = arch && !after ? { archived_at: arch.archived_at, archived_by: arch.archived_by } : {}
  /* spec 150 B3: the hub's topic read carries its priority, 3 when nobody set it */
  stamp.priority = mockPriorities(state)[id] || TOPIC_PRIORITY_DEFAULT
  if (order !== 'desc') return { task_id: id, messages: all, next: null, ...stamp }
  const desc = all.slice().reverse()
  const start = before ? desc.findIndex((m) => m.msg_id === before) + 1 : 0
  const page = desc.slice(start, start + limit)
  const more = start + limit < desc.length
  return { task_id: id, messages: page, next: more && page.length ? page[page.length - 1].msg_id : null, ...stamp }
}

/** The flat messages of a channel or a DM peer, oldest first; mock has no server pages. */
export function mockListMessages(state, { channel, peer, limit = 50, since } = {}) {
  mockReadFault('list') // SPL-1839 e2e hook: `spool.mock.read-fault`
  /* the same test hook, read again: a line an e2e adds after boot is
     held as the hub would hold a reply its socket just delivered */
  const extra = storageGetJson('spool.mock.extra-messages', [])
  if (Array.isArray(extra)) {
    const held = new Set(state.messages.map((m) => m.msg_id))
    /* an archived card (archived_at) was filed under state.archived at boot */
    state.messages.push(...extra.filter((m) => m && m.msg_id && !m.archived_at && !held.has(m.msg_id)))
  }
  let rows = state.messages.slice()
  if (channel) rows = rows.filter((m) => m.channel === channel)
  /* specs/058: a DM is per <ID>@<box>, as the hub's peer filter is */
  /* dc6d5e3f: plus the channel lines between me and that agent, as pointers */
  else if (peer) rows = [...rows.filter((m) => belongsTo(m, { peer: String(peer) })), ...mockDmPointers(rows, state.me && state.me.id, String(peer))]
  if (since) rows = rows.filter((m) => m.ts > since)
  /* SPL-6205: the cap keeps the newest `limit` lines but never a topic's
     opening line, as the live listMessages does (spool-client.mjs): a topic
     longer than the cap keeps its middle card. Only a topic ROOT counts as
     an opening line (is_parent 1, or msg_id = task_id): an old reply that is
     its task's first held row stays outside the window, as live, where the
     opener is read only for a topic the page lists */
  const isRoot = (m) => Number(m.is_parent) === 1 || Boolean(m.msg_id && m.msg_id === m.task_id)
  const openers = new Set()
  const seenTask = new Set()
  for (const m of rows) {
    if (!m || !m.task_id || seenTask.has(m.task_id)) continue
    seenTask.add(m.task_id)
    if (isRoot(m)) openers.add(m)
  }
  const cut = rows.length - limit
  return { messages: rows.filter((m, i) => i >= cut || openers.has(m)), next: null, ...seededTotals(rows) }
}

/** spec 189 B5: the e2e hook's priorities ride on the feed read as the hub's
    topic totals do (spec 150 B6); nothing when the hook is unset. */
function seededTotals(rows) {
  const seeded = storageGetJson('spool.mock.priorities', null)
  if (!seeded || typeof seeded !== 'object') return {}
  const held = new Set(rows.map((m) => m && m.task_id))
  const totals = {}
  for (const [id, n] of Object.entries(seeded)) if (held.has(id)) totals[id] = { count: 0, last_ts: '', priority: n }
  return { totals }
}

/**
 * The mock's send: the row the hub's insert would store, appended to the
 * mock messages. `p` is sendMessage's arguments plus its parsed post
 * (to, toBox, kind, body); `uuid` is the client's id maker.
 */
export function mockSendMessage(state, p, uuid) {
  const { channel, task_id, parent_task_id, is_parent, files, msg_id, mc_id, to, toBox, kind, body } = p
  /* 080 T006: the hub de-dupes by msg_id, so a resend of a held send
     (same msg_id) stores nothing new - the mock does the same */
  const dup = msg_id ? state.messages.find((m) => m.msg_id === msg_id) : null
  if (dup) return dup
  /* spec 186 7.1.1: a multicast copy goes into an existing channel topic only */
  if (mc_id) mockMulticastDoor(state, task_id, is_parent)
  /* spec 117 FR-1: a reply with no channel and no `to` into a topic that has
     no single other end names nobody to deliver it to, and the hub refuses it
     (400 dm_needs_to). With one other end the hub re-addresses it; the mock
     stores it as sent, so a reply the WUI did not address still shows. */
  /* FR-2: a new channel-less root with no `to` (no topic yet, or one with
     no rows) is refused the same way: a new topic belongs in a channel or
     goes to a person (22f73584 was readable by its author only) */
  const topic = task_id || parent_task_id
  if (!channel && (!to || to === '@channel')) {
    const rows = topic ? state.messages.filter((m) => m.task_id === topic || m.parent_task_id === topic) : []
    const ends = new Set(rows.flatMap((m) => [m.from, m.to]).filter((i) => i && i !== state.me.id && i !== 'ALL-0' && i !== '@channel'))
    if (!rows.length || ends.size !== 1) throw Object.assign(new Error('say who this is for'), { status: 400, token: 'dm_needs_to' })
  }
  /* spec 068: what the hub's insert stores - <to>@<to_box> for a
     message to one agent; the mock reads a bare peer's box off the roster */
  const seatBox = toBox || Object.keys(state.roster || {}).find((b) => (state.roster[b] || []).includes(to))
  /* spec 025 box owner lock (B8): the hub's 403 box_locked, under the e2e hook `spool.mock.box-lock` */
  if (isAgentId(to)) mockBoxSendRefusal(state.me.id, seatBox)
  const row = {
    v: 1,
    msg_id: msg_id || uuid(),
    task_id: task_id || uuid(),
    ts: new Date().toISOString(),
    from: state.me.id,
    from_box: state.me.box,
    to,
    to_box: toBox,
    kind,
    body,
    files: files || [],
    channel: channel || null,
    parent_task_id: parent_task_id || null,
    ...(is_parent === 0 || is_parent === 1 ? { is_parent } : {}),
    ...(isAgentId(to) && seatBox ? { responsible: `${to}@${seatBox}` } : {}),
  }
  if (mockNoteToSelf(state.me.id, to, body)) row.note_to_self = true
  state.messages.push(row)
  /* 7.1.3: the hub keeps mc_id in a column, on neither the row nor the frame */
  if (mc_id) (state.multicast ||= {})[row.msg_id] = String(mc_id)
  mockNoteNonMembers(state, row)
  return row
}

/**
 * Spec 042 "Note to self", the mock twin of the hub's isNoteToSelf
 * (internal/hub/note_to_self.go): a person's post addressed only to the
 * person (its @mentions, and `to` when it is a person: a leading @tag is
 * sent as the addressee). The mock has no linked accounts.
 */
export function mockNoteToSelf(me, to, body) {
  const ids = [...mentionedIds(body), ...(PERSON_RE.test(String(to || '')) ? [to] : [])]
  return PERSON_RE.test(me) && ids.length > 0 && ids.every((id) => id === me)
}

/** A person's seat id (store.IsFlowMember): only people can be outside a channel's read door. */
const PERSON_RE = /^(HUM|GST)-[0-9]+$/

/** The hub's unnamedPerson: a person with no name and no sign-in address on file. */
const UNNAMED_PERSON = 'a person with no name on file'

/**
 * SPL-2426, the hub's mentionNames over the mock's humans: the display name,
 * else the part before @ of the sign-in address, else UNNAMED_PERSON; never
 * the bare id.
 */
export function mockPersonName(state, id) {
  const h = (state.humans || []).find((x) => x.human_id === id) || {}
  const name = String(h.display_name || '').trim() || String(h.email || '').trim().split('@')[0]
  return name || UNNAMED_PERSON
}

/** The hub's mentionNonMemberBody: "A", "A and B", "A, B and C". */
function namesList(names) {
  return names.length > 1 ? `${names.slice(0, -1).join(', ')} and ${names[names.length - 1]}` : names.join('')
}

/**
 * SPL-2419, the mock twin of the hub's noteMentionNonMembers
 * (internal/hub/mention_non_member.go): after a post in a members-only
 * channel that @mentions people who are not members, one automatic HUB-0
 * line in the same topic names them, by name (SPL-2426). The words are the
 * hub's, verbatim.
 */
export function mockNoteNonMembers(state, row) {
  const channel = normalizeChannelId(row.channel)
  if (!channel || isPublicChannel(channel)) return null
  const inside = new Set([state.me.id, ...((state.memberships || {})[channel] || [])])
  const ids = [...new Set(mentionedIds(row.body))].filter((id) => PERSON_RE.test(id) && !inside.has(id))
  if (!ids.length) return null
  const verb = ids.length > 1 ? 'do not belong' : 'does not belong'
  const note = {
    v: 1, msg_id: `${row.msg_id}-non-member`, task_id: row.task_id, ts: row.ts, from: 'HUB-0', from_box: 'box-wui',
    to: 'ALL-0', to_box: 'box-wui', kind: 'note', files: [], channel: row.channel, parent_task_id: null, is_parent: 0,
    body: `${namesList(ids.map((id) => mockPersonName(state, id)))} ${verb} to this channel and cannot see these messages.`,
  }
  state.messages.push(note)
  return note
}

/** The mock hub's fanout: a BroadcastChannel, so another tab of this browser gets the frame (spec 150 C309). */
const MOCK_LIVE_CHANNEL = 'spool.mock.live'

function mockLive() {
  return typeof BroadcastChannel === 'function' ? new BroadcastChannel(MOCK_LIVE_CHANNEL) : null
}

/**
 * Spec 150 row B7, the mock twin of PUT /v1/topics/{task_id}/priority: 400
 * outside 1..5; e2e hook `spool.mock.priority-fault` = a token (e.g.
 * not_allowed) answers 403 with it, as the hub refuses by the archive
 * policy. Sends the `topic_priority` frame to the browser's other tabs.
 */
export function mockSetTopicPriority(state, id, priority) {
  const fault = storageGetJson('spool.mock.priority-fault', null)
  if (fault) throw Object.assign(new Error(`spool 403 ${fault}`), { status: 403, token: String(fault) })
  const n = Number(priority)
  if (!Number.isInteger(n) || n < 1 || n > 5) throw Object.assign(new Error('priority must be 1..5'), { status: 400, token: 'bad_json' })
  state.priorities = { ...(state.priorities || {}), [id]: n }
  const out = { task_id: id, priority: n, set_by: state.me.id, set_at: new Date().toISOString() }
  const bc = mockLive()
  if (bc) {
    bc.postMessage({ type: 'topic_priority', task_id: id, priority: n })
    bc.close()
  }
  return out
}

/** The receiving side: fn(task_id, priority) for each frame another tab sends. */
export function mockOnTopicPriority(fn) {
  const bc = mockLive()
  if (!bc) return
  bc.onmessage = (e) => {
    const f = e && e.data
    if (f && f.type === 'topic_priority') fn(f.task_id, f.priority)
  }
}

/*
 * Spec 182 row L3 (SPL-6034), the mock twin of the loop routes of section
 * 7.1.2 (GET / POST /v1/topics/{task_id}/loops, PUT / DELETE
 * .../loops/{loop_id}, PUT .../loops/order of v0.11 change 8), so the dialog works before the hub (row L2) serves
 * them. `state.loops` is task_id -> loops. A write is checked with the
 * form's rule (400 bad_loop) and sends the `topic_loops` frame to the
 * browser's other tabs. e2e hook `spool.mock.loops-fault` = a token (e.g.
 * not_allowed) refuses every write with 403 and answers may_edit false.
 */
function mockLoopsOf(state, taskId) {
  state.loops = state.loops || {}
  return (state.loops[taskId] ||= [])
}

function mockLoopFault() {
  const fault = storageGetJson('spool.mock.loops-fault', null)
  if (fault) throw Object.assign(new Error(`spool 403 ${fault}`), { status: 403, token: String(fault) })
}

function mockLoopTell(taskId, loops) {
  const bc = mockLive()
  if (!bc) return
  bc.postMessage({ type: 'topic_loops', task_id: taskId, loops })
  bc.close()
}

/**
 * A route body (7.1.2) over the loop it edits, as the form of topic-loops.mjs.
 * v0.11: `others` keeps the extra triggers of a loop stored with several,
 * while the body does not send triggers (a pause / resume keeps them).
 */
function mockLoopForm(body, old = {}) {
  const b = body && typeof body === 'object' ? body : {}
  const pick = (k) => (b[k] !== undefined ? b[k] : old[k])
  const [trigger = '', ...others] = Array.isArray(pick('triggers')) ? pick('triggers').map(String) : []
  return {
    prompt: pick('prompt'), trigger, others: b.triggers !== undefined ? [] : others, sent: b.triggers, interval: pick('interval_min'), keyword: pick('keyword'),
    idle: pick('idle_min'), dailyAt: pick('daily_at'), dailyTz: pick('daily_tz') || 'UTC',
  }
}

/** MOCK ONLY: the next hh:mm in UTC (the hub computes it in daily_tz) */
function mockNextDaily(hhmm) {
  const [h, m] = String(hhmm).split(':').map(Number)
  const d = new Date()
  d.setUTCHours(h, m, 0, 0)
  if (d.getTime() <= Date.now()) d.setUTCDate(d.getUTCDate() + 1)
  return d.toISOString()
}

const MOCK_LOOP_FIELDS = ['interval_min', 'next_due_at', 'keyword', 'idle_min', 'daily_at', 'daily_tz', 'daily_due_at']

/** The loop JSON of 7.1.2 from a checked form and the row it replaces: each field only with its box. */
function mockLoopRow(form, old) {
  const body = { triggers: [] }
  for (const trigger of [form.trigger, ...(form.others || [])]) {
    const one = loopBody({ ...form, trigger })
    Object.assign(body, one, { triggers: [...body.triggers, ...one.triggers] })
  }
  const row = { ...old, prompt: body.prompt, triggers: body.triggers }
  for (const k of MOCK_LOOP_FIELDS) delete row[k]
  for (const k of ['interval_min', 'keyword', 'idle_min', 'daily_at', 'daily_tz']) if (body[k] !== undefined) row[k] = body[k]
  if (body.daily_at && row.state !== 'paused') row.daily_due_at = mockNextDaily(body.daily_at)
  const every = body.interval_min || (body.triggers.includes('every_hour') ? 60 : 0)
  if (every && row.state !== 'paused') row.next_due_at = new Date(Date.now() + Math.min(every, 60) * 60000).toISOString()
  return row
}

/* v0.11: a write that sends triggers sends exactly one (the hub's 400 bad_loop);
   one that leaves them out keeps the stored ones, a retired key such as
   post_has_file too (change 9, as the hub's store does) */
function mockLoopBad(form) {
  const several = Array.isArray(form.sent) && new Set(form.sent).size !== 1
  const err = loopFormError(form)
  const kept = form.sent === undefined && err === 'feed.topic_loops.err_trigger' && LOOP_KEYS.includes(form.trigger)
  if (several || (err && !kept)) throw Object.assign(new Error('bad loop'), { status: 400, token: 'bad_loop' })
}

/** GET: { task_id, may_edit, loops } */
export function mockTopicLoops(state, taskId) {
  const fault = storageGetJson('spool.mock.loops-fault', null)
  return { task_id: taskId, may_edit: !fault, loops: mockLoopsOf(state, taskId).slice() }
}

/** POST: 201 <loop> */
export function mockAddTopicLoop(state, taskId, body) {
  mockLoopFault()
  const form = mockLoopForm(body)
  mockLoopBad(form)
  const loop_id = typeof crypto !== 'undefined' && crypto.randomUUID ? crypto.randomUUID() : `loop-${Date.now()}`
  const base = { loop_id, task_id: taskId, state: 'on', set_by: state.me.id, set_at: new Date().toISOString(), fires_in_hour: 0, idle: '' }
  const row = mockLoopRow(form, base)
  const list = mockLoopsOf(state, taskId)
  list.push(row)
  mockLoopTell(taskId, list.slice())
  return row
}

/** PUT: any of prompt, triggers, interval_min, state; the editor becomes the author (4.5) */
export function mockEditTopicLoop(state, taskId, loopId, patch) {
  mockLoopFault()
  const list = mockLoopsOf(state, taskId)
  const at = list.findIndex((l) => l.loop_id === loopId)
  if (at < 0) throw Object.assign(new Error('no such loop'), { status: 404, token: 'not_found' })
  const old = list[at]
  const p = patch && typeof patch === 'object' ? patch : {}
  if (p.state !== undefined && p.state !== 'on' && p.state !== 'paused') throw Object.assign(new Error('bad state'), { status: 400, token: 'bad_loop' })
  const form = mockLoopForm(p, old)
  mockLoopBad(form)
  const edited = ['prompt', 'triggers', ...MOCK_LOOP_FIELDS].some((k) => p[k] !== undefined)
  const next = { ...old, state: p.state || old.state, set_by: state.me.id, set_at: new Date().toISOString() }
  if (edited) next.fires_in_hour = 0
  list[at] = mockLoopRow(form, next)
  mockLoopTell(taskId, list.slice())
  return list[at]
}

/** DELETE: { loop_id, deleted } (idempotent) */
export function mockDeleteTopicLoop(state, taskId, loopId) {
  mockLoopFault()
  const list = mockLoopsOf(state, taskId)
  const at = list.findIndex((l) => l.loop_id === loopId)
  if (at >= 0) list.splice(at, 1)
  mockLoopTell(taskId, list.slice())
  return { loop_id: loopId, deleted: at >= 0 }
}

/** PUT .../loops/order (v0.11 change 8): { task_id, loops } in the order sent; every loop id once, else 400 bad_loop */
export function mockOrderTopicLoops(state, taskId, loopIds) {
  mockLoopFault()
  const list = mockLoopsOf(state, taskId)
  const ids = Array.isArray(loopIds) ? loopIds.map(String) : []
  const byId = new Map(list.map((l) => [l.loop_id, l]))
  if (ids.length !== list.length || new Set(ids).size !== ids.length || !ids.every((id) => byId.has(id))) {
    throw Object.assign(new Error('bad loop order'), { status: 400, token: 'bad_loop' })
  }
  list.splice(0, list.length, ...ids.map((id) => byId.get(id)))
  mockLoopTell(taskId, list.slice())
  return { task_id: taskId, loops: list.slice() }
}

/** The receiving side: fn(frame) for each `topic_loops` frame another tab sends; returns the off switch. */
export function mockOnTopicLoops(fn) {
  const bc = mockLive()
  if (!bc) return () => {}
  bc.onmessage = (e) => {
    const f = e && e.data
    if (f && f.type === 'topic_loops') fn(f)
  }
  return () => bc.close()
}

/* spec 186 7.1.2: the hub's limits on a topic_select frame */
const SELECT_PATTERNS_MAX = 10
const SELECT_PATTERN_BYTES = 256

/**
 * Spec 186 7.1.2 (row M3): the mock hub's `topic_select`. It stands in for
 * the hub's resolver (internal/hub/topic_select.go): each line trimmed, an
 * empty one dropped, `*` = every topic in scope, any other line a
 * case-insensitive unanchored pattern on the topic's title; ticked task ids
 * join; a line that does not compile answers `topic_select_bad_pattern`
 * naming it ("line N: <pattern>: <why>"). Scope: the channel topics of the
 * mock tenant, never a DM, never `issues`, never an archived topic. This is
 * the mock's own code: the page and its components never read a pattern.
 */
export function mockTopicSelect(state, { req_id, action, task_ids = [], patterns = [] } = {}) {
  const refuse = (error, detail) => ({ type: 'topic_selected', req_id, ok: false, error, detail, topics: [] })
  if (action !== 'multicast') return refuse('bad_json', `unknown action "${action}"`)
  if (!task_ids.length && !patterns.length) return refuse('bad_json', 'task_ids and patterns are both empty')
  if (patterns.length > SELECT_PATTERNS_MAX) return refuse('bad_json', `at most ${SELECT_PATTERNS_MAX} patterns`)
  let all = false
  const res = []
  for (const [i, raw] of patterns.entries()) {
    if (new TextEncoder().encode(String(raw)).length > SELECT_PATTERN_BYTES) return refuse('bad_json', `pattern ${i + 1} is over ${SELECT_PATTERN_BYTES} bytes`)
    const p = String(raw).trim()
    if (p === '') continue
    if (p === '*') { all = true; continue }
    try { res.push(new RegExp(p, 'i')) } catch (e) { return refuse('topic_select_bad_pattern', `line ${i + 1}: ${p}: ${e && e.message ? e.message : 'invalid'}`) }
  }
  const ticks = new Set(task_ids.map((id) => String(id).toLowerCase()))
  const inScope = topicsFromMessages(state.messages.filter((m) => m.channel && m.channel !== 'issues'))
  const topics = inScope
    .filter((t) => all || ticks.has(String(t.task_id).toLowerCase()) || res.some((re) => re.test(String(t.subject || ''))))
    .map((t) => ({ task_id: t.task_id, channel: String(t.channel || ''), title: String(t.subject || '') }))
  return { type: 'topic_selected', req_id, ok: true, topics }
}

/**
 * Spec 186 M11 e2e hook: `spool.mock.multicast-refuse` = { "<task_id or
 * title>": "<token>" } makes the mock's multicast_check refuse those targets
 * with that token, as the hub would for an archived or unreadable topic.
 */
const MULTICAST_REFUSE_MOCK_KEY = 'spool.mock.multicast-refuse'

/** The mock tenant's multicast scope: its channel topics, never a DM, never `issues` (7.1.2, R1). */
function mockMulticastScope(state) {
  return topicsFromMessages(state.messages.filter((m) => m.channel && m.channel !== 'issues'))
}

/** A copy's target must be an existing channel topic of the mock tenant, as a reply (7.1.1); else the 404 that never says it exists. */
function mockMulticastDoor(state, taskId, isParent) {
  const known = mockMulticastScope(state).some((t) => t.task_id === String(taskId || ''))
  if (isParent !== 0 || !known) throw Object.assign(new Error('no such topic'), { status: 404, token: 'multicast_no_topic' })
}

/**
 * Spec 186 7.1.2 (row M11): the mock hub's `multicast_check`. Each selected
 * task id in scope is ok unless the e2e hook refuses it; one out of scope is
 * `multicast_no_topic`; none answers `multicast_none`. The mock has no
 * quota. It stores nothing.
 */
export function mockMulticastCheck(state, { req_id, task_ids = [] } = {}, refuse = storageGetJson(MULTICAST_REFUSE_MOCK_KEY, {}) || {}) {
  const answer = (ok, targets, error = '', detail = '') => ({ type: 'multicast_checked', req_id, ok, ...(error ? { error, detail } : {}), targets })
  const ids = [...new Set(task_ids.map((id) => String(id)))]
  if (!ids.length) return answer(false, [], 'multicast_none', 'no topic selected')
  const scope = new Map(mockMulticastScope(state).map((t) => [t.task_id, t]))
  const targets = ids.map((id) => {
    const t = scope.get(id)
    if (!t) return { task_id: id, channel: '', title: '', ok: false, error: 'multicast_no_topic' }
    const title = String(t.subject || '')
    const why = refuse[id] || refuse[title]
    return { task_id: id, channel: String(t.channel || ''), title, ok: !why, ...(why ? { error: String(why) } : {}) }
  })
  return answer(targets.every((t) => t.ok), targets)
}
