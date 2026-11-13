/**
 * Spec 154 section 12 (SPL-5431): a member's card with their address.
 *
 *   GET /v1/view/members/{id}/card?workspace=  {human_id, display_name, email}
 *
 * The hub answers it to a signed-in person who is a member of the same
 * workspace; another workspace's member is 404 not_found, a Bearer token or
 * an act-as session 403 person_only. No bearer here: the card is a person's.
 * Any refusal throws { status, error } (status 0 off the network); the person
 * card then shows no Email row. In a name-only workspace (section 12.4, the
 * hub's SPOOL_HUB_MEMBER_CARD_NAME_ONLY_WORKSPACES, t1 by default) the hub
 * answers email null, and the card shows no Email row either. The mock
 * (useMock) answers an example.com address for a HUM-<n> id, null in t1 like
 * the hub, and 404 for anything else.
 */
import { BOOT_READ_TIMEOUT_MS } from './fetch-timeouts.mjs'

const refused = (status, error) => Object.assign(new Error(`status ${status}`), { status, error })

/** The card URL for member `id`, scoped to the caller's workspace (`api.tenant`). */
export function memberCardUrl(api, id) {
  const q = api.tenant ? '?workspace=' + encodeURIComponent(String(api.tenant)) : ''
  return `${String(api.base || '').replace(/\/+$/, '')}/v1/view/members/${encodeURIComponent(id)}/card${q}`
}

/** The card as the hub sends it: email and display_name are a string or null. */
function shaped(out) {
  const str = (v) => (typeof v === 'string' && v.trim() ? v.trim() : null)
  return { human_id: String(out?.human_id || ''), display_name: str(out?.display_name), email: str(out?.email) }
}

/** Reads member `id`'s card; throws { status, error } on any refusal (status 0 offline). */
export async function memberCard(api, id) {
  if (api.mock) {
    if (!/^HUM-\d+$/.test(String(id))) throw refused(404, 'not_found')
    const email = api.tenant === 't1' ? null : String(id).toLowerCase() + '@example.com'
    return { human_id: id, display_name: null, email }
  }
  let res
  try {
    res = await fetch(memberCardUrl(api, id), {
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
  return shaped(out)
}
