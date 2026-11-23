/**
 * The private-workspace order (spec 181 4.1, row B3): an order form, no card
 * [Q-18 C]. The hub route is B2's `POST /api/v1/checkout/private-workspace`
 * (csi-spl-api internal/payments/handler.go `submitOrder`): a signed-in
 * person's order only, the biz_owner is the session's email; it answers 201
 * with the order, 200 when the same order is replayed.
 *
 * The price lines mirror the hub's B1 plan (internal/store/price_plans.go):
 * PrivateVMSeatCents = 900, PlanCurrency = EUR, PrivateVMMarginPct = 33. The
 * hub has no read of that plan before the submit yet, so these three are the
 * one WUI copy; the submit's answer carries the hub's own values and the page
 * shows those once it has them. There is NO token line and never will be:
 * we never resell tokens [Q-10 A, P5]. The VM line has no number: no route
 * gives the VM's estimated cost yet, so the page names how it is priced.
 */

export const ORDER_ROUTE = '/api/v1/checkout/private-workspace'

/** The B1 plan, as the hub writes it: seat cents per human member, EUR, VM cost + 33 %. */
export const PRIVATE_VM_PLAN = Object.freeze({ currency: 'EUR', seatMemberCents: 900, vmMarginPct: 33 })

/** The only price lines the page shows: seats and the VM cost (P5: never a token line). */
export const PRICE_LINES = Object.freeze(['seat_member', 'vm_cost'])

/** The hub's error tokens of the submit that the page has its own copy for. */
const ORDER_ERRORS = new Set(['unauthorized', 'email_mismatch', 'bad_tenant_id', 'tenant_taken', 'bad_seats', 'bad_billing', 'network'])

/** The catalogue key for a submit error token; '' for none, the generic one for an unknown one. */
export function orderErrorKey(code) {
  const c = String(code || '')
  if (!c) return ''
  return ORDER_ERRORS.has(c) ? `checkout_private.error.${c}` : 'checkout_private.error.generic'
}

/** Seats as a whole number >= 1, or 0 for anything else. */
export function seatCount(v) {
  const n = Number(v)
  return Number.isInteger(n) && n >= 1 ? n : 0
}

/**
 * seats x the seat price, in cents; 0 for a bad seat count.
 * @param {unknown} seats
 * @param {{ seatMemberCents: number }} [plan]
 */
export function seatsMonthCents(seats, plan = PRIVATE_VM_PLAN) {
  return seatCount(seats) * Number(plan.seatMemberCents || 0)
}

/** The plan as the submit's answer states it, else the WUI copy. */
export function planFromAnswer(data) {
  const d = data || {}
  const cents = Number(d.seat_member_cents)
  const pct = Number(d.vm_margin_pct)
  return {
    currency: String(d.currency || PRIVATE_VM_PLAN.currency),
    seatMemberCents: d.seat_member_cents != null && Number.isFinite(cents) && cents >= 0 ? cents : PRIVATE_VM_PLAN.seatMemberCents,
    vmMarginPct: d.vm_margin_pct != null && Number.isFinite(pct) && pct >= 0 ? pct : PRIVATE_VM_PLAN.vmMarginPct,
  }
}

/**
 * The order body B2 takes: tenant_id, seats_users, billing {name, address,
 * country, vat_id}, locale. No email (the hub takes the session's) and no
 * payment field of any kind.
 */
export function orderBody(form) {
  const f = form || {}
  const vat = String(f.vatId || '').trim()
  return {
    tenant_id: String(f.tenant || '').trim().toLowerCase(),
    seats_users: seatCount(f.seats),
    billing: {
      name: String(f.name || '').trim(),
      address: String(f.address || '').trim(),
      country: String(f.country || '').trim().toUpperCase(),
      ...(vat ? { vat_id: vat } : {}),
    },
    ...(f.locale ? { locale: String(f.locale) } : {}),
  }
}

/** The page-side check before the submit: the first bad field's error token, or ''. */
export function orderInvalid(body, validTenant) {
  if (!validTenant(body.tenant_id)) return 'bad_tenant_id'
  if (body.seats_users < 1) return 'bad_seats'
  const b = body.billing
  if (!b.name || !b.address || !/^[A-Z]{2}$/.test(b.country)) return 'bad_billing'
  return ''
}

/**
 * POST the order. Resolves (never throws) to { ok, status, data, error }:
 * `error` is the hub's token, 'network' when the hub was not reached.
 */
export async function submitOrder(body, { fetchFn = globalThis.fetch, base = '', timeoutMs = 20000 } = {}) {
  let res
  try {
    res = await fetchFn(`${String(base || '').replace(/\/+$/, '')}${ORDER_ROUTE}`, {
      method: 'POST',
      credentials: 'include',
      cache: 'no-store',
      headers: { accept: 'application/json', 'content-type': 'application/json' },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(timeoutMs),
    })
  } catch {
    return { ok: false, status: 0, data: null, error: 'network' }
  }
  let data = null
  try { data = await res.json() } catch { data = null }
  if (res.ok) return { ok: true, status: res.status, data, error: '' }
  return { ok: false, status: res.status, data: null, error: String((data && data.error) || 'unavailable') }
}
