// Spec 160 3.5 (SPL-3888, row B5): the File streams tab's pure helpers
// (src/utils/monitoring-file-streams.mjs).
// Run: node --test tests/unit/monitoring-file-streams.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  FS_MOCK_IDS, FS_PAGE, FS_POLL_MS, FS_VIEW_MAX, atBottom, fileStreamBoxes, fileStreamGroupsOf, fileStreamLinesOf, fileStreamOpenOf, fileStreamQuery,
  fileStreamsOf, filterFileStreamLines, lastSeqOf, mergeFileStreamLines, mockFileStreamLines, mockFileStreams, startFileStreamPoll,
} from '../../src/utils/monitoring-file-streams.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (p) => readFileSync(join(WUI, p), 'utf8')
const line = (seq, text = `l${seq}`) => ({ seq, at: '2026-10-28T00:00:00Z', text, marker: false })

describe('file streams helpers (spec 160 3.5)', () => {
  const body = {
    streams: [
      { id: 's3', box_id: 'box-b', stream_key: 'web', path: '/var/log/web.log', state: 'missing', reason: 'not_found', last_seq: 0 },
      { id: 's2', box_id: 'box-a', stream_key: 'cron', path: '/var/log/cron.log', state: 'following', last_seq: 4, lines_total: 4 },
      { id: 's1', box_id: 'box-a', stream_key: 'app', path: '/var/log/app.log', state: 'following', last_seq: 9, last_line_at: '2026-10-28T00:00:09Z', lines_total: 9 },
      { id: '', box_id: 'box-a', stream_key: 'x' }, { id: 's9', box_id: '../x', stream_key: 'app' }, { id: 's8', box_id: 'box-a', stream_key: 'App/..' },
    ],
  }
  it('the streams: junk rows dropped, sorted by box then key; the boxes in order', () => {
    const s = fileStreamsOf(body)
    assert.deepEqual(s.map((x) => `${x.boxId}/${x.streamKey}`), ['box-a/app', 'box-a/cron', 'box-b/web'])
    assert.equal(s[2].reason, 'not_found')
    assert.deepEqual(fileStreamBoxes(s), ['box-a', 'box-b'])
    assert.deepEqual(fileStreamsOf(null), [])
  })
  it('the list: one group per box in order, its streams by key; lines_total and last_line_at kept (C39)', () => {
    const s = fileStreamsOf(body)
    assert.deepEqual(fileStreamGroupsOf(s).map((g) => [g.boxId, g.streams.map((x) => x.streamKey)]), [['box-a', ['app', 'cron']], ['box-b', ['web']]])
    assert.deepEqual([s[0].linesTotal, s[0].lastLineAt], [9, '2026-10-28T00:00:09Z'])
    assert.deepEqual([s[2].linesTotal, s[2].lastLineAt], [0, ''])
    assert.deepEqual(fileStreamGroupsOf([]), [])
  })
  it('the open file from the URL: only a box and a stream the hub returned, else none (no fallback); seq only on it (C21, C40)', () => {
    const s = fileStreamsOf(body)
    const none = { box: '', stream: '', id: '', seq: 0 }
    assert.deepEqual(fileStreamOpenOf({ box: 'box-a', stream: 'cron' }, s), { box: 'box-a', stream: 'cron', id: 's2', seq: 0 })
    assert.deepEqual(fileStreamOpenOf({}, s), none, 'nothing open before a tail -f click')
    assert.deepEqual(fileStreamOpenOf({ box: 'box-a' }, s), none)
    assert.deepEqual(fileStreamOpenOf({ box: 'nope', stream: 'web' }, s), none)
    assert.deepEqual(fileStreamOpenOf({ box: 'box-a', stream: 'web' }, s), none, 'a stream of another box')
    assert.deepEqual(fileStreamOpenOf({ box: 'box-a', stream: '/etc/passwd' }, s), none, 'never a typed path')
    assert.deepEqual(fileStreamOpenOf({ box: ['box-b'], stream: ['web'] }, s), { box: 'box-b', stream: 'web', id: 's3', seq: 0 })
    assert.deepEqual(fileStreamOpenOf({ box: 'box-a', stream: 'app', seq: '7' }, s), { box: 'box-a', stream: 'app', id: 's1', seq: 7 })
    for (const seq of ['0', '-1', 'x', '1.5']) assert.equal(fileStreamOpenOf({ box: 'box-a', stream: 'app', seq }, s).seq, 0, seq)
    assert.deepEqual(fileStreamOpenOf({}, []), none)
    assert.deepEqual(fileStreamQuery('box-a', 'app'), { box: 'box-a', stream: 'app' })
    assert.deepEqual(fileStreamQuery('box-a', 'app', 7), { box: 'box-a', stream: 'app', seq: '7' })
    assert.deepEqual(fileStreamQuery('', ''), {})
  })
  it('the lines: oldest first, junk dropped; merge keeps one row per seq and at most FS_VIEW_MAX, the oldest dropped', () => {
    assert.deepEqual(fileStreamLinesOf({ lines: [line(3), line(1), { seq: 0 }, { seq: 'x' }] }).map((l) => l.seq), [1, 3])
    assert.deepEqual(mergeFileStreamLines([line(1), line(2)], [line(2, 'again'), line(3)]).map((l) => `${l.seq}:${l.text}`), ['1:l1', '2:again', '3:l3'])
    const many = Array.from({ length: FS_VIEW_MAX + 5 }, (_, i) => line(i + 1))
    const kept = mergeFileStreamLines([], many)
    assert.equal(kept.length, FS_VIEW_MAX)
    assert.equal(kept[0].seq, 6)
    assert.equal(lastSeqOf(kept), FS_VIEW_MAX + 5)
    assert.equal(lastSeqOf([]), 0)
  })
  it('find in view is case-insensitive over the loaded lines; empty finds all', () => {
    const ls = [line(1, 'INFO ok'), line(2, 'WARN disk'), line(3, 'info again')]
    assert.deepEqual(filterFileStreamLines(ls, 'info').map((l) => l.seq), [1, 3])
    assert.equal(filterFileStreamLines(ls, '  ').length, 3)
  })
  it('atBottom: within the slack is the bottom (Follow stays on); scrolled up is not (C20)', () => {
    assert.equal(atBottom({ scrollTop: 492, clientHeight: 100, scrollHeight: 600 }), true)
    assert.equal(atBottom({ scrollTop: 300, clientHeight: 100, scrollHeight: 600 }), false)
    assert.equal(atBottom(null), true)
  })
  it('the poll loads every FS_POLL_MS while visible; paused or hidden it sends nothing (C19); stop clears it', () => {
    let fire = () => {}
    let every = 0
    let cleared = false
    let loads = 0
    let paused = false
    let vis = 'visible'
    const p = startFileStreamPoll({ load: () => loads++, visibility: () => vis, paused: () => paused,
      setTimer: (fn, ms) => { fire = fn; every = ms; return 1 }, clearTimer: () => { cleared = true } })
    assert.equal(every, FS_POLL_MS)
    fire(); fire()
    assert.equal(loads, 2)
    paused = true
    for (let i = 0; i < 4; i++) fire()
    assert.equal(loads, 2, 'paused: 0 requests')
    paused = false; vis = 'hidden'
    fire()
    assert.equal(loads, 2, 'hidden: 0 requests')
    p.stop()
    assert.equal(cleared, true)
  })
  it('the mock: three streams; app grows one line per poll; after, before and the newest page', () => {
    const t0 = Date.parse('2026-10-28T00:00:00Z')
    const s = fileStreamsOf(mockFileStreams(t0))
    assert.deepEqual(s.map((x) => x.streamKey), ['app', 'cron', 'web'])
    const last0 = s[0].lastSeq
    assert.equal(fileStreamsOf(mockFileStreams(t0 + 2 * FS_POLL_MS))[0].lastSeq, last0 + 2)
    const newest = fileStreamLinesOf(mockFileStreamLines(FS_MOCK_IDS.app, { limit: 10 }, t0))
    assert.deepEqual([newest[0].seq, lastSeqOf(newest)], [last0 - 9, last0])
    assert.deepEqual(fileStreamLinesOf(mockFileStreamLines(FS_MOCK_IDS.app, { after: last0 }, t0 + FS_POLL_MS)).map((l) => l.seq), [last0 + 1])
    assert.deepEqual(fileStreamLinesOf(mockFileStreamLines(FS_MOCK_IDS.app, { before: 5, limit: 3 }, t0)).map((l) => l.seq), [2, 3, 4])
    assert.ok(fileStreamLinesOf(mockFileStreamLines(FS_MOCK_IDS.app, { limit: FS_PAGE }, t0)).some((l) => l.marker))
    assert.ok(fileStreamLinesOf(mockFileStreamLines(FS_MOCK_IDS.cron, { limit: 5 }, t0)).every((l) => l.text.includes('cron') && !l.text.includes('app')), 'a mock line names its stream (C40)')
    assert.ok(s[0].linesTotal > 0, 'the mock carries lines_total')
    assert.throws(() => mockFileStreamLines('nope'), (e) => e.status === 404)
  })
  it('the page: its own chunk, a list with a tail -f per row (no box/file selects), the controls the e2e drives, no inline style (CSP)', () => {
    const page = read('src/pages/monitoring/file-streams/index.vue')
    assert.doesNotMatch(page, /<select/, 'a list, not two selects (C39)')
    for (const id of ['fs-page', 'fs-group', 'fs-row', 'fs-tail', 'fs-follow', 'fs-pause', 'fs-jump', 'fs-new', 'fs-view', 'fs-line', 'fs-forbidden', 'fs-none', 'fs-find']) {
      assert.match(page, new RegExp(`data-test="${id}"`), id)
    }
    assert.doesNotMatch(page, /:style=|style="/)
    assert.doesNotMatch(read('src/utils/spool-client.mjs'), /monitoring-file-streams/, 'the eager client never imports it')
    assert.match(read('src/utils/spool-client-lazy.mjs'), /await import\('\.\/monitoring-file-streams\.mjs'\)/)
  })
})
