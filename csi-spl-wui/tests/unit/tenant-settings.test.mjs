// SPL-1037 (specs/046): Tenant settings, WUI side - the entry and section
// gates (strict, not fail-open), the section-of-path reader, the body
// readers, the responder id rule, the mock hub rules.
// Run: node tests/unit/tenant-settings.test.mjs
import { moveItem, normalizeTenantChannels, normalizeTenantSettings, tenantSettingsErrorKey, validResponderId } from '../../src/utils/tenant-settings.mjs'
import { TENANT_SETTINGS_SECTIONS, tenantSettingsSectionOf, tenantSettingsSections, tenantSettingsVisible } from '../../src/utils/tenant-settings-nav.mjs'
import { createMockTenant } from '../../src/utils/tenant-settings-mock.mjs'
import { normalizeMe } from '../../src/utils/access.mjs'
import { runsInUnitSuite } from './lib/in-suite.mjs'

let failed = 0
const ok = (name, cond, why = '') => { if (cond) console.log(`  OK   ${name}`); else { failed++; console.log(`  FAIL ${name} ${why}`) } }
const throws = (fn, token) => { try { fn(); return false } catch (e) { return e.token === token } }

console.log('tenant-settings')
const all = ['members.invite', 'members.roles', 'tenant.settings', 'topics.read']
const admin = normalizeMe({ human_id: 'HUM-1', role: 'admin', permissions: all })
const owner = normalizeMe({ human_id: 'HUM-2', role: 'biz_owner', permissions: [...all, 'billing.manage'] })
const dev = normalizeMe({ human_id: 'HUM-3', role: 'developer', permissions: ['topics.read', 'notes.send', 'channels.manage'] })
const ids = (me, o) => tenantSettingsSections(me, o).map((s) => s.id).join(',')
ok('admin sees every section', ids(admin) === 'members,agents,channels,general', ids(admin))
ok('biz_owner sees every section (046: admins AND biz_owners)', ids(owner) === 'members,agents,channels,general')
ok('CONTROL: a developer sees no entry', !tenantSettingsVisible(dev) && ids(dev) === '')
ok('CONTROL: no answer does NOT fail open', !tenantSettingsVisible(null) && !tenantSettingsVisible(normalizeMe({})))
ok('members.invite alone shows Members only', ids(normalizeMe({ permissions: ['members.invite'] })) === 'members')
ok('mock plays the admin', tenantSettingsVisible(null, { mock: true }))
ok('every section names a permission', TENANT_SETTINGS_SECTIONS.every((s) => s.perm && s.label.startsWith('tenant_settings.')))

ok('section of a path', tenantSettingsSectionOf('/tenant-settings/general') === 'general')
ok('section of a locale path', tenantSettingsSectionOf('/fi/tenant-settings/channels/?x=1') === 'channels')
ok('the list is no section', tenantSettingsSectionOf('/tenant-settings') === '')
ok('CONTROL: personal settings are not tenant settings', tenantSettingsSectionOf('/settings/profile') === '')
ok('CONTROL: an unknown section', tenantSettingsSectionOf('/tenant-settings/billing') === '')

const s = normalizeTenantSettings({ tenant_id: 't1', display_name: 'Acme', default_locale: 'fi', responders: ['CLE-01', 3, ''], max_responders: 20 })
ok('settings reader', s.tenantId === 't1' && s.displayName === 'Acme' && s.defaultLocale === 'fi' && s.responders.join() === 'CLE-01' && s.maxResponders === 20)
ok('settings reader survives junk', normalizeTenantSettings(null).responders.length === 0 && normalizeTenantSettings(null).maxResponders === 20)

const rows = normalizeTenantChannels({ channels: [
  { channel: 'zeta', name: 'Zeta', visibility: 'members', members: 2, archivable: true },
  { channel: 'lobby', visibility: 'default', no_fallback: true },
  { channel: '' },
] })
ok('channels: defaults first, junk dropped', rows.map((r) => r.channel).join() === 'lobby,zeta')
ok('channels: name falls back to the id', rows[0].name === 'lobby' && rows[0].noFallback === true && rows[0].archivable === false)

ok('responder ids', validResponderId('CLE-01') && validResponderId(' GRK-3 ') && validResponderId('AGY-02'))
ok('CONTROL: a human is not a responder', !validResponderId('HUM-4') && !validResponderId('cle-01') && !validResponderId('CLE01'))
ok('move up', moveItem(['a', 'b', 'c'], 2, -1).join() === 'a,c,b')
ok('move past the end is a no-op', moveItem(['a', 'b'], 1, 1).join() === 'a,b' && moveItem(['a', 'b'], 0, -1).join() === 'a,b')
ok('error words', tenantSettingsErrorKey({ token: 'channel_public' }) === 'tenant_settings.error.channel_public' && tenantSettingsErrorKey({ token: 'x' }) === 'tenant_settings.error.generic')

const m = createMockTenant()
m.patch({ display_name: ' New ', responders: ['GRK-3', 'GRK-3', 'CLE-01'] })
ok('mock patch', m.settings().display_name === 'New' && m.settings().responders.join() === 'GRK-3,CLE-01')
ok('mock refuses a human responder', throws(() => m.patch({ responders: ['HUM-1'] }), 'bad_responder'))
ok('mock refuses archiving a default channel', throws(() => m.archive('lobby'), 'channel_public'))
m.archive('design')
ok('mock archives a created channel', !m.channels().channels.some((c) => c.channel === 'design'))
m.setNoFallback('secret', false)
ok('mock no-fallback flag', m.channels().channels.find((c) => c.channel === 'secret').no_fallback === false)

const suite = runsInUnitSuite(import.meta.url)
ok('pnpm test runs this suite', suite.ok, suite.why)

if (failed) {
  console.error(`\n${failed} failure(s)`)
  process.exit(1)
}
console.log('\nAll tenant-settings checks passed.')
