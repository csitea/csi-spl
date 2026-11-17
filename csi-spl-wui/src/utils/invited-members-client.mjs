/**
 * Spec 025 section 13 (SPL-5706): the workspace's inactive members, the
 * people holding an open invite who have not signed in yet.
 *
 *   GET /v1/view/members/invited?workspace=  {invited: [{id, label, masked, invited_on, expires_at}]}
 *
 * The hub answers it to a signed-in person who is a member of the workspace;
 * a Bearer token or an act-as session is 403 person_only. `label` is the
 * address, its masked form (j…@example.com, `masked: true`) in the demo
 * except to a members.invite holder, or "" (`masked: true`) in a name-only
 * workspace (t1 by default), to everyone: there an invitee has no name and
 * the page shows `people.invitee_no_name` (spec 154 section 12.6, SPL-5830;
 * owner HUM-10 msg 10b28abb). `id` (INV-<16 hex>) adds or removes the person
 * in a channel when the address is masked. Any refusal throws
 * { status, error } (status 0 off the network). The mock (useMock) answers
 * one invitee, with no label in t1 like the hub.
 */
import { BOOT_READ_TIMEOUT_MS } from './fetch-timeouts.mjs'

const refused = (status, error) => Object.assign(new Error(`status ${status}`), { status, error })

/** The list URL, scoped to the caller's workspace (`api.tenant`). */
function invitedMembersUrl(api) {
  const q = api.tenant ? '?workspace=' + encodeURIComponent(String(api.tenant)) : ''
  return `${String(api.base || '').replace(/\/+$/, '')}/v1/view/members/invited${q}`
}

/** The mock's one invitee: invitee@example.com, with no label in t1. */
const MOCK_INVITEE = Object.freeze({ id: 'INV-6e6577636f6d6572', email: 'invitee@example.com' })

/**
 * The rows as the hub sends them; a row with no id, or with no label that is
 * not masked, is dropped. A masked row with no label is an invitee with no
 * name (a name-only workspace): the page names it (`people.invitee_no_name`).
 */
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
    .filter((r) => r.id && (r.label || r.masked))
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
    return invitedRows({ invited: [{ id: MOCK_INVITEE.id, label: masked ? '' : MOCK_INVITEE.email, masked,
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
 * channel members answer): their keys in order, and the label of each key; a
 * masked row with no label takes `unnamed` (the page's
 * `people.invitee_no_name`).
 */
export function inviteeKeys(rows, unnamed = '') {
  const keys = []
  const labels = {}
  for (const r of rows || []) {
    if (!r || !r.id) continue
    const label = r.label || (r.masked ? unnamed : '')
    if (!label) continue
    const key = inviteeKey(r)
    if (labels[key]) continue
    keys.push(key)
    labels[key] = label
  }
  return { keys, labels }
}
