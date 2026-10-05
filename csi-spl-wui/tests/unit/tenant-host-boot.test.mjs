// SPL-959: the arrival hops of a tenant host (utils/tenant-host-boot.mjs).
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { reactive, ref, nextTick } from 'vue'

import { activeElsewhere, bootTenantHost, hostAnswers } from '../../src/utils/tenant-host-boot.mjs'
import { classifyHref } from '../../src/utils/link-target.mjs'

const SITE = 'https://app.example'
const PUB = { siteUrl: SITE, tenant: 't1', apiBase: 'https://api.app.example' }
const U = '0b8a6a52-6c1e-4f5e-9d1e-2c7b7f5e8a11'
const MEMBER_T1 = { tenants: [{ tenant_id: 't1' }, { tenant_id: 'northwind' }] }

function rig(href, { claims = MEMBER_T1, locateTo = '', state = 'in', down = [] } = {}) {
  const u = new URL(href)
  const replaced = []
  const fetched = []
  const probed = []
  const timers = []
  const hostsDown = new Set(down)
  const win = {
    location: { href, pathname: u.pathname, search: u.search, hash: u.hash, replace: (x) => replaced.push(x) },
    setTimeout: (fn, ms) => timers.push({ fn, ms }),
  }
  const fetchFn = async (url, opts) => {
    if (url.endsWith('/build.json')) {
      probed.push({ url, opts })
      /* a host that is not provisioned yet: NXDOMAIN / refused by the CSP */
      if (hostsDown.has(new URL(url).hostname)) throw new TypeError('Failed to fetch')
      return { ok: true, type: 'opaque' }
    }
    fetched.push({ url, opts })
    return locateTo
      ? { ok: true, json: async () => ({ tenant: locateTo }) }
      : { ok: false, json: async () => ({}) }
  }
  const session = reactive({ state, claims })
  const notMember = ref({ tenant: '', home: '' })
  const page = u.hostname === 'app.example' ? 't1' : u.hostname.split('.')[0]
  bootTenantHost({ pub: PUB, page, session, notMember, win, fetchFn })
  return { replaced, fetched, probed, timers, hostsDown, notMember, session }
}
const settle = async () => { for (let i = 0; i < 5; i++) { await nextTick(); await new Promise((r) => setTimeout(r, 0)) } }

describe('tenant-host boot', () => {
  it('apex + ?tenant=<t> hops to t with the same path (the sign-in return)', async () => {
    const r = rig(SITE + '/issues?issue=SPL-3&tenant=northwind', { state: 'loading' })
    await settle()
    assert.deepEqual(r.replaced, ['https://northwind.app.example/issues?issue=SPL-3'])
    assert.equal(r.probed[0].url, 'https://northwind.app.example/build.json')
    assert.equal(r.probed[0].opts.mode, 'no-cors')
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
    assert.deepEqual(r.notMember.value, { tenant: 'globex', home: 'https://app.example/', pending: '' })
  })
  it('waits for the session: nothing happens while signed out', async () => {
    const r = rig('https://globex.app.example/', { claims: { tenants: [{ tenant_id: 't1' }] }, state: 'out' })
    await settle()
    assert.equal(r.notMember.value.tenant, '')
    r.session.state = 'in'
    await settle()
    assert.equal(r.notMember.value.tenant, 'globex')
  })
  it('047 B5: a paid tenant whose host is not up yet - the sign-in return stays on the apex (login usable)', async () => {
    const r = rig(SITE + '/login?tenant=w1paid1', { state: 'out', claims: {}, down: ['w1paid1.app.example'] })
    await settle()
    assert.deepEqual(r.replaced, [])
    assert.equal(r.notMember.value.tenant, '', 'nothing covers the sign-in page while signed out')
  })
  it('047 B5: signed in, host not up: "being prepared", no hop into NXDOMAIN; it hops once the host answers', async () => {
    const r = rig(SITE + '/login?tenant=w1paid1', { state: 'out', claims: {}, down: ['w1paid1.app.example'] })
    await settle()
    r.session.claims = { tenants: [{ tenant_id: 'w1paid1' }] }
    r.session.state = 'in'
    await settle()
    assert.deepEqual(r.replaced, [])
    assert.deepEqual(r.notMember.value, { tenant: 'w1paid1', home: '', pending: 'w1paid1.app.example' })
    assert.equal(r.timers.length, 1)
    assert.equal(r.timers[0].ms, 30000)
    // still down: the retry schedules the next one
    await r.timers.shift().fn()
    assert.deepEqual(r.replaced, [])
    assert.equal(r.timers.length, 1)
    // the host is provisioned (and the CSP re-deploy admits it)
    r.hostsDown.clear()
    await r.timers.shift().fn()
    assert.deepEqual(r.replaced, ['https://w1paid1.app.example/'])
  })
  it('047 B5: right after a native sign-in the claims name t but no tenants list - t is the home', async () => {
    const r = rig(SITE + '/', { claims: { t: 'b5paid1' }, down: ['b5paid1.app.example'] })
    await settle()
    assert.deepEqual(r.notMember.value, { tenant: 'b5paid1', home: '', pending: 'b5paid1.app.example' })
  })
  it('activeElsewhere: t only without a tenants list; CONTROL: the page tenant, a list or a bad id give nothing', () => {
    assert.equal(activeElsewhere({ t: 'b5paid1' }, 't1'), 'b5paid1')
    assert.equal(activeElsewhere({ t: 't1' }, 't1'), '')
    assert.equal(activeElsewhere({ t: 'b5paid1', tenants: [{ tenant_id: 't1' }] }, 't1'), '')
    assert.equal(activeElsewhere({ t: 'Bad Id!' }, 't1'), '')
    assert.equal(activeElsewhere(null, 't1'), '')
  })
  it('CONTROL: a hop to the apex tenant is never probed (the apex always answers)', async () => {
    const r = rig('https://globex.app.example/', { claims: { tenants: [{ tenant_id: 't1' }] } })
    await settle()
    assert.equal(r.probed.length, 0)
  })
  it('hostAnswers: a response of any kind is up; a thrown fetch or a bad url is down', async () => {
    assert.equal(await hostAnswers('https://a.app.example/x?y=1', async (u) => { assert.equal(u, 'https://a.app.example/build.json'); return { type: 'opaque' } }), true)
    assert.equal(await hostAnswers('https://a.app.example/', async () => { throw new TypeError('Failed to fetch') }), false)
    assert.equal(await hostAnswers('not a url', async () => ({})), false)
  })
  it('turns the link rule on: a same-env tenant host is internal', () => {
    rig(SITE + '/', { state: 'out' })
    assert.equal(classifyHref('https://northwind.app.example/x', SITE).internal, true)
  })

  it('r3-07: hostAnswers reads a host that never answers as down after timeoutMs', async () => {
    const calls = []
    assert.equal(await hostAnswers('https://a.app.example/', hang(calls), { timeoutMs: 5 }), false)
    assert.ok(calls[0][1].signal, 'the probe carries an abort signal')
  })
})

/* a fetch that never answers, but honours init.signal like the real one */
const hang = (calls = []) => (url, init = {}) => {
  calls.push([url, init])
  return new Promise((_, reject) => {
    if (init.signal) init.signal.addEventListener('abort', () => reject(new DOMException('aborted', 'AbortError')))
  })
}
