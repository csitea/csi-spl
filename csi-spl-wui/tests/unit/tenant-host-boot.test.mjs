// SPL-959: the arrival hops of a tenant host (utils/tenant-host-boot.mjs).
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { reactive, ref, nextTick } from 'vue'

import { bootTenantHost } from '../../src/utils/tenant-host-boot.mjs'
import { classifyHref } from '../../src/utils/link-target.mjs'

const SITE = 'https://app.example'
const PUB = { siteUrl: SITE, tenant: 't1', apiBase: 'https://api.app.example' }
const U = '0b8a6a52-6c1e-4f5e-9d1e-2c7b7f5e8a11'
const MEMBER_T1 = { tenants: [{ tenant_id: 't1' }, { tenant_id: 'northwind' }] }

function rig(href, { claims = MEMBER_T1, locateTo = '', state = 'in' } = {}) {
  const u = new URL(href)
  const replaced = []
  const fetched = []
  const win = { location: { href, pathname: u.pathname, search: u.search, hash: u.hash, replace: (x) => replaced.push(x) } }
  const fetchFn = async (url, opts) => {
    fetched.push({ url, opts })
    return locateTo
      ? { ok: true, json: async () => ({ tenant: locateTo }) }
      : { ok: false, json: async () => ({}) }
  }
  const session = reactive({ state, claims })
  const notMember = ref({ tenant: '', home: '' })
  const page = u.hostname === 'app.example' ? 't1' : u.hostname.split('.')[0]
  bootTenantHost({ pub: PUB, page, session, notMember, win, fetchFn })
  return { replaced, fetched, notMember, session }
}
const settle = async () => { for (let i = 0; i < 5; i++) { await nextTick(); await new Promise((r) => setTimeout(r, 0)) } }

describe('tenant-host boot', () => {
  it('apex + ?tenant=<t> hops to t with the same path (the sign-in return)', async () => {
    const r = rig(SITE + '/issues?issue=SPL-3&tenant=northwind', { state: 'loading' })
    assert.deepEqual(r.replaced, ['https://northwind.app.example/issues?issue=SPL-3'])
  })
  it('apex old topic link of another tenant: locate, then that host, same path', async () => {
    const r = rig(`${SITE}/channel/general?topic=${U}`, { locateTo: 'northwind' })
    await settle()
    assert.equal(r.fetched[0].url, `https://api.app.example/v1/view/locate/${U}`)
    assert.equal(r.fetched[0].opts.credentials, 'include')
    assert.deepEqual(r.replaced, [`https://northwind.app.example/channel/general?topic=${U}`])
  })
  it('CONTROL: an apex topic of t1 itself stays; an issue link is never located', async () => {
    const a = rig(`${SITE}/t/${U}`, { locateTo: 't1' })
    const b = rig(`${SITE}/issues?issue=SPL-12`, { locateTo: 'northwind' })
    await settle()
    assert.deepEqual(a.replaced, [])
    assert.deepEqual(b.replaced, [])
    assert.equal(b.fetched.length, 0)
  })
  it('apex, not a member of t1: the last used tenant host', async () => {
    const r = rig(SITE + '/', { claims: { tenants: [{ tenant_id: 'globex' }, { tenant_id: 'northwind', last_active_at: '2026-09-26T10:00:00Z' }] } })
    await settle()
    assert.deepEqual(r.replaced, ['https://northwind.app.example/'])
  })
  it('a tenant host the viewer is not a member of: "not a member", no hop, no data', async () => {
    const r = rig('https://globex.app.example/issues', { claims: { tenants: [{ tenant_id: 't1' }] } })
    await settle()
    assert.deepEqual(r.replaced, [])
    assert.deepEqual(r.notMember.value, { tenant: 'globex', home: 'https://app.example/' })
  })
  it('waits for the session: nothing happens while signed out', async () => {
    const r = rig('https://globex.app.example/', { claims: { tenants: [{ tenant_id: 't1' }] }, state: 'out' })
    await settle()
    assert.equal(r.notMember.value.tenant, '')
    r.session.state = 'in'
    await settle()
    assert.equal(r.notMember.value.tenant, 'globex')
  })
  it('turns the link rule on: a same-env tenant host is internal', () => {
    rig(SITE + '/', { state: 'out' })
    assert.equal(classifyHref('https://northwind.app.example/x', SITE).internal, true)
  })
})
