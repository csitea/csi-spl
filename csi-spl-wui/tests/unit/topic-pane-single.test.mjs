// CLE-3429 — the shell renders exactly ONE topic section (1..1).
//
// The bug this guards: layouts/default.vue mounted BOTH <TopicPane /> and
// <LiveTopicPane />, unconditionally and side by side, each with its own
// v-if over its own pinia store. Neither store is reset on a route change,
// so arming one while the other was still armed put two `aside.topic`
// sections on screen and kept them there for every later route. Measured on
// the mock stack (nuxi dev, NUXT_PUBLIC_USE_MOCK=1) before the fix:
//   /channel/lobby -> open a topic            -> 1 aside
//   SPA-nav to /lobby -> open a topic there   -> 2 asides   <-- the bug
//   SPA-nav to /                               -> 2 asides
//
// CONTROL: put a second, directive-less `<TopicPane />` back next to the
// chain in layouts/default.vue and "one exclusive v-if/v-else chain" below
// goes red — that is the assertion, not a comment about one.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { runsInUnitSuite } from './lib/in-suite.mjs'
import { CHANNEL, LIVE, NONE, closes, sectionCount, topicSection } from '../../src/utils/topic-pane.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (rel) => readFileSync(join(WUI, rel), 'utf8')
const PANES = [
  ['LiveTopicPane', 'src/components/LiveTopicPane.vue'],
  ['TopicPane', 'src/components/TopicPane.vue'],
]

/** The template half of an SFC — mounts in <script> (imports) must not count. */
function template(src) {
  const m = src.match(/<template>([\s\S]*)<\/template>/)
  assert.ok(m, 'the SFC has a <template>')
  return m[1]
}

/** Every `<Name …>` mount in a template, with the attributes it carries. */
function mounts(tpl, name) {
  return [...tpl.matchAll(new RegExp(`<${name}\\b([^>]*)>`, 'g'))].map((m) => m[1])
}

/**
 * The shell as the layout drives it: opening a section closes the other,
 * through the very `closes()` the layout's watchers call.
 */
function open(state, which, id = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb') {
  const shut = closes(which, state)
  if (which === LIVE) state.paneTaskId = id
  if (which === CHANNEL) state.topicOpen = true
  if (shut === LIVE) state.paneTaskId = null
  if (shut === CHANNEL) state.topicOpen = false
  return state
}

describe('CLE-3429 — exactly one topic section (1..1)', () => {
  it('pnpm test runs this suite', () => {
    const s = runsInUnitSuite(import.meta.url)
    assert.ok(s.ok, s.why)
  })

  it('no shell state whatsoever renders two sections', () => {
    /* exhaustive over the state space the two stores can reach */
    for (const paneTaskId of [null, '', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa']) {
      for (const topicOpen of [false, true]) {
        const n = sectionCount({ paneTaskId, topicOpen })
        assert.ok(n === 0 || n === 1, `sectionCount(${paneTaskId}, ${topicOpen}) = ${n}`)
      }
    }
    assert.equal(sectionCount({}), 0)
    assert.equal(topicSection({}), NONE)
  })

  it('the reproduced route walk keeps the count at one, and shows what was opened LAST', () => {
    const state = { paneTaskId: null, topicOpen: false }
    /* 1. /channel/lobby, nothing open */
    assert.equal(sectionCount(state), 0)
    /* 2. open a topic from the channel feed (MessageFeed -> topic.openTopic) */
    open(state, CHANNEL)
    assert.equal(sectionCount(state), 1)
    assert.equal(topicSection(state), CHANNEL)
    /* 3. SPA-nav to /lobby — no store is reset, so the count must not move */
    assert.equal(sectionCount(state), 1)
    /* 4. open a topic there (the lobby row -> pane.open) — this was the 2 */
    open(state, LIVE)
    assert.equal(sectionCount(state), 1, 'two topic sections at once')
    assert.equal(topicSection(state), LIVE)
    /* 5. SPA-nav to / and back to /channel — still one */
    assert.equal(sectionCount(state), 1)
    /* 6. and back the other way: a channel topic now outranks the stale live pane */
    open(state, CHANNEL)
    assert.equal(sectionCount(state), 1)
    assert.equal(topicSection(state), CHANNEL)
    assert.equal(state.paneTaskId, null, 'the live pane was closed, not left armed')
  })

  it('closes() names the section that must give way, and nothing otherwise', () => {
    assert.equal(closes(LIVE, { topicOpen: true }), CHANNEL)
    assert.equal(closes(LIVE, { topicOpen: false }), '')
    assert.equal(closes(CHANNEL, { paneTaskId: 'x' }), LIVE)
    assert.equal(closes(CHANNEL, { paneTaskId: null }), '')
    assert.equal(closes('nonsense', { topicOpen: true, paneTaskId: 'x' }), '')
  })

  it('the layout mounts the panes as ONE exclusive v-if/v-else chain', () => {
    const tpl = template(read('src/layouts/default.vue'))
    const live = mounts(tpl, 'LiveTopicPane')
    const chan = mounts(tpl, 'TopicPane').filter((_, i, a) => a.length >= 0)
    /* `<TopicPane` also prefixes nothing else; LiveTopicPane is matched on its own \b */
    assert.equal(live.length, 1, `LiveTopicPane is mounted ${live.length} times`)
    assert.equal(chan.length, 1, `TopicPane is mounted ${chan.length} times`)

    const attrs = [...live, ...chan]
    const ifs = attrs.filter((a) => /\sv-if[=\s]/.test(a))
    const elses = attrs.filter((a) => /\sv-else(-if)?[=\s]/.test(a))
    assert.equal(ifs.length, 1, 'exactly one of the two panes opens the chain with v-if')
    assert.equal(elses.length, 1, 'the other pane continues it with v-else / v-else-if — not a second v-if')
    assert.equal(
      attrs.filter((a) => !/\sv-(if|else|else-if)[=\s]/.test(a)).length,
      0,
      'neither pane is mounted unconditionally',
    )
    /* the chain must be contiguous: the v-else mount follows the v-if mount */
    assert.ok(
      tpl.indexOf('v-else-if="section === CHANNEL"') > tpl.indexOf('v-if="section === LIVE"'),
      'the v-else-if branch follows the v-if branch',
    )
  })

  it('the layout decides with utils/topic-pane, and closes the losing store', () => {
    const src = read('src/layouts/default.vue')
    assert.match(src, /from '~\/utils\/topic-pane\.mjs'/)
    assert.match(src, /topicSection\(\{\s*paneTaskId: livePane\.taskId,\s*topicOpen: topic\.open\s*\}\)/)
    /* both directions, or a stale section outranks the one just opened; and
       both sync, so the losing store is cleared before the render it would spoil */
    assert.match(
      src,
      /watch\(\(\) => livePane\.taskId[\s\S]{0,260}topic\.close\(\)[\s\S]{0,60}flush: 'sync'/,
      "opening the live pane closes the channel topic, flush: 'sync'",
    )
    assert.match(
      src,
      /watch\(\(\) => topic\.open[\s\S]{0,260}livePane\.close\(\)[\s\S]{0,60}flush: 'sync'/,
      "opening a channel topic closes the live pane, flush: 'sync'",
    )
  })

  it('both panes carry the same data-test hook, so a DOM count cannot miss one', () => {
    for (const [name, rel] of PANES) {
      const tpl = template(read(rel))
      assert.match(tpl, /<aside\b[^>]*\bdata-test="topic-section"/, `${name} aside`)
      assert.equal((tpl.match(/data-test="topic-section"/g) || []).length, 1, `${name}: one hook`)
    }
    const live = template(read('src/components/LiveTopicPane.vue'))
    const chan = template(read('src/components/TopicPane.vue'))
    assert.match(live, /data-section="live"/)
    assert.match(chan, /data-section="channel"/)
  })
})
