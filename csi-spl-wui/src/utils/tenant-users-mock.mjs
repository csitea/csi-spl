/**
 * The mock hub's member directory (NUXT_PUBLIC_USE_MOCK=1). Its
 * own module so spool-client loads it only in a mock build (dynamic import):
 * the initial chunk stays inside the 027 budget (SPL-1037).
 */
import { looksLikeEmail } from './tenant-users.mjs'


function mockErr(status, token) {
  const e = new Error(`spool ${status} ${token}`)
  e.status = status
  e.token = token
  return e
}

/** The hub's invitemail.DefaultMinGap: least time between two mails of one invite. */
export const MOCK_MAIL_GAP_MS = 10 * 60 * 1000

/**
 * The hub's rules for one POST /v1/members/invites (CLE-77780, FR-016): every
 * POST (re)stores the invite and resets mail_count, keeping mailed_at; no_mail
 * sends nothing; a mailing POST mails unless the last mail is under
 * MOCK_MAIL_GAP_MS old ('rate_limited'). HUM-10 2026-10-03: the page hid that
 * skip; the mock reproduces it so the e2e can drive it.
 */
function mockMailStep(prev, at, noMail) {
  const last = prev?.mailed_at || null
  if (noMail) return { mail: 'not_sent', mailCount: 0, mailedAt: last }
  if (last && at.getTime() - new Date(last).getTime() < MOCK_MAIL_GAP_MS) return { mail: 'rate_limited', mailCount: 0, mailedAt: last }
  return { mail: 'sent', mailCount: 1, mailedAt: at.toISOString() }
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
    invite(email, role, { noMail } = {}) {
      const e = String(email || '').trim().toLowerCase()
      if (!looksLikeEmail(e)) throw mockErr(400, 'bad_email')
      const r = role || 'developer'
      if (!MOCK_ROLES.includes(r)) throw mockErr(400, 'bad_role')
      if (r === 'biz_owner') throw mockErr(403, 'forbidden')
      const at = now()
      const { mail, mailCount, mailedAt } = mockMailStep(invites.find((i) => i.email === e), at, noMail)
      invites = invites.filter((i) => i.email !== e)
      invites.push({ email: e, role: r, invited_by: you, created_at: at.toISOString(), expires_at: new Date(at.getTime() + 7 * 864e5).toISOString(), mail_count: mailCount, mailed_at: mailedAt })
      return { email: e, role: r, mail }
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
    patch(id, p = {}) {
      const m = find(id)
      if (!m) throw mockErr(404, 'not_found')
      if (m.role === 'biz_owner') throw mockErr(403, 'forbidden')
      if (p.disabled === true && id === you) throw mockErr(409, 'self')
      if (p.disabled === true && m.role === 'admin' && admins(id) === 0) throw mockErr(409, 'last_admin')
      if (p.display_name !== undefined) {
        const n = String(p.display_name).trim()
        if (!n) throw mockErr(400, 'bad_name')
        m.display_name = n
      }
      if (p.disabled !== undefined) m.suspended = Boolean(p.disabled)
      return null
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
