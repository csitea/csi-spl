// The lobby's feed paints before the rest of the shell (utils/feed-first.mjs, spec 109 T006).
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { FEED_FIRST_IDLE_MS, whenPainted } from '../../src/utils/feed-first.mjs'

/** A window whose frames, timers and idle slots run only when the test drains them. */
function fakeWin({ idle = true } = {}) {
  const q = []
  return {
    setTimeout: (fn, ms) => q.push({ fn, ms, kind: 'timer' }),
    requestAnimationFrame: (fn) => q.push({ fn, kind: 'frame' }),
    ...(idle ? { requestIdleCallback: (fn, o) => q.push({ fn, ms: o.timeout, kind: 'idle' }) } : {}),
    drain() { for (let i = 0; i < q.length; i++) if (!q[i].ran) { q[i].ran = true; q[i].fn() } },
    q,
  }
}

const read = (p) => readFileSync(new URL(`../../src/${p}`, import.meta.url), 'utf8')

describe('feed first: the shell follows the painted rows', () => {
  it('CONTROL: nothing runs in the task that rendered the rows', () => {
    const win = fakeWin()
    let n = 0
    whenPainted(() => n++, { win })
    assert.equal(n, 0)
    win.drain()
    assert.equal(n, 1)
  })

  it('after the next frame, then an idle slot with a timeout', () => {
    const win = fakeWin()
    whenPainted(() => {}, { win })
    win.drain()
    assert.deepEqual(win.q.map((t) => t.kind), ['frame', 'timer', 'idle'])
    assert.equal(win.q[2].ms, FEED_FIRST_IDLE_MS)
  })

  it('no requestIdleCallback (Safari): a timer stands in', () => {
    const win = fakeWin({ idle: false })
    let n = 0
    whenPainted(() => n++, { win })
    win.drain()
    assert.equal(n, 1)
    assert.deepEqual(win.q.map((t) => t.kind), ['frame', 'timer', 'timer'])
  })
})

describe('feed first: wired into the layout and the lobby', () => {
  const layout = read('layouts/default.vue')
  const lobby = read('pages/lobby.vue')

  it('the layout holds the top bar and ChannelSidebar on a desktop /lobby only, with a cap', () => {
    assert.match(layout, /<TopBar v-if="shellIn" \/>/)
    assert.match(layout, /<ChannelSidebar v-if="shellIn" \/>/)
    const hold = layout.slice(layout.indexOf("useState('shell-in'"))
    assert.match(hold.slice(0, 400), /isLobbyPath\(window\.location\.pathname\)/)
    assert.match(hold.slice(0, 400), /matchMedia\(MOBILE_STACK_QUERY\)/, 'a phone never holds: level 1 is the sidebar')
    assert.match(hold.slice(0, 600), /setTimeout\(\(\) => \{ shellIn\.value = true \}, SHELL_CAP_MS\)/)
  })

  it('CONTROL: every other place renders the shell at once (the state starts true off /lobby)', () => {
    assert.match(layout, /useState\('shell-in', \(\) => !\(import\.meta\.client && /)
  })

  it('the lobby lets it in after its first rows painted, and on leave', () => {
    assert.match(lobby, /whenPainted\(\(\) => \{ shellIn\.value = true \}\)/)
    assert.match(lobby, /onBeforeUnmount\(\(\) => \{ shellIn\.value = true \}\)/)
  })

  it('only the lobby imports the module, so it stays out of the shell chunk', () => {
    assert.doesNotMatch(layout, /from '~\/utils\/feed-first/)
  })
})
