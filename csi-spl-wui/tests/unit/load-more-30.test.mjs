// A feed shows 30 rows first, then a Load more button reads the next 30 from
// the hub. It covers the Msgs list (channel / DM / lobby / topic page) and the
// right-hand topic pane, which read every reply in one 200-row call before.
// Run: node --test tests/unit/load-more-30.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readdirSync, readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { channelView } from '../../src/utils/channel-feed.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (p) => readFileSync(join(WUI, p), 'utf8')

function msg(n) {
  const hh = String(n).padStart(2, '0')
  return { msg_id: `m${hh}`, task_id: `t${hh}`, ts: `2026-09-19T10:${hh}:00Z`, from: 'HUM-2', kind: 'note', body: `root ${n}`, channel: 'lobby', parent_task_id: null }
}

describe('the page is 30 rows', () => {
  it('both feed stores page by 30', () => {
    assert.match(read('src/stores/channel.ts'), /export const WINDOW = 30\n/)
    assert.match(read('src/stores/live.ts'), /export const WINDOW = 30\n/)
  })

  it('the channel store asks the hub for 30 on the first read and on every Load more', () => {
    const st = read('src/stores/channel.ts')
    const refresh = st.slice(st.indexOf('async function refresh'), st.indexOf('async function catchUp'))
    assert.match(refresh, /limit: WINDOW,/)
    const older = st.slice(st.indexOf('async function loadOlder'), st.indexOf('function setSearch'))
    assert.match(older, /limit: WINDOW,/)
    assert.match(older, /loadingOlder\.value = true/)
  })

  it('30 held rows show first; one Load more reveals the next 30', () => {
    const rows = Array.from({ length: 70 }, (_, i) => msg(i))
    const first = channelView(rows, { visible: 30 })
    assert.equal(first.rows.length, 30)
    assert.equal(first.hasOlder, true)
    assert.equal(first.rows[0].msg_id, 'm69')
    const second = channelView(rows, { visible: 60 })
    assert.equal(second.rows.length, 60)
    assert.equal(second.hasOlder, true)
    const third = channelView(rows, { visible: 90 })
    assert.equal(third.rows.length, 70)
    assert.equal(third.hasOlder, false)
  })
})

describe('LiveFeed: a Load more button, not a scroll sentinel', () => {
  const feed = read('src/components/LiveFeed.vue')

  it('renders the button only while there is more, and it emits older', () => {
    assert.match(feed, /<div v-if="hasOlder" class="older-sentinel">/)
    assert.match(feed, /data-testid="load-more"/)
    assert.match(feed, /@click="\$emit\('older'\)"/)
    assert.match(feed, /:disabled="loadingOlder"/)
    assert.match(feed, /t\('feed\.load_more'\)/)
  })

  it('no longer loads by itself when the bottom scrolls into view', () => {
    assert.doesNotMatch(feed, /IntersectionObserver/)
  })

  it('every feed that pages hands the button its in-flight flag', () => {
    for (const [rel, store] of [
      ['src/components/MessageFeed.vue', 'channel'],
      ['src/components/LiveTopicPane.vue', 'pane'],
      ['src/components/TopicPane.vue', null],
      ['src/pages/lobby.vue', 'store'],
      ['src/pages/t/[task_id].vue', 'store'],
    ]) {
      const src = read(rel)
      assert.match(src, /@older="/, rel)
      assert.match(src, store ? new RegExp(`:loading-older="${store}\\.loadingOlder"`) : /:loading-older="loadingOlder"/, rel)
    }
    assert.match(read('src/stores/live.ts'), /applyEdited, loadingOlder,/)
  })

  it('the label exists in every locale', () => {
    for (const f of readdirSync(join(WUI, 'i18n/locales'))) {
      const label = JSON.parse(read(`i18n/locales/${f}`)).feed.load_more
      assert.equal(typeof label, 'string', f)
      assert.ok(label.trim().length > 0, f)
    }
  })
})

describe('TopicPane: the newest 30 replies, then older pages', () => {
  const pane = read('src/components/TopicPane.vue')

  it('first read is newest first, 30 rows, and keeps the cursor', () => {
    assert.match(pane, /api\.getTopic\(id, \{ order: 'desc', limit: WINDOW \}\)/)
    assert.match(pane, /olderCursor\.value = data\.next \|\| null/)
    assert.doesNotMatch(pane, /api\.getTopic\(id\)\)/)
  })

  it('Load more reads before=<next> and merges by msg_id', () => {
    const older = pane.slice(pane.indexOf('async function loadOlder'), pane.indexOf('async function loadOldestRow'))
    assert.match(older, /order: 'desc', limit: WINDOW, before: olderCursor\.value \|\| undefined/)
    assert.match(older, /mergeById\(liveRows\.value, data\.messages \|\| \[\]\)/)
    assert.match(pane, /:has-older="hasOlder"/)
  })

  it('the heading still names the first message when the newest page does not reach it', () => {
    assert.match(pane, /api\.getTopic\(id, \{ limit: 1 \}\)/)
    assert.match(pane, /topicTitleFromRows\(oldestRow\.value \? \[oldestRow\.value, \.\.\.rows\] : rows, topic\.rootMsg\)/)
  })
})

describe('loadAll keeps its reach', () => {
  it('the /t page and the live pane still page back ~1000 rows with 30-row pages', () => {
    const st = read('src/stores/live.ts')
    assert.match(st, /const MAX_ALL_ROWS = 1000\n/)
    assert.match(st, /const MAX_PAGES = 2 \* Math\.ceil\(MAX_ALL_ROWS \/ WINDOW\)/)
  })
})
