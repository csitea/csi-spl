// SPL-4453 (rows 5 and 9 of the F12 console report SPL-4422): the admin and
// operator reads of Monitoring and Reporting decide from /v1/view/me first;
// a member sends none, an unknown reader still reads (the hub's 403 is the control).
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { countedRead, gateMe, lanesReadPlan, operatorReadable, permReadable, staffReadable } from '../../src/utils/read-gates.mjs'
import { normalizeMe } from '../../src/utils/access.mjs'

const me = (body) => normalizeMe(body)
const MEMBER = me({ role: 'member', roles: ['member'], tenant_owner: false, permissions: ['topics.read'] })
const DEVELOPER = me({ role: 'developer', permissions: ['topics.read', 'notes.send'] })
const ADMIN = me({ role: 'admin', roles: ['admin'], permissions: ['topics.read', 'audit.read'] })
const OWNER = me({ role: 'member', roles: ['member'], tenant_owner: true, permissions: ['topics.read'] })
const BIZ = me({ role: 'biz_owner', permissions: ['members.invite'] })
const SECOND_ADMIN = me({ role: 'developer', roles: ['developer', 'admin'], permissions: ['topics.read'] })

describe('read gates (SPL-4453)', () => {
  it('a member sends no operator, staff or audit read', () => {
    for (const m of [MEMBER, DEVELOPER]) {
      assert.equal(operatorReadable(m), false)
      assert.equal(staffReadable(m), false)
      assert.equal(permReadable(m, 'audit.read'), false)
      assert.equal(lanesReadPlan(m), 'none')
    }
  })

  it('an admin reads the fleet first; operator_admin false (SPL-4451) sends the own lanes straight away', () => {
    assert.equal(operatorReadable(ADMIN), true)
    assert.equal(lanesReadPlan(ADMIN), 'fleet')
    assert.equal(permReadable(ADMIN, 'audit.read'), true)
    const notOp = { ...ADMIN, operatorAdmin: false }
    assert.equal(operatorReadable(notOp), false)
    assert.equal(lanesReadPlan(notOp), 'own')
  })

  it('staff is the hub pair: the tenant owner, biz_owner (the owner role) or admin in the role set; none of them is an operator by it', () => {
    for (const m of [OWNER, BIZ, SECOND_ADMIN]) {
      assert.equal(staffReadable(m), true)
      assert.equal(operatorReadable(m), false)
      assert.equal(lanesReadPlan(m), 'own')
    }
  })

  it('an unknown reader fails open: no answer, or a door-off guest with no permission list', () => {
    for (const m of [null, undefined, me({ role: null, permissions: null })]) {
      assert.equal(operatorReadable(m), true)
      assert.equal(staffReadable(m), true)
      assert.equal(permReadable(m, 'audit.read'), true)
      assert.equal(lanesReadPlan(m), 'fleet')
    }
  })

  it('gateMe loads /v1/view/me only when the store has none', async () => {
    let loads = 0
    const store = { me: null, load: async () => { loads++; store.me = MEMBER } }
    assert.equal(await gateMe(store), MEMBER)
    assert.equal(await gateMe(store), MEMBER)
    assert.equal(loads, 1)
  })

  it('countedRead records a mock 403 by its path and rethrows; a live build or another status records nothing', async () => {
    const g = /** @type {{ SPOOL_MOCK_403?: string[] }} */ (globalThis)
    delete g.SPOOL_MOCK_403
    const refuse = (status) => async () => { throw Object.assign(new Error('x'), { status }) }
    await assert.rejects(countedRead({ mock: true }, '/v1/view/lanes', refuse(403)))
    await assert.rejects(countedRead({ mock: false }, '/v1/view/file-streams', refuse(403)))
    await assert.rejects(countedRead({ mock: true }, '/v1/operator/fleet-tokens', refuse(500)))
    let route = '/v1/operator/fleet-lanes'
    await assert.rejects(countedRead({ mock: true }, () => route, async () => { route = '/v1/view/lanes'; throw Object.assign(new Error('x'), { status: 403 }) }))
    assert.deepEqual(g.SPOOL_MOCK_403, ['GET /v1/view/lanes', 'GET /v1/view/lanes'])
    assert.equal(await countedRead({ mock: true }, '/v1/reporting/marketing', async () => 7), 7)
    delete g.SPOOL_MOCK_403
  })
})
