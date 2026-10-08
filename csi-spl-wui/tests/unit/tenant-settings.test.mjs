// SPL-1037 (specs/046): Tenant settings, WUI side - the entry and section
// gates (strict, not fail-open), the section-of-path reader, the body
// readers, the responder id rule, the mock hub rules.
// Run: node tests/unit/tenant-settings.test.mjs
import { readFileSync } from 'node:fs'
import { issuePrefixOf, moveItem, normalizeTenantChannels, normalizeTenantSettings, tenantSettingsErrorKey, TOPIC_ARCHIVE_POLICY_OPTIONS, validResponderId } from '../../src/utils/tenant-settings.mjs'
import { TENANT_SETTINGS_SECTIONS, tenantSettingsSectionOf, tenantSettingsSections, tenantSettingsVisible } from '../../src/utils/tenant-settings-nav.mjs'
import { createMockTenant } from '../../src/utils/tenant-settings-mock.mjs'
import { mockPerfSummary, normalizePerfSummary, perfCompareRows, perfSummaryQuery } from '../../src/utils/perf-summary.mjs'
import { normalizeMe } from '../../src/utils/access.mjs'
import { runsInUnitSuite } from './lib/in-suite.mjs'
import { setAgentIdNow } from '../../src/utils/agent-id.mjs'

/* spec 061 FR-004: these ids are legacy (CLE-01); pin the clock before
   LEGACY_ID_UNTIL so this file does not turn red at the deadline on its own */
setAgentIdNow('2026-10-02T12:00:00Z')

let failed = 0
const ok = (name, cond, why = '') => { if (cond) console.log(`  OK   ${name}`); else { failed++; console.log(`  FAIL ${name} ${why}`) } }
const throws = (fn, token) => { try { fn(); return false } catch (e) { return e.token === token } }

console.log('tenant-settings')
const all = ['members.invite', 'members.roles', 'tenant.settings', 'topics.read']
const admin = normalizeMe({ human_id: 'HUM-1', role: 'admin', permissions: all })
const owner = normalizeMe({ human_id: 'HUM-2', role: 'biz_owner', permissions: [...all, 'billing.manage'] })
const dev = normalizeMe({ human_id: 'HUM-3', role: 'developer', permissions: ['topics.read', 'notes.send', 'channels.manage'] })
const ids = (me, o) => tenantSettingsSections(me, o).map((s) => s.id).join(',')
ok('admin sees every section', ids(admin) === 'members,agents,split,channels,general,hours,performance', ids(admin))
ok('biz_owner sees every section (046: admins AND biz_owners)', ids(owner) === 'members,agents,split,channels,general,hours,performance')
ok('CONTROL: a developer sees no entry', !tenantSettingsVisible(dev) && ids(dev) === '')
ok('CONTROL: no answer does NOT fail open', !tenantSettingsVisible(null) && !tenantSettingsVisible(normalizeMe({})))
ok('members.invite alone shows Members only', ids(normalizeMe({ permissions: ['members.invite'] })) === 'members')
/* spec 066 L7: Performance is a tenant.settings section, like the hub's summary route */
ok('066 L7: Performance needs tenant.settings', TENANT_SETTINGS_SECTIONS.find((s) => s.id === 'performance')?.perm === 'tenant.settings' &&
  ids(normalizeMe({ permissions: ['tenant.settings'] })).split(',').includes('performance'))
ok('066 L7 CONTROL: no tenant.settings, no Performance', !ids(normalizeMe({ permissions: ['members.invite', 'members.roles', 'topics.read'] })).split(',').includes('performance') &&
  !ids(dev).split(',').includes('performance'))
ok('066 L7: the Performance path is a section', tenantSettingsSectionOf('/fi/tenant-settings/performance') === 'performance')
ok('mock plays the admin', tenantSettingsVisible(null, { mock: true }))
ok('every section names a permission', TENANT_SETTINGS_SECTIONS.every((s) => s.perm && s.label.startsWith('tenant_settings.')))

ok('section of a path', tenantSettingsSectionOf('/tenant-settings/general') === 'general')
ok('section of a locale path', tenantSettingsSectionOf('/fi/tenant-settings/channels/?x=1') === 'channels')
ok('the list is no section', tenantSettingsSectionOf('/tenant-settings') === '')
ok('CONTROL: personal settings are not tenant settings', tenantSettingsSectionOf('/settings/profile') === '')
ok('CONTROL: an unknown section', tenantSettingsSectionOf('/tenant-settings/billing') === '')

const s = normalizeTenantSettings({ tenant_id: 't1', display_name: 'Acme', default_locale: 'fi', responders: ['CLE-01', 3, ''], max_responders: 20 })
ok('settings reader', s.tenantId === 't1' && s.displayName === 'Acme' && s.defaultLocale === 'fi' && s.responders.join() === 'CLE-01' && s.maxResponders === 20)
// CLE-77819: "Who can archive topics" - read, defaulted, and the mock enforces the three values
ok('archive policy reader: absent / unknown = everyone', s.topicArchivePolicy === 'everyone' && normalizeTenantSettings({ topic_archive_policy: 'bogus' }).topicArchivePolicy === 'everyone')
ok('archive policy reader: admins / starter pass', normalizeTenantSettings({ topic_archive_policy: 'admins' }).topicArchivePolicy === 'admins' && normalizeTenantSettings({ topic_archive_policy: 'starter' }).topicArchivePolicy === 'starter')
ok('archive policy options, in order', TOPIC_ARCHIVE_POLICY_OPTIONS.join() === 'everyone,admins,starter')
ok('vendor split: absent = the default 40/50/10/0/0', s.agentSplit.claude === 40 && s.agentSplit.grok === 50 && s.agentSplit.agy === 10 && s.agentSplit.qwen === 0 && s.agentSplit.mistral === 0)
ok('vendor split: a saved 100 is kept', normalizeTenantSettings({ agent_split: { claude: 30, grok: 40, agy: 20, qwen: 10, mistral: 0 } }).agentSplit.qwen === 10)
// spec 110 7g: grok's share moves to mistral, five numbers.
ok('vendor split: mistral 55, grok 0 is kept', JSON.stringify(normalizeTenantSettings({ agent_split: { claude: 30, grok: 0, agy: 5, qwen: 10, mistral: 55 } }).agentSplit) === '{"claude":30,"grok":0,"agy":5,"qwen":10,"mistral":55}')
ok('vendor split: a sum other than 100 falls back to the default', normalizeTenantSettings({ agent_split: { claude: 30, grok: 0, agy: 5, qwen: 9, mistral: 55 } }).agentSplit.mistral === 0)
ok('CONTROL vendor split: a four-number body is the default', normalizeTenantSettings({ agent_split: { claude: 30, grok: 40, agy: 20, qwen: 10 } }).agentSplit.claude === 40)
{
  const mp = createMockTenant()
  ok('mock: fresh split is 40/50/10/0/0', mp.settings().agent_split.claude === 40 && mp.settings().agent_split.qwen === 0 && mp.settings().agent_split.mistral === 0)
  const saved = mp.patch({ agent_split: { claude: 30, grok: 0, agy: 5, qwen: 10, mistral: 55 } })
  ok('mock: a split that sums to 100 is saved', saved.agent_split.claude === 30 && saved.agent_split.mistral === 55 && saved.agent_split.grok === 0)
  ok('CONTROL mock: a split off 100 is bad_split', throws(() => mp.patch({ agent_split: { claude: 30, grok: 0, agy: 5, qwen: 9, mistral: 55 } }), 'bad_split') && mp.settings().agent_split.mistral === 55)
  ok('CONTROL mock: a four-number split is bad_split, as on the hub', throws(() => mp.patch({ agent_split: { claude: 40, grok: 50, agy: 10, qwen: 0 } }), 'bad_split') && mp.settings().agent_split.mistral === 55)
}
const splitPage = readFileSync(new URL('../../src/pages/tenant-settings/split.vue', import.meta.url), 'utf8')
ok('Vendor split page has one input per kind, a live sum and the guideline note',
  splitPage.includes('data-test="tenant-split-claude"') && splitPage.includes('data-test="tenant-split-grok"') &&
  splitPage.includes('data-test="tenant-split-agy"') && splitPage.includes('data-test="tenant-split-qwen"') &&
  splitPage.includes('data-test="tenant-split-mistral"') && splitPage.includes("t('tenant_settings.split_mistral')") &&
  splitPage.includes('data-test="tenant-split-sum"') && splitPage.includes("t('tenant_settings.split_note')") &&
  splitPage.includes('agent_split:'))
{
  const mp = createMockTenant()
  ok('mock: fresh workspace archives for everyone', mp.settings().topic_archive_policy === 'everyone')
  ok('mock: set admins', mp.patch({ topic_archive_policy: 'admins' }).topic_archive_policy === 'admins')
  ok('CONTROL mock: an unknown policy is a 400 bad_setting', throws(() => mp.patch({ topic_archive_policy: 'nobody' }), 'bad_setting') && mp.settings().topic_archive_policy === 'admins')
}
const gen = readFileSync(new URL('../../src/pages/tenant-settings/general.vue', import.meta.url), 'utf8')
ok('General page offers the archive policy select and saves it', gen.includes('data-test="tenant-general-archive-policy"') && gen.includes('patch.topic_archive_policy = policy.value'))
const hoursPage = readFileSync(new URL('../../src/pages/tenant-settings/hours.vue', import.meta.url), 'utf8')
ok('spec 107: the hours keys are their own section, Hours, not General', hoursPage.includes('<HoursSettings') && !gen.includes('HoursSettings') &&
  tenantSettingsSectionOf('/tenant-settings/hours') === 'hours' && TENANT_SETTINGS_SECTIONS.find((s) => s.id === 'hours')?.perm === 'tenant.settings')
ok('W16 settings reader: the issue prefix', s.issuePrefix === '' && normalizeTenantSettings({ issue_prefix: 'ACME' }).issuePrefix === 'ACME')
ok('W16 prefix rule: upper-cased, 1..10 of A-Z0-9 from a letter', issuePrefixOf(' ops ') === 'OPS' && issuePrefixOf('A1') === 'A1' &&
  issuePrefixOf('1A') === '' && issuePrefixOf('A-B') === '' && issuePrefixOf('ABCDEFGHIJK') === '' && issuePrefixOf('') === '')
{
  const mt = createMockTenant()
  ok('W16 mock: the prefix starts at SPL', mt.settings().issue_prefix === 'SPL')
  ok('W16 mock: a prefix is saved upper-cased', mt.patch({ issue_prefix: 'acme' }).issue_prefix === 'ACME')
  ok('W16 mock: a bad prefix is refused', throws(() => mt.patch({ issue_prefix: '9x' }), 'bad_setting'))
}
ok('settings reader survives junk', normalizeTenantSettings(null).responders.length === 0 && normalizeTenantSettings(null).maxResponders === 20)

const rows = normalizeTenantChannels({ channels: [
  { channel: 'zeta', name: 'Zeta', visibility: 'members', members: 2, archivable: true },
  { channel: 'lobby', visibility: 'default', no_fallback: true },
  { channel: '' },
] })
ok('channels: defaults first, junk dropped', rows.map((r) => r.channel).join() === 'lobby,zeta')
ok('channels: name falls back to the id', rows[0].name === 'lobby' && rows[0].noFallback === true && rows[0].archivable === false)

ok('responder ids', validResponderId('c-004') && validResponderId('CLE-01') && validResponderId(' GRK-3 ') && validResponderId('AGY-02'))
ok('CONTROL: a human is not a responder', !validResponderId('HUM-4') && !validResponderId('cle-01') && !validResponderId('CLE01'))
ok('move up', moveItem(['a', 'b', 'c'], 2, -1).join() === 'a,c,b')
ok('move past the end is a no-op', moveItem(['a', 'b'], 1, 1).join() === 'a,b' && moveItem(['a', 'b'], 0, -1).join() === 'a,b')
ok('error words', tenantSettingsErrorKey({ token: 'channel_public' }) === 'tenant_settings.error.channel_public' && tenantSettingsErrorKey({ token: 'x' }) === 'tenant_settings.error.generic')

{
  /* spec 066 L7: the summary reader (hub perf_summary.go shape) */
  const q = perfSummaryQuery({ days: 30, build: ' 1.3.12 ', buildB: 'x y' })
  ok('066 L7 query: days, a trimmed build, a bad token left out', q === 'days=30&build=1.3.12', q)
  ok('066 L7 query: an unknown window is 7', perfSummaryQuery({ days: 365 }) === 'days=7')
  const s = normalizePerfSummary({ days: 7, rows: [
    { metric: 'send_ack', device: 'phone', view: 'channel', n: 49, p50: 10, p75: 20, p95: 90, failed: 1 },
    { metric: 'nope', device: 'phone', n: 9 },
    { metric: 'load_rail', device: 'tv', view: 'x', n: 60, p50: 5, p75: 7, p95: 9 },
  ] })
  ok('066 L7 reader: unknown metrics dropped, device and view read safely', s.rows.length === 2 && s.rows[1].device === 'desktop' && s.rows[1].view === '')
  ok('066 L7 reader: p95 hidden under n = 50, kept from 50', s.rows[0].p95 === null && s.rows[1].p95 === 9)
  ok('066 L7 reader: junk is an empty summary', normalizePerfSummary(null).rows.length === 0 && normalizePerfSummary({ off: true }).off === true)
  const a = normalizePerfSummary(mockPerfSummary({})).rows
  ok('066 L7 mock: ranked by p75, one group under n = 50 without p95', a.every((r, i) => i === 0 || (a[i - 1].p75 ?? 0) >= (r.p75 ?? 0)) &&
    a.some((r) => r.n < 50 && r.p95 === null) && a.every((r) => r.n >= 50 ? r.p95 !== null : true), a.map((r) => r.p75).join())
  const ab = normalizePerfSummary(mockPerfSummary({ build: '1.3.11', buildB: '1.3.12' }))
  const cmp = perfCompareRows(ab.rows, ab.rowsB)
  ok('066 L7 compare: B joined per group, delta = B p75 - A p75', ab.buildB === '1.3.12' && cmp.length === ab.rows.length &&
    cmp.every((c) => c.b && c.delta === Math.round(c.b.p75 - c.a.p75)) && cmp[0].delta < 0)
  const only = perfCompareRows([], [{ metric: 'inp', device: 'phone', view: '', n: 1, p50: 1, p75: 1, p95: null, failed: 0 }])
  ok('066 L7 compare: a group only B has is kept, no delta', only.length === 1 && only[0].a === null && only[0].delta === null)
}
const perfPage = readFileSync(new URL('../../src/pages/tenant-settings/performance.vue', import.meta.url), 'utf8')
ok('066 L7: the Performance page reads the summary and shows n beside the percentiles', perfPage.includes('api.getPerfSummary(') &&
  perfPage.includes('data-test="tenant-perf-n"') && perfPage.includes('data-test="tenant-perf-p95"') && perfPage.includes('data-test="tenant-perf-days"') &&
  perfPage.includes('data-test="tenant-perf-build-b"'))
const lazy = readFileSync(new URL('../../src/utils/spool-client-lazy.mjs', import.meta.url), 'utf8')
ok('066 L7: the client calls the admin summary route', lazy.includes('/v1/admin/perf/summary?'))

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
