// The sidebar tenant drop box: with one membership one option, the signed-in
// session's tenant (display name when the session has one, else the id), and
// choosing it does nothing. With several (specs/026 §6) every membership is a
// row and choosing one switches the session (POST /api/v1/auth/tenant). No
// tenant id is hard-coded.
//
// Run: node tests/unit/tenant-switcher.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync, readdirSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { fixedTenantOption, tenantHint, tenantSelectWidthPx, tenantSwitchOptions } from '../../src/utils/tenant-switcher.mjs'

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

describe('tenantSwitchOptions (specs/026 §6)', () => {
  it('one membership (or none): the single fixed row, no switching', () => {
    assert.deepEqual(
      tenantSwitchOptions({ active_tenant: 't1', tenants: [{ tenant_id: 't1', display_name: 'csitea' }] }),
      { selected: 't1', canSwitch: false, options: [{ id: 't1', label: 'csitea' }] },
    )
    assert.deepEqual(tenantSwitchOptions(null, 'beta'), { selected: 'beta', canSwitch: false, options: [{ id: 'beta', label: 'beta' }] })
    // a duplicated row is still one membership
    assert.equal(tenantSwitchOptions({ tenants: [{ tenant_id: 'aa' }, { tenant_id: 'aa' }] }).canSwitch, false)
  })

  it('several memberships: every one listed, the active one selected', () => {
    const claims = {
      active_tenant: 'bb',
      t: 'aa',
      tenants: [{ tenant_id: 'aa', display_name: 'Aa Co' }, { tenant_id: 'bb', name: 'Bb' }, { tenant_id: 'cc' }, 'junk', null],
    }
    assert.deepEqual(tenantSwitchOptions(claims, 'configured'), {
      selected: 'bb',
      canSwitch: true,
      options: [{ id: 'aa', label: 'Aa Co' }, { id: 'bb', label: 'Bb' }, { id: 'cc', label: 'cc' }],
    })
  })

  it('several memberships and none active (or a stale one): a blank first row, nothing chosen for the human', () => {
    const many = { t: 'gone', tenants: [{ tenant_id: 'aa' }, { tenant_id: 'bb' }] }
    const box = tenantSwitchOptions(many, 'configured')
    assert.equal(box.selected, '')
    assert.equal(box.canSwitch, true)
    assert.deepEqual(box.options.map((o) => o.id), ['', 'aa', 'bb'])
  })
})

describe('tenantHint (CLE-34991, the hover explanation)', () => {
  const t = (key, p) => (p ? key + '(' + JSON.stringify(p) + ')' : key)

  it('names the selected tenant, then says it is the only one', () => {
    const box = tenantSwitchOptions({ active_tenant: 'acme', tenants: [{ tenant_id: 'acme', display_name: 'Acme Co' }] })
    assert.equal(tenantHint(box, t), 'sidebar.tenant_hint({"name":"Acme Co"}) sidebar.tenant_hint_one')
  })

  it('several memberships: the tail says picking another one switches', () => {
    const box = tenantSwitchOptions({ active_tenant: 'bb', tenants: [{ tenant_id: 'aa' }, { tenant_id: 'bb', name: 'Bb' }] })
    assert.equal(tenantHint(box, t), 'sidebar.tenant_hint({"name":"Bb"}) sidebar.tenant_hint_switch')
  })

  it('nothing selected (blank row, or no tenant at all): the caption stands in for the name, never an empty slot', () => {
    const blank = tenantSwitchOptions({ tenants: [{ tenant_id: 'aa' }, { tenant_id: 'bb' }] })
    assert.equal(tenantHint(blank, t), 'sidebar.tenant_hint({"name":"sidebar.tenant"}) sidebar.tenant_hint_switch')
    assert.equal(tenantHint(tenantSwitchOptions(null), t), 'sidebar.tenant_hint({"name":"sidebar.tenant"}) sidebar.tenant_hint_one')
    assert.equal(tenantHint(null, t), 'sidebar.tenant_hint({"name":"sidebar.tenant"}) sidebar.tenant_hint_one')
  })
})

describe('the drop box sits above the direct-messages icon', () => {
  const vue = src('src/components/ChannelSidebar.vue')
  const css = src('src/assets/css/main.css')

  it('one select, wired to the session; only a real switch calls the hub', () => {
    const box = vue.indexOf('data-testid="tenant-switcher"')
    const rail = vue.indexOf('class="sidebar-rail"')
    const heading = vue.indexOf('data-testid="sidebar-help-dm"')
    assert.ok(box > 0 && rail > box && heading > rail)
    assert.equal(vue.split('<option').length - 1, 1)
    assert.match(vue, /tenantSwitchOptions\(session\.claims, api\.tenant\)/)
    // CLE-555 red on e443566: with no session and no configured tenant (the CI
    // mock bundle) the one row had an empty label and rendered as a blank
    // option. The row text falls back to the caption, as before e443566.
    assert.match(vue, /<option v-for="o in tenantBox\.options"[^>]*>\{\{ o\.label \|\| t\('sidebar\.tenant'\) \}\}<\/option>/)
    assert.match(vue, /data-testid="tenant-switcher-select"/)
    assert.doesNotMatch(vue.slice(box, rail), /disabled/)
    const fn = vue.slice(vue.indexOf('async function onTenantChange'))
    const body = fn.slice(0, fn.indexOf('\n}'))
    assert.match(body, /HTMLSelectElement/)
    // the guard (single row, mock, busy, same tenant) returns before the call
    const guard = body.indexOf('!box.canSwitch || api.mock')
    const callAt = body.indexOf('authClient.switchTenant(want)')
    assert.ok(guard > 0 && callAt > guard, 'guard before the switch call')
    assert.doesNotMatch(body, /fetch\(/)
    assert.equal(src('src/utils/tenant-switcher.mjs').includes("'t1'"), false)
    assert.equal(vue.includes('t1'), false)
  })

  it('CLE-34991: one slim row - no visible caption, the caption names the select, hover explains', () => {
    const box = vue.slice(vue.indexOf('data-testid="tenant-switcher"') - 60, vue.indexOf('class="sidebar-rail"'))
    assert.doesNotMatch(box, /tenant-switcher__label/)
    assert.doesNotMatch(box, /<label/)
    assert.match(box, /<UiIcon name="building"/)
    assert.match(box, /:aria-label="t\('sidebar\.tenant'\)"/)
    assert.match(box, /class="tenant-switcher" data-testid="tenant-switcher" :title="tenantHintText"/)
    assert.match(box, /aria-describedby="tenant-switcher-hint"/)
    assert.match(box, /id="tenant-switcher-hint" class="sr-only"[^>]*>\{\{ tenantHintText \}\}/)
    assert.match(vue, /const tenantHintText = computed\(\(\) => tenantHint\(tenantBox\.value, t\)\)/)
    const style = vue.slice(vue.indexOf('<style'))
    assert.doesNotMatch(style, /\.tenant-switcher__label/)
    const rule = style.slice(style.indexOf('.tenant-switcher {'), style.indexOf('}', style.indexOf('.tenant-switcher {')))
    assert.match(rule, /align-items:\s*center/)
    assert.doesNotMatch(rule, /flex-direction:\s*column|border:/)
    const sel = style.slice(style.indexOf('.tenant-switcher__select {'), style.indexOf('}', style.indexOf('.tenant-switcher__select {')))
    assert.match(sel, /height:\s*24px/)
    assert.match(src('src/utils/uiIcons.ts'), /building:\s*\[/)
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

describe('switchTenant (auth-client, specs/026 §6)', () => {
  it('POSTs only {tenant} to /api/v1/auth/tenant with credentials and CORS-allowed headers', async () => {
    const { createAuthClient } = await import('../../src/utils/auth-client.mjs')
    const calls = []
    const fetchFn = async (url, opts) => {
      calls.push({ url, opts })
      return { ok: true, status: 200, json: async () => ({ t: 'bb', active_tenant: 'bb' }) }
    }
    const out = await createAuthClient({ fetchFn, base: 'https://api.example.com', locale: () => 'fi', sendLocale: true }).switchTenant('bb')
    assert.equal(out.ok, true)
    assert.equal(out.data.active_tenant, 'bb')
    assert.equal(calls.length, 1)
    assert.equal(calls[0].url, 'https://api.example.com/api/v1/auth/tenant')
    assert.equal(calls[0].opts.method, 'POST')
    assert.equal(calls[0].opts.credentials, 'include')
    assert.deepEqual(JSON.parse(calls[0].opts.body), { tenant: 'bb' })
    const sent = Object.keys(calls[0].opts.headers).map((h) => h.toLowerCase())
    assert.deepEqual(sent.filter((h) => !['accept', 'content-type', 'x-locale'].includes(h)), [], sent.join(','))
  })

  it('CONTROL: a 403 not_member resolves to ok:false with the token, never throws', async () => {
    const { createAuthClient } = await import('../../src/utils/auth-client.mjs')
    const fetchFn = async () => ({ ok: false, status: 403, headers: { get: () => null }, json: async () => ({ error: 'not_member' }) })
    const out = await createAuthClient({ fetchFn }).switchTenant('zz')
    assert.equal(out.ok, false)
    assert.equal(out.error, 'not_member')
  })
})

describe('tenantSelectWidthPx', () => {
  it('puts the arrow 3px after the widest name', () => {
    assert.equal(tenantSelectWidthPx(40), 59)
    assert.equal(tenantSelectWidthPx(40.2), 60)
    assert.equal(tenantSelectWidthPx(0), 19)
    assert.equal(tenantSelectWidthPx(Number.NaN), 19)
  })
})
