// CLE-3433 — the version footer read a bare `v0.1.0` from .version, a marker
// nobody has bumped. ORC listed it third among the things the owner may mean
// by "the UI seems completely broken": it answers a question nobody asks and
// not the one they do — "am I looking at the build that carries the fix?".
// The deploy workflow already writes /build.json beside the page, so the
// footer reads it. The semver is untouched; the commit is added.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { buildStampText, buildStampTitle, readBuildStamp, shortCommit } from '../../src/utils/build-stamp.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const src = (rel) => readFileSync(join(WUI, rel), 'utf8')
const LIVE = { commit: '4c212dd0ee1c0d1a5a2f3f5a6b7c8d9e0f1a2b3c', built_at: '2026-09-21T12:26:00Z', run: '35599162052' }

describe('build stamp (CLE-3433)', () => {
  it('shows the semver plus a short commit', () => {
    assert.equal(buildStampText('v0.1.0', LIVE), 'v0.1.0 · 4c212dd')
  })

  it('with no build.json the footer is EXACTLY what it was', () => {
    assert.equal(buildStampText('v0.1.0', null), 'v0.1.0')
    assert.equal(buildStampText('v0.1.0', undefined), 'v0.1.0')
  })

  it('a commit that is not a sha is not printed as one', () => {
    assert.equal(shortCommit('unknown'), '')
    assert.equal(shortCommit(''), '')
    assert.equal(shortCommit(null), '')
    assert.equal(buildStampText('v0.1.0', { commit: 'not-a-sha' }), 'v0.1.0')
  })

  it('the title carries the whole stamp, and is empty when there is none', () => {
    assert.equal(buildStampTitle(LIVE), `${LIVE.commit} · ${LIVE.built_at} · run ${LIVE.run}`)
    assert.equal(buildStampTitle(null), '')
  })

  /* the footer must never be the reason the shell breaks */
  it('a missing, failing or malformed build.json reads as null, never throws', async () => {
    assert.equal(await readBuildStamp(async () => ({ ok: false, status: 404 })), null)
    assert.equal(await readBuildStamp(async () => { throw new Error('offline') }), null)
    assert.equal(await readBuildStamp(async () => ({ ok: true, json: async () => ({ nope: 1 }) })), null)
    assert.equal(await readBuildStamp(async () => ({ ok: true, json: async () => { throw new Error('bad json') } })), null)
    assert.deepEqual(await readBuildStamp(async () => ({ ok: true, json: async () => LIVE })), LIVE)
  })

  it('the sidebar reads it once on mount, client side', () => {
    const s = src('src/components/ChannelSidebar.vue')
    assert.match(s, /from '~\/utils\/build-stamp\.mjs'/)
    assert.match(s, /onMounted\(async \(\) => \{ build\.value = await readBuildStamp\(\) \}\)/)
    assert.match(s, /data-test="app-version"/)
    // owner 2026-09-26: the stamp sits IN the icon row, right of the note, one line
    // owner 2026-09-26: the version is FIRST in the row, then the dot, bell and note
    const row = s.slice(s.indexOf('<div class="foot-row">'), s.indexOf('<NotificationCenter />') + 30)
    const iv = row.indexOf('data-test="app-version"'), ih = row.indexOf('data-testid="connection-health"'), inc = row.indexOf('<NotificationCenter />')
    assert.ok(iv > 0 && iv < ih && ih < inc, 'order must be version, dot, bell/note')
    assert.match(s, /\.foot-row \{ display: flex; align-items: center; gap: 8px; padding: 8px 16px 4px; \}/)
    assert.match(s, /\.foot-row \.version-stamp \{[^}]*white-space: nowrap;[^}]*text-overflow: ellipsis;/)
    // owner 2026-09-26: only the version shows; the commit is in a card that
    // stays open (hover/focus/tap), closes on Esc after a grace delay, copyable
    assert.doesNotMatch(s, /class="vs-sha"/)
    assert.doesNotMatch(s, /data-test="app-version"[^>]*:title=/)
    assert.match(s, /data-test="app-version-card"/)
    assert.match(s, /data-test="app-version-copy"/)
    assert.match(s, /navigator\.clipboard\.writeText\(buildCommit\.value\)/)
    assert.match(s, /@keydown\.esc\.stop=/)
    assert.match(s, /\.vs-wrap:focus-within \.vs-pop/)
    assert.match(s, /\.vs-wrap\.is-open \.vs-pop/)
    assert.match(s, /user-select: text;/)
    assert.match(s, /transition: opacity 0\.15s ease 0\.4s/)
  })
})
