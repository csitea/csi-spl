// CLE-3433 pinned the predicate: only a SETTLED 'out' is a signed-out visitor.
// 'loading' is a probe in flight and 'unknown' is an unreachable hub
// (auth-v1 §4), NOT a signed-out human. The mock tenant has no sign-in.
//
// The product screens no longer render SignedOutNotice. A settled 'out'
// replaces those routes with /login (signed-out-redirect.test.mjs). This file
// keeps the predicate, the sidebar gate, and the notice component's own copy
// honest.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync, readdirSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { isSignedOutVisitor } from '../../src/utils/shell-bootstrap.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const src = (rel) => readFileSync(join(WUI, rel), 'utf8')
const FEED_PAGES = ['src/pages/index.vue', 'src/pages/lobby.vue', 'src/pages/channel/[name].vue', 'src/pages/dm/[peer].vue']

describe('isSignedOutVisitor (CLE-3433)', () => {
  it("only a settled 'out' counts", () => {
    assert.equal(isSignedOutVisitor('out'), true)
    assert.equal(isSignedOutVisitor('in'), false)
    assert.equal(isSignedOutVisitor('loading'), false)
    assert.equal(isSignedOutVisitor('unknown'), false)
    assert.equal(isSignedOutVisitor(undefined), false)
    assert.equal(isSignedOutVisitor(null), false)
  })

  it('the mock tenant has no sign-in, so it is never a signed-out visitor', () => {
    assert.equal(isSignedOutVisitor('out', true), false)
  })
})

describe('product feed pages do not paint the signed-out notice', () => {
  for (const page of FEED_PAGES) {
    it(`${page}: no longer renders SignedOutNotice`, () => {
      const s = src(page)
      assert.doesNotMatch(s, /<SignedOutNotice/)
      assert.doesNotMatch(s, /navigateTo\(.*login/)
    })
  }

  it('the notice links to /login carrying the route it came from', () => {
    const s = src('src/components/SignedOutNotice.vue')
    assert.match(s, /localePath\('\/login'\)/)
    assert.match(s, /redirect: route\.fullPath/)
    assert.match(s, /data-test="signed-out-notice"/)
    assert.match(s, /auth\.signed_out_view/)
  })

  it('the sidebar stops offering "new channel" to someone who cannot create one', () => {
    const s = src('src/components/ChannelSidebar.vue')
    /* access.can fails OPEN by design; a settled signed-out probe is not a
       failed read, and the control could only ever answer 401. The gate is one
       computed now (the + button), not a v-if repeated per element. */
    assert.match(s, /const canCreate = computed\(\(\) => !signedOut\.value && access\.can\('channels\.manage'\)\)/)
    assert.match(s, /v-if="canCreate"/)
    assert.match(s, /isSignedOutVisitor\(session\.state, api\.mock\)/)
  })

  it('all 19 locales carry auth.signed_out_view, with the {link} slot intact', () => {
    const dir = join(WUI, 'i18n/locales')
    const files = readdirSync(dir).filter((f) => f.endsWith('.json')).sort()
    assert.equal(files.length, 19)
    for (const f of files) {
      const j = JSON.parse(readFileSync(join(dir, f), 'utf8'))
      const v = j.auth && j.auth.signed_out_view
      assert.equal(typeof v, 'string', `${f}: auth.signed_out_view missing`)
      assert.ok(v.includes('{link}'), `${f}: lost the {link} slot`)
    }
    assert.equal(JSON.parse(src('i18n/locales/en.json')).auth.signed_out_view, '{link} to read and send messages.')
  })
})
