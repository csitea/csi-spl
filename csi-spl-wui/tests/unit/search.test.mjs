// 022 top-bar global search — pure helpers (src/utils/search.mjs).
// Run: node tests/unit/search.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import {
  SEARCH_OPERATORS,
  applyCompletion,
  completeOperators,
  flattenGroups,
  highlightSegments,
  mockSearch,
  moveIndex,
  normalizeSearchResponse,
  omniboxMode,
  operatorTokenAt,
  searchApiQuery,
  searchPath,
  searchQueryOf,
  searchTarget,
} from '../../src/utils/search.mjs'

describe('omnibox mode switch', () => {
  it('/search and /s switch to search, with or without a query', () => {
    for (const s of ['/search', '/search ', '/search from:EZB-1 is:task', '/s foo', '/SEARCH x', '/search\nx']) {
      assert.equal(omniboxMode(s), 'search', s)
    }
  })
  it('CONTROL: everything else sends', () => {
    for (const s of ['', 'hello', ' /search x', '/searching', '/sx', 'use /search later', '@CLE-07 /search', '```\n/search\n```']) {
      assert.equal(omniboxMode(s), 'send', s)
    }
  })
  it('the query is the rest of the line, verbatim (grammar stays the hub\'s)', () => {
    assert.equal(searchQueryOf('/search from:EZB-1 is:task'), 'from:EZB-1 is:task')
    assert.equal(searchQueryOf('/s   "exact  phrase" -foo OR (a b)  '), '"exact  phrase" -foo OR (a b)')
    assert.equal(searchQueryOf('/search'), '')
    assert.equal(searchQueryOf('hello'), '')
  })
})

describe('query building', () => {
  it('deep link encodes q, empty → help view', () => {
    assert.equal(searchPath('from:EZB-1 is:task'), '/search?q=from%3AEZB-1%20is%3Atask')
    assert.equal(searchPath('  '), '/search')
    assert.equal(searchPath('a&b=c#d'), '/search?q=a%26b%3Dc%23d')
  })
  it('API query carries q raw plus cursor/limit only when set', () => {
    const p = new URLSearchParams(searchApiQuery({ q: 'in:#lobby "x y" -z', cursor: 'c1', limit: 25 }))
    assert.equal(p.get('q'), 'in:#lobby "x y" -z')
    assert.equal(p.get('cursor'), 'c1')
    assert.equal(p.get('limit'), '25')
    const bare = new URLSearchParams(searchApiQuery({ q: 'x' }))
    assert.deepEqual([...bare.keys()], ['q'])
  })
  it('CONTROL: an injection-shaped query is just an encoded string', () => {
    const q = "'; DROP TABLE messages; --"
    assert.equal(new URLSearchParams(searchApiQuery({ q })).get('q'), q)
  })
})

describe('operator autocomplete', () => {
  it('token at caret, only past the /search command', () => {
    assert.deepEqual(operatorTokenAt('/search fr', 10), { token: 'fr', start: 8, end: 10 })
    assert.equal(operatorTokenAt('/search', 7), null)
    assert.equal(operatorTokenAt('hello fr', 8), null)
  })
  it('negation and paren are not part of the token', () => {
    assert.deepEqual(operatorTokenAt('/search -is:', 12), { token: 'is:', start: 9, end: 12 })
    assert.deepEqual(operatorTokenAt('/search (fro', 12), { token: 'fro', start: 9, end: 12 })
  })
  it('the token extends to the right of the caret', () => {
    assert.deepEqual(operatorTokenAt('/search from:x y', 10), { token: 'from:x', start: 8, end: 14 })
  })
  it('CONTROL: nothing to complete inside a quoted phrase', () => {
    assert.equal(operatorTokenAt('/search "fr', 11), null)
    assert.equal(operatorTokenAt('/search "a fr', 13), null)
  })
  it('operator-name prefix lists operators', () => {
    const got = completeOperators('f').map((c) => c.insert)
    assert.deepEqual(got, ['from:', 'filename:'])
    assert.ok(completeOperators('Is').some((c) => c.insert === 'is:'))
  })
  it('closed values after the colon', () => {
    assert.deepEqual(completeOperators('is:').map((c) => c.insert), ['is:task ', 'is:note ', 'is:result ', 'is:reject '])
    assert.deepEqual(completeOperators('type:r').map((c) => c.insert), ['type:robot '])
    assert.deepEqual(completeOperators('has:c').map((c) => c.insert), ['has:code '])
  })
  it('CONTROL: open operators and a complete value offer nothing; unknown prefix nothing', () => {
    assert.deepEqual(completeOperators('from:'), [])
    assert.deepEqual(completeOperators('is:task'), [])
    assert.deepEqual(completeOperators('zz'), [])
    assert.deepEqual(completeOperators(''), [])
  })
  it('the catalogue carries every operator the brief names', () => {
    const ops = SEARCH_OPERATORS.map((o) => o.op)
    for (const op of ['from:', 'in:', 'is:', 'has:', 'before:', 'after:', 'type:', 'title:', 'filename:', 'larger:', 'smaller:', 'online:', 'box:']) {
      assert.ok(ops.includes(op), op)
    }
  })
  it('applying a completion replaces the token and puts the caret after it', () => {
    const tok = operatorTokenAt('/search a fr b', 12)
    assert.deepEqual(applyCompletion('/search a fr b', tok, 'from:'), { text: '/search a from: b', cursor: 15 })
  })
})

describe('highlight segments (offsets, never HTML)', () => {
  it('splits text around [start,end] pairs', () => {
    assert.deepEqual(highlightSegments('deploy the task now', [[11, 15]]), [
      { text: 'deploy the ', mark: false },
      { text: 'task', mark: true },
      { text: ' now', mark: false },
    ])
  })
  it('accepts {start,end} and {offset,length}', () => {
    assert.deepEqual(highlightSegments('abcdef', [{ start: 0, end: 2 }, { offset: 4, length: 2 }]).map((s) => s.mark), [true, false, true])
  })
  it('CONTROL: overlapping, out-of-range, reversed and junk offsets', () => {
    assert.deepEqual(highlightSegments('abcdef', [[1, 4], [3, 5]]), [
      { text: 'a', mark: false }, { text: 'bcde', mark: true }, { text: 'f', mark: false },
    ])
    assert.deepEqual(highlightSegments('abc', [[-5, 99]]), [{ text: 'abc', mark: true }])
    assert.deepEqual(highlightSegments('abc', [[2, 1], [1, 1], ['x', 2], null]), [{ text: 'abc', mark: false }])
    assert.deepEqual(highlightSegments('', [[0, 3]]), [{ text: '', mark: false }])
  })
  it('CONTROL: markup in a snippet stays text', () => {
    const t = '<script>alert(1)</script><img src=x onerror=alert(1)>'
    const segs = highlightSegments(t, [[0, 8]])
    assert.equal(segs.map((s) => s.text).join(''), t)
    assert.equal(segs[0].text, '<script>')
  })
})

describe('response normalisation', () => {
  it('groups in render order, empty groups dropped', () => {
    const r = normalizeSearchResponse({
      query: 'x',
      groups: {
        messages: [{ msg_id: 'm1', task_id: 't1', snippet: { text: 'x', highlights: [[0, 1]] } }],
        robots: [{ id: 'CLE-07', box: 'box-a', online: true }],
        users: [],
      },
      next_cursor: 'n1',
      warnings: ['foo: unknown', { token: 'bar:', message: 'unknown operator' }],
    })
    assert.deepEqual(r.groups.map((g) => g.type), ['robots', 'messages'])
    assert.equal(r.groups[0].items[0].key, 'robots:CLE-07@box-a')
    assert.equal(r.next, 'n1')
    assert.deepEqual(r.warnings, [{ token: '', message: 'foo: unknown' }, { token: 'bar:', message: 'unknown operator' }])
  })
  it('a flat results[] is the messages section; string snippet and body fallback', () => {
    const r = normalizeSearchResponse({ results: [{ msg_id: 'a', snippet: 'hi', highlights: [[0, 2]] }, { msg_id: 'b', body: 'yo' }] })
    assert.deepEqual(r.groups.map((g) => g.type), ['messages'])
    assert.deepEqual(r.groups[0].items[0].snippet, { text: 'hi', highlights: [[0, 2]] })
    assert.equal(r.groups[0].items[1].snippet.text, 'yo')
  })
  it('CONTROL: junk input is an empty result, not a throw', () => {
    for (const d of [null, undefined, 'x', 42, { groups: 'x' }, { results: 'x' }]) {
      const r = normalizeSearchResponse(d)
      assert.deepEqual(r.groups, [])
      assert.equal(r.next, null)
    }
  })
})

describe('keyboard', () => {
  it('ArrowDown/Up wrap; Home/End jump; others keep', () => {
    assert.equal(moveIndex(-1, 3, 'ArrowDown'), 0)
    assert.equal(moveIndex(2, 3, 'ArrowDown'), 0)
    assert.equal(moveIndex(0, 3, 'ArrowUp'), 2)
    assert.equal(moveIndex(-1, 3, 'ArrowUp'), 2)
    assert.equal(moveIndex(1, 3, 'Home'), 0)
    assert.equal(moveIndex(1, 3, 'End'), 2)
    assert.equal(moveIndex(1, 3, 'x'), 1)
    assert.equal(moveIndex(0, 0, 'ArrowDown'), -1)
  })
  it('flattened rows walk across sections', () => {
    const r = normalizeSearchResponse({ groups: { robots: [{ id: 'A' }], messages: [{ msg_id: '1' }, { msg_id: '2' }] } })
    assert.deepEqual(flattenGroups(r.groups).map((x) => x.key), ['robots:A', 'messages:1', 'messages:2'])
  })
})

describe('click targets', () => {
  it('per type', () => {
    assert.deepEqual(searchTarget({ type: 'messages', task_id: 't', msg_id: 'm' }), { thread: 't', focus: 'm' })
    assert.deepEqual(searchTarget({ type: 'messages', task_id: 'r', parent_task_id: 'p', msg_id: 'm' }), { thread: 'p', focus: 'm' })
    assert.deepEqual(searchTarget({ type: 'threads', task_id: 't' }), { thread: 't', focus: '' })
    assert.deepEqual(searchTarget({ type: 'files', task_id: 't', msg_id: 'm' }), { thread: 't', focus: 'm' })
    assert.deepEqual(searchTarget({ type: 'robots', id: 'CLE-07', box: 'box-a' }), { path: '/dm/CLE-07%40box-a' })
    assert.deepEqual(searchTarget({ type: 'users', id: 'HUM-1' }), { path: '/dm/HUM-1' })
    assert.deepEqual(searchTarget({ type: 'channels', channel_id: '#lobby' }), { path: '/channel/lobby' })
  })
  it('CONTROL: a row without an id goes nowhere', () => {
    for (const r of [null, {}, { type: 'messages' }, { type: 'robots' }, { type: 'channels' }, { type: 'nope', id: 'x' }]) {
      assert.equal(searchTarget(r), null)
    }
  })
})

describe('mock matcher (lde only)', () => {
  const msgs = [
    { msg_id: '1', task_id: 't1', ts: '2026-09-19T10:00:00Z', from: 'EZB-1', from_box: 'box-a', to: 'CLE-07', kind: 'task', channel: 'lobby', body: 'Deploy the hub' },
    { msg_id: '2', task_id: 't2', ts: '2026-09-19T11:00:00Z', from: 'CLE-07', from_box: 'box-a', to: 'EZB-1', kind: 'result', channel: null, body: 'deploy done, deploy ok' },
  ]
  it('free words + from:/is:/in:, newest first, offsets on every hit', () => {
    assert.deepEqual(mockSearch(msgs, 'deploy').groups.messages.map((m) => m.msg_id), ['2', '1'])
    assert.deepEqual(mockSearch(msgs, 'from:EZB-1 is:task').groups.messages.map((m) => m.msg_id), ['1'])
    assert.deepEqual(mockSearch(msgs, 'in:dm').groups.messages.map((m) => m.msg_id), ['2'])
    assert.deepEqual(mockSearch(msgs, 'in:#lobby').groups.messages.map((m) => m.msg_id), ['1'])
    assert.deepEqual(mockSearch(msgs, 'deploy').groups.messages[0].snippet.highlights, [[0, 6], [13, 19]])
  })
  it('CONTROL: no match → empty; an operator the mock does not model warns', () => {
    assert.deepEqual(mockSearch(msgs, 'nothing-like-this').groups.messages, [])
    assert.equal(mockSearch(msgs, 'larger:1M deploy').warnings.length, 1)
  })
})

describe('spool-client search()', async () => {
  const { createSpoolClient } = await import('../../src/utils/spool-client.mjs')
  it('live: GET /v1/view/search with q raw, Bearer token, normalised groups', async () => {
    const calls = []
    const fetchFn = async (url, opts) => {
      calls.push({ url, opts })
      return new Response(JSON.stringify({ groups: { messages: [{ msg_id: 'm1', task_id: 't1', snippet: { text: 'hi', highlights: [[0, 2]] } }] }, next_cursor: 'n' }), { status: 200, headers: { 'content-type': 'application/json' } })
    }
    const c = createSpoolClient({ mock: false, base: 'https://t1.example.com/', fetchFn, token: 'tok' })
    const r = await c.search({ q: 'from:EZB-1 is:task', cursor: 'c' })
    const u = new URL(calls[0].url)
    assert.equal(u.origin + u.pathname, 'https://t1.example.com/v1/view/search')
    assert.equal(u.searchParams.get('q'), 'from:EZB-1 is:task')
    assert.equal(u.searchParams.get('cursor'), 'c')
    assert.equal(calls[0].opts.headers.authorization, 'Bearer tok')
    assert.equal(r.groups[0].items[0].key, 'messages:m1')
    assert.equal(r.next, 'n')
  })
  it('live: 400 bad_query surfaces status + the hub detail', async () => {
    const fetchFn = async () => new Response(JSON.stringify({ error: 'bad_query', detail: 'unbalanced ( at 5' }), { status: 400, headers: { 'content-type': 'application/json' } })
    const c = createSpoolClient({ mock: false, base: 'https://h', fetchFn })
    await assert.rejects(c.search({ q: 'a (b' }), (e) => e.status === 400 && e.token === 'bad_query' && /unbalanced/.test(e.detail))
  })
  it('mock: searches the local corpus, no fetch', async () => {
    const c = createSpoolClient({ mock: true, fetchFn: () => { throw new Error('no fetch in mock') } })
    const r = await c.search({ q: '' })
    assert.ok(Array.isArray(r.groups))
  })
})
