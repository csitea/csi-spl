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
export function mockGetTopic(state, id, { limit = 200, after, order, before, viewToken } = {}) {
  mockReadFault('topic') // SPL-1839 e2e hook: `spool.mock.read-fault`
  /* e2e hook (topic-view-door): `spool.mock.view-door` = { detail } stands in
     for a hub whose door this session does not open (view-v1 section 2): a
     401 view_door until a view token is set */
  const door = storageGetJson('spool.mock.view-door', null)
  if (door && !viewToken) throw Object.assign(new Error('spool 401 view_door'), { status: 401, token: 'view_door', detail: String(door.detail || '') })
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
  state.messages.push(row)
  mockNoteNonMembers(state, row)
  return row
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
