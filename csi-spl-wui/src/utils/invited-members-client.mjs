/**
 * Spec 025 section 13 (SPL-5706): the workspace's inactive members, the
 * people holding an open invite who have not signed in yet.
 *
 *   GET /v1/view/members/invited?workspace=  {invited: [{id, label, masked, invited_on, expires_at}]}
 *
 * The hub answers it to a signed-in person who is a member of the workspace;
 * a Bearer token or an act-as session is 403 person_only. `label` is the
 * address, or its masked form (j…@example.com, `masked: true`) where a member
 * card shows no address (a name-only workspace, t1 by default), except to a
 * members.invite holder. `id` (INV-<16 hex>) adds or removes the person in a
 * channel when the address is masked. Any refusal throws { status, error }
 * (status 0 off the network). The mock (useMock) answers one invitee, masked
 * in t1 like the hub.
 */
import { BOOT_READ_TIMEOUT_MS } from './fetch-timeouts.mjs'

const refused = (status, error) => Object.assign(new Error(`status ${status}`), { status, error })

/** The list URL, scoped to the caller's workspace (`api.tenant`). */
function invitedMembersUrl(api) {
  const q = api.tenant ? '?workspace=' + encodeURIComponent(String(api.tenant)) : ''
  return `${String(api.base || '').replace(/\/+$/, '')}/v1/view/members/invited${q}`
}

/** The mock's one invitee: newcomer@example.com, masked in t1. */
const MOCK_INVITEE = Object.freeze({ id: 'INV-6e6577636f6d6572', email: 'newcomer@example.com', masked: 'n…@example.com' })

/** The rows as the hub sends them; a row with no id or label is dropped. */
function invitedRows(out) {
  const list = Array.isArray(out?.invited) ? out.invited : []
  return list
    .map((r) => ({
      id: String(r?.id || ''),
      label: String(r?.label || ''),
      masked: r?.masked === true,
      invitedOn: typeof r?.invited_on === 'string' ? r.invited_on : '',
      expiresAt: typeof r?.expires_at === 'string' ? r.expires_at : '',
    }))
    .filter((r) => r.id && r.label)
}

/**
 * The key a channel picker uses for an invitee: the address when it is shown
 * (the add and the undo take it, spec 025 section 11), else the invite id.
 */
function inviteeKey(row) {
  return row.masked ? row.id : row.label
}

/** Reads the inactive members; throws { status, error } on any refusal. */
export async function invitedMembers(api) {
  if (api.mock) {
    const masked = api.tenant === 't1'
    return invitedRows({ invited: [{ id: MOCK_INVITEE.id, label: masked ? MOCK_INVITEE.masked : MOCK_INVITEE.email, masked,
      invited_on: '2026-11-16T09:00:00Z', expires_at: '2026-11-23T09:00:00Z' }] })
  }
  let res
  try {
    res = await fetch(invitedMembersUrl(api), {
      method: 'GET',
      credentials: api.credentials,
      headers: { accept: 'application/json' },
      signal: AbortSignal.timeout(BOOT_READ_TIMEOUT_MS),
    })
  } catch {
    throw refused(0, '')
  }
  const out = await res.json().catch(() => null)
  if (!res.ok) throw refused(res.status, String(out?.error || ''))
  return invitedRows(out)
}

/**
 * The picker's view of invitee rows ({id, label, masked}, from this list or a
 * channel members answer): their keys in order, and the label of each key.
 */
export function inviteeKeys(rows) {
  const keys = []
  const labels = {}
  for (const r of rows || []) {
    if (!r || !r.id || !r.label) continue
    const key = inviteeKey(r)
    if (labels[key]) continue
    keys.push(key)
    labels[key] = r.label
  }
  return { keys, labels }
}
