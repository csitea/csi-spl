// SPL-959: the page's host names its tenant; the apex is the apex tenant (t1).
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'

import {
  homeTenant, isTenantHostOf, oldLinkId, pageTenant, siteHostOf, tenantOrigin, tenantParamHop, tenantUrl,
} from '../../src/utils/tenant-host.mjs'

const PRD = 'https://app.example'
const DEV = 'https://dev.app.example'
const U = '0b8a6a52-6c1e-4f5e-9d1e-2c7b7f5e8a11'

describe('tenant-host', () => {
  it('pageTenant: apex = apex tenant, one label = that tenant', () => {
    assert.equal(pageTenant('app.example', PRD, 't1'), 't1')
    assert.equal(pageTenant('leiden.app.example', PRD, 't1'), 'leiden')
    assert.equal(pageTenant('LEIDEN.app.example', PRD, 't1'), 'leiden')
    assert.equal(pageTenant('leiden.dev.app.example', DEV, 't1'), 'leiden')
    assert.equal(pageTenant('dev.app.example', DEV, 't1'), 't1')
  })
  it('pageTenant CONTROLS: other env, reserved, nested, foreign, lde', () => {
    assert.equal(pageTenant('dev.app.example', PRD, 't1'), '') // reserved label
    assert.equal(pageTenant('api.app.example', PRD, 't1'), '')
    assert.equal(pageTenant('leiden.dev.app.example', PRD, 't1'), '') // two labels
    assert.equal(pageTenant('leiden.app.example', DEV, 't1'), '') // prd host seen by dev
    assert.equal(pageTenant('evilapp.example', PRD, 't1'), '')
    assert.equal(pageTenant('localhost', PRD, 't1'), '')
    assert.equal(pageTenant('leiden.app.example', '', 't1'), '')
    assert.equal(pageTenant('leiden.app.example', 'http://app.example', 't1'), '')
  })
  it('tenantUrl: same path on the tenant host, the apex tenant on the apex', () => {
    assert.equal(tenantUrl('leiden', PRD, 't1', '/issues?issue=SPL-3'), 'https://leiden.app.example/issues?issue=SPL-3')
    assert.equal(tenantUrl('t1', PRD, 't1', '/issues'), 'https://app.example/issues')
    assert.equal(tenantUrl('csitea', DEV, 't1', '/'), 'https://csitea.dev.app.example/')
    assert.equal(tenantUrl('leiden', PRD, 't1', '//evil.example/x'), 'https://leiden.app.example/')
    assert.equal(tenantUrl('api', PRD, 't1', '/'), '')
    assert.equal(tenantOrigin('Bad Tenant', PRD, 't1'), '')
    assert.equal(siteHostOf('https://app.example:8443'), '')
  })
  it('isTenantHostOf: same env hosts only', () => {
    assert.ok(isTenantHostOf('https://app.example/x', PRD))
    assert.ok(isTenantHostOf('https://leiden.app.example/issues', PRD))
    assert.ok(!isTenantHostOf('https://api.app.example/', PRD))
    assert.ok(!isTenantHostOf('https://dev.app.example/', PRD))
    assert.ok(!isTenantHostOf('https://leiden.dev.app.example/', PRD))
    assert.ok(!isTenantHostOf('http://leiden.app.example/', PRD))
    assert.ok(!isTenantHostOf('https://leiden.app.example:444/', PRD))
    assert.ok(!isTenantHostOf('https://app.example/', DEV))
    assert.ok(isTenantHostOf('https://leiden.dev.app.example/', DEV))
  })
  it('tenantParamHop: apex + ?tenant=<t> goes to t, keeping the rest', () => {
    assert.equal(tenantParamHop(PRD + '/issues?tenant=leiden&issue=SPL-3#x', PRD, 't1'), 'https://leiden.app.example/issues?issue=SPL-3#x')
    assert.equal(tenantParamHop(PRD + '/?tenant=t1', PRD, 't1'), '')
    assert.equal(tenantParamHop(PRD + '/?tenant=api', PRD, 't1'), '')
    assert.equal(tenantParamHop(PRD + '/issues', PRD, 't1'), '')
    assert.equal(tenantParamHop('https://leiden.app.example/?tenant=csitea', PRD, 't1'), '') // only the apex hops
  })
  it('oldLinkId: topic, thread, in, /t/<uuid>', () => {
    assert.equal(oldLinkId(`/channel/general?topic=${U}`), U)
    assert.equal(oldLinkId(`https://app.example/?thread=${U}&in=x`), U)
    assert.equal(oldLinkId(`/t/${U}`), U)
    assert.equal(oldLinkId(`/fi/t/${U}`), U)
    assert.equal(oldLinkId('/issues?issue=SPL-12'), '')
    assert.equal(oldLinkId('/dm/HUM-3'), '')
    assert.equal(oldLinkId('/channel/general?topic=not-a-uuid'), '')
  })
  it('homeTenant: last used, else first; a member stays', () => {
    const claims = { tenants: [
      { tenant_id: 'csitea' },
      { tenant_id: 'leiden', last_active_at: '2026-09-25T10:00:00Z' },
      { tenant_id: 'luka', last_active_at: '2026-09-24T10:00:00Z' },
    ] }
    assert.equal(homeTenant(claims, 't1'), 'leiden')
    assert.equal(homeTenant(claims, 'leiden'), '')
    assert.equal(homeTenant({ tenants: [{ tenant_id: 'csitea' }] }, 't1'), 'csitea')
    assert.equal(homeTenant({ tenants: [] }, 't1'), '')
    assert.equal(homeTenant(null, 't1'), '')
  })
})
