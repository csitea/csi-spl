// SPL-959: real old links, as they sit in prd message bodies today (measured
// 2026-09-26 on the prd messages table, every row; only the host is replaced
// by the placeholder apex). Each must still land on the right place once the
// apex is the apex tenant (t1) and every other tenant has its own host.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { reactive, ref, nextTick } from 'vue'

import { bootTenantHost } from '../../src/utils/tenant-host-boot.mjs'

const SITE = 'https://app.example'
const PUB = { siteUrl: SITE, tenant: 't1', apiBase: 'https://api.app.example' }
/* the csi-rel topic that a t1 message and a csi-rel message both link to */
const CSI_REL_TOPIC = '293c00ae-32b5-43bd-94cd-f875c449adb0'
const OWNER = { [CSI_REL_TOPIC]: 'csi-rel' } // what GET /v1/view/locate answers
const VIEWER = { tenants: [{ tenant_id: 't1' }, { tenant_id: 'csi-rel' }] }

async function land(href) {
  const u = new URL(href)
  const replaced = []
  const located = []
  const win = { location: { href, pathname: u.pathname, search: u.search, hash: u.hash, replace: (x) => replaced.push(x) } }
  const fetchFn = async (url) => {
    const id = url.split('/').pop()
    located.push(id)
    return OWNER[id] ? { ok: true, json: async () => ({ tenant: OWNER[id] }) } : { ok: false, json: async () => ({}) }
  }
  bootTenantHost({ pub: PUB, page: 't1', session: reactive({ state: 'in', claims: VIEWER }), notMember: ref({ tenant: '', home: '' }), win, fetchFn })
  for (let i = 0; i < 5; i++) { await nextTick(); await new Promise((r) => setTimeout(r, 0)) }
  return { to: replaced[0] || href, located }
}

describe('real prd old links on the apex', () => {
  it('a topic link of another tenant moves to that tenant host, same path and hash', async () => {
    const href = `${SITE}/channel/development?topic=${CSI_REL_TOPIC}#6c97436b-1f77-4e4e-868d-7763adf522ad`
    const r = await land(href)
    assert.equal(r.to, `https://csi-rel.app.example/channel/development?topic=${CSI_REL_TOPIC}#6c97436b-1f77-4e4e-868d-7763adf522ad`)
  })
  for (const path of [
    '/issues?issue=SPL-12', // an issue key on the apex means t1 (keys repeat across tenants)
    '/issues?epic=SPL-2&issue=SPL-16',
    '/dm/CLE-120@box-desk',
    '/settings/appearance',
    '/channel/lobby',
    '/channel/spool-hub-devel',
  ]) {
    it(`${path} stays on the apex (t1), with no lookup`, async () => {
      const r = await land(SITE + path)
      assert.equal(r.to, SITE + path)
      assert.deepEqual(r.located, [])
    })
  }
  it('a /t/<uuid> nobody owns stays on the apex after one lookup', async () => {
    const r = await land(`${SITE}/t/00000000-0000-4000-8000-000000000000`)
    assert.equal(r.to, `${SITE}/t/00000000-0000-4000-8000-000000000000`)
    assert.deepEqual(r.located, ['00000000-0000-4000-8000-000000000000'])
  })
})
