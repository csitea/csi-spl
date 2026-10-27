// Channel members and agents: who the Properties dialog lists and offers, and
// who may invite, edit or delete (moved out of spool-client.mjs, CLE-77925).
// spool-client.mjs is in the initial JS; these helpers are used only by the
// channel dialogs and the rail menu, which load later, so they live here and
// ride with those chunks. Import them from here, never re-export them from
// spool-client.mjs (that would put them back in the initial JS).
import { isPublicChannel, normalizeChannelId, rosterHumanIds } from '~/utils/spool-client.mjs'
import { isParticipantId } from '~/utils/agent-id.mjs'
import { isoDateTime } from '~/utils/date-iso.mjs'

const HUMAN_ID_RE = /^HUM-[0-9]+$/

/** What the hub says of a channel agent: '' = it did not say. */
export type ChannelAgentState = '' | 'online' | 'offline' | 'unseated'

/** An agent row of the dialog: its state only when the hub said one. */
export type AgentRow = { id: string, box: string, state?: Exclude<ChannelAgentState, ''> }

/** Sort agent rows by id, then box. */
const byIdBox = (a: { id: string, box: string }, b: { id: string, box: string }): number =>
  (a.id < b.id ? -1 : a.id > b.id ? 1 : a.box < b.box ? -1 : a.box > b.box ? 1 : 0)

/**
 * Who the invite picker offers: HUM-* already in the tenant, not already
 * in the channel. Agents, guests and current members are left out.
 */
export function channelInviteCandidates(rosterIds: readonly string[], memberIds: readonly string[]): string[] {
  const members = new Set((memberIds || []).map((id) => String(id)))
  const seen = new Set<string>()
  const out: string[] = []
  for (const raw of rosterIds || []) {
    const id = String(raw || '')
    if (!HUMAN_ID_RE.test(id) || members.has(id) || seen.has(id)) continue
    seen.add(id)
    out.push(id)
  }
  return out
}

/**
 * People the dropdown offers for the text typed so far. Empty text keeps
 * every id. Any other text matches when the id contains it, ignoring case,
 * so "17" finds HUM-17.
 */
export function filterPeopleContains(ids: readonly string[] | null | undefined, query?: string, names: Record<string, string> | null = null): string[] {
  const q = String(query || '').trim().toLowerCase()
  const nameOf = (id: string): string => (names && typeof names === 'object' && Object.hasOwn(names, id) ? String(names[id] || '') : '')
  const out: string[] = []
  for (const raw of ids || []) {
    const id = String(raw || '')
    if (!id) continue
    // the member id, or the display name they chose (owner, 2026-09-26)
    if (!q || id.toLowerCase().includes(q) || nameOf(id).toLowerCase().includes(q)) out.push(id)
  }
  return out
}

/**
 * Agents the dropdown offers for the text typed so far. Empty text keeps
 * every row. Any other text matches when the id or the box contains it,
 * ignoring case, so "desk" finds an agent on box-desk.
 */
export function filterAgentsContains(rows: readonly { id?: string, box?: string }[] | null | undefined, query?: string): { id: string, box: string }[] {
  const q = String(query || '').trim().toLowerCase()
  const out: { id: string, box: string }[] = []
  for (const row of rows || []) {
    if (!row || !row.id) continue
    const id = String(row.id)
    const box = String(row.box || '')
    if (!q || `${id} ${box}`.toLowerCase().includes(q)) out.push({ id, box })
  }
  return out
}

const INVITE_EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/

/**
 * spec 025 section 11: typed text the people picker offers to add by
 * address (a person who has not joined the workspace yet), lower-cased; ''
 * when it is not an address.
 */
export function inviteEmail(text: unknown): string {
  const t = String(text || '').trim().toLowerCase()
  return t.length <= 320 && INVITE_EMAIL_RE.test(t) ? t : ''
}

/** Hub error token (`not_a_member`, `channel_public`, `forbidden`, `unknown_channel`). */
export function inviteErrorToken(err: unknown): string {
  if (err && typeof err === 'object' && (err as { token?: unknown }).token) return String((err as { token?: unknown }).token)
  if (err instanceof Error && err.message) return err.message
  return ''
}

/** Signed-in HUM-* . Live uses /v1/view/me. The mock has no me() and uses the roster. */
export function signedInHuman(me: { humanId?: string | null } | null | undefined, opts: { mock?: boolean, rosterMe?: string } = {}): string {
  const id = me && typeof me.humanId === 'string' ? me.humanId : ''
  if (HUMAN_ID_RE.test(id)) return id
  if (opts && opts.mock) {
    const rosterMe = String(opts.rosterMe || '')
    return HUMAN_ID_RE.test(rosterMe) ? rosterMe : ''
  }
  return ''
}

/**
 * Who this browser is. /v1/view/me wins. The socket welcome is the same HUM-*
 * when that read has not landed yet (a 401 before the session door is armed
 * used to leave the invite plus disabled for the channel owner).
 */
export function viewerHumanId(me: { humanId?: string | null } | null | undefined, socketId?: string, opts: { mock?: boolean, rosterMe?: string } = {}): string {
  const fromMe = signedInHuman(me, opts)
  if (fromMe) return fromMe
  const socket = String(socketId || '')
  return HUMAN_ID_RE.test(socket) ? socket : ''
}

/**
 * Owner, or any current member when members_open_invite is on.
 * A channel recorded as hub or wui has no human owner, so a signed-in
 * member may invite. An empty created_by is not that case.
 * An unknown caller may try; the hub still refuses a non-owner.
 */
export function canAddChannelMember({ selfId, createdBy, membersOpenInvite }: { selfId?: string, createdBy?: string, membersOpenInvite?: boolean } = {}): boolean {
  const self = String(selfId || '')
  const by = String(createdBy || '')
  if (!HUMAN_ID_RE.test(self)) return true
  if (self === by) return true
  if (membersOpenInvite === true) return true
  return by !== '' && !HUMAN_ID_RE.test(by)
}

/**
 * Announced agents the channel can still invite. Humans and the browser
 * box are not agents. An agent already in the channel is left out.
 */
export function channelAgentCandidates(roster: Record<string, readonly string[]> | null | undefined, current: readonly { id?: string, box?: string }[] | null | undefined): { id: string, box: string }[] {
  const have = new Set((current || []).map((row) => String(row && row.id) + '\0' + String(row && row.box)))
  const out: { id: string, box: string }[] = []
  const seen = new Set<string>()
  const boxes = roster && typeof roster === 'object' ? Object.keys(roster) : []
  boxes.sort()
  for (const box of boxes) {
    if (box === 'box-wui') continue
    const ids = Array.isArray(roster?.[box]) ? roster[box] : []
    for (const raw of ids) {
      const id = String(raw || '')
      if (!isParticipantId(id) || id.startsWith('HUM-')) continue
      const key = id + '\0' + box
      if (have.has(key) || seen.has(key)) continue
      seen.add(key)
      out.push({ id, box })
    }
  }
  out.sort(byIdBox)
  return out
}

/** The Settings checkbox is enabled only for the channel owner. */
export function canEditOpenInvite({ selfId, createdBy }: { selfId?: string, createdBy?: string } = {}): boolean {
  const self = String(selfId || '')
  return HUMAN_ID_RE.test(self) && self === String(createdBy || '')
}

/**
 * SPL-72: Delete is offered on a created channel to the member who created
 * it, and to nobody else - no role widens it (channels-v1 §5.4). A default
 * channel never. The hub refuses anyone else anyway; this only hides it.
 */
export function canDeleteChannel({ selfId, row }: { selfId?: string, row?: { channel_id?: string, default?: boolean, created_by?: string } } = {}): boolean {
  const r: { channel_id?: string, default?: boolean, created_by?: string } = row || {}
  if (r.default === true || isPublicChannel(normalizeChannelId(String(r.channel_id || '')))) return false
  return canEditOpenInvite({ selfId, createdBy: r.created_by })
}

/**
 * SPL-987: whether a channel agent can hear the channel, from the hub's
 * members answer. 'unseated' = its box no longer lists it (seated false);
 * 'online' / 'offline' = its box does, with / without a live socket to the
 * hub. '' = the hub did not say (an older hub, or a row added in this dialog).
 * Neither state says the agent's terminal is running - the hub cannot see it.
 */
export function channelAgentState(raw: { online?: boolean, seated?: boolean, state?: string } | null | undefined): ChannelAgentState {
  if (!raw || typeof raw !== 'object') return ''
  if (raw.seated === false) return 'unseated'
  if (raw.online === true) return 'online'
  if (raw.online === false) return 'offline'
  if (raw.state === 'online' || raw.state === 'offline' || raw.state === 'unseated') return raw.state
  return ''
}

/**
 * SPL-997 (spec 038 FR-035): the "fallback responder" line of a channel, from
 * the hub's members answer `fallback`. null = the hub did not say (an older
 * hub, or the fallback is off). id '' = no agent of the workspace is online,
 * so a post here reaches no agent now. active = no member agent is online, so
 * posts go to the fallback now. recent = the channel's fallback deliveries of
 * the last 7 days (count, newest agent, newest instant as YYYY-MM-DD HH:MM UTC).
 * off = the channel opted out (FR-039, a proof / test channel): nobody gets
 * its unheard posts.
 */
export function channelFallbackLine(input: unknown): { id: string, box: string, active: boolean, off: boolean, recent: { count: number, id: string, at: string } } | null {
  if (!input || typeof input !== 'object') return null
  const raw = input as { id?: unknown, box?: unknown, recent?: unknown, active?: unknown, off?: unknown }
  const rawId = String(raw.id || '')
  const id = isParticipantId(rawId) && !rawId.startsWith('HUM-') ? rawId : ''
  const box = id ? String(raw.box || '') : ''
  const rec = (raw.recent && typeof raw.recent === 'object' ? raw.recent : {}) as { count?: unknown, at?: unknown, id?: unknown }
  const count = Number.isInteger(rec.count) && Number(rec.count) > 0 ? Number(rec.count) : 0
  /* SPL-2144: in the viewer's zone, like every clock (it printed the hub's UTC digits) */
  const at = count && typeof rec.at === 'string' && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}/.test(rec.at)
    ? isoDateTime(rec.at)
    : ''
  return { id, box, active: raw.active === true && raw.off !== true, off: raw.off === true, recent: { count, id: count ? String(rec.id || '') : '', at } }
}

/** Agents that receive the channel. People and the browser box are not agents. */
export function channelAgentRows(agents: readonly { id?: string, box?: string, online?: boolean, seated?: boolean }[] | null | undefined): AgentRow[] {
  const rows: AgentRow[] = []
  const seen = new Set<string>()
  for (const raw of agents || []) {
    const id = String((raw && raw.id) || '')
    const box = String((raw && raw.box) || '')
    if (!id || /^HUM-/.test(id) || box === 'box-wui') continue
    const key = id + '\0' + box
    if (seen.has(key)) continue
    seen.add(key)
    const state = channelAgentState(raw)
    rows.push(state ? { id, box, state } : { id, box })
  }
  rows.sort(byIdBox)
  return rows
}

/**
 * Who a default channel (lobby, alerts, feedback) lists: every person of the
 * tenant, read-only, and only the agents someone added (owner decision
 * 2026-09-25). An announced agent is NOT in it until a member picks it.
 */
export function defaultChannelRows(roster: Record<string, readonly string[]> | null | undefined, subscribed: readonly { id?: string, box?: string, online?: boolean, seated?: boolean }[] | null | undefined): { people: string[], agents: AgentRow[] } {
  const people = channelInviteCandidates(rosterHumanIds(roster), [])
  const agents = channelAgentRows(subscribed || [])
  return { people, agents }
}

export function aboutChannelName(row: { name?: string, channel_id?: string, channel?: string } | null | undefined): string {
  const name = String((row && row.name) || '').trim()
  if (name) return name
  return String((row && (row.channel_id || row.channel)) || '')
}

export function aboutChannelDescription(row: { description?: string } | null | undefined): string {
  return String((row && row.description) || '').trim()
}
