// SPL-4513 (round 2 of the console errors, SPL-4509 rows 1-6): a signed-out
// visitor on a member-only page goes to /login and reads nothing. The member
// pages used to mount for a visitor and read member endpoints: 170 of 202
// console lines in c-743's crawl (401 /v1/view/me, reporting, notes, archive,
// fleet lanes, and the hub socket). Public pages stay where they are.
// SPL-4937: /people, /users and /tenant-settings joined them; /calendar and
// /goals/<id> were checked and each keep their own signed-out path.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { isProductScreen, signedOutLoginTarget, SIGNED_OUT_LOCALE_CODES } from '../../src/utils/signed-out-redirect.mjs'
import { earlyLoginHref } from '../../src/utils/signed-out-redirect-script.mjs'
import { SIGNED_OUT_HINT_COOKIE } from '../../src/utils/signed-out-hint.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const src = (rel) => readFileSync(join(WUI, rel), 'utf8')
const early = (path) => earlyLoginHref({
  path, search: '', hash: '', cookie: `${SIGNED_OUT_HINT_COOKIE}=1`,
  cookieKey: SIGNED_OUT_HINT_COOKIE, locales: [...SIGNED_OUT_LOCALE_CODES], defaultLocale: 'en',
})

/* every route added by SPL-4513 and SPL-4937, with a tab or an id below it */
const MEMBER = [
  '/monitoring', '/monitoring/agents', '/monitoring/boxes', '/monitoring/costs', '/monitoring/events',
  '/monitoring/file-streams', '/monitoring/lanes', '/monitoring/tokens', '/monitoring/topics',
  '/reporting', '/reporting/costs', '/reporting/issues', '/reporting/lanes', '/reporting/marketing',
  '/reporting/posts', '/reporting/releases', '/reporting/sql', '/reporting/tokens',
  '/notes', '/issues', '/issues?id=SPL-1', '/archive',
  '/workspace/docs', '/workspace/docs?doc=x',
  '/agents', '/agents/c-001', '/boxes', '/boxes/sat',
  '/events',
  '/people', '/people/HUM-1', '/people/contact/new', '/users', '/users?edit=x',
  '/tenant-settings', '/tenant-settings/members', '/tenant-settings/agent-keys',
  '/fi/monitoring/lanes', '/fi/issues', '/he/reporting/releases', '/monitoring/',
  '/fi/people', '/fi/tenant-settings/general',
]

/* checked to stay public: /releases waits for the owner (row 7), the docs
   page is its own door, the auth pages must not loop, the rest are landing
   or shared pages a visitor reads */
const PUBLIC = [
  '/releases', '/releases/v1.2.3', '/docs', '/docs/README.md', '/login', '/fi/login',
  '/verify-email', '/reset-password', '/checkout', '/embed', '/blog', '/blog/a-post',
  '/help', '/help/getting-started', '/roadmap', '/public-calendar', '/m/abc',
  '/monitoringx', '/reportingx', '/issuesx', '/workspace', '/workspace/other', '/agentsx', '/eventsx',
  '/peoplex', '/usersx', '/tenant-settingsx',
]

/* not /login, each by its own code, so never in PRODUCT_ROOTS: a visitor of
   /calendar goes to the public calendar (HUM-10 ef57739c, pages/calendar.vue,
   signedOutCalendarTarget), and a goal page reads a public roadmap of the page
   host signed out (spec 112 WUI-3, useRoadmapGoals) */
const OWN_DOOR = ['/calendar', '/fi/calendar', '/goals/G01-x', '/fi/goals/G01-x']

describe('member-only pages send a signed-out visitor to /login', () => {
  for (const path of MEMBER) {
    it(`${path} is a product screen, in the middleware and the early script`, () => {
      assert.equal(isProductScreen(path), true, path)
      const dest = signedOutLoginTarget(path, 'out', false)
      assert.equal(dest?.path, '/login', path)
      assert.equal(dest.query.redirect, path)
      assert.notEqual(early(path.split('?')[0]), '', `early ${path}`)
    })
  }

  for (const path of PUBLIC) {
    it(`${path} stays public`, () => {
      assert.equal(isProductScreen(path), false, path)
      assert.equal(signedOutLoginTarget(path, 'out', false), null, path)
      assert.equal(early(path), '', `early ${path}`)
    })
  }

  for (const path of OWN_DOOR) {
    it(`${path} keeps its own signed-out path, not /login`, () => {
      assert.equal(isProductScreen(path), false, path)
      assert.equal(signedOutLoginTarget(path, 'out', false), null, path)
      assert.equal(early(path), '', `early ${path}`)
    })
  }

  it('/public-calendar is not caught by a /calendar root', () => {
    for (const path of ['/public-calendar', '/fi/public-calendar', '/public-calendar/']) {
      assert.equal(isProductScreen(path), false, path)
      assert.equal(early(path), '', `early ${path}`)
    }
  })
})

describe("no member read while the session is 'out'", () => {
  it('access.load() returns before /v1/view/me when signed out', () => {
    const s = src('src/stores/access.ts')
    assert.match(s, /useSessionStore/)
    const guard = s.search(/session\.state === 'out'/)
    const read = s.indexOf('api.me()')
    assert.ok(guard >= 0 && read > guard, 'the out guard comes before the me() read')
  })

  // its behaviour (a sign-out still closes an open socket): signed-out-socket-close.test.mjs
  it('useLive.ensure() opens no socket when signed out', () => {
    const s = src('src/composables/useLive.ts')
    assert.match(s, /useSessionStore/)
    assert.match(s, /function signedOutTab\(sessionState: string\): boolean \{\n  if \(sessionState !== 'out'\) return false/)
    const ensureAt = s.indexOf('function ensure()')
    const guard = s.indexOf('if (signedOutTab(session.state)) return live', ensureAt)
    const dialAt = s.indexOf('live = dial(', ensureAt)
    const reconnect = s.indexOf("live.state === 'signed_out'", ensureAt)
    assert.ok(ensureAt >= 0 && guard > ensureAt && guard < dialAt && guard < reconnect, 'the out guard comes before any connect')
  })
})
