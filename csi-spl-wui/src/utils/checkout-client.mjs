/**
 * Tenant checkout client (specs/006-spool-hub-rental/contracts/checkout-v1.md 1.2).
 * Same-origin: Hosting rewrites /api/v1/checkout/** to the hub (lde: nitro devProxy).
 *
 * Secrets, and where they may live:
 *   - claim_token: sessionStorage ONLY (§1.2). Never a URL, localStorage, a
 *     log line or an error message. Dropped after a successful claim (§2.4).
 *   - the emailed link token (§1.8): arrives in the URL FRAGMENT, is read once
 *     and cleared from the address bar by the claim page, then held in memory.
 *   - root_private_key: returned by the claim to the caller, which holds it in
 *     component memory. This module never stores, logs or puts it in a URL.
 */
import { validTenant } from './tenant.mjs'
import { cardKeyUsable } from './card-element.mjs'

export const CHECKOUT_PREFIX = '/api/v1/checkout'

/** sessionStorage keys. checkout_id is not a secret (§1.3 carries none). */
export const CHECKOUT_STORE_ID = 'spool.checkout.id'
export const CHECKOUT_STORE_CLAIM = 'spool.checkout.claim'

const ERRORS = {
  bad_request: 'Check the email address and try again.',
  bad_tenant_id: 'That name is not allowed — use lower-case letters, digits and dashes.',
  tenant_taken: 'That name is taken — pick another one.',
  payment_unavailable: 'Checkout is unavailable right now — try again later.',
  not_found: 'We cannot find this checkout.',
  not_paid: 'The payment is not confirmed yet.',
  claimed: 'This key was already collected — on the success page or from the emailed link.',
  claim_expired: 'The claim window has closed — contact support to re-key the tenant.',
  conflict: 'This tenant was re-keyed meanwhile — contact support.',
  bad_link: 'This link is incomplete — open the link from the email again.',
  not_fake_checkout: 'This checkout is not a test checkout.',
  not_pending: 'This checkout is closed.',
  no_token: 'This browser tab does not hold the claim for this checkout — open the success page in the tab you paid from.',
  timeout: 'The payment is still not confirmed — reload this page in a minute.',
  network: 'The hub did not answer — try again.',
  storage_blocked: 'This browser blocks session storage — allow it for this site and try again.',
  card_declined: 'The card was not accepted — check the details and try again.',
  card_failed: 'The card payment did not go through — try again, or use another card.',
  card_sdk: 'The card form did not load — check your connection or content blocker and reload.',
}

const GENERIC_ERROR = 'Something went wrong — try again.'

/** Copy for an error token. Never echoes hub `detail` (it could carry input). */
export function checkoutErrorMessage(code) {
  const c = String(code || '')
  if (!c) return ''
  return ERRORS[c] || GENERIC_ERROR
}

/**
 * spec 021: the catalogue key for checkoutErrorMessage(code) — the pages
 * render it through t(); the English above stays the en source. null for an
 * empty code, `checkout.error.generic` for an unknown one.
 */
export function checkoutErrorKey(code) {
  const c = String(code || '')
  if (!c) return null
  return { key: Object.hasOwn(ERRORS, c) ? `checkout.error.${c}` : 'checkout.error.generic', params: {} }
}

/** Every checkout error code with its English copy (en catalogue source + tests). */
export function checkoutErrorCopy() {
  return { ...ERRORS, generic: GENERIC_ERROR }
}

/** One NumberFormat per locale, built on first use (a new one per call costs
 *  ~x25 a reused one); null for a locale Intl refuses. */
const PRICE_FORMATS = new Map()
function priceFormat(locale) {
  if (!PRICE_FORMATS.has(locale)) {
    let f = null
    try {
      f = new Intl.NumberFormat(locale, { minimumFractionDigits: 2, maximumFractionDigits: 2 })
    } catch { /* unknown locale → the plain form */ }
    PRICE_FORMATS.set(locale, f)
  }
  return PRICE_FORMATS.get(locale)
}

/**
 * "20.00 EUR"; unknown / bad amounts → ''. With a `locale` (spec 021: the
 * active UI locale) the amount uses that locale's digits and separators,
 * e.g. 'fi' → "20,00 EUR"; without one the output is unchanged.
 */
export function formatPrice(cents, currency, locale) {
  const n = Number(cents)
  if (!Number.isFinite(n) || n < 0) return ''
  let amount = (n / 100).toFixed(2)
  const fmt = locale ? priceFormat(String(locale)) : null
  if (fmt) amount = fmt.format(n / 100)
  return `${amount} ${String(currency || '').toUpperCase()}`.trim()
}

/**
 * What the plan page can offer (checkout-v1 1.1 §1.1):
 *   'fake'        — rail=fake (lde/dev): the form, then "Pay (dev fake)"
 *   'card'        — rail=card with a usable publishable key: the form, then
 *                   the card step (card-element.mjs)
 *   'none'        — rail=none, or available=false: not on sale
 *   'unsupported' — a rail this page has no payment step for (a card rail
 *                   without a usable publishable key, or anything unknown):
 *                   no form, so no checkout holds a slug that the page cannot
 *                   take payment for
 */
export function checkoutMode(plan) {
  const p = plan || {}
  const rail = String(p.rail || 'none')
  if (rail === 'none' || p.available === false) return 'none'
  if (rail === 'fake') return 'fake'
  if (rail === 'card' && cardKeyUsable(p.publishable_key)) return 'card'
  return 'unsupported'
}

/**
 * §1.8: `#checkout=<id>&token=<t>` → { id, token }; anything malformed → ''s.
 * Pure: the page clears the fragment itself (history.replaceState).
 */
export function readClaimFragment(hash) {
  const q = new URLSearchParams(String(hash || '').replace(/^#/, ''))
  const id = String(q.get('checkout') || '')
  const token = String(q.get('token') || '')
  if (!/^co_[A-Za-z0-9_-]{1,64}$/.test(id) || !/^[A-Za-z0-9_-]{16,256}$/.test(token)) return { id: '', token: '' }
  return { id, token }
}

/** A file name for the key download: `<tenant>.root.key`. */
export function keyFileName(tenant) {
  return `${validTenant(tenant) ? tenant : 'tenant'}.root.key`
}

// ── storage (sessionStorage only) ─────────────────────────────────────────

function session(storage) {
  if (storage) return storage
  try { return globalThis.sessionStorage || null } catch { return null }
}

export function saveCheckout({ checkout_id, claim_token } = {}, storage) {
  const s = session(storage)
  if (!s) return false
  try {
    s.setItem(CHECKOUT_STORE_ID, String(checkout_id || ''))
    s.setItem(CHECKOUT_STORE_CLAIM, String(claim_token || ''))
    return true
  } catch {
    return false
  }
}

/** { id, token } from sessionStorage; '' for what is missing. */
export function loadCheckout(storage) {
  const s = session(storage)
  if (!s) return { id: '', token: '' }
  try {
    return { id: String(s.getItem(CHECKOUT_STORE_ID) || ''), token: String(s.getItem(CHECKOUT_STORE_CLAIM) || '') }
  } catch {
    return { id: '', token: '' }
  }
}

/** Drop the claim token (§2.4). The id stays so a reload can show "already claimed". */
export function dropClaimToken(storage) {
  const s = session(storage)
  try { if (s) s.removeItem(CHECKOUT_STORE_CLAIM) } catch { /* nothing to drop */ }
}

/** Drop both keys: a new checkout starts clean. */
export function forgetCheckout(storage) {
  const s = session(storage)
  try {
    if (s) { s.removeItem(CHECKOUT_STORE_CLAIM); s.removeItem(CHECKOUT_STORE_ID) }
  } catch { /* nothing to drop */ }
}

// ── HTTP ──────────────────────────────────────────────────────────────────

export function createCheckoutClient({ fetchFn = globalThis.fetch, base = '' } = {}) {
  const root = String(base || '').replace(/\/+$/, '')

  /**
   * Resolves (never throws) to { ok, status, data, error }: `error` is the hub
   * envelope token, 'network' when the hub was not reached, 'unavailable' for
   * a non-JSON failure. A request body never reaches an error or a log.
   */
  async function call(path, { method = 'GET', body } = {}) {
    let res
    try {
      res = await fetchFn(`${root}${CHECKOUT_PREFIX}${path}`, {
        method,
        credentials: 'same-origin',
        cache: 'no-store',
        headers: body === undefined
          ? { accept: 'application/json' }
          : { accept: 'application/json', 'content-type': 'application/json' },
        body: body === undefined ? undefined : JSON.stringify(body),
      })
    } catch {
      return { ok: false, status: 0, data: null, error: 'network' }
    }
    let data = null
    try { data = await res.json() } catch { data = null }
    if (res.ok) return { ok: true, status: res.status, data, error: '' }
    return { ok: false, status: res.status, data: null, error: String((data && data.error) || 'unavailable') }
  }

  return {
    /** §1.1 → data { plan_id, amount_cents, currency, rail, tenant_url_pattern }. */
    plan() {
      return call('/plan')
    },
    /**
     * §1.2 → data { checkout_id, claim_token, method, rail, tenant_url } (+ client_secret, publishable_key on rail=card). `method` omitted = the default.
     *
     * `locale` (spec 021 T022) is the ACTIVE UI locale, kept on the checkout
     * row (rdb 0025) so the claim mail the hub sends after the payment speaks
     * the language the buyer bought in. It rides the BODY, not a header: a
     * custom header would preflight, and a hub whose CORS allow-list lacks it
     * would refuse the whole checkout (the same trap that broke sign-in,
     * 2e2c601). Omitted when empty; the hub falls back to its default and
     * refuses nothing, so an unknown code costs the buyer nothing.
     */
    start({ tenant_id, email, locale } = {}) {
      const loc = String(locale || '').trim()
      return call('', {
        method: 'POST',
        body: { tenant_id: String(tenant_id || ''), email: String(email || ''), ...(loc ? { locale: loc } : {}) },
      })
    },
    /** §1.3 → data { checkout_id, tenant_id, status, claimed, tenant_host, host_status }. */
    status(id) {
      return call(`/${encodeURIComponent(String(id || ''))}`)
    },
    /** §1.4 → data { tenant_id, tenant_url, root_private_key, emailed }. Pages go through claimOnce. */
    claim({ checkout_id, claim_token } = {}) {
      return call('/claim', { method: 'POST', body: { checkout_id: String(checkout_id || ''), claim_token: String(claim_token || '') } })
    },
    /** §1.5, lde/dev only. */
    fakePay(id) {
      return call('/fake-pay', { method: 'POST', body: { checkout_id: String(id || '') } })
    },
  }
}

// ── claim exactly once ────────────────────────────────────────────────────

/**
 * In-flight / settled claims by checkout id, module-wide, so a re-mounted
 * success page or two overlapping polls share ONE POST /claim.
 */
const CLAIMS = new Map()

/**
 * POST /claim for this checkout at most once per page load (either token,
 * §1.4). Outcomes:
 *   { state: 'ok', result }    — the key is in `result`; the token is dropped
 *   { state: 'claimed' }       — 410 claimed: collected before, by either token
 *   { state: 'expired' }       — 410 claim_expired: past the claim window
 *   { state: 'error', error }  — anything else (409 not_paid / conflict, 404,
 *                                5xx, network); the page may offer ONE
 *                                user-initiated retry via resetClaim()
 */
export function claimOnce(client, { id, token } = {}, storage) {
  const key = String(id || '')
  if (CLAIMS.has(key)) return CLAIMS.get(key)
  const p = (async () => {
    const out = await client.claim({ checkout_id: key, claim_token: token })
    if (out.ok && out.data && out.data.root_private_key) {
      dropClaimToken(storage)
      return { state: 'ok', result: out.data }
    }
    if (out.status === 410) {
      dropClaimToken(storage)
      return { state: out.error === 'claim_expired' ? 'expired' : 'claimed' }
    }
    return { state: 'error', error: out.ok ? 'unavailable' : out.error }
  })()
  CLAIMS.set(key, p)
  return p
}

/** Forget a FAILED claim so a user click may try once more. */
export async function resetClaim(id) {
  const key = String(id || '')
  const p = CLAIMS.get(key)
  if (!p) return
  const out = await p
  if (out.state === 'error') CLAIMS.delete(key)
}

/**
 * §2.3: poll status until paid, then claimOnce. Returns the claimOnce outcome,
 * { state: 'claimed' } when the status already says claimed, or
 * { state: 'failed' | 'cancelled' | 'stopped' | 'error', error? }.
 * `isStopped()` ends the loop (page left); `sleep` is injectable for tests.
 */
export async function pollAndClaim(client, { id, token } = {}, {
  storage,
  intervalMs = 2000,
  maxPolls = 450,
  sleep = (ms) => new Promise((r) => setTimeout(r, ms)),
  isStopped = () => false,
  onStatus = () => {},
} = {}) {
  for (let i = 0; i < maxPolls; i++) {
    if (isStopped()) return { state: 'stopped' }
    const st = await client.status(id)
    if (isStopped()) return { state: 'stopped' }
    if (st.ok) {
      const s = String((st.data && st.data.status) || '')
      onStatus(s)
      if (st.data && st.data.claimed === true) {
        dropClaimToken(storage)
        return { state: 'claimed' }
      }
      if (s === 'paid') {
        if (!token) return { state: 'error', error: 'no_token' }
        return claimOnce(client, { id, token }, storage)
      }
      if (s === 'failed' || s === 'cancelled') return { state: s }
    } else if (st.status === 404) {
      return { state: 'error', error: 'not_found' }
    }
    await sleep(intervalMs)
  }
  return { state: 'error', error: 'timeout' }
}

// ── the tenant host (specs/024) ───────────────────────────────────────────

/**
 * There is no wildcard host: the tenant's own address <tenant>.<fqdn> is
 * provisioned by a scheduled reconcile after the payment (mapping, DNS record,
 * certificate: typically 15-30 min). `host_status` on §1.3 / §1.4 reads
 * 'pending' until it answers, then 'ready' ('unknown' = the hub cannot tell).
 * Polls §1.3 until the host is no longer pending and resolves to the last
 * host_status seen, or 'stopped' when `isStopped()` (page left). A failed
 * poll is retried; nothing here throws.
 */
export async function pollHostReady(client, id, {
  intervalMs = 30000,
  maxPolls = 240,
  sleep = (ms) => new Promise((r) => setTimeout(r, ms)),
  isStopped = () => false,
} = {}) {
  let last = 'pending'
  for (let i = 0; i < maxPolls; i++) {
    if (isStopped()) return 'stopped'
    const st = await client.status(id)
    if (isStopped()) return 'stopped'
    if (st.ok && st.data && st.data.host_status) {
      last = String(st.data.host_status)
      if (last !== 'pending') return last
    }
    await sleep(intervalMs)
  }
  return last
}
