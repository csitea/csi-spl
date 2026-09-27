// Owner, topic d1f76e76 (2026-09-26): the tab reads "<tenant display name>.spool-hub".
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

import { tabTitle, tenantTabName } from '../../src/utils/tab-title.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const claims = (active, tenants) => ({ active_tenant: active, tenants })
const ALL = [
  { tenant_id: 't1', display_name: 'spool-hub' },
  { tenant_id: 'csi-rel', display_name: 'hooli' },
  { tenant_id: 'northwind', display_name: 'northwind' },
  { tenant_id: 'globex' },
]

describe('tab title', () => {
  it('the display name, not the slug: hooli.spool-hub', () => {
    assert.equal(tenantTabName(claims('csi-rel', ALL), 'csi-rel', 't1'), 'hooli.spool-hub')
    assert.equal(tenantTabName(claims('northwind', ALL), 'northwind', 't1'), 'northwind.spool-hub')
  })
  it('the apex tenant is plain spool-hub (never spool-hub.spool-hub)', () => {
    assert.equal(tenantTabName(claims('t1', ALL), 't1', 't1'), 'spool-hub')
    assert.equal(tenantTabName(claims('t1', [{ tenant_id: 't1', display_name: 'csitea' }]), 't1', 't1'), 'spool-hub')
  })
  it('no display name: the id; signed out on a tenant host: the host tenant', () => {
    assert.equal(tenantTabName(claims('globex', ALL), 'globex', 't1'), 'globex.spool-hub')
    assert.equal(tenantTabName(null, 'northwind', 't1'), 'northwind.spool-hub')
    assert.equal(tenantTabName(null, '', 't1'), 'spool-hub')
  })
  it('a page title stays in front', () => {
    assert.equal(tabTitle('Search: x', 'hooli.spool-hub'), 'Search: x · hooli.spool-hub')
    assert.equal(tabTitle('', 'hooli.spool-hub'), 'hooli.spool-hub')
    assert.equal(tabTitle('spool-hub', 'northwind.spool-hub'), 'northwind.spool-hub') // the static default title
  })
  it('app.vue sets the title template from these helpers', () => {
    const app = readFileSync(join(WUI, 'src/app.vue'), 'utf8')
    assert.match(app, /titleTemplate: \(page\) => tabTitle\(page, tabName\.value\)/)
  })
})
