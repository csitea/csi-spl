// Spec 160 3.5 (SPL-3888, row B5): the File streams tab's pure helpers
// (src/utils/monitoring-file-streams.mjs); the file globs of 3.8 (SPL-4695,
// row B12): their parse, the add body, the refusal sentences, the mock's
// checks, and every text key in every locale (C56).
// Run: node --test tests/unit/monitoring-file-streams.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync, readdirSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  FS_GLOB_ACTIONS, FS_GLOB_ERRORS, FS_GLOB_STATES, FS_MOCK_GLOB_IDS, FS_MOCK_IDS, FS_PAGE, FS_POLL_MS, FS_VIEW_MAX, atBottom,
  fileStreamBoxes, fileStreamGlobAuditOf, fileStreamGlobAuditQuery, fileStreamGlobBody, fileStreamGlobCounted, fileStreamGlobErrorKey,
  fileStreamGlobStateKey, fileStreamGlobsOf, fileStreamGroupsOf, fileStreamLinesOf, fileStreamOpenOf, fileStreamQuery, fileStreamRowErrorKey,
  fileStreamsOf, fileStreamsRemovedOf, filterFileStreamLines, lastSeqOf, mergeFileStreamLines, mockAddFileStreamGlob, mockFileStreamGlobAudit, mockFileStreamGlobs,
  mockFileStreamGlobsReset, mockFileStreamLines, mockFileStreams, mockGlobSyntax, mockRemoveFileStream, mockRemoveFileStreamGlob, mockRestoreFileStream, startFileStreamPoll,
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

describe('a file out of the view (spec 160 3.10, SPL-4979)', () => {
  it('the removed list: parsed apart from streams, an older hub sends none; a box with only removed files is a group', () => {
    const row = { id: 'x', box_id: 'box-a', stream_key: 'app', path: '/a', state: 'gone', removed_at: 'now' }
    assert.deepEqual(fileStreamsRemovedOf({ streams: [] }), [])
    assert.deepEqual(fileStreamsOf({ removed: [row] }), [])
    const removed = fileStreamsRemovedOf({ removed: [row] })
    assert.equal(removed[0].streamKey, 'app')
    const g = fileStreamGroupsOf([], { globs: [], folders: [] }, removed)
    assert.deepEqual(g.map((x) => [x.boxId, x.streams.length, x.removed.length]), [['box-a', 0, 1]])
  })
  it('a refusal has its own sentence, box_locked by token, the rest by status', () => {
    assert.equal(fileStreamRowErrorKey({ status: 403, token: 'box_locked' }), 'monitoring.file_streams.file.err.box_locked')
    assert.equal(fileStreamRowErrorKey({ status: 403 }), 'monitoring.file_streams.file.err.forbidden')
    assert.equal(fileStreamRowErrorKey({ status: 404 }), 'monitoring.file_streams.file.err.not_found')
    assert.equal(fileStreamRowErrorKey({ status: 500 }), 'monitoring.file_streams.glob.err.other')
  })
  it('the mock: remove, a second remove 404, a locked put back 403 with a refused audit row, put back; each audited once', () => {
    mockFileStreamGlobsReset()
    const id = FS_MOCK_IDS.cron
    const before = mockFileStreamGlobAudit().audit.length
    assert.equal(fileStreamsOf(mockFileStreams()).length, 3)
    assert.throws(() => mockRestoreFileStream(id), (e) => e.status === 404)
    assert.equal(mockRemoveFileStream(id), null)
    assert.throws(() => mockRemoveFileStream(id), (e) => e.status === 404)
    const b = mockFileStreams()
    assert.deepEqual(fileStreamsOf(b).map((s) => s.streamKey), ['app', 'web'])
    assert.deepEqual(fileStreamsRemovedOf(b).map((s) => [s.streamKey, s.state]), [['cron', 'gone']])
    globalThis.SPOOL_MOCK_FS_LOCKED_BOXES = ['box-a']
    assert.throws(() => mockRestoreFileStream(id), (e) => e.status === 403 && e.token === 'box_locked')
    globalThis.SPOOL_MOCK_FS_LOCKED_BOXES = []
    assert.equal(mockRestoreFileStream(id), null)
    assert.equal(fileStreamsOf(mockFileStreams()).length, 3)
    assert.equal(mockFileStreamGlobAudit().audit.length, before + 3)
    delete globalThis.SPOOL_MOCK_FS_LOCKED_BOXES
    mockFileStreamGlobsReset()
  })
})

describe('file globs typed in the page (spec 160 3.8, row B12)', () => {
  const body = {
    globs: [
      { id: 'g2', box_id: 'box-b', key: 'web', glob: '/var/log/web/*.log', state: 'pending', matched: 0 },
      { id: 'g1', box_id: 'box-a', key: 'sys', glob: '/var/log/*.log', state: 'partial', matched: 12, followed: 5, over_cap: 7, reported_at: '2026-11-03T00:00:00Z' },
      { id: 'g3', box_id: 'box-a', key: 'odd', glob: '/var/log/x*', state: 'following-ish' },
      { id: '', box_id: 'box-a', key: 'x' }, { id: 'g9', box_id: '../x', key: 'y' },
    ],
    folders: [{ box_id: 'box-a', path: '/var/log', state: 'allowed' }, { box_id: 'box-a', path: '/etc', state: 'refused', reason: 'short' }, { box_id: 'box-c', path: '/var/log', state: 'allowed' }],
  }
  it('the globs: junk dropped, by box then key; an unknown state reads pending, never following (3.8.1)', () => {
    const g = fileStreamGlobsOf(body)
    assert.deepEqual(g.globs.map((x) => `${x.boxId}/${x.key}`), ['box-a/odd', 'box-a/sys', 'box-b/web'])
    assert.equal(g.globs[0].state, 'pending')
    assert.deepEqual([g.globs[1].matched, g.globs[1].followed, g.globs[1].overCap], [12, 5, 7])
    assert.deepEqual(g.folders.map((f) => `${f.boxId}:${f.path}:${f.state}`), ['box-a:/etc:refused', 'box-a:/var/log:allowed', 'box-c:/var/log:allowed'])
    assert.deepEqual(fileStreamGlobsOf(null), { globs: [], folders: [] })
  })
  it('the groups: a box with only globs or folders is a group too, each with its own globs and folders', () => {
    const groups = fileStreamGroupsOf(fileStreamsOf({ streams: [{ id: 's1', box_id: 'box-a', stream_key: 'app' }] }), fileStreamGlobsOf(body))
    assert.deepEqual(groups.map((g) => [g.boxId, g.streams.length, g.globs.length, g.folders.length]), [['box-a', 1, 2, 2], ['box-b', 0, 1, 0], ['box-c', 0, 0, 1]])
  })
  it('a state key per state; "N of M" only once the box reported matches', () => {
    for (const st of FS_GLOB_STATES) assert.equal(fileStreamGlobStateKey(st), `monitoring.file_streams.glob.state.${st}`)
    assert.equal(fileStreamGlobStateKey('weird'), 'monitoring.file_streams.glob.state.pending')
    const [, sys, web] = fileStreamGlobsOf(body).globs
    assert.equal(fileStreamGlobCounted(sys), true)
    assert.equal(fileStreamGlobCounted(web), false, 'pending: no count')
    assert.equal(fileStreamGlobCounted({ state: 'none', matched: 0 }), false)
  })
  it('the add body is {box_id, key, glob} only, the key trimmed, the glob as typed (C55)', () => {
    assert.deepEqual(fileStreamGlobBody('box-a', ' sys ', ' /var/log/*.log'), { box_id: 'box-a', key: 'sys', glob: ' /var/log/*.log' })
    assert.deepEqual(Object.keys(fileStreamGlobBody()), ['box_id', 'key', 'glob'])
  })
  it('a refusal shows its code\'s sentence; a 403/404 without a code theirs; anything else the generic one (C55)', () => {
    for (const c of FS_GLOB_ERRORS) assert.equal(fileStreamGlobErrorKey({ status: 400, token: c }), `monitoring.file_streams.glob.err.${c}`)
    assert.equal(fileStreamGlobErrorKey({ status: 403, token: '' }), 'monitoring.file_streams.glob.err.forbidden')
    assert.equal(fileStreamGlobErrorKey({ status: 404 }), 'monitoring.file_streams.glob.err.not_found')
    assert.equal(fileStreamGlobErrorKey({ status: 500, token: 'internal' }), 'monitoring.file_streams.glob.err.other')
    assert.equal(fileStreamGlobErrorKey(null), 'monitoring.file_streams.glob.err.other')
  })
  it('the audit: newest first, unknown actions dropped; its query', () => {
    const a = fileStreamGlobAuditOf({ audit: [{ id: 'a1', action: 'add', at: '2026-11-01T00:00:00Z' }, { id: 'a2', action: 'refused', reason: 'bad_glob', at: '2026-11-02T00:00:00Z' }, { id: 'a3', action: 'nuke', at: 'x' }], next_before: 'b' })
    assert.deepEqual(a.rows.map((r) => r.id), ['a2', 'a1'])
    assert.equal(a.nextBefore, 'b')
    assert.equal(fileStreamGlobAuditQuery({ limit: 50 }), '?limit=50')
    assert.equal(fileStreamGlobAuditQuery({}), '')
  })
  it('the mock syntax is the hub\'s CheckFileStreamGlob: each bad glob of C43 refused, good ones pass', () => {
    for (const g of ['var/log/*.log', '/var/**/x', '/var/*/x.log', '/var/log/[ab].log', '/var/log/{a,b}', '/var/../x', '/var/log/a\u0001', '/' + 'a'.repeat(512), '']) {
      assert.notEqual(mockGlobSyntax(g), '', JSON.stringify(g))
    }
    for (const g of ['/var/log/*.log', '$HOME/logs/app-?.log', '/var/csi/csi-spl/token-burn/cron.log']) assert.equal(mockGlobSyntax(g), '', g)
  })
  it('the mock hub: add in its order (box 404, bad_glob, bad_key, outside_folders, taken, cap), audit per refusal but bad_key, remove twice 404', () => {
    mockFileStreamGlobsReset()
    const t0 = Date.parse('2026-11-03T00:00:00Z')
    const code = (fn) => { try { fn(); return 'ok' } catch (e) { return `${e.status} ${e.token}` } }
    const add = (o) => code(() => mockAddFileStreamGlob(JSON.stringify(o), t0))
    assert.equal(fileStreamGlobsOf(mockFileStreamGlobs(t0)).globs.length, 2)
    assert.equal(add({ box_id: 'box-a', key: 'k', glob: '/var/log/*.log', extra: 1 }), '400 bad_request', 'a field the hub does not know')
    assert.equal(add({ box_id: 'box-z', key: 'k', glob: '/var/log/*.log' }), '404 not_found')
    assert.equal(add({ box_id: 'box-a', key: 'k', glob: 'var/log' }), '400 bad_glob')
    assert.equal(add({ box_id: 'box-a', key: 'K!', glob: '/var/log/*.log' }), '400 bad_key')
    assert.equal(add({ box_id: 'box-a', key: 'k', glob: '/etc/ssh/*' }), '400 outside_folders', '/etc is announced refused')
    assert.equal(add({ box_id: 'box-a', key: 'syslog', glob: '/var/log/*.txt' }), '409 glob_key_taken')
    assert.equal(add({ box_id: 'box-a', key: 'app', glob: '/var/csi/csi-spl/*.log' }), 'ok')
    for (let i = 2; i < 8; i++) assert.equal(add({ box_id: 'box-a', key: `k${i}`, glob: '/var/log/*.log' }), 'ok')
    assert.equal(add({ box_id: 'box-a', key: 'k9', glob: '/var/log/*.log' }), '409 too_many_globs')
    const live = fileStreamGlobsOf(mockFileStreamGlobs(t0)).globs
    assert.equal(live.find((g) => g.key === 'app').state, 'pending', 'a new glob is pending until the box reports it')
    const audit = fileStreamGlobAuditOf(mockFileStreamGlobAudit({ limit: 500 }, t0)).rows
    assert.deepEqual(audit.filter((r) => r.action === 'refused').map((r) => r.reason).sort(), ['bad_glob', 'glob_key_taken', 'outside_folders', 'too_many_globs'])
    assert.equal(mockRemoveFileStreamGlob(FS_MOCK_GLOB_IDS.syslog, t0), null)
    assert.equal(code(() => mockRemoveFileStreamGlob(FS_MOCK_GLOB_IDS.syslog, t0)), '404 not_found')
    const after = fileStreamGlobAuditOf(mockFileStreamGlobAudit({ limit: 500 }, t0)).rows
    assert.equal(after.filter((r) => r.action === 'remove').length, 1, 'a second remove writes no audit row')
    mockFileStreamGlobsReset()
  })
  it('every glob text key is in en.json and every locale, translated (C56)', () => {
    const dir = join(WUI, 'i18n/locales')
    const keys = ['title', 'folders', 'no_folders', 'none', 'add', 'key', 'key_hint', 'glob', 'glob_hint', 'submit', 'adding', 'cancel', 'remove', 'keep',
      'remove_ask', 'matches', 'over_cap', 'reason', 'unavailable', 'audit_title', 'audit_none',
      ...FS_GLOB_STATES.map((x) => `state.${x}`), ...FS_GLOB_ACTIONS.map((x) => `audit.${x}`), ...[...FS_GLOB_ERRORS, 'other'].map((x) => `err.${x}`)]
    const at = (o, k) => k.split('.').reduce((n, p) => (n && typeof n === 'object' ? n[p] : undefined), o)
    const en = JSON.parse(readFileSync(join(dir, 'en.json'), 'utf8')).monitoring.file_streams.glob
    for (const f of readdirSync(dir).filter((x) => x.endsWith('.json'))) {
      const g = JSON.parse(readFileSync(join(dir, f), 'utf8')).monitoring?.file_streams?.glob
      for (const k of keys) {
        assert.equal(typeof at(g, k), 'string', `${f} monitoring.file_streams.glob.${k}`)
        if (f !== 'en.json' && /[a-z]{3}/i.test(at(en, k))) assert.notEqual(at(g, k), at(en, k), `${f} ${k} is English`)
      }
    }
    const page = read('src/pages/monitoring/file-streams/index.vue')
    for (const id of ['fs-globs', 'fs-glob', 'fs-glob-state', 'fs-glob-matches', 'fs-glob-remove', 'fs-glob-confirm', 'fs-glob-remove-yes', 'fs-glob-add', 'fs-glob-form', 'fs-glob-key', 'fs-glob-glob', 'fs-glob-submit', 'fs-glob-error', 'fs-audit']) {
      assert.match(page, new RegExp(`data-test="${id}"`), id)
    }
  })
})
