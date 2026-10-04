/**
 * The admin's Users page (specs/025 FR-012): GET /v1/members,
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
    suspended: m.suspended === true,
    lastSeen: str(m.last_seen),
    /* spec 072 A27: when the membership stops granting access ('' = no end) */
    accessUntil: str(m.access_until),
    accessEnded: m.access_ended === true,
    you: m.you === true,
    manageable: m.manageable === true,
    /* CLE-77778: the invite this member accepted — who ordered it and when */
    orderedBy: str(m.ordered_by),
    orderedByName: str(m.ordered_by_name),
    orderedVia: str(m.ordered_via),
    invitedOn: str(m.invited_on),
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
    /* CLE-77781: how many invitation mails have gone out (0 = none sent yet,
       e.g. a NO_MAIL operator invite). The pane shows it as mailed/not mailed. */
    mailCount: typeof i.mail_count === 'number' && i.mail_count > 0 ? i.mail_count : 0,
    /* HUM-10 2026-10-03: when the last invitation mail went out ('' = never).
       A re-invite resets mail_count but not this, so "was it mailed" reads here. */
    mailedAt: str(i.mailed_at),
    /* CLE-77778: who ordered this invite (a HUM-* id / display name) and via what */
    orderedBy: str(i.ordered_by),
    orderedByName: str(i.ordered_by_name),
    orderedVia: str(i.ordered_via),
    /* the list's own tenant (047 W13: the invite link names it) */
    tenant: str(b.tenant_id),
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

/**
 * Spec 072 A27: the access_until a date input means — the END of that local
 * day (the next local midnight), as RFC 3339 UTC. '' for no / a bad date.
 */
export function accessUntilOfDate(day) {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(day || ''))
  if (!m) return ''
  const at = new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3]) + 1)
  return Number.isNaN(at.getTime()) ? '' : at.toISOString().replace(/\.\d{3}Z$/, 'Z')
}

/** The local day (YYYY-MM-DD) a stored access_until ends; '' for none. The inverse of accessUntilOfDate. */
export function accessDateOf(iso) {
  const at = new Date(String(iso || ''))
  if (!iso || Number.isNaN(at.getTime())) return ''
  const last = new Date(at.getTime() - 1)
  const pad = (n) => String(n).padStart(2, '0')
  return `${last.getFullYear()}-${pad(last.getMonth() + 1)}-${pad(last.getDate())}`
}

/** The i18n key for a failed call's hub token ('' → the generic one). */
export function userErrorKey(err) {
  const token = err && typeof err.token === 'string' ? err.token : ''
  const known = ['forbidden', 'last_admin', 'last_owner', 'self', 'bad_email', 'bad_role', 'role_changed', 'not_found', 'shared_account', 'bad_name', 'bad_locale', 'bad_access_until', 'not_migrated']
  return 'users.error.' + (known.includes(token) ? token : 'generic')
}

/**
 * 047 W13: the link an admin hands an invitee when no mail arrives. It is the
 * sign-in page of the tenant (the shape invitemail.SignInURL mails) and carries
 * no secret: admission is the verified-email match. '' without a tenant.
 */
export function inviteLink(origin, tenant, email = '') {
  const o = String(origin || '').replace(/\/+$/, '')
  const id = String(tenant || '').trim()
  if (!o || !id) return ''
  // SPL-1231: the invitee's own address rides as a sign-in hint (named on the
  // login page, pre-selected at Google / Microsoft); admission is unchanged.
  const e = String(email || '').trim().toLowerCase()
  const hint = /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(e) ? `&login_hint=${encodeURIComponent(e)}` : ''
  return `${o}/login?tenant=${encodeURIComponent(id)}${hint}`
}

/** A loose address check before the round trip; the hub has the last word. */
export function looksLikeEmail(s) {
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(String(s || '').trim())
}

/** Whether an invitation mail ever went out for this invite (HUM-10). */
export function inviteMailed(row) {
  return Boolean(row && (row.mailCount > 0 || row.mailedAt))
}

/**
 * The open (unexpired) pending invite for `email` in a normalizeDirectory()
 * result, or null. HUM-10: re-submitting the invite form for such an address
 * used to re-create it silently (and reset its mail count); the page opens
 * the existing invite instead.
 */
export function openInviteFor(dir, email) {
  const e = String(email || '').trim().toLowerCase()
  if (!e || !dir || !Array.isArray(dir.invites)) return null
  return dir.invites.find((i) => i.email === e && !i.expired) || null
}

/**
 * The i18n key for a POST /v1/members/invites `mail` outcome after the admin
 * clicked Send / Resend: 'sent', 'rate_limited' (mailed too recently; the hub
 * keeps the earlier mail), else the invite stands and no mail went out.
 */
export function mailOutcomeKey(outcome) {
  if (outcome === 'sent') return 'users.invited'
  if (outcome === 'rate_limited') return 'users.mail_rate_limited'
  return 'users.mail_not_sent'
}
