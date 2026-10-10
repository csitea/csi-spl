/**
 * Spec 073 4.6 (Tenant settings -> Agents): the join-token panel's pure
 * helpers. The panel itself is JoinTokensPanel.vue, loaded on demand.
 */
import { accessAllows } from './access.mjs'

/** The hub permission that mints, lists and revokes join tokens and seats (rbac.AgentsJoin). */
export const AGENTS_JOIN = 'agents.join'

/**
 * Whether the session sees the join-token controls. A hub that lists the
 * session's permissions decides (admin holds agents.join, biz_owner does
 * not); like accessAllows, no list at all fails open and the hub's 403 is
 * the control.
 * @param {{ permissions?: string[] | null } | null} me normalizeMe() output
 */
export function canJoinAgents(me) {
  return accessAllows(me, AGENTS_JOIN)
}

/** One row of GET /v1/tenant/agents/join-tokens, defaulted. */
export function normalizeJoinToken(r) {
  const o = r && typeof r === 'object' ? r : {}
  const s = (v) => (typeof v === 'string' ? v : '')
  const state = ['open', 'used', 'revoked'].includes(o.state) ? o.state : 'open'
  return {
    id: s(o.id),
    label: s(o.label),
    boxId: s(o.box_id),
    forHuman: s(o.for_human),
    createdBy: s(o.created_by),
    expiresAt: s(o.expires_at),
    state,
    consumedBox: s(o.consumed_box),
  }
}

/**
 * Whether the hub mints join tokens for this workspace: spec 108's switch
 * (section 3.8), off by default and turned on only by the hub operator. The
 * list answers it as `enabled`; a hub that predates the switch answers none,
 * which keeps the old behaviour (its mint is the control).
 */
export function joinEnabled(body) {
  return !(body && body.enabled === false)
}

/** The list answer -> rows, open ones first, then by expiry. */
export function joinTokenRows(body) {
  const list = body && Array.isArray(body.tokens) ? body.tokens : []
  const rank = { open: 0, used: 1, revoked: 2 }
  return list.map(normalizeJoinToken).filter((r) => r.id)
    .sort((a, b) => rank[a.state] - rank[b.state] || a.expiresAt.localeCompare(b.expiresAt))
}

/**
 * Time left until expiresAt as h:mm:ss / m:ss, '' once passed or unparsable.
 * The lifetime comes from the hub's answer, never a literal here.
 */
export function joinCountdown(expiresAt, nowMs = Date.now()) {
  const end = Date.parse(String(expiresAt || ''))
  if (!Number.isFinite(end)) return ''
  const left = Math.floor((end - nowMs) / 1000)
  if (left <= 0) return ''
  const h = Math.floor(left / 3600)
  const m = Math.floor((left % 3600) / 60)
  const sec = String(left % 60).padStart(2, '0')
  return h ? `${h}:${String(m).padStart(2, '0')}:${sec}` : `${m}:${sec}`
}

/** The seated boxes of a roster (box-wui excluded), sorted, once each. */
export function seatedBoxes(seats) {
  const out = new Set()
  for (const s of Array.isArray(seats) ? seats : []) {
    const b = s && typeof s.box === 'string' ? s.box : ''
    if (b && b !== 'box-wui') out.add(b)
  }
  return [...out].sort()
}

/** The mint body: empty optional fields are omitted, box id lower-cased. */
export function joinMintBody({ label = '', boxId = '', forHuman = '' } = {}) {
  const body = {}
  const l = String(label).trim()
  const b = String(boxId).trim().toLowerCase()
  const h = String(forHuman).trim().toUpperCase()
  if (l) body.label = l
  if (b) body.box_id = b
  if (h) body.for_human = h
  return body
}

/**
 * The members a token may be for (spec 073 4.1 for_human): a current member,
 * so not disabled and access_until absent or still ahead. [{ id, name }].
 */
export function joinMemberOptions(body, nowMs = Date.now()) {
  const list = body && Array.isArray(body.members) ? body.members : []
  const out = []
  for (const m of list) {
    const id = m && typeof m.human_id === 'string' ? m.human_id : ''
    if (!/^HUM-[0-9]+$/.test(id) || m.disabled === true) continue
    const until = typeof m.access_until === 'string' && m.access_until ? Date.parse(m.access_until) : NaN
    if (Number.isFinite(until) && until <= nowMs) continue
    out.push({ id, name: typeof m.display_name === 'string' && m.display_name ? m.display_name : id })
  }
  return out
}
