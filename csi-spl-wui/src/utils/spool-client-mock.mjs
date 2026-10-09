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

/** view-v1 §4.3 over the mock messages: one row per topic, no server pages. */
export function mockListTopics(state, { limit = 50, channel, dm, peer } = {}) {
  let rows = state.messages.slice()
  if (channel) rows = rows.filter((m) => m.channel === channel)
  else if (dm) rows = rows.filter((m) => !m.channel)
  if (peer) {
    const [id] = String(peer).split('@')
    rows = rows.filter((m) => m.from === id || m.to === id)
  }
  return { topics: topicsFromMessages(rows).slice(0, limit), next: null }
}

/** view-v1 §4.4 over the mock messages, `order: 'desc'` paged by `before`. */
export function mockGetTopic(state, id, { limit = 200, after, order, before } = {}) {
  /* t1 404cd808: the hub's topic read keeps the topic's own archived
     card (only the lobby feed hides archived rows), so the mock does too */
  const all = topicMessages([...state.messages, ...(state.archived || [])], id)
  /* t1 8fb802cd: the hub's archive stamp, as its own rule reads it */
  const arch = (state.archived || []).find((m) => m.archived_at && (m.msg_id === id || m.task_id === id))
  const stamp = arch && !after ? { archived_at: arch.archived_at, archived_by: arch.archived_by } : {}
  if (order !== 'desc') return { task_id: id, messages: all, next: null, ...stamp }
  const desc = all.slice().reverse()
  const start = before ? desc.findIndex((m) => m.msg_id === before) + 1 : 0
  const page = desc.slice(start, start + limit)
  const more = start + limit < desc.length
  return { task_id: id, messages: page, next: more && page.length ? page[page.length - 1].msg_id : null, ...stamp }
}

/** The flat messages of a channel or a DM peer, oldest first; mock has no server pages. */
export function mockListMessages(state, { channel, peer, limit = 50, since } = {}) {
  /* the same test hook, read again: a line an e2e adds after boot is
     held as the hub would hold a reply its socket just delivered */
  const extra = storageGetJson('spool.mock.extra-messages', [])
  if (Array.isArray(extra)) {
    const held = new Set(state.messages.map((m) => m.msg_id))
    state.messages.push(...extra.filter((m) => m && m.msg_id && !held.has(m.msg_id)))
  }
  let rows = state.messages.slice()
  if (channel) rows = rows.filter((m) => m.channel === channel)
  /* specs/058: a DM is per <ID>@<box>, as the hub's peer filter is */
  /* dc6d5e3f: plus the channel lines between me and that agent, as pointers */
  else if (peer) rows = [...rows.filter((m) => belongsTo(m, { peer: String(peer) })), ...mockDmPointers(rows, state.me && state.me.id, String(peer))]
  if (since) rows = rows.filter((m) => m.ts > since)
  return { messages: rows.slice(-limit), next: null }
}

/**
 * The mock's send: the row the hub's insert would store, appended to the
 * mock messages. `p` is sendMessage's arguments plus its parsed post
 * (to, toBox, kind, body); `uuid` is the client's id maker.
 */
export function mockSendMessage(state, p, uuid) {
  const { channel, task_id, parent_task_id, is_parent, files, msg_id, to, toBox, kind, body } = p
  /* 080 T006: the hub de-dupes by msg_id, so a resend of a held send
     (same msg_id) stores nothing new - the mock does the same */
  const dup = msg_id ? state.messages.find((m) => m.msg_id === msg_id) : null
  if (dup) return dup
  /* spec 117 FR-1: a reply with no channel and no `to` into a topic that has
     no single other end names nobody to deliver it to, and the hub refuses it
     (400 dm_needs_to). With one other end the hub re-addresses it; the mock
     stores it as sent, so a reply the WUI did not address still shows. */
  const topic = task_id || parent_task_id
  if (!channel && (!to || to === '@channel') && topic) {
    const rows = state.messages.filter((m) => m.task_id === topic || m.parent_task_id === topic)
    const ends = new Set(rows.flatMap((m) => [m.from, m.to]).filter((i) => i && i !== state.me.id && i !== 'ALL-0' && i !== '@channel'))
    if (rows.length && ends.size !== 1) throw Object.assign(new Error('say who this is for'), { status: 400, token: 'dm_needs_to' })
  }
  /* spec 068: what the hub's insert stores - <to>@<to_box> for a
     message to one agent; the mock reads a bare peer's box off the roster */
  const seatBox = toBox || Object.keys(state.roster || {}).find((b) => (state.roster[b] || []).includes(to))
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
  state.messages.push(row)
  return row
}
