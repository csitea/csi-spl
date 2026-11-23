// spec 181 row B3: the private-workspace order util (utils/private-workspace-order.mjs).
// - the WUI copy of the B1 plan equals the hub's Go constants
//   (csi-spl-api .../internal/store/price_plans.go): a drift fails here. A hub
//   read of the private_vm plan (+ a VM estimate) is to replace the copy.
// - the order body carries no email and no payment field [Q-18 C], and the
//   price lines are seats and the VM cost only, never a token line [Q-10 A].
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  ORDER_ROUTE, PRICE_LINES, PRIVATE_VM_PLAN, orderBody, orderErrorKey, orderInvalid,
  planFromAnswer, seatsMonthCents, submitOrder,
} from '../../src/utils/private-workspace-order.mjs'
import { validTenant } from '../../src/utils/tenant.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const GO_PLAN = join(WUI, '../csi-spl-api/src/go/spool-hub-api/internal/store/price_plans.go')
const HANDLER = join(WUI, '../csi-spl-api/src/go/spool-hub-api/internal/payments/handler.go')

function goConst(src, name) {
  const m = src.match(new RegExp(`\\b${name}\\s*=\\s*("?)([^"\\s]+)\\1`))
  assert.ok(m, `${name} not found in price_plans.go`)
  return m[2]
}

describe('private-workspace order (spec 181 B3)', () => {
  it('the WUI plan copy equals the hub B1 constants (drift guard)', () => {
    const src = readFileSync(GO_PLAN, 'utf8')
    assert.equal(PRIVATE_VM_PLAN.seatMemberCents, Number(goConst(src, 'PrivateVMSeatCents')))
    assert.equal(PRIVATE_VM_PLAN.vmMarginPct, Number(goConst(src, 'PrivateVMMarginPct')))
    assert.equal(PRIVATE_VM_PLAN.currency, goConst(src, 'PlanCurrency'))
  })

  it('the route is the hub B2 submit route', () => {
    const src = readFileSync(HANDLER, 'utf8')
    assert.match(src, /RoutePrefix\s+=\s+"\/api\/v1\/checkout"/)
    assert.match(src, /RouteOrder\s+=\s+RoutePrefix \+ "\/private-workspace"/)
    assert.equal(ORDER_ROUTE, '/api/v1/checkout/private-workspace')
  })

  it('the price lines are seats and the VM cost only, no token line (P5)', () => {
    assert.deepEqual([...PRICE_LINES], ['seat_member', 'vm_cost'])
    assert.equal(seatsMonthCents(3), 2700)
    assert.equal(seatsMonthCents(0), 0)
    assert.equal(seatsMonthCents('2.5'), 0)
  })

  it('the body is the order only: no email, no card, no payment field', () => {
    const b = orderBody({ tenant: ' Acme-1 ', seats: '2', name: 'Example Oy', address: 'Street 1', country: 'fi', vatId: '', locale: 'fi' })
    assert.deepEqual(b, { tenant_id: 'acme-1', seats_users: 2, billing: { name: 'Example Oy', address: 'Street 1', country: 'FI' }, locale: 'fi' })
    assert.doesNotMatch(JSON.stringify(b), /card|email|payment|token|cvc|iban/i)
    assert.equal(orderBody({ vatId: 'FI123' }).billing.vat_id, 'FI123')
  })

  it('the page-side check names the first bad field', () => {
    const good = orderBody({ tenant: 'acme', seats: 1, name: 'n', address: 'a', country: 'FI' })
    assert.equal(orderInvalid(good, validTenant), '')
    assert.equal(orderInvalid({ ...good, tenant_id: 'api' }, validTenant), 'bad_tenant_id')
    assert.equal(orderInvalid({ ...good, seats_users: 0 }, validTenant), 'bad_seats')
    assert.equal(orderInvalid({ ...good, billing: { ...good.billing, country: 'FIN' } }, validTenant), 'bad_billing')
  })

  it('error tokens map to their catalogue keys, unknown ones to generic', () => {
    assert.equal(orderErrorKey(''), '')
    assert.equal(orderErrorKey('unauthorized'), 'checkout_private.error.unauthorized')
    assert.equal(orderErrorKey('tenant_taken'), 'checkout_private.error.tenant_taken')
    assert.equal(orderErrorKey('internal'), 'checkout_private.error.generic')
  })

  it('the answer plan wins over the copy; a missing value keeps the copy', () => {
    assert.deepEqual(planFromAnswer({ currency: 'EUR', seat_member_cents: 1000, vm_margin_pct: 30 }), { currency: 'EUR', seatMemberCents: 1000, vmMarginPct: 30 })
    assert.deepEqual(planFromAnswer({}), { ...PRIVATE_VM_PLAN })
  })

  it('submitOrder posts JSON with credentials to base + route, never throws', async () => {
    const seen = []
    const fetchFn = async (url, init) => { seen.push({ url, init }); return new Response(JSON.stringify({ order_id: 'wo_x', tenant_id: 'acme' }), { status: 201 }) }
    const out = await submitOrder({ tenant_id: 'acme' }, { fetchFn, base: 'https://api.example.com/' })
    assert.equal(out.ok, true)
    assert.equal(out.status, 201)
    assert.equal(seen[0].url, 'https://api.example.com/api/v1/checkout/private-workspace')
    assert.equal(seen[0].init.method, 'POST')
    assert.equal(seen[0].init.credentials, 'include')
    const refused = await submitOrder({}, { fetchFn: async () => new Response(JSON.stringify({ error: 'unauthorized' }), { status: 401 }) })
    assert.deepEqual([refused.ok, refused.error], [false, 'unauthorized'])
    const down = await submitOrder({}, { fetchFn: async () => { throw new Error('x') } })
    assert.equal(down.error, 'network')
  })
})
