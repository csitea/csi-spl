// CLE-34969: the admin's Users page, WUI side - the entry gate (strict, not
// fail-open), the GET /v1/members reader, the error words, the mock hub rules.
// Run: node tests/unit/tenant-users.test.mjs
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { looksLikeEmail, memberLabel, normalizeDirectory, USER_PANE_SIDE, userErrorKey, usersEntryVisible } from '../../src/utils/tenant-users.mjs'
import { createMockDirectory } from '../../src/utils/tenant-users-mock.mjs'
import { normalizeMe } from '../../src/utils/access.mjs'
import { tabForPath, USERS_TAB } from '../../src/utils/sidebar-tabs.mjs'
import { runsInUnitSuite } from './lib/in-suite.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
let failed = 0
const ok = (name, cond, why = '') => { if (cond) console.log(`  OK   ${name}`); else { failed++; console.log(`  FAIL ${name} ${why}`) } }
const throws = (fn, token) => { try { fn(); return false } catch (e) { return e.token === token } }

console.log('tenant-users')
const admin = normalizeMe({ human_id: 'HUM-1', role: 'admin', permissions: ['members.invite', 'members.roles', 'topics.read'] })
const owner = normalizeMe({ human_id: 'HUM-2', role: 'biz_owner', permissions: ['members.roles', 'billing.manage'] })
ok('admin sees Users', usersEntryVisible(admin))
ok('CONTROL: biz_owner (no members.invite) does not', !usersEntryVisible(owner))
ok('CONTROL: no answer does NOT fail open', !usersEntryVisible(null) && !usersEntryVisible(normalizeMe({})))
ok('mock plays the admin', usersEntryVisible(null, { mock: true }))
ok('/users picks the users tab', tabForPath('/users') === USERS_TAB && tabForPath('/fi/users') === USERS_TAB)
ok('pane side is one switch', USER_PANE_SIDE === 'right' || USER_PANE_SIDE === 'left')

const d = normalizeDirectory({
  you: 'HUM-1',
  members: [{ human_id: 'HUM-1', display_name: 'Ann', email: 'a@example.com', role: 'admin', you: true }, { human_id: '' }, { human_id: 'HUM-3', email: 'b@example.com', role: 'tester', manageable: true }],
  invites: [{ email: 'p@example.com', role: 'developer', expired: true }, {}],
  roles: [{ id: 'admin', grantable: true }, { id: 'biz_owner', grantable: false }, null],
})
ok('rows keep their shape', d.members.length === 2 && d.members[0].you && !d.members[0].manageable && d.members[1].manageable && d.members[1].key === 'm:HUM-3')
ok('invites keyed by address', d.invites.length === 1 && d.invites[0].key === 'i:p@example.com' && d.invites[0].expired)
ok('roles', d.roles.length === 2 && d.roles[1].grantable === false)
ok('garbage body is empty', normalizeDirectory('x').members.length === 0)
ok('label falls back name -> email -> id', memberLabel(d.members[0]) === 'Ann' && memberLabel(d.members[1]) === 'b@example.com' && memberLabel(d.invites[0]) === 'p@example.com')
ok('error keys', userErrorKey({ token: 'last_admin' }) === 'users.error.last_admin' && userErrorKey({ token: 'weird' }) === 'users.error.generic' && userErrorKey(null) === 'users.error.generic')
ok('email check', looksLikeEmail(' x@y.io ') && !looksLikeEmail('nope') && !looksLikeEmail('a@b'))

const m = createMockDirectory(() => new Date('2026-09-25T00:00:00Z'))
ok('mock lists 4 + 1', m.list().members.length === 4 && m.list().invites.length === 1)
ok('CONTROL: mock refuses self removal', throws(() => m.remove('HUM-1'), 'self'))
ok('CONTROL: mock refuses last admin demotion', throws(() => m.setRole('HUM-1', 'tester'), 'last_admin'))
ok('CONTROL: mock refuses touching the owner', throws(() => m.remove('HUM-2'), 'forbidden'))
m.invite('New@Example.com', 'tester')
ok('mock invite lowercases', m.list().invites.some((i) => i.email === 'new@example.com' && i.role === 'tester'))
m.setRole('HUM-3', 'tester')
m.remove('HUM-12')
m.revoke('pending@example.com')
ok('mock writes land', m.list().members.length === 3 && m.list().invites.length === 1)

// Every users.* key the code names exists in en.json (all 19 are the parity test's job).
const en = JSON.parse(readFileSync(join(WUI, 'i18n/locales/en.json'), 'utf8'))
const code = ['src/pages/users.vue', 'src/components/UserEditPane.vue', 'src/components/ChannelSidebar.vue'].map((f) => readFileSync(join(WUI, f), 'utf8')).join('\n')
const used = [...code.matchAll(/t\('(users\.[a-z_.]+|sidebar\.users)'/g)].map((x) => x[1])
const get = (k) => k.split('.').reduce((o, p) => (o && typeof o === 'object' ? o[p] : undefined), en)
const missing = used.filter((k) => typeof get(k) !== 'string')
ok('every users key the code names is in en.json', used.length > 20 && missing.length === 0, missing.join(','))
for (const tok of ['forbidden', 'last_admin', 'last_owner', 'self', 'bad_email', 'bad_role', 'role_changed', 'not_found', 'generic']) {
  ok('error word ' + tok, typeof get('users.error.' + tok) === 'string')
}

const s = runsInUnitSuite(import.meta.url)
ok('pnpm test runs this suite', s.ok, s.why)

console.log(failed ? `tenant-users: ${failed} FAILED` : 'tenant-users: all OK')
if (failed) process.exitCode = 1
