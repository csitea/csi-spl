// CLE-77886 (owner, t1 topic ac0fa400): on a phone every section keeps the
// one section strip; a section page shows it instead of a bare title, and
// the strip rolls endlessly.
//
// Run: node tests/unit/section-strip.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { chatKind, isSectionPage, loopPosition, railLinkSection, sectionExitPath } from '../../src/utils/section-strip.mjs'

describe('isSectionPage', () => {
  it('every section page the owner named, with or without a locale', () => {
    for (const p of ['/issues', '/people', '/boxes', '/agents', '/events', '/help', '/docs', '/tenant-settings', '/archive', '/', '/fi/issues', '/issues?epic=SPL-1', '/people/']) {
      assert.equal(isSectionPage(p), true, p)
    }
  })
  it('a drill-down keeps its own header and Back', () => {
    for (const p of ['/channel/general', '/dm/HUM-2', '/people/HUM-2', '/agents/CLE-1', '/boxes/b1', '/help/how-to-post', '/docs/README.md', '/tenant-settings/members', '/t/abc', '/search']) {
      assert.equal(isSectionPage(p), false, p)
    }
  })
})

describe('railLinkSection', () => {
  it('names the rail link a route belongs to', () => {
    assert.equal(railLinkSection('/help'), 'help')
    assert.equal(railLinkSection('/fi/help/how-to-post'), 'help')
    assert.equal(railLinkSection('/tenant-settings/members'), 'settings')
    assert.equal(railLinkSection('/docs'), 'docs')
    assert.equal(railLinkSection('/fi/docs/csi-spl-doc/specs/072-x/spec.md'), 'docs')
    assert.equal(railLinkSection('/issues'), '')
  })
})

describe('loopPosition', () => {
  it('keeps the view inside the middle copy, never at an end', () => {
    assert.equal(loopPosition(500, 700), 500)
    assert.equal(loopPosition(100, 700), 800)
    assert.equal(loopPosition(1100, 700), 400)
    assert.equal(loopPosition(350, 700), 350)
    assert.equal(loopPosition(1050, 700), 1050)
  })
  it('no set width (not measured / nothing overflows) leaves it alone', () => {
    assert.equal(loopPosition(5, 0), 5)
    assert.equal(loopPosition(5, NaN), 5)
  })
})

describe('the way out of a section page (HUM-24, 7930dfbf)', () => {
  it('chatKind names the conversation a reader left', () => {
    assert.equal(chatKind('/channel/general'), 'channel')
    assert.equal(chatKind('/fi/lobby'), 'channel')
    assert.equal(chatKind('/dm/HUM-2'), 'dm')
    assert.equal(chatKind('/issues'), '')
    assert.equal(chatKind('/people/HUM-2'), '')
  })
  it('Channels -> the last channel, DMs -> the last DM, Flow / X -> the last conversation, else the lobby', () => {
    const last = { channel: '/channel/alerts?topic=a', dm: '/dm/HUM-2', chat: '/dm/HUM-2' }
    assert.equal(sectionExitPath(last, 'channels'), '/channel/alerts?topic=a')
    assert.equal(sectionExitPath(last, 'dm'), '/dm/HUM-2')
    assert.equal(sectionExitPath(last, 'flow'), '/dm/HUM-2')
    assert.equal(sectionExitPath(last), '/dm/HUM-2')
    assert.equal(sectionExitPath({}, 'channels'), '/lobby')
    assert.equal(sectionExitPath({}), '/lobby')
    assert.equal(sectionExitPath({}, 'dm'), '')
  })
})
