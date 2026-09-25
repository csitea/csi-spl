/**
 * The admin's Users page (specs/025 FR-012, CLE-34969): GET /v1/members,
 * POST /v1/members/invites, PUT /v1/members/{id}/role, DELETE
 * /v1/members/{id}, DELETE /v1/members/invites?email=.
 *
 * Unlike access.mjs this gate does NOT fail open: the entry shows only when
 * the hub listed members.invite for the signed-in member. The hub re-checks
 * every call; hiding is convenience. Node tests import this file.
 */

/** The permission behind the Users entry and every members.invite route. */
export const USERS_PERMISSION = 'members.invite'

/**
 * Which side of the list the edit pane opens on. The owner may ask for the
 * other side (CLE-100 is asking); this constant is the one switch.
 * 'right' is where a message opens its topic pane.
 */
export const USER_PANE_SIDE = 'right'

/**
 * Whether the sidebar shows Users. `me` is normalizeMe()'s shape. The mock
 * build has no /v1/view/me and plays the admin, so the e2e can drive the page.
 */
export function usersEntryVisible(me, { mock = false } = {}) {
  if (mock) return true
  return Boolean(me && Array.isArray(me.permissions) && me.permissions.includes(USERS_PERMISSION))
}

const str = (v) => (typeof v === 'string' ? v : '')

/** A GET /v1/members body → { you, members[], invites[], roles[] } with safe types. */
export function normalizeDirectory(body) {
  const b = body && typeof body === 'object' ? body : {}
  const members = (Array.isArray(b.members) ? b.members : []).filter((m) => m && str(m.human_id)).map((m) => ({
    kind: 'member',
    key: 'm:' + m.human_id,
    humanId: m.human_id,
    displayName: str(m.display_name),
    email: str(m.email),
    role: str(m.role),
    since: str(m.since),
    disabled: m.disabled === true,
    you: m.you === true,
    manageable: m.manageable === true,
  }))
  const invites = (Array.isArray(b.invites) ? b.invites : []).filter((i) => i && str(i.email)).map((i) => ({
    kind: 'invite',
    key: 'i:' + i.email,
    email: i.email,
    role: str(i.role),
    invitedBy: str(i.invited_by),
    createdAt: str(i.created_at),
    expiresAt: str(i.expires_at),
    expired: i.expired === true,
  }))
  const roles = (Array.isArray(b.roles) ? b.roles : []).filter((r) => r && str(r.id)).map((r) => ({ id: r.id, grantable: r.grantable === true }))
  return { you: str(b.you), members, invites, roles }
}

/** One label for a member row: the name, else the address, else the id. */
export function memberLabel(row) {
  if (!row) return ''
  if (row.kind === 'invite') return row.email
  return row.displayName || row.email || row.humanId
}

/** The i18n key for a failed call's hub token ('' → the generic one). */
export function userErrorKey(err) {
  const token = err && typeof err.token === 'string' ? err.token : ''
  const known = ['forbidden', 'last_admin', 'last_owner', 'self', 'bad_email', 'bad_role', 'role_changed', 'not_found']
  return 'users.error.' + (known.includes(token) ? token : 'generic')
}

/** A loose address check before the round trip; the hub has the last word. */
export function looksLikeEmail(s) {
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(String(s || '').trim())
}

/* ---- mock directory (NUXT_PUBLIC_USE_MOCK=1) ---------------------------- */

function mockErr(status, token) {
  const e = new Error(`spool ${status} ${token}`)
  e.status = status
  e.token = token
  return e
}

const MOCK_ROLES = ['biz_owner', 'product_owner', 'admin', 'developer', 'tester', 'pure_agent', 'biz_customer', 'regular_user']

/**
 * The hub's rules in memory: the viewer (HUM-1) is an admin; a biz_owner is
 * beyond the admin's reach; nobody removes themselves; the last admin stays.
 */
export function createMockDirectory(now = () => new Date()) {
  const t0 = '2026-09-20T09:00:00Z'
  const members = [
    { human_id: 'HUM-1', display_name: 'Admin (you)', email: 'admin@example.com', role: 'admin', since: t0 },
    { human_id: 'HUM-2', display_name: 'Owner', email: 'owner@example.com', role: 'biz_owner', since: t0 },
    { human_id: 'HUM-3', display_name: 'Dev One', email: 'dev1@example.com', role: 'developer', since: '2026-09-21T10:00:00Z' },
    { human_id: 'HUM-12', display_name: 'Tess Tester', email: 'tester@example.com', role: 'tester', since: '2026-09-22T11:00:00Z' },
  ]
  let invites = [{ email: 'pending@example.com', role: 'developer', invited_by: 'HUM-1', created_at: '2026-09-24T08:00:00Z', expires_at: '2026-10-01T08:00:00Z' }]
  const you = 'HUM-1'
  const admins = (except) => members.filter((m) => m.human_id !== except && m.role === 'admin').length
  const find = (id) => members.find((m) => m.human_id === id)
  return {
    list() {
      return {
        tenant_id: 'mock',
        you,
        members: members.map((m) => ({ ...m, you: m.human_id === you, manageable: m.human_id !== you && m.role !== 'biz_owner' })),
        invites: invites.map((i) => ({ ...i, expired: new Date(i.expires_at) <= now() })),
        roles: MOCK_ROLES.map((id) => ({ id, grantable: id !== 'biz_owner' })),
      }
    },
    invite(email, role) {
      const e = String(email || '').trim().toLowerCase()
      if (!looksLikeEmail(e)) throw mockErr(400, 'bad_email')
      const r = role || 'developer'
      if (!MOCK_ROLES.includes(r)) throw mockErr(400, 'bad_role')
      if (r === 'biz_owner') throw mockErr(403, 'forbidden')
      const at = now()
      invites = invites.filter((i) => i.email !== e)
      invites.push({ email: e, role: r, invited_by: you, created_at: at.toISOString(), expires_at: new Date(at.getTime() + 7 * 864e5).toISOString() })
      return { email: e, role: r, mail: 'not_configured' }
    },
    setRole(id, role) {
      const m = find(id)
      if (!m) throw mockErr(404, 'not_found')
      if (!MOCK_ROLES.includes(role)) throw mockErr(400, 'bad_role')
      if (m.role === 'biz_owner' || role === 'biz_owner') throw mockErr(403, 'forbidden')
      if (m.role === 'admin' && role !== 'admin' && admins(id) === 0) throw mockErr(409, 'last_admin')
      m.role = role
      return { human_id: id, role }
    },
    remove(id) {
      const m = find(id)
      if (!m) throw mockErr(404, 'not_found')
      if (m.role === 'biz_owner') throw mockErr(403, 'forbidden')
      if (id === you) throw mockErr(409, 'self')
      if (m.role === 'admin' && admins(id) === 0) throw mockErr(409, 'last_admin')
      members.splice(members.indexOf(m), 1)
      return null
    },
    revoke(email) {
      const e = String(email || '').trim().toLowerCase()
      if (!invites.some((i) => i.email === e)) throw mockErr(404, 'not_found')
      invites = invites.filter((i) => i.email !== e)
      return null
    },
  }
}
