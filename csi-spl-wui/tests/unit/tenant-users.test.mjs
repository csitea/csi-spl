// the admin's Users page, WUI side - the entry gate (strict, not
// fail-open), the GET /v1/members reader, the error words, the mock hub rules.
// Run: node tests/unit/tenant-users.test.mjs
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { accessDateOf, accessUntilOfDate, inviteMailed, looksLikeEmail, mailOutcomeKey, memberLabel, normalizeDirectory, openInviteFor, passwordResetState, signInProviderName, USER_PANE_SIDE, userErrorKey, usersEntryVisible } from '../../src/utils/tenant-users.mjs'
import { createMockDirectory, MOCK_MAIL_GAP_MS, MOCK_RESET_GAP_MS } from '../../src/utils/tenant-users-mock.mjs'
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

// HUM-10 2026-10-03 (prd): create (no mail) -> Send (sent) -> the form again
// for the same address (no mail: resets mail_count) -> Send twice inside the
// gap (rate_limited). The page then read "not sent" for a mailed invite. The
// list must keep WHEN it was mailed, and each outcome must have its own words.
let clock = new Date('2026-10-03T05:02:38Z')
const h = createMockDirectory(() => clock)
const look = () => normalizeDirectory(h.list()).invites.find((i) => i.email === 'x@example.com')
ok('HUM-10 create stores without mail', h.invite('x@example.com', 'tester', { noMail: true }).mail === 'not_sent' && !inviteMailed(look()))
clock = new Date('2026-10-03T05:02:45Z')
ok('HUM-10 Send mails it', h.invite('x@example.com', 'tester').mail === 'sent' && look().mailedAt === '2026-10-03T05:02:45.000Z' && inviteMailed(look()))
clock = new Date('2026-10-03T05:08:46Z')
h.invite('x@example.com', 'tester', { noMail: true })
ok('HUM-10 a re-invite resets the count but the list still says mailed, and when', look().mailCount === 0 && look().mailedAt === '2026-10-03T05:02:45.000Z' && inviteMailed(look()), JSON.stringify(look()))
clock = new Date('2026-10-03T05:08:48Z')
ok('HUM-10 a resend inside the gap is rate_limited and keeps the earlier mail', h.invite('x@example.com', 'tester').mail === 'rate_limited' && look().mailedAt === '2026-10-03T05:02:45.000Z')
clock = new Date(Date.parse('2026-10-03T05:02:45Z') + MOCK_MAIL_GAP_MS)
ok('CONTROL: after the gap a resend mails again', h.invite('x@example.com', 'tester').mail === 'sent' && look().mailedAt === clock.toISOString())
ok('outcome words', mailOutcomeKey('sent') === 'users.invited' && mailOutcomeKey('rate_limited') === 'users.mail_rate_limited' && mailOutcomeKey('not_configured') === 'users.mail_not_sent' && mailOutcomeKey(undefined) === 'users.mail_not_sent')
const od = normalizeDirectory({ invites: [{ email: 'open@example.com', expired: false, mailed_at: '2026-10-03T05:02:45Z' }, { email: 'old@example.com', expired: true }] })
ok('the form finds an open invite by address', openInviteFor(od, ' Open@Example.com ')?.key === 'i:open@example.com' && od.invites[0].mailedAt === '2026-10-03T05:02:45Z')
ok('CONTROL: an expired invite or an unknown address re-invites', openInviteFor(od, 'old@example.com') === null && openInviteFor(od, 'new@example.com') === null && openInviteFor(null, 'x@example.com') === null)
ok('CONTROL: never mailed reads not mailed', !inviteMailed(normalizeDirectory({ invites: [{ email: 'n@example.com', mail_count: 0, mailed_at: null }] }).invites[0]))

// Every users.* key the code names exists in en.json (all 19 are the parity test's job).
const en = JSON.parse(readFileSync(join(WUI, 'i18n/locales/en.json'), 'utf8'))
const code = ['src/pages/users.vue', 'src/components/UserEditPane.vue', 'src/components/TenantUsers.vue', 'src/components/ChannelSidebar.vue'].map((f) => readFileSync(join(WUI, f), 'utf8')).join('\n')
const used = [...code.matchAll(/t\('(users\.[a-z_.]+|sidebar\.users)'/g)].map((x) => x[1])
const get = (k) => k.split('.').reduce((o, p) => (o && typeof o === 'object' ? o[p] : undefined), en)
const missing = used.filter((k) => typeof get(k) !== 'string')
ok('every users key the code names is in en.json', used.length > 20 && missing.length === 0, missing.join(','))
for (const tok of ['forbidden', 'last_admin', 'last_owner', 'self', 'bad_email', 'bad_role', 'role_changed', 'not_found', 'bad_access_until', 'not_migrated', 'generic']) {
  ok('error word ' + tok, typeof get('users.error.' + tok) === 'string')
}

// spec 072 A27: a membership that ends on a date.
const ax = normalizeDirectory({ members: [{ human_id: 'HUM-7', access_until: '2026-11-01T22:00:00Z', access_ended: true }, { human_id: 'HUM-8', access_until: null }] })
ok('access_until is read', ax.members[0].accessUntil === '2026-11-01T22:00:00Z' && ax.members[0].accessEnded === true)
ok('CONTROL: no end reads empty, not ended', ax.members[1].accessUntil === '' && ax.members[1].accessEnded === false)
// The mock's access_ended reads the injected clock, not the real one.
let accessClock = new Date('2026-09-29T12:00:00Z')
const am = createMockDirectory(() => accessClock)
const endedOf = (id) => am.list().members.find((x) => x.human_id === id).access_ended
am.patch('HUM-3', { access_until: '2026-09-30T00:00:00Z' })
ok('mock access_ended: an end after the clock has not ended', endedOf('HUM-3') === false)
accessClock = new Date('2026-09-30T00:00:00Z')
am.patch('HUM-3', { access_until: '2026-09-30T00:00:00Z' })
ok('mock access_ended: an end at the clock has ended', endedOf('HUM-3') === true)
am.patch('HUM-3', { access_until: null })
ok('CONTROL: mock access_ended: no end never ends', endedOf('HUM-3') === false)
const until = accessUntilOfDate('2026-11-01')
ok('a day ends at the next local midnight', until !== '' && new Date(until).getTime() === new Date(2026, 10, 2).getTime(), until)
ok('the day round-trips', accessDateOf(until) === '2026-11-01', accessDateOf(until))
ok('CONTROL: a bad day is no end', accessUntilOfDate('') === '' && accessUntilOfDate('11/01/2026') === '' && accessDateOf('') === '')
ok('error key bad_access_until', userErrorKey({ token: 'bad_access_until' }) === 'users.error.bad_access_until')
// t1 ea0af569: the admin's Reset password. Offered on a member the reader
// manages (never the reader); disabled, naming the provider, for an IdP-only
// member; an unknown sign-in (an older hub) stays enabled - the hub decides.
const rd = normalizeDirectory({ members: [
  { human_id: 'HUM-3', manageable: true, sign_in: ['password'] },
  { human_id: 'HUM-4', manageable: true, sign_in: ['google'] },
  { human_id: 'HUM-5', manageable: true },
  { human_id: 'HUM-1', manageable: false, you: true, sign_in: ['password'] },
  { human_id: 'HUM-2', manageable: false, sign_in: ['password'] },
] })
const rs = (id) => passwordResetState(rd.members.find((m) => m.humanId === id))
ok('reset: a password member is offered and enabled', rs('HUM-3').offered && rs('HUM-3').enabled)
ok('reset: an IdP-only member is offered DISABLED, naming the provider', rs('HUM-4').offered && !rs('HUM-4').enabled && rs('HUM-4').providers.join() === 'Google', JSON.stringify(rs('HUM-4')))
ok('reset: an unknown sign-in stays enabled (the hub decides)', rs('HUM-5').enabled && rd.members.find((m) => m.humanId === 'HUM-5').signIn === null)
ok('CONTROL reset: never on the reader itself', !rs('HUM-1').offered && !rs('HUM-1').enabled)
ok('CONTROL reset: never on a member the reader cannot manage (a non-admin manages nobody)', !rs('HUM-2').offered)
ok('CONTROL reset: nothing for no row / an invite', !passwordResetState(null).offered && !passwordResetState({ kind: 'invite' }).offered)
ok('signInProviderName', signInProviderName('github') === 'GitHub' && signInProviderName('microsoft') === 'Microsoft' && signInProviderName('acme') === 'Acme' && signInProviderName('') === '')
for (const tok of ['no_password', 'rate_limited', 'email_delivery_unavailable']) {
  ok('reset error word ' + tok, userErrorKey({ token: tok }) === 'users.error.' + tok && typeof get('users.error.' + tok) === 'string')
}
for (const k of ['reset_password', 'reset_password_hint', 'reset_password_federated', 'reset_confirm_title', 'reset_confirm', 'reset_sign_out', 'reset_send', 'reset_sent']) {
  ok('reset string users.' + k, typeof get('users.' + k) === 'string')
}
let resetClock = new Date('2026-10-07T12:00:00Z')
const rm = createMockDirectory(() => resetClock)
const r1 = rm.resetPassword('HUM-3', true)
ok('mock reset: the member\'s address and the sign-out come back', r1.email === 'dev1@example.com' && r1.signed_out === true)
ok('mock reset: a second inside the gap is 429', throws(() => rm.resetPassword('HUM-3', true), 'rate_limited'))
resetClock = new Date(resetClock.getTime() + MOCK_RESET_GAP_MS)
ok('CONTROL mock reset: past the gap it goes again', rm.resetPassword('HUM-3', false).signed_out === false)
ok('mock reset: IdP-only 409, self 409, owner 403, unknown 404',
  throws(() => rm.resetPassword('HUM-12'), 'no_password') && throws(() => rm.resetPassword('HUM-1'), 'self') &&
  throws(() => rm.resetPassword('HUM-2'), 'forbidden') && throws(() => rm.resetPassword('HUM-99'), 'not_found'))
ok('mock list carries sign_in', JSON.stringify(rm.list().members.find((m) => m.human_id === 'HUM-12').sign_in) === '["google"]')

const s = runsInUnitSuite(import.meta.url)
ok('pnpm test runs this suite', s.ok, s.why)

console.log(failed ? `tenant-users: ${failed} FAILED` : 'tenant-users: all OK')
if (failed) process.exitCode = 1
