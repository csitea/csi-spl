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

  it('leaves it open on desktop, with no pane, and on Back / Forward', () => {
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
    assert.match(src, /if \(routeLeavesTopic\(nav\)\) \{ livePane\.close\(\); topic\.close\(\) \}/)
    assert.match(src, /router\.options\.history\.listen\(/)
  })
})
