// t1 6e21c7d8: on a phone the open topic pane is the only panel on screen; a
// link from a post to another page must close it so that page shows
// (utils/topic-pane.mjs routeLeavesTopic, wired in layouts/default.vue).
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { routeLeavesTopic } from '../../src/utils/topic-pane.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const link = { mobile: true, open: true, popstate: false, fromPath: '/channel/lobby', toPath: '/t/abc', toQuery: {} }

describe('a link out of the open topic pane on a phone', () => {
  it('closes the pane when a post links to another page', () => {
    assert.equal(routeLeavesTopic(link), true)
  })

  it('leaves it open on desktop for a non-section page, with no pane, and on Back / Forward', () => {
    assert.equal(routeLeavesTopic({ ...link, mobile: false }), false)
    assert.equal(routeLeavesTopic({ ...link, open: false }), false)
    assert.equal(routeLeavesTopic({ ...link, popstate: true }), false)
  })

  it('leaves it open for a ?topic= write and a same-path navigation', () => {
    assert.equal(routeLeavesTopic({ ...link, toPath: '/channel/x', toQuery: { topic: 't' } }), false)
    assert.equal(routeLeavesTopic({ ...link, toPath: '/channel/lobby' }), false)
    assert.equal(routeLeavesTopic({}), false)
  })

  it('the layout closes both topic stores on it', () => {
    const src = readFileSync(join(WUI, 'src/layouts/default.vue'), 'utf8')
    assert.match(src, /if \(routeLeavesTopic\(nav\)\) \{ livePane\.close\(\); topic\.close\(\); operatorPane\.close\(\) \}/)
    assert.match(src, /router\.options\.history\.listen\(/)
  })
})

// spec 078 FR-004 / FR-005: on desktop a section page or /search closes the
// right pane; channel to channel / DM and Back keep today's rules.
describe('a section change on desktop closes the right pane', () => {
  const desk = { ...link, mobile: false }

  it('closes it on every section page and on /search', () => {
    for (const toPath of ['/', '/issues', '/events', '/archive', '/users', '/people', '/agents', '/boxes', '/help', '/docs', '/tenant-settings', '/search']) {
      assert.equal(routeLeavesTopic({ ...desk, toPath, toQuery: {} }), true, toPath)
    }
    assert.equal(routeLeavesTopic({ ...desk, toPath: '/search', toQuery: { q: 'x' } }), true)
  })

  it('keeps it on channel to channel, channel to DM and a drill-down', () => {
    assert.equal(routeLeavesTopic({ ...desk, toPath: '/channel/feedback' }), false)
    assert.equal(routeLeavesTopic({ ...desk, toPath: '/dm/peer' }), false)
    assert.equal(routeLeavesTopic({ ...desk, toPath: '/help/interface-overview' }), false)
  })

  it('keeps it on Back / Forward, a ?topic= write and with no pane', () => {
    assert.equal(routeLeavesTopic({ ...desk, toPath: '/people', popstate: true }), false)
    assert.equal(routeLeavesTopic({ ...desk, toPath: '/search', toQuery: { q: 'x', topic: 't' } }), false)
    assert.equal(routeLeavesTopic({ ...desk, toPath: '/people', open: false }), false)
    assert.equal(routeLeavesTopic({ ...desk, fromPath: '/search', toPath: '/search', toQuery: { q: 'y' } }), false)
  })
})
