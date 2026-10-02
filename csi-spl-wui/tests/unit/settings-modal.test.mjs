// CLE-77853 (bug 49568e8b): Settings is a modal over the current view, keyed
// by ?settings=<section>. The query reader, the old-address redirect target,
// the close step, and the wiring (one UiDialog, routed; the middleware; no
// settings page left that replaces the view).
// Run: node tests/unit/settings-modal.test.mjs
import { existsSync, readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  DEFAULT_SETTINGS_SECTION,
  SETTINGS_SECTIONS,
  isSettingsPath,
  settingsCloseStep,
  settingsModalTarget,
  settingsQuerySection,
  settingsShownSection,
  withoutSettings,
} from '../../src/utils/settings-nav.mjs'
import { runsInUnitSuite } from './lib/in-suite.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '..', '..')
const read = (p) => readFileSync(join(WUI, p), 'utf8')
let failed = 0
const ok = (name, cond, why = '') => { if (cond) console.log(`  OK   ${name}`); else { failed++; console.log(`  FAIL ${name} ${why}`) } }
const eq = (name, got, want) => ok(name, JSON.stringify(got) === JSON.stringify(want), `got ${JSON.stringify(got)} want ${JSON.stringify(want)}`)

console.log('settings-modal')

eq('no key = closed', settingsQuerySection({ topic: 'x' }), null)
eq('no query = closed', settingsQuerySection(undefined), null)
eq('bare key = open, no section', settingsQuerySection({ settings: '' }), '')
eq('null value (?settings) = open, no section', settingsQuerySection({ settings: null }), '')
eq('a known section', settingsQuerySection({ settings: 'security' }), 'security')
eq('an array value takes the first', settingsQuerySection({ settings: ['keys', 'profile'] }), 'keys')
eq('an unknown section opens on none', settingsQuerySection({ settings: 'nope' }), '')
for (const s of SETTINGS_SECTIONS) eq(`every section is reachable: ${s.id}`, settingsQuerySection({ settings: s.id }), s.id)

eq('desktop: bare opens the default section', settingsShownSection('', false), DEFAULT_SETTINGS_SECTION)
eq('phone: bare is the list', settingsShownSection('', true), '')
eq('a section shows as itself', settingsShownSection('keys', true), 'keys')
eq('closed stays closed', settingsShownSection(null, false), null)

for (const p of ['/settings', '/settings/', '/settings/keys', '/fi/settings/keys', '/bg/settings', '/settings/notifications?x=1']) ok(`old address: ${p}`, isSettingsPath(p))
for (const p of ['/', '/lobby', '/tenant-settings', '/tenant-settings/members', '/channel/settings', '/settings/keys/extra', '/help/settings']) ok(`not an old address: ${p}`, !isSettingsPath(p))

eq('from a view: the view + ?settings=<section>',
  settingsModalTarget('/settings/notifications', { path: '/channel/general', query: { topic: 'abc' }, matched: 1 }),
  { path: '/channel/general', query: { topic: 'abc', settings: 'notifications' } })
eq('the user menu (/settings) from a view: bare key',
  settingsModalTarget('/settings', { path: '/issues', query: {}, matched: 1 }),
  { path: '/issues', query: { settings: '' } })
eq('from a view with Settings open: the section is replaced',
  settingsModalTarget('/settings/keys', { path: '/lobby', query: { settings: 'profile' }, matched: 1 }),
  { path: '/lobby', query: { settings: 'keys' } })
eq('cold deep link: the lobby',
  settingsModalTarget('/settings/security', { path: '/', query: {}, matched: 0 }),
  { path: '/lobby', query: { settings: 'security' } })
eq('cold deep link keeps the locale prefix',
  settingsModalTarget('/fi/settings/keys', { path: '/', query: {}, matched: 0 }),
  { path: '/fi/lobby', query: { settings: 'keys' } })
eq('from another old address: the lobby',
  settingsModalTarget('/settings/keys', { path: '/settings', query: {}, matched: 1 }),
  { path: '/lobby', query: { settings: 'keys' } })
const q = { settings: 'keys', topic: 't' }
eq('withoutSettings drops only the key', withoutSettings(q), { topic: 't' })
eq('withoutSettings leaves its input alone', q, { settings: 'keys', topic: 't' })

eq('close: Back when the entry under is the view', settingsCloseStep('/channel/general', '/channel/general'), 'back')
eq('close: replace on a cold deep link', settingsCloseStep(null, '/lobby'), 'replace')
eq('close: replace when the entry under is something else', settingsCloseStep('/issues', '/lobby'), 'replace')

const dialog = read('src/components/SettingsDialog.vue')
ok('the dialog is the shared UiDialog, routed', /<UiDialog[^>]*\brouted\b/.test(dialog))
ok('the dialog is large, like the Edit epic dialog', /<UiDialog[^>]*size="lg"/.test(dialog))
ok('section links replace (Back closes, not walks sections)', (dialog.match(/\breplace\b/g) || []).length >= 2)
for (const s of SETTINGS_SECTIONS) ok(`the dialog mounts components/settings/${s.id}.vue`, dialog.includes(`~/components/settings/${s.id}.vue`) && existsSync(join(WUI, `src/components/settings/${s.id}.vue`)))
const app = read('src/app.vue')
ok('app.vue mounts the dialog once', (app.match(/<(?:Lazy)?SettingsDialog\b/g) || []).length === 1)
/* CLE-77925: the dialog is its own chunk, not initial JS - mounted the first
   time ?settings= appears and kept mounted after */
ok('app.vue mounts the dialog lazily, on the first ?settings=',
  /<LazySettingsDialog v-if="settingsMounted"/.test(app) && /settingsQuerySection\(route\.query[^)]*\) !== null/.test(app))
const mw = read('src/middleware/settings-modal.global.ts')
ok('the middleware redirects the old addresses', /isSettingsPath/.test(mw) && /settingsModalTarget/.test(mw) && /navigateTo/.test(mw))
ok('no settings page replaces the view', !existsSync(join(WUI, 'src/pages/settings.vue')) && !existsSync(join(WUI, 'src/pages/settings/index.vue')))
const ui = read('src/components/UiDialog.vue')
ok('a routed UiDialog pushes no overlay entry of its own', /history:\s*!props\.routed/.test(ui))
ok('a routed UiDialog keeps its X on a phone', /\.ui-dialog\.routed \.ui-dialog__close\s*\{\s*display:\s*inline-flex/.test(ui))

const suite = runsInUnitSuite(import.meta.url)
ok('pnpm test runs this suite', suite.ok, suite.why)

if (failed) {
  console.error(`\n${failed} failure(s)`)
  process.exit(1)
}
console.log('\nAll settings-modal checks passed.')
