/**
 * The web-UI sign-in relay (spec 181 row B11, gap G11; owner Q-5, Q-14 A;
 * spec 159 4.3): a workspace's biz owner or admin signs the CLI on the
 * workspace's private VM in to their own subscription, from this page only.
 *   POST   /v1/signin-relay               { kind } -> { relay, kind, box, state, expires_at }
 *   GET    /v1/signin-relay/{relay}       -> { relay, kind, box, state, url?, reason?, expires_at }
 *   POST   /v1/signin-relay/{relay}/input { input } -> { relay, state: 'input_sent' }
 *   DELETE /v1/signin-relay/{relay}       -> 204
 * The hub's switch is per vendor and off by default (403 signin_relay_off).
 * The typed code is sent once and cleared; nothing here keeps it, and the
 * mock below never stores it either.
 * Node tests import this file; components/SigninRelayPanel.vue and the lazy
 * client half (its mock) do too.
 */

/** The kinds with a subscription login (159 4.2, 4.3; O1, O2, O3). */
export const SIGNIN_RELAY_KINDS = Object.freeze(['claude', 'grok', 'mistral'])

/** The states that end a relay: nothing more to wait for. */
export const SIGNIN_RELAY_DONE = Object.freeze(['signed_in', 'delivered', 'failed', 'ended'])

/** The longest code the hub takes (hub signinRelayInputMax). */
const SIGNIN_RELAY_INPUT_MAX = 512

/** True for one line of 1..512 bytes with no control character. */
export function signinInputOK(s) {
  if (typeof s !== 'string' || s === '') return false
  if (new TextEncoder().encode(s).length > SIGNIN_RELAY_INPUT_MAX) return false
  // eslint-disable-next-line no-control-regex
  return !/[\u0000-\u001f\u007f-\u009f]/.test(s)
}

/** The vendor URL when it is an https URL with a host, else ''. Only such a URL becomes a link. */
export function signinSafeUrl(u) {
  if (typeof u !== 'string' || u === '') return ''
  try {
    const p = new URL(u)
    return p.protocol === 'https:' && p.host ? p.href : ''
  } catch {
    return ''
  }
}

/** The relay view the panel reads; anything else reads as failed. */
export function normalizeSigninRelay(body) {
  const b = body && typeof body === 'object' ? body : {}
  const str = (v) => (typeof v === 'string' ? v : '')
  return { relay: str(b.relay), kind: str(b.kind), state: str(b.state) || 'failed', url: signinSafeUrl(b.url), reason: str(b.reason) }
}

/** A refusal -> its i18n key under tenant_settings.agent_keys.signin.error. */
export function signinRelayErrorKey(err) {
  const token = err && typeof err.token === 'string' ? err.token : ''
  const known = ['signin_relay_off', 'no_private_vm', 'bad_input', 'not_found']
  return 'tenant_settings.agent_keys.signin.error.' + (known.includes(token) ? token : 'generic')
}

/* ---- the mock hub (NUXT_PUBLIC_USE_MOCK) --------------------------------- */

/** The mock's "switch on" list (e2e: 'claude'); absent = off, as the hub ships. */
export const SIGNIN_RELAY_MOCK_KINDS_KEY = 'spool.mock.signin_relay_kinds'

const mockRelays = new Map()

function relayError(status, token) {
  const err = new Error(token)
  err.status = status
  err.token = token
  return err
}

function mockKindsOn(store) {
  try {
    const s = store || (typeof globalThis.localStorage !== 'undefined' ? globalThis.localStorage : null)
    return String((s && s.getItem(SIGNIN_RELAY_MOCK_KINDS_KEY)) || '').split(/[ ,]+/).filter(Boolean)
  } catch {
    return []
  }
}

/** One mock relay op; never keeps the input. */
export function mockSigninRelay(op, id, body, store) {
  if (op === 'start') {
    const kind = body && body.kind
    if (!mockKindsOn(store).includes(kind)) throw relayError(403, 'signin_relay_off')
    const relay = 'mock-relay-' + (mockRelays.size + 1)
    mockRelays.set(relay, { relay, kind, box: 'vm-1', state: 'url', url: 'https://example.com/oauth/authorize?mock=1' })
    return { relay, kind, box: 'vm-1', state: 'starting' }
  }
  const r = mockRelays.get(id)
  if (!r) throw relayError(404, 'not_found')
  if (op === 'get') return { ...r }
  if (op === 'input') {
    if (!signinInputOK(body && body.input)) throw relayError(400, 'bad_input')
    r.state = 'signed_in'
    return { relay: id, state: 'input_sent' }
  }
  if (op === 'end') {
    r.state = 'ended'
    return null
  }
  throw new Error('signinRelay: unknown op ' + op)
}
