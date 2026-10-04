/**
 * P3-30 (perf audit round 3): the spool client's writers, admin and issue
 * calls - every method no first screen needs. spool-client.mjs is in the
 * initial JS; this half loads on the first call to one of these (its stubs
 * there await this chunk), so it no longer rides every first load. Each
 * takes the client's ctx first: { live, mock, state, dir, tenantMock,
 * issuesMock, mockArchivePolicy }.
 *
 * Only `lazySpoolMethods` is exported: Nuxt auto-imports every utils/ export
 * by name, and a name like createChannel would collide with other modules'.
 */
import { channelSlug } from './channel-feed.mjs'
import { channelsFromView, normalizeViewMessage } from './view-api.mjs'
import { storageGet, storageSetJson } from './prefs.mjs'
import { CHANNEL_ORDER_MAX, MOCK_CHANNEL_ORDER_KEY, normalizeChannelOrder } from './channel-order.mjs'
import { isPublicChannel, normalizeChannelId, rosterHumanIds } from './spool-client.mjs'
import { FLOW_SEEN_KEY, flowEventKind, mockFlowCounts, mockFlowEvents, mockFlowKeys, parseFlowCounts, parseFlowKeys } from './flow-badge.mjs'
import { loadCursors } from './read-cursor.mjs'

const HUMAN_ID_RE = /^HUM-[0-9]+$/

/* issues-v1 §4 query - the same as issues.mjs issueQuery (kept here so the
   Issues code stays out of this chunk too; tests/unit/issues.test.mjs
   checks the two agree). */
function issueQuery(filter = {}, sort = '') {
  const q = new URLSearchParams()
  if (filter.kind) q.set('kind', filter.kind)
  for (const k of ['epic', 'parent', 'status', 'priority', 'level', 'assignee', 'label']) {
    const v = filter[k]
    if (Array.isArray(v) && v.length) q.set(k, v.join(','))
  }
  if (filter.deadlineBefore) q.set('deadline_before', filter.deadlineBefore)
  if (filter.deadlineAfter) q.set('deadline_after', filter.deadlineAfter)
  if (sort && sort !== 'priority') q.set('sort', sort)
  return q.toString()
}

const CHANNEL_ERRORS = {
  channel_exists: (slug) => `#${slug} already exists`,
  channel_archived: (slug) => `#${slug} is reserved: an archived channel has this name`,
  bad_channel: (slug) => `"${slug}" is not a valid channel name (a-z, 0-9, "-", max 64)`,
}

function parseMemberList(data, channel) {
  const members = Array.isArray(data && data.members) ? data.members.map((id) => String(id)) : []
  const agents = Array.isArray(data && data.agents)
    ? data.agents.map((a) => {
      const row = { id: String((a && a.id) || ''), box: String((a && a.box) || '') }
      if (a && typeof a.online === 'boolean') row.online = a.online
      if (a && typeof a.seated === 'boolean') row.seated = a.seated
      return row
    }).filter((a) => a.id)
    : []
  const responders = Array.isArray(data && data.responders)
    ? data.responders.map((id) => String(id)).filter(Boolean)
    : []
  return {
    channel: String((data && data.channel) || channel || ''),
    default: Boolean(data && data.default),
    members,
    members_open_invite: Boolean(data && data.members_open_invite),
    created_by: String((data && data.created_by) || ''),
    agents,
    responders,
  }
}

function memberError(status, token, detail) {
  return Object.assign(new Error(detail || token), { status, token, detail: detail || '' })
}

function mockMemberList(ctx, channel) {
  const { state } = ctx
  const id = normalizeChannelId(channel)
  const known = id && state.channels.some((c) => c.channel_id === id)
  if (!known) throw memberError(404, 'unknown_channel', `no channel ${channel} in this tenant`)
  if (isPublicChannel(id)) {
    return {
      channel: id,
      default: true,
      members: [],
      members_open_invite: false,
      created_by: 'hub',
      agents: (state.agentMembers[id] || []).slice(),
    }
  }
  const row = state.channels.find((c) => c.channel_id === id)
  const members = (state.memberships[id] || []).slice()
  if (!members.includes(state.me.id)) {
    throw memberError(404, 'unknown_channel', `no channel ${channel} in this tenant`)
  }
  return {
    channel: id,
    default: false,
    members,
    members_open_invite: state.openInvite[id] === true,
    created_by: String((row && row.created_by) || ''),
    agents: (state.agentMembers[id] || []).slice(),
  }
}

function mockMayInvite(ctx, row) {
  const { state } = ctx
  if (!row) return false
  if (row.created_by === state.me.id) return true
  if (state.openInvite[row.channel_id] === true) return true
  return Boolean(row.created_by) && !HUMAN_ID_RE.test(row.created_by)
}

function mockAddMember(ctx, channel, humanId) {
  const { state } = ctx
  const id = normalizeChannelId(channel)
  const hid = String(humanId || '')
  if (!hid) throw memberError(400, 'bad_json', 'body must be {human_id}')
  const row = state.channels.find((c) => c.channel_id === id)
  if (!row) throw memberError(404, 'unknown_channel', `no channel ${channel} in this tenant`)
  if (isPublicChannel(id)) {
    throw memberError(409, 'channel_public', `#${id} is a default channel: every member of the tenant already reads it`)
  }
  const members = state.memberships[id]
  if (!members || !members.includes(state.me.id)) {
    throw memberError(404, 'unknown_channel', `no channel ${channel} in this tenant`)
  }
  if (!mockMayInvite(ctx, row)) throw memberError(403, 'forbidden', 'forbidden')
  if (!HUMAN_ID_RE.test(hid) || !rosterHumanIds(state.roster).includes(hid)) {
    throw memberError(404, 'not_a_member', `${hid} is not a member of this tenant`)
  }
  if (!members.includes(hid)) members.push(hid)
  return { channel: id, human_id: hid, added_by: state.me.id }
}

function mockAddAgent(ctx, channel, agentId, box) {
  const { state } = ctx
  const id = normalizeChannelId(channel)
  const agent = String(agentId || '')
  const boxId = String(box || '')
  if (!agent || !boxId) throw memberError(400, 'bad_json', 'body must be {id, box}')
  const row = state.channels.find((c) => c.channel_id === id)
  if (!row) throw memberError(404, 'unknown_channel', `no channel ${channel} in this tenant`)
  // A default channel takes agents too; any member picks them (created_by hub).
  if (!isPublicChannel(id)) {
    const members = state.memberships[id]
    if (!members || !members.includes(state.me.id)) {
      throw memberError(404, 'unknown_channel', `no channel ${channel} in this tenant`)
    }
    if (!mockMayInvite(ctx, row)) throw memberError(403, 'forbidden', 'forbidden')
  }
  const announced = (state.roster && state.roster[boxId]) || []
  if (!announced.includes(agent)) {
    throw memberError(404, 'not_a_member', `${agent} is not announced on ${boxId}`)
  }
  const list = state.agentMembers[id] || (state.agentMembers[id] = [])
  if (!list.some((a) => a.id === agent && a.box === boxId)) list.push({ id: agent, box: boxId })
  return { channel: id, id: agent, box: boxId }
}

function mockRemoveMember(ctx, channel, humanId) {
  const { state } = ctx
  const id = normalizeChannelId(channel)
  const hid = String(humanId || '')
  const row = state.channels.find((c) => c.channel_id === id)
  if (!row) throw memberError(404, 'unknown_channel', `no channel ${channel} in this tenant`)
  if (isPublicChannel(id)) throw memberError(409, 'channel_public', `#${id} has no membership to remove`)
  const members = state.memberships[id]
  if (!members || !members.includes(state.me.id)) {
    throw memberError(404, 'unknown_channel', `no channel ${channel} in this tenant`)
  }
  if (hid !== state.me.id && !mockMayInvite(ctx, row)) throw memberError(403, 'forbidden', 'forbidden')
  state.memberships[id] = members.filter((m) => m !== hid)
  return null
}

function mockRemoveAgent(ctx, channel, agentId, box) {
  const { state } = ctx
  const id = normalizeChannelId(channel)
  const agent = String(agentId || '')
  const boxId = String(box || '')
  const row = state.channels.find((c) => c.channel_id === id)
  if (!row) throw memberError(404, 'unknown_channel', `no channel ${channel} in this tenant`)
  if (!isPublicChannel(id)) {
    const members = state.memberships[id]
    if (!members || !members.includes(state.me.id)) {
      throw memberError(404, 'unknown_channel', `no channel ${channel} in this tenant`)
    }
    if (!mockMayInvite(ctx, row)) throw memberError(403, 'forbidden', 'forbidden')
  }
  const list = state.agentMembers[id] || []
  state.agentMembers[id] = list.filter((a) => !(a.id === agent && a.box === boxId))
  return null
}

function mockDeleteChannel(ctx, channel) {
  const { state } = ctx
  const id = normalizeChannelId(channel)
  const row = state.channels.find((c) => c.channel_id === id)
  if (!row) throw memberError(404, 'unknown_channel', `no channel ${channel} in this tenant`)
  const members = state.memberships[id] || []
  if (!isPublicChannel(id) && !members.includes(state.me.id)) {
    throw memberError(404, 'unknown_channel', `no channel ${channel} in this tenant`)
  }
  if (isPublicChannel(id)) throw memberError(409, 'channel_public', `#${id} is a default channel: it cannot be deleted`)
  if (row.created_by !== state.me.id) throw memberError(403, 'forbidden', 'forbidden')
  state.channels = state.channels.filter((c) => c.channel_id !== id)
  delete state.memberships[id]
  if (state.archivedChannels) delete state.archivedChannels[id]
  return null
}

function mockArchiveChannel(ctx, channel) {
  const { state } = ctx
  const id = normalizeChannelId(channel)
  const row = state.channels.find((c) => c.channel_id === id)
  if (!row) throw memberError(404, 'unknown_channel', `no channel ${channel} in this tenant`)
  const members = state.memberships[id] || []
  if (!isPublicChannel(id) && !members.includes(state.me.id)) {
    throw memberError(404, 'unknown_channel', `no channel ${channel} in this tenant`)
  }
  if (isPublicChannel(id)) throw memberError(409, 'channel_public', `#${id} is a default channel: it cannot be archived`)
  if (row.created_by !== state.me.id) throw memberError(403, 'forbidden', 'forbidden')
  state.archivedChannels = state.archivedChannels || {}
  state.archivedChannels[id] = { ...row, members: [...members] }
  state.channels = state.channels.filter((c) => c.channel_id !== id)
  return null
}

function mockUnarchiveChannel(ctx, channel) {
  const { state } = ctx
  const id = normalizeChannelId(channel)
  const kept = state.archivedChannels && state.archivedChannels[id]
  if (!kept) throw memberError(404, 'unknown_channel', `no archived channel ${channel} in this tenant`)
  const { members, ...row } = kept
  if (!state.channels.some((c) => c.channel_id === id)) state.channels.push(row)
  state.memberships[id] = members || [state.me.id]
  delete state.archivedChannels[id]
  return row
}

function mockSetOpen(ctx, channel, flag) {
  const { state } = ctx
  const id = normalizeChannelId(channel)
  const row = state.channels.find((c) => c.channel_id === id)
  if (!row) throw memberError(404, 'unknown_channel', `no channel ${channel} in this tenant`)
  if (isPublicChannel(id)) {
    throw memberError(409, 'channel_public', `#${id} is a default channel: every member of the tenant already reads it`)
  }
  const members = state.memberships[id] || []
  if (!members.includes(state.me.id)) {
    throw memberError(404, 'unknown_channel', `no channel ${channel} in this tenant`)
  }
  if (row.created_by !== state.me.id) throw memberError(403, 'forbidden', 'forbidden')
  state.openInvite[id] = flag === true
  return { channel: id, members_open_invite: state.openInvite[id] === true }
}

/**
 * PUT /v1/me/channel-order (contracts/move-v1.md §7): the whole list;
 * answers the stored one, normalized ([] clears it -> null).
 */
async function setChannelOrder(ctx, ids) {
  const { live, mock } = ctx
  if (!Array.isArray(ids) || ids.some((v) => typeof v !== 'string')) {
    throw Object.assign(new Error('channel_order must be a list'), { status: 400, token: 'bad_json' })
  }
  if (mock) {
    const list = normalizeChannelOrder(ids)
    if (list.length > CHANNEL_ORDER_MAX) throw Object.assign(new Error('too many ids'), { status: 400, token: 'bad_json' })
    storageSetJson(MOCK_CHANNEL_ORDER_KEY, list.length ? list : null)
    return { channel_order: list.length ? list : null }
  }
  return live('/v1/me/channel-order', {
    method: 'PUT',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ channel_order: ids }),
  })
}

/**
 * DELETE /v1/members/{human_id} (025 FR-007). Humans only; the hub
 * answers 404 for anything else. Mock has no memberships.
 */
async function removeMember(ctx, humanId) {
  const { live, mock } = ctx
  const id = String(humanId || '')
  if (!/^HUM-\d+$/.test(id)) {
    const err = new Error('not a member')
    err.status = 404
    err.token = 'not_found'
    throw err
  }
  if (mock) return null
  return live(`/v1/members/${encodeURIComponent(id)}`, { method: 'DELETE' })
}

/**
 * GET /v1/members: the tenant's members, pending invites and
 * the roles the caller may grant. members.invite (admin) only.
 */
async function listTenantUsers(ctx) {
  const { live, mock, dir } = ctx
  if (mock) return (await dir()).list()
  return live('/v1/members')
}

/**
 * POST /v1/members/invites: store the invite, and mail it unless noMail
 * (CLE-77780: no mail without an explicit click). `locale` rides as
 * X-Locale for the mail.
 */
async function inviteTenantUser(ctx, { email, role, locale, noMail } = {}) {
  const { live, mock, dir } = ctx
  const body = { email: String(email || '').trim(), ...(role ? { role: String(role) } : {}), ...(noMail ? { no_mail: true } : {}) }
  if (mock) return (await dir()).invite(body.email, body.role, { noMail: Boolean(noMail) })
  return live('/v1/members/invites', {
    method: 'POST',
    headers: { 'content-type': 'application/json', ...(locale ? { 'x-locale': String(locale) } : {}) },
    body: JSON.stringify(body),
  })
}

/** PUT /v1/members/{id}/role; `fromRole` makes a stale page answer 409 role_changed. */
async function setTenantUserRole(ctx, humanId, role, fromRole = '') {
  const { live, mock, dir } = ctx
  const id = String(humanId || '')
  if (mock) return (await dir()).setRole(id, String(role || ''))
  return live(`/v1/members/${encodeURIComponent(id)}/role`, {
    method: 'PUT',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ role: String(role || ''), ...(fromRole ? { from_role: String(fromRole) } : {}) }),
  })
}

/** DELETE /v1/members/{id}: remove a member from the tenant. */
async function removeTenantUser(ctx, humanId) {
  const { live, mock, dir } = ctx
  const id = String(humanId || '')
  if (mock) return (await dir()).remove(id)
  return live(`/v1/members/${encodeURIComponent(id)}`, { method: 'DELETE' })
}

/**
 * GET /v1/audit/clones (specs/054 §7, CLE-77797): the tenant's act-as
 * trail, newest first. CLE-77799 reads it for the People-card Activity log
 * and filters it to one person (target_hum) client-side. audit.read only;
 * a 403 is left to the caller. The mock answers a small fixed trail.
 */
async function auditClones(ctx) {
  const { live, mock } = ctx
  if (mock) {
    const data = await import('./mock-data.mjs')
    return data.MOCK_CLONES.map((c) => ({ ...c }))
  }
  return live('/v1/audit/clones')
}

/**
 * GET /v1/members/{id}/activity (CLE-77799): one member's audit trail —
 * membership events (role change, removal) and auth events (sign-in with
 * method, sign-out, session expiry), newest first. Readable by the tenant's
 * admins/owners (audit.read) or by the member themself; the hub is the
 * authority. The act-as trail rides GET /v1/audit/clones and is merged by
 * the caller. The mock records no server events, so it answers [].
 */
async function memberActivity(ctx, humanId) {
  const { live, mock } = ctx
  if (mock) return []
  return live(`/v1/members/${encodeURIComponent(String(humanId || ''))}/activity`)
}

/** DELETE /v1/members/invites?email=: revoke a pending invite. */
async function revokeTenantInvite(ctx, email) {
  const { live, mock, dir } = ctx
  const e = String(email || '').trim()
  if (mock) return (await dir()).revoke(e)
  return live(`/v1/members/invites?email=${encodeURIComponent(e)}`, { method: 'DELETE' })
}

/**
 * PATCH /v1/members/{id} (specs/046): { display_name?, locale?, disabled?, access_until? }.
 * disabled suspends the member in THIS tenant only; access_until (RFC 3339,
 * null = no end) ends their access here on a date (spec 072 A27).
 */
async function patchTenantUser(ctx, humanId, patch = {}) {
  const { live, mock, dir } = ctx
  const id = String(humanId || '')
  if (mock) return (await dir()).patch(id, patch)
  return live(`/v1/members/${encodeURIComponent(id)}`, {
    method: 'PATCH',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(patch),
  })
}

/** GET /v1/tenant/settings (specs/046, tenant.settings): name, default locale, responders. */
async function getTenantSettings(ctx) {
  const { live, mock, tenantMock } = ctx
  if (mock) return (await tenantMock()).settings()
  return live('/v1/tenant/settings')
}

/** PATCH /v1/tenant/settings { display_name?, default_locale?, responders? } → the new settings. */
async function patchTenantSettings(ctx, patch = {}) {
  const { live, mock, tenantMock } = ctx
  if (mock) return (await tenantMock()).patch(patch)
  return live('/v1/tenant/settings', {
    method: 'PATCH',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(patch),
  })
}

/** GET /v1/tenant/channels: every channel of the tenant (private ones too), admin view. */
async function listTenantChannels(ctx) {
  const { live, mock, tenantMock } = ctx
  if (mock) return (await tenantMock()).channels()
  return live('/v1/tenant/channels')
}

/** PATCH /v1/tenant/channels/{ch} { no_fallback }. */
async function setTenantChannelNoFallback(ctx, channel, off) {
  const { live, mock, tenantMock } = ctx
  const ch = String(channel || '')
  if (mock) return (await tenantMock()).setNoFallback(ch, off)
  return live(`/v1/tenant/channels/${encodeURIComponent(ch)}`, {
    method: 'PATCH',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ no_fallback: Boolean(off) }),
  })
}

/** DELETE /v1/tenant/channels/{ch}: archive a channel without being its creator. */
async function archiveTenantChannel(ctx, channel) {
  const { live, mock, tenantMock } = ctx
  const ch = String(channel || '')
  if (mock) return (await tenantMock()).archive(ch)
  return live(`/v1/tenant/channels/${encodeURIComponent(ch)}`, { method: 'DELETE' })
}

/**
 * GET /v1/admin/perf/summary (spec 066 section 6 (b), tenant.settings): this
 * workspace's timings per (metric, device, view). The mock build answers
 * perf-summary.mjs's canned summary.
 */
async function getPerfSummary(ctx, opts = {}) {
  const { live, mock } = ctx
  const ps = await import('./perf-summary.mjs')
  if (mock) return ps.mockPerfSummary(opts)
  return live(`/v1/admin/perf/summary?${ps.perfSummaryQuery(opts)}`)
}

/**
 * message-edit-v1 §1 — PATCH /v1/messages/{msg_id}, body { body }.
 *
 * The prefix is `/v1/`, NOT `/api/v1/`: the latter is the auth handler's
 * mount, the view / channels surface is `/v1/`. `content-type` is the
 * only header, and it is one the channels POST already sends, so this
 * adds no new CORS preflight — a new request header has broken sign-in
 * in this repo before.
 *
 * The tenant is the member session's (spec 026) and is never in the body.
 * Refusals arrive as { error, detail } and `live()` already lifts `error`
 * onto err.token, which is what utils/msg-edit.mjs switches on.
 */
async function editMessage(ctx, msgId, body) {
  const { live, mock, state } = ctx
  const id = String(msgId || '')
  const text = String(body == null ? '' : body)
  if (!id) throw Object.assign(new Error('msg_id required'), { status: 400, token: 'bad_json' })
  if (mock) {
    /* The lde mock is a real edit against the in-memory store, including
       the two refusals the hub makes, so the browser e2e exercises the
       whole path (open, type, commit, marker, rollback) without a hub. */
    const row = state.messages.find((m) => m.msg_id === id)
    if (!row) throw Object.assign(new Error('no such message'), { status: 404, token: 'not_found' })
    if (!text.trim()) throw Object.assign(new Error('body must not be empty'), { status: 400, token: 'empty_body' })
    if (row.from !== state.me.id) throw Object.assign(new Error('only the author may edit this message'), { status: 403, token: 'not_author' })
    if (row.from_box !== state.me.box) throw Object.assign(new Error('box-signed envelope'), { status: 409, token: 'not_editable' })
    row.body = text
    /* §FR-ED-009: an edit does NOT move the message — ts, received_at and
       cursor are deliberately left exactly as they were. */
    row.edited_at = new Date().toISOString().replace(/\.\d+Z$/, 'Z')
    row.edited_by = state.me.id
    row.revision = (Number(row.revision) || 1) + 1
    return { ...row }
  }
  const data = await live(`/v1/messages/${encodeURIComponent(id)}`, {
    method: 'PATCH',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ body: text }),
  })
  return normalizeViewMessage(data)
}

/**
 * DELETE /v1/messages/{msg_id}. 204 on success. The same refusals as an
 * edit: not_author, not_editable, not_found. The mock removes the row
 * from its store so a later read does not bring it back.
 */
async function deleteMessage(ctx, msgId) {
  const { live, mock, state } = ctx
  const id = String(msgId || '')
  if (!id) throw Object.assign(new Error('msg_id required'), { status: 400, token: 'bad_json' })
  if (mock) {
    const at = state.messages.findIndex((m) => m.msg_id === id)
    if (at < 0) throw Object.assign(new Error('no such message'), { status: 404, token: 'not_found' })
    const row = state.messages[at]
    if (row.from !== state.me.id) throw Object.assign(new Error('only the author may delete this message'), { status: 403, token: 'not_author' })
    if (row.from_box !== state.me.box) throw Object.assign(new Error('box-signed envelope'), { status: 409, token: 'not_editable' })
    state.messages.splice(at, 1)
    return null
  }
  await live(`/v1/messages/${encodeURIComponent(id)}`, { method: 'DELETE' })
  return null
}

/**
 * POST /v1/messages/{msg_id}/merge {into}. {msg_id} is the
 * source, the row that goes away; `into` keeps both bodies, older first.
 * ONE request: the hub edits `into` and deletes the source in one
 * transaction, so a merge can no longer leave the source behind (the old
 * PATCH-then-DELETE lost its DELETE on prd). Resolves with the kept row
 * (plus merged_from); rejects with the hub token on err.token
 * (not_same_thread, not_same_author, not_allowed, not_editable, is_card,
 * has_replies, not_found, too_large). The mock applies the same rules
 * against its store.
 */
async function mergeMessage(ctx, msgId, intoId) {
  const { live, mock, state } = ctx
  const src = String(msgId || '')
  const into = String(intoId || '')
  if (!src || !into || src === into) throw Object.assign(new Error('two message ids required'), { status: 400, token: 'bad_json' })
  /* the mock's rules load on use: they are not first-paint code (specs/027) */
  if (mock) return (await import('./mock-merge.mjs')).mockMerge(state, src, into)
  const data = await live(`/v1/messages/${encodeURIComponent(src)}/merge`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ into }),
  })
  const row = normalizeViewMessage(data)
  row.merged_from = src
  return row
}

/**
 * SPL-983, specs/041 topic-archive-v1 §2: archive (PUT) or unarchive
 * (DELETE) a topic card. The hub lets the card's author, the tenant owner
 * or an admin (403 not_allowed otherwise); a reply is 409 not_a_card.
 * Returns { msg_id, task_id, archived, archived_at?, archived_by? }.
 */
async function archiveTopic(ctx, msgId, archived = true) {
  const { live, mock, state } = ctx
  const id = String(msgId || '')
  if (!id) throw Object.assign(new Error('msg_id required'), { status: 400, token: 'bad_json' })
  if (mock) {
    state.archived = state.archived || []
    if (archived) {
      const at = state.messages.findIndex((m) => m.msg_id === id)
      if (at < 0) throw Object.assign(new Error('no such message'), { status: 404, token: 'not_found' })
      const row = { ...state.messages[at], archived_at: new Date().toISOString(), archived_by: state.me.id }
      state.messages.splice(at, 1)
      state.archived.unshift(row)
      return { msg_id: id, task_id: row.task_id, archived: true, archived_at: row.archived_at, archived_by: row.archived_by }
    }
    const at = state.archived.findIndex((m) => m.msg_id === id)
    if (at >= 0) {
      const [row] = state.archived.splice(at, 1)
      state.messages.push({ ...row, archived_at: undefined, archived_by: undefined })
    }
    return { msg_id: id, task_id: '', archived: false }
  }
  return live(`/v1/messages/${encodeURIComponent(id)}/archive`, { method: archived ? 'PUT' : 'DELETE' })
}

/** Owner (t1 56b8cc17): an archived topic leaves the unread counts; the Flow store re-reads them on this. */
const TOPIC_ARCHIVED_EVENT = 'spool:topic-archived'

async function archiveTopicAndTell(ctx, msgId, archived = true) {
  const out = await archiveTopic(ctx, msgId, archived)
  if (typeof globalThis.dispatchEvent === 'function' && typeof CustomEvent === 'function') {
    globalThis.dispatchEvent(new CustomEvent(TOPIC_ARCHIVED_EVENT, { detail: { msgId, archived } }))
  }
  return out
}

/** topic-archive-v1 §3: { replies, task_ids, can_delete, ... } for the confirm dialog. */
async function topicSize(ctx, msgId) {
  const { live, mock, state, mockArchivePolicy } = ctx
  const id = String(msgId || '')
  if (mock) {
    /* test hook (mock only): a confirm dialog reads the reply count from
       the hub, and on prd that round-trip takes real time. e2e sets
       `spool-mock-topic-size-delay-ms` to replay that latency window so a
       test can prove the Delete button stays keyboard-usable while it
       loads (TopicDeleteDialog, owner topic b6a7db19). Off by default. */
    const delay = typeof localStorage !== 'undefined' ? Number(localStorage.getItem('spool-mock-topic-size-delay-ms') || 0) : 0
    if (delay > 0) await new Promise((r) => setTimeout(r, delay))
    const all = [...state.messages, ...(state.archived || [])]
    const row = all.find((m) => m.msg_id === id)
    const replies = row ? all.filter((m) => m.msg_id !== id && (m.task_id === row.task_id || m.task_id === id)).length : 0
    /* CLE-77819: with the opt-in policy, the mock answers can_archive the
       way the hub's resolveCard does for a plain developer. */
    const policy = mockArchivePolicy()
    const canArchive = !policy || policy === 'everyone' || (policy === 'starter' && Boolean(row) && row.from === state.me.id)
    return { msg_id: id, task_id: row ? row.task_id : '', replies, task_ids: row ? [row.task_id] : [], can_delete: true, can_archive: canArchive }
  }
  return live(`/v1/view/messages/${encodeURIComponent(id)}/topic`)
}

/**
 * topic-archive-v1 §4: DELETE the card and every child, one transaction.
 * Returns { deleted, msg_ids, task_ids }.
 */
async function deleteTopic(ctx, msgId) {
  const { live, mock, state } = ctx
  const id = String(msgId || '')
  if (!id) throw Object.assign(new Error('msg_id required'), { status: 400, token: 'bad_json' })
  if (mock) {
    const pool = [...state.messages, ...(state.archived || [])]
    const row = pool.find((m) => m.msg_id === id)
    if (!row) throw Object.assign(new Error('no such message'), { status: 404, token: 'not_found' })
    const gone = (m) => m.msg_id === id || m.task_id === row.task_id || m.task_id === id
    const ids = pool.filter(gone).map((m) => m.msg_id)
    state.messages = state.messages.filter((m) => !gone(m))
    state.archived = (state.archived || []).filter((m) => !gone(m))
    return { msg_id: id, task_id: row.task_id, deleted: ids.length, msg_ids: ids, task_ids: [row.task_id, id] }
  }
  return live(`/v1/messages/${encodeURIComponent(id)}/topic`, { method: 'DELETE' })
}

/**
 * SPL-1024 move-v1 §2: POST /v1/messages/{msg_id}/move {to_channel} moves
 * a topic's card and every row under it to another channel. The answer
 * carries `undo` ({ to_channel }). Refusals keep the hub token (409
 * lobby / same_place / not_in_channel / issue_topic / not_a_card, 404
 * unknown_channel, 403 not_allowed).
 */
async function moveTopic(ctx, msgId, toChannel) {
  const { live, mock, state } = ctx
  const id = String(msgId || '')
  const to = String(toChannel || '').trim().replace(/^#/, '').toLowerCase()
  if (!id || !to) throw Object.assign(new Error('msg_id and channel required'), { status: 400, token: 'bad_json' })
  if (mock) return (await import('./move-mock.mjs')).mockMove(state, id, { to_channel: to })
  return live(`/v1/messages/${encodeURIComponent(id)}/move`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ to_channel: to }),
  })
}

/**
 * move-v1 §3: {to_task} moves a reply (and its own thread) into another
 * topic. The answer carries `undo` ({ to_task: <home task> }).
 */
async function moveMessage(ctx, msgId, toTask) {
  const { live, mock, state } = ctx
  const id = String(msgId || '')
  const to = String(toTask || '')
  if (!id || !to) throw Object.assign(new Error('msg_id and task required'), { status: 400, token: 'bad_json' })
  if (mock) return (await import('./move-mock.mjs')).mockMove(state, id, { to_task: to })
  return live(`/v1/messages/${encodeURIComponent(id)}/move`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ to_task: to }),
  })
}

/**
 * 714c7028: {to_task} merges a whole topic (this card's topic) into another
 * topic, ordered by the original timestamps; the source opener becomes a
 * reply. The answer carries `undo` ({ from_task, msg_ids }). Refusals keep
 * the hub token (409 same_place / lobby / not_in_channel / issue_topic /
 * not_a_card / cycle, 404 not_found, 403 not_allowed).
 */
async function mergeTopic(ctx, msgId, toTask) {
  const { live, mock, state } = ctx
  const id = String(msgId || '')
  const to = String(toTask || '')
  if (!id || !to) throw Object.assign(new Error('msg_id and task required'), { status: 400, token: 'bad_json' })
  if (mock) return (await import('./move-mock.mjs')).mockMergeTopic(state, id, { to_task: to })
  return live(`/v1/messages/${encodeURIComponent(id)}/merge-topic`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ to_task: to }),
  })
}

/** 714c7028: the undo of a merge - {undo:{from_task,msg_ids}} puts the topic back. */
async function mergeUndo(ctx, msgId, fromTask, msgIds) {
  const { live, mock, state } = ctx
  const id = String(msgId || '')
  const undo = { from_task: String(fromTask || ''), msg_ids: (Array.isArray(msgIds) ? msgIds : []).map(String) }
  if (!id || !undo.from_task) throw Object.assign(new Error('msg_id and from_task required'), { status: 400, token: 'bad_json' })
  if (mock) return (await import('./move-mock.mjs')).mockMergeTopic(state, id, { undo })
  return live(`/v1/messages/${encodeURIComponent(id)}/merge-topic`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ undo }),
  })
}

/**
 * 8f588edd: POST /v1/messages/{msg_id}/promote-topic {} splits a reply out
 * of its topic into a NEW topic of its own (the hub mints the task_id, in
 * the message's own channel). The answer carries the new `task_id` and
 * `undo` ({ from_task: <new topic>, msg_ids }). Refusals keep the hub token
 * (409 is_card / lobby / not_in_channel / issue_topic / cycle, 403
 * not_allowed).
 */
async function promoteTopic(ctx, msgId) {
  const { live, mock, state } = ctx
  const id = String(msgId || '')
  if (!id) throw Object.assign(new Error('msg_id required'), { status: 400, token: 'bad_json' })
  if (mock) return (await import('./move-mock.mjs')).mockPromoteTopic(state, id, {})
  return live(`/v1/messages/${encodeURIComponent(id)}/promote-topic`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({}),
  })
}

/** 8f588edd: the undo of a promote - {undo:{from_task,msg_ids}} re-seats the reply. */
async function promoteUndo(ctx, msgId, fromTask, msgIds) {
  const { live, mock, state } = ctx
  const id = String(msgId || '')
  const undo = { from_task: String(fromTask || ''), msg_ids: (Array.isArray(msgIds) ? msgIds : []).map(String) }
  if (!id || !undo.from_task) throw Object.assign(new Error('msg_id and from_task required'), { status: 400, token: 'bad_json' })
  if (mock) return (await import('./move-mock.mjs')).mockPromoteTopic(state, id, { undo })
  return live(`/v1/messages/${encodeURIComponent(id)}/promote-topic`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ undo }),
  })
}

/** move-v1 §4: { msg_id, task_id, channel, is_card, can_move, moved_from_channel?, moved_from_task? }. */
async function moveInfo(ctx, msgId) {
  const { live, mock, state } = ctx
  const id = String(msgId || '')
  if (mock) {
    const row = state.messages.find((m) => m.msg_id === id)
    if (!row) throw Object.assign(new Error('no such message'), { status: 404, token: 'not_found' })
    /* parent_task_id: mock only. The hub reads a topic by task_id, so a
       reply is found in getTopic(task_id); the mock reads it by
       parent_task_id || task_id and loses it (open-message.mjs). */
    return { msg_id: id, task_id: row.task_id, parent_task_id: row.parent_task_id || undefined, channel: row.channel || null, is_card: row.is_parent !== 0, can_move: row.from === state.me.id }
  }
  return live(`/v1/view/messages/${encodeURIComponent(id)}/move`)
}

/**
 * topic-archive-v1 §5: the archived cards this member may read, newest
 * archived first. { cards: [{ message, msg_id, task_id, channel,
 * archived_at, archived_by, replies, can_delete }], next }.
 */
async function listArchived(ctx, { before } = {}) {
  const { live, mock, state } = ctx
  if (mock) {
    return {
      cards: (state.archived || []).map((m) => ({ message: m, msg_id: m.msg_id, task_id: m.task_id, channel: m.channel || null,
        archived_at: m.archived_at, archived_by: m.archived_by, replies: 0, can_delete: true })),
      next: null,
    }
  }
  const q = before ? `?before=${encodeURIComponent(before)}` : ''
  const body = await live(`/v1/view/archived${q}`)
  const cards = Array.isArray(body && body.cards) ? body.cards : []
  return {
    cards: cards.map((c) => ({ ...c, message: normalizeViewMessage(c.message || {}, '') })),
    next: (body && body.next) || null,
  }
}

/**
 * PUT adds the viewer's emoji; DELETE removes it. Body is {emoji} either
 * way. The same call for an opening message and a reply — the hub does
 * not look at is_parent. Returns { msg_id, task_id, reactions }.
 */
/**
 * SPL-952 — PATCH /v1/messages/{msg_id}/kind, body { kind }. The hub lets
 * the author, a biz_owner or an admin set it (403 not_allowed otherwise)
 * and answers the view element with the kind override beside the envelope.
 */
async function setMessageKind(ctx, msgId, kind) {
  const { live, mock, state } = ctx
  const id = String(msgId || '')
  const k = String(kind || '')
  if (!id || !k) throw Object.assign(new Error('kind required'), { status: 400, token: 'bad_json' })
  if (mock) {
    /* the lde mock member sets any kind, as a biz_owner would */
    const row = state.messages.find((m) => m.msg_id === id)
    if (!row) throw Object.assign(new Error('no such message'), { status: 404, token: 'not_found' })
    row.kind = k
    row.kind_set_by = state.me.id
    row.kind_set_at = new Date().toISOString().replace(/\.\d+Z$/, 'Z')
    return { ...row }
  }
  const data = await live(`/v1/messages/${encodeURIComponent(id)}/kind`, {
    method: 'PATCH',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ kind: k }),
  })
  return normalizeViewMessage(data)
}

async function setReaction(ctx, msgId, emoji, op, current) {
  const { live, mock, state } = ctx
  const id = String(msgId || '')
  const glyph = String(emoji || '')
  if (!id || !glyph) throw Object.assign(new Error('emoji required'), { status: 400, token: 'bad_json' })
  if (mock) {
    /* A mock send from the live store keeps the row in that store and
       does not push it here. The card still has the message, so the
       first emoji on it starts the row from the list the card holds. */
    let row = state.messages.find((m) => m.msg_id === id)
    if (!row) {
      row = { msg_id: id, task_id: '', reactions: Array.isArray(current) ? current.map((r) => ({ emoji: r.emoji, actors: Array.isArray(r.actors) ? r.actors.slice() : [] })) : [] }
      state.messages.push(row)
    }
    const me = state.me.id
    const list = Array.isArray(row.reactions)
      ? row.reactions.map((r) => ({ emoji: r.emoji, actors: Array.isArray(r.actors) ? r.actors.slice() : [] }))
      : []
    const at = list.findIndex((r) => r.emoji === glyph)
    if (op === 'remove') {
      if (at >= 0) {
        list[at].actors = list[at].actors.filter((a) => a !== me)
        if (!list[at].actors.length) list.splice(at, 1)
      }
    } else if (at < 0) {
      list.push({ emoji: glyph, actors: [me] })
    } else if (!list[at].actors.includes(me)) {
      list[at].actors.push(me)
    }
    row.reactions = list.map((r) => ({ emoji: r.emoji, actors: r.actors.slice() }))
    return { msg_id: id, task_id: row.task_id, reactions: row.reactions.map((r) => ({ emoji: r.emoji, actors: r.actors.slice() })) }
  }
  return live(`/v1/messages/${encodeURIComponent(id)}/reactions`, {
    method: op === 'remove' ? 'DELETE' : 'PUT',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ emoji: glyph }),
  })
}

/**
 * channels-v1 §5.1: POST /v1/channels; 409 channel_exists / 400 bad_channel
 * keep their token. `description` (§5.1, 1.2.0) is what the new-channel
 * dialog collected next to the title, and is sent ONLY when there is one:
 * the hub rejects unknown fields, so a no-description create still works
 * against a hub that predates rdb 0027.
 */
async function createChannel(ctx, { channel_id, name, description } = {}) {
  const { live, mock, state } = ctx
  const slug = channelSlug(channel_id || name)
  if (!slug) throw Object.assign(new Error('channel id required'), { status: 400, token: 'bad_channel' })
  const about = String(description || '').trim().slice(0, 500)
  if (mock) {
    if (state.archivedChannels && state.archivedChannels[slug]) {
      throw memberError(409, 'channel_archived', 'reserved: an archived channel has this name')
    }
    const row = { channel_id: slug, name: name || slug, created_by: state.me.id }
    if (about) row.description = about
    if (!state.channels.some((c) => c.channel_id === slug)) {
      state.channels.push(row)
      // channels-v1 §7.4: creating a channel puts its creator in it.
      if (!isPublicChannel(slug)) {
        state.memberships[slug] = [state.me.id]
        state.openInvite[slug] = false
      }
    }
    return row
  }
  let data
  try {
    data = await live('/v1/channels', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({
        channel: slug,
        name: String(name || slug).slice(0, 80),
        ...(about ? { description: about } : {}),
      }),
    })
  } catch (e) {
    const msg = CHANNEL_ERRORS[e && e.token]
    if (msg) e.message = msg(slug)
    throw e
  }
  const [row] = channelsFromView({ channels: [data || { channel: slug }] })
  return row
}

/**
 * channels-v1 §7.4. A default channel answers `default: true`,
 * `members: []` (people: everyone) and the agents someone added. A caller who is not in the channel gets the same 404
 * as a missing channel (`unknown_channel`).
 */
async function listChannelMembers(ctx, channel) {
  const { live, mock } = ctx
  if (mock) return mockMemberList(ctx, channel)
  const data = await live(`/v1/channels/${encodeURIComponent(String(channel || ''))}/members`)
  return parseMemberList(data, channel)
}

/**
 * channels-v1 §7.4: POST `{human_id}`. 201 on success. The caller must
 * already be in the channel and hold `channels.manage`; the target must
 * already be in the tenant. Mock records the id on that channel.
 */
async function addChannelMember(ctx, channel, humanId) {
  const { live, mock } = ctx
  const id = String(humanId || '')
  if (mock) return mockAddMember(ctx, channel, id)
  const data = await live(`/v1/channels/${encodeURIComponent(String(channel || ''))}/members`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ human_id: id }),
  })
  return data || { channel: String(channel || ''), human_id: id }
}

/**
 * Invite one announced agent into the channel. The row survives the
 * box's next announce. 201 {channel, id, box}.
 */
async function addChannelAgent(ctx, channel, agentId, box) {
  const { live, mock } = ctx
  const id = String(agentId || '')
  const boxId = String(box || '')
  if (mock) return mockAddAgent(ctx, channel, id, boxId)
  const data = await live(`/v1/channels/${encodeURIComponent(String(channel || ''))}/agents`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ id, box: boxId }),
  })
  return data || { channel: String(channel || ''), id, box: boxId }
}

/** Take one human out of the channel. Leaving yourself needs no extra permission. */
async function removeChannelMember(ctx, channel, humanId) {
  const { live, mock } = ctx
  const id = String(humanId || '')
  if (mock) return mockRemoveMember(ctx, channel, id)
  await live(`/v1/channels/${encodeURIComponent(String(channel || ''))}/members/${encodeURIComponent(id)}`, {
    method: 'DELETE',
  })
  return null
}

/** Take one agent out. A later announce does not put that agent back. */
async function removeChannelAgent(ctx, channel, agentId, box) {
  const { live, mock } = ctx
  const id = String(agentId || '')
  const boxId = String(box || '')
  if (mock) return mockRemoveAgent(ctx, channel, id, boxId)
  await live(`/v1/channels/${encodeURIComponent(String(channel || ''))}/agents/${encodeURIComponent(boxId)}/${encodeURIComponent(id)}`, {
    method: 'DELETE',
  })
  return null
}

/**
 * channels-v1 membership flag. Only the channel owner may change it.
 * Absent on a read means false. 403 forbidden, 409 channel_public,
 * 404 unknown_channel.
 */
async function setMembersOpenInvite(ctx, channel, open) {
  const { live, mock } = ctx
  const flag = open === true
  if (mock) return mockSetOpen(ctx, channel, flag)
  const data = await live(`/v1/channels/${encodeURIComponent(String(channel || ''))}`, {
    method: 'PATCH',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ members_open_invite: flag }),
  })
  const returned = data && typeof data.members_open_invite === 'boolean' ? data.members_open_invite : flag
  return {
    channel: String((data && (data.channel || data.channel_id)) || channel || ''),
    members_open_invite: returned,
  }
}

/**
 * SPL-72, channels-v1 §5.4: the creator HARD-deletes a channel (rdb 0092),
 * so the name is free again. 204. 404 unknown_channel (not a member),
 * 409 channel_public, 403 forbidden.
 */
async function deleteChannel(ctx, channel) {
  const { live, mock } = ctx
  if (mock) return mockDeleteChannel(ctx, channel)
  await live(`/v1/channels/${encodeURIComponent(String(channel || ''))}`, { method: 'DELETE' })
  return null
}

/**
 * rdb 0092: the creator archives a channel - it is hidden, its slug stays
 * reserved, and its topics move to the Archive view. PUT .../archive, 204.
 * 404 unknown_channel, 409 channel_public, 403 forbidden. Reversible by
 * unarchiveChannel.
 */
async function archiveChannel(ctx, channel) {
  const { live, mock } = ctx
  if (mock) return mockArchiveChannel(ctx, channel)
  await live(`/v1/channels/${encodeURIComponent(String(channel || ''))}/archive`, { method: 'PUT' })
  return null
}

/**
 * rdb 0092: bring an archived channel back (channels.manage). PUT
 * .../unarchive, 200 {channel,...}. 404 when no archived channel by that
 * name.
 */
async function unarchiveChannel(ctx, channel) {
  const { live, mock } = ctx
  if (mock) return mockUnarchiveChannel(ctx, channel)
  const data = await live(`/v1/channels/${encodeURIComponent(String(channel || ''))}/unarchive`, { method: 'PUT' })
  const [row] = channelsFromView({ channels: [data || { channel: normalizeChannelId(channel) }] })
  return row
}

/**
 * specs/039 issues-v1 §1: the tenant's issues with the filters and sort
 * of §4 applied by the hub. `{ prefix, statuses, counts, issues, labels, channel }`.
 */
async function listIssues(ctx, { filter = {}, sort = '' } = {}) {
  const { live, mock, issuesMock } = ctx
  const q = issueQuery(filter, sort)
  if (mock) return issuesMock().list(q)
  return live(`/v1/view/issues${q ? `?${q}` : ''}`)
}

/** issues-v1 §1: one issue by key (SPL-12) → `{ issue }`; 404 not_found. */
async function getIssue(ctx, ref) {
  const { live, mock, issuesMock } = ctx
  if (mock) return issuesMock().get(ref)
  return live(`/v1/view/issues/${encodeURIComponent(String(ref || ''))}`)
}

/** issues-v1 §3: create → `{ issue }`. Refusals keep their token (bad_issue, unknown_label, bad_assignee, unknown_parent). */
async function createIssue(ctx, body = {}) {
  const { live, mock, issuesMock } = ctx
  if (mock) return issuesMock().create(body)
  return live('/v1/issues', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body),
  })
}

/** issues-v1 §3: a partial update; only the fields given change, '' clears → `{ issue }`. */
async function updateIssue(ctx, ref, patch = {}) {
  const { live, mock, issuesMock } = ctx
  if (mock) return issuesMock().update(ref, patch)
  return live(`/v1/issues/${encodeURIComponent(String(ref || ''))}`, {
    method: 'PATCH',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(patch),
  })
}

/** issues-v1 §1 (SPL-1027 / SPL-1226): the soft delete → `{ issue, descendants }`
 *  as it was; 403 forbidden, 409 issue_has_children. With `{ cascade: true }`
 *  a whole epic or feature and all of its descendants go in one call. */
async function deleteIssue(ctx, ref, { cascade = false } = {}) {
  const { live, mock, issuesMock } = ctx
  if (mock) return issuesMock().remove(ref, cascade)
  const q = cascade ? '?cascade=1' : ''
  return live(`/v1/issues/${encodeURIComponent(String(ref || ''))}${q}`, { method: 'DELETE' })
}

/** SPL-1226: soft-archive an issue → `{ issue, descendants }`; with
 *  `{ cascade: true }` the whole epic / feature and its descendants. */
async function archiveIssue(ctx, ref, { cascade = false } = {}) {
  const { live, mock, issuesMock } = ctx
  if (mock) return issuesMock().archive(ref, cascade)
  const q = cascade ? '?cascade=1' : ''
  return live(`/v1/issues/${encodeURIComponent(String(ref || ''))}/archive${q}`, { method: 'POST' })
}

/** issues-v1 §1: a new label in the tenant's catalogue → `{ label }`; 409 label_exists. */
async function createIssueLabel(ctx, { name = '', color = '' } = {}) {
  const { live, mock, issuesMock } = ctx
  if (mock) return issuesMock().label({ name, color })
  return live('/v1/issue-labels', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(color ? { name, color } : { name }),
  })
}

/** The client's lazy half by method name (spool-client.mjs LAZY_METHODS names the same set). */
/* spec 062 (Flow per user): the mock's marks - f:seen and the entries opened */
function mockFlowMarks(state) {
  if (!state.flowMarks) state.flowMarks = { seen: '', opened: new Set() }
  return state.flowMarks
}

/**
 * Spec 062 §4.2: the viewer's flow events, a page (`before` = the hub's
 * cursor), optionally one kind; `countsOnly` reads the counts alone. The hub
 * filters and counts (FR-008); the mock derives both from its feed for `self`.
 * Returns { events, next, counts, unread, keys } (counts = the badge, unread
 * = the chips, keys = unread per sidebar row; each null when the hub sends none).
 */
/** MOCK ONLY: 'off' makes the mock Flow answer without `keys`, as an older hub. */
const MOCK_FLOW_KEYS_OFF = 'spool.mock.flow-keys'

async function listFlow(ctx, { limit = 30, before = '', kind = '', countsOnly = false, self = '' } = {}) {
  const { live, mock, state } = ctx
  if (mock) {
    const marks = mockFlowMarks(state)
    const all = mockFlowEvents(state.messages, self)
    /* the reader's read cursors stand in for the hub's read marks */
    const cursors = loadCursors()
    /* an archived topic's lines are read, as the hub's cover rule has them (t1 56b8cc17) */
    const cards = state.archived || []
    const gone = new Set([...cards.map((m) => String(m.msg_id)), ...cards.map((m) => String(m.task_id))])
    const opened = new Set([...marks.opened, ...all.filter((e) => gone.has(String(e.msg_id)) || gone.has(String(e.task_id)) || gone.has(String(e.parent_task_id || ''))).map((e) => String(e.msg_id))])
    const counts = mockFlowCounts(all, marks.seen, opened, cursors)
    const unread = mockFlowCounts(all, '', opened, cursors)
    /* MOCK_FLOW_KEYS_OFF: the mock answers as a hub without `keys` (the rows keep their own counts) */
    const keys = storageGet(MOCK_FLOW_KEYS_OFF) === 'off' ? null : mockFlowKeys(all, opened, cursors)
    if (countsOnly) return { events: [], next: '', counts, unread, keys }
    const pick = kind ? all.filter((e) => flowEventKind(e.kind) === kind) : all
    const from = Number(before) || 0
    const page = pick.slice(from, from + limit).map((e, i) => ({ ...e, cursor: String(from + i + 1), unread: !opened.has(String(e.msg_id)) }))
    return { events: page, next: from + limit < pick.length ? String(from + limit) : '', counts, unread, keys }
  }
  const q = new URLSearchParams()
  if (countsOnly) q.set('counts_only', 'true')
  else {
    q.set('limit', String(limit))
    if (before) q.set('before', String(before))
    if (kind) q.set('kind', String(kind))
  }
  const data = (await live(`/v1/view/flow?${q}`)) || {}
  return {
    events: Array.isArray(data.events) ? data.events : [],
    next: String(data.next || ''),
    counts: parseFlowCounts(data.counts),
    unread: parseFlowCounts(data.unread),
    keys: parseFlowKeys(data.keys),
  }
}

/**
 * Spec 062 §2.4: write the Flow's read marks - f:seen (the pane opened) and
 * f:<msg_id> (an entry opened) - through the read-marks route. The hub then
 * pushes a `flow` frame to every socket of the member (FR-007).
 */
async function markFlow(ctx, marks) {
  const { live, mock, state } = ctx
  if (mock) {
    const m = mockFlowMarks(state)
    for (const [k, v] of Object.entries(marks || {})) {
      if (k === FLOW_SEEN_KEY) m.seen = String((v && v.ts) || '')
      else if (k.startsWith('f:')) m.opened.add(k.slice(2))
    }
    return null
  }
  return live('/v1/me/reads', {
    method: 'PUT',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ marks }),
    keepalive: true,
  })
}

export const lazySpoolMethods = {
  listFlow,
  markFlow,
  setChannelOrder,
  removeMember,
  listTenantUsers,
  inviteTenantUser,
  setTenantUserRole,
  removeTenantUser,
  auditClones,
  memberActivity,
  revokeTenantInvite,
  patchTenantUser,
  getTenantSettings,
  patchTenantSettings,
  listTenantChannels,
  setTenantChannelNoFallback,
  archiveTenantChannel,
  getPerfSummary,
  editMessage,
  deleteMessage,
  mergeMessage,
  archiveTopic: archiveTopicAndTell,
  topicSize,
  deleteTopic,
  moveTopic,
  moveMessage,
  mergeTopic,
  mergeUndo,
  promoteTopic,
  promoteUndo,
  moveInfo,
  listArchived,
  setMessageKind,
  setReaction,
  createChannel,
  listChannelMembers,
  addChannelMember,
  addChannelAgent,
  removeChannelMember,
  removeChannelAgent,
  setMembersOpenInvite,
  deleteChannel,
  archiveChannel,
  unarchiveChannel,
  listIssues,
  getIssue,
  createIssue,
  updateIssue,
  deleteIssue,
  archiveIssue,
  createIssueLabel,
}
