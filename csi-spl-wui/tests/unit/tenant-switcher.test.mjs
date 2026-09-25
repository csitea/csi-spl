// The sidebar tenant drop box is fixed: one option, the signed-in session's
// tenant (display name when the session has one, else the id). Choosing it
// does nothing. No tenant id is hard-coded.
//
// Run: node tests/unit/tenant-switcher.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync, readdirSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { fixedTenantOption } from '../../src/utils/tenant-switcher.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const src = (rel) => readFileSync(join(WUI, rel), 'utf8')

describe('fixedTenantOption', () => {
  it('uses the membership display name for the active tenant, else its id', () => {
    const claims = {
      active_tenant: 'acme',
      t: 'other',
      tenants: [
        { tenant_id: 'other', display_name: 'Other Co' },
        { tenant_id: 'acme', role: 'admin', display_name: 'Acme Co' },
      ],
    }
    assert.deepEqual(fixedTenantOption(claims, 'configured'), { id: 'acme', label: 'Acme Co' })
    assert.deepEqual(
      fixedTenantOption({ active_tenant: 'acme', tenants: [{ tenant_id: 'acme', name: 'Acme' }] }),
      { id: 'acme', label: 'Acme' },
    )
    assert.deepEqual(fixedTenantOption({ t: 'acme' }), { id: 'acme', label: 'acme' })
    assert.deepEqual(fixedTenantOption({ active_tenant: '  acme  ' }), { id: 'acme', label: 'acme' })
    assert.deepEqual(
      fixedTenantOption({ active_tenant: 't1', tenants: [{ tenant_id: 't1', role: 'admin', display_name: 'csitea' }] }),
      { id: 't1', label: 'csitea' },
    )
  })

  it('prefers active_tenant over t, and a display_name over name', () => {
    assert.deepEqual(
      fixedTenantOption({
        active_tenant: 'acme',
        t: 'beta',
        tenants: [{ tenant_id: 'acme', display_name: 'Shown', name: 'Hidden' }],
      }),
      { id: 'acme', label: 'Shown' },
    )
  })

  it('uses the only membership when the session has not bound one', () => {
    assert.deepEqual(
      fixedTenantOption({ active_tenant: null, tenants: [{ tenant_id: 'solo', display_name: 'Solo' }] }),
      { id: 'solo', label: 'Solo' },
    )
  })

  it('does not pick among several memberships, and does not borrow their name for the configured id', () => {
    const many = {
      tenants: [
        { tenant_id: 'aa', display_name: 'Aa' },
        { tenant_id: 'bb', display_name: 'Bb' },
      ],
    }
    assert.deepEqual(fixedTenantOption(many, 'configured'), { id: 'configured', label: 'configured' })
    assert.deepEqual(fixedTenantOption(many), { id: '', label: '' })
  })

  it('a session tenant_name labels the session id, not a configured-only fallback', () => {
    assert.deepEqual(
      fixedTenantOption({ t: 'acme', tenant_name: 'Acme Co' }, 'other'),
      { id: 'acme', label: 'Acme Co' },
    )
    assert.deepEqual(
      fixedTenantOption({ tenant_name: 'Acme Co' }, 'configured'),
      { id: 'configured', label: 'configured' },
    )
  })

  it('falls back to the client tenant, and names nothing when that is empty too', () => {
    assert.deepEqual(fixedTenantOption(null, 'beta'), { id: 'beta', label: 'beta' })
    assert.deepEqual(fixedTenantOption(undefined, ''), { id: '', label: '' })
    assert.deepEqual(fixedTenantOption({ active_tenant: 1, t: null, tenants: 'nope' }, '  '), { id: '', label: '' })
  })
})

describe('the drop box sits above the direct-messages icon', () => {
  const vue = src('src/components/ChannelSidebar.vue')
  const css = src('src/assets/css/main.css')

  it('one select, wired to the session, and choosing it does not navigate', () => {
    const box = vue.indexOf('data-testid="tenant-switcher"')
    const rail = vue.indexOf('class="sidebar-rail"')
    const heading = vue.indexOf('data-testid="sidebar-help-dm"')
    assert.ok(box > 0 && rail > box && heading > rail)
    assert.equal(vue.split('<option').length - 1, 1)
    assert.match(vue, /fixedTenantOption\(session\.claims, api\.tenant\)/)
    assert.match(vue, /data-testid="tenant-switcher-select"/)
    assert.doesNotMatch(vue.slice(box, rail), /disabled/)
    const fn = vue.slice(vue.indexOf('function keepTenant'))
    assert.match(fn, /HTMLSelectElement/)
    assert.doesNotMatch(fn.slice(0, fn.indexOf('\n}')), /navigateTo|fetch\(|api\./)
    assert.equal(src('src/utils/tenant-switcher.mjs').includes("'t1'"), false)
    assert.equal(vue.includes('t1'), false)
  })

  it('the strip stays a row under a full-width switcher', () => {
    assert.match(css, /\.sidebar\s*\{[^}]*flex-direction:\s*column/)
    assert.match(css, /\.sidebar-main\s*\{[^}]*flex-direction:\s*row/)
    assert.match(css, /\.sidebar-main\s*\{[^}]*min-width:\s*0/)
    assert.match(css, /\.sidebar-main\s*\{[^}]*min-height:\s*0/)
  })
})

describe('sidebar.tenant is translated in every locale', () => {
  it('every non-English value differs from English', () => {
    const dir = join(WUI, 'i18n/locales')
    const en = JSON.parse(src('i18n/locales/en.json')).sidebar.tenant
    assert.equal(en, 'Tenant')
    const codes = readdirSync(dir).filter((f) => f.endsWith('.json')).map((f) => f.replace(/\.json$/, ''))
    assert.equal(codes.length, 19)
    for (const code of codes) {
      const value = JSON.parse(readFileSync(join(dir, code + '.json'), 'utf8')).sidebar.tenant
      assert.equal(typeof value, 'string', code)
      assert.ok(value.trim().length > 0, code)
      if (code !== 'en') assert.notEqual(value, en, code)
    }
  })
})
