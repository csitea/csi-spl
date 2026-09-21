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
  mergeSearchPage,
  mockSearch,
  moveIndex,
  normalizeOperators,
  normalizeSearchResponse,
  omniboxMode,
  operatorTokenAt,
  searchApiQuery,
  searchPath,
  searchQueryOf,
  searchTarget,
  shouldLoadOperators,
} from '../../src/utils/search.mjs'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (rel) => readFileSync(join(WUI, rel), 'utf8')

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
    assert.deepEqual(completeOperators('is:r').map((c) => c.insert), ['is:result ', 'is:reject ', 'is:root ', 'is:revoked '])
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
    for (const op of ['from:', 'to:', 'in:', 'is:', 'has:', 'before:', 'after:', 'on:', 'type:', 'title:', 'subject:', 'name:', 'filename:', 'ext:', 'larger:', 'smaller:', 'box:', 'thread:']) {
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

describe('response normalisation (search-v1 §4)', () => {
  const answer = {
    query: 'deploy foo:bar',
    sort: 'newest',
    types: ['message', 'thread', 'file', 'robot', 'user', 'channel', 'box'],
    warnings: [{ token: 'foo:bar', pos: 7, detail: 'unknown operator foo: searched as text' }],
    groups: {
      messages: { results: [{ msg_id: 'm1', task_id: 't1', snippet: { text: 'we deploy', highlights: [[3, 9]] } }], next: 'cm' },
      threads: { results: [{ task_id: 't1', title: { text: 'Deploy plan', highlights: [[0, 6]] }, count: 2 }], next: null },
      files: { results: [{ file_id: null, name: { text: 'deploy.pdf', highlights: [] }, msg_id: 'm1', task_id: 't1' }, { file_id: null, name: { text: 'b.txt', highlights: [] }, msg_id: 'm1', task_id: 't1' }], next: null },
      robots: { results: [{ id: 'CLE-07', box: 'box-a', online: true, name: { text: 'CLE-07@box-a', highlights: [[0, 3]] } }], next: null },
      users: { results: [], next: null },
      channels: { results: [{ channel: 'tasks', name: { text: 'tasks', highlights: [] } }], next: null },
      boxes: { results: [{ box_id: 'box-a', name: { text: 'box-a', highlights: [] } }], next: null },
    },
  }
  it('groups in render order, per-group next, empty groups dropped', () => {
    const r = normalizeSearchResponse(answer)
    assert.deepEqual(r.groups.map((g) => g.type), ['robots', 'channels', 'boxes', 'threads', 'files', 'messages'])
    assert.equal(r.groups.find((g) => g.type === 'messages').next, 'cm')
    assert.equal(r.groups.find((g) => g.type === 'threads').next, null)
    assert.deepEqual(r.warnings, [{ token: 'foo:bar', pos: 7, detail: 'unknown operator foo: searched as text' }])
  })
  it('display text per type: snippet / title / name', () => {
    const r = normalizeSearchResponse(answer)
    const by = Object.fromEntries(r.groups.map((g) => [g.type, g.items[0].display]))
    assert.deepEqual(by.messages, { text: 'we deploy', highlights: [[3, 9]] })
    assert.deepEqual(by.threads, { text: 'Deploy plan', highlights: [[0, 6]] })
    assert.deepEqual(by.robots, { text: 'CLE-07@box-a', highlights: [[0, 3]] })
    assert.equal(by.boxes.text, 'box-a')
  })
  it('keys are unique even for two null-id attachments of one message', () => {
    const r = normalizeSearchResponse(answer)
    const keys = flattenGroups(r.groups).map((x) => x.key)
    assert.equal(new Set(keys).size, keys.length)
  })
  it('a flat results[] or bare-array group is accepted', () => {
    assert.deepEqual(normalizeSearchResponse({ results: [{ msg_id: 'a', snippet: { text: 'hi', highlights: [] } }] }).groups.map((g) => g.type), ['messages'])
    assert.deepEqual(normalizeSearchResponse({ groups: { users: [{ id: 'HUM-1' }] } }).groups[0].items[0].display.text, 'HUM-1')
  })
  it('a cursor page (one section) appends to its group and takes its next', () => {
    const cur = normalizeSearchResponse(answer)
    const page = normalizeSearchResponse({ groups: { messages: { results: [{ msg_id: 'm1' }, { msg_id: 'm2' }], next: null } } })
    const m = mergeSearchPage(cur, page)
    const msgs = m.groups.find((g) => g.type === 'messages')
    assert.deepEqual(msgs.items.map((x) => x.msg_id), ['m1', 'm2'])
    assert.equal(msgs.next, null)
    assert.equal(m.groups.length, cur.groups.length)
  })
  it('CONTROL: junk input is an empty result, not a throw', () => {
    for (const d of [null, undefined, 'x', 42, { groups: 'x' }, { results: 'x' }, { groups: { messages: { results: [null, 3] } } }]) {
      const r = normalizeSearchResponse(d)
      assert.deepEqual(r.groups, [])
    }
  })
})

describe('operators document (search-v1 §6)', () => {
  it('names, aliases, enum keys and type values become completions', () => {
    const ops = normalizeOperators({
      version: '1.0',
      types: [{ type: 'message' }, { type: 'robot' }],
      operators: [
        { name: 'from', aliases: [], values: 'id', example: 'from:CLE-07' },
        { name: 'is', values: 'enum', enum: { task: ['message'], online: ['robot'] } },
        { name: 'title', aliases: ['subject'], values: 'text' },
        { name: 'type', values: 'type' },
      ],
    })
    assert.deepEqual(ops.map((o) => o.op), ['from:', 'is:', 'title:', 'subject:', 'type:'])
    assert.deepEqual(completeOperators('is:', ops).map((c) => c.insert), ['is:task ', 'is:online '])
    assert.deepEqual(completeOperators('type:', ops).map((c) => c.insert), ['type:message ', 'type:robot '])
    assert.deepEqual(completeOperators('su', ops).map((c) => c.insert), ['subject:'])
  })
  it('CONTROL: junk or empty → the built-in catalogue; bad names dropped', () => {
    assert.equal(normalizeOperators(null), SEARCH_OPERATORS)
    assert.equal(normalizeOperators({ operators: [] }), SEARCH_OPERATORS)
    assert.equal(normalizeOperators({ operators: [{ name: '<img>' }] }), SEARCH_OPERATORS)
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
    const r = normalizeSearchResponse({ groups: { robots: { results: [{ id: 'A' }] }, messages: { results: [{ msg_id: '1' }, { msg_id: '2' }] } } })
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
    assert.deepEqual(searchTarget({ type: 'channels', channel: 'lobby' }), { path: '/channel/lobby' })
    assert.deepEqual(searchTarget({ type: 'boxes', box_id: 'box-a' }), { search: 'box:box-a' })
  })
  it('CONTROL: a row without an id goes nowhere', () => {
    for (const r of [null, {}, { type: 'messages' }, { type: 'robots' }, { type: 'channels' }, { type: 'boxes' }, { type: 'nope', id: 'x' }]) {
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
    assert.deepEqual(mockSearch(msgs, 'deploy').groups.messages.results.map((m) => m.msg_id), ['2', '1'])
    assert.deepEqual(mockSearch(msgs, 'from:EZB-1 is:task').groups.messages.results.map((m) => m.msg_id), ['1'])
    assert.deepEqual(mockSearch(msgs, 'in:dm').groups.messages.results.map((m) => m.msg_id), ['2'])
    assert.deepEqual(mockSearch(msgs, 'in:#lobby').groups.messages.results.map((m) => m.msg_id), ['1'])
    assert.deepEqual(mockSearch(msgs, 'deploy').groups.messages.results[0].snippet.highlights, [[0, 6], [13, 19]])
  })
  it('CONTROL: no match → empty; an operator the mock does not model warns', () => {
    assert.deepEqual(mockSearch(msgs, 'nothing-like-this').groups.messages.results, [])
    assert.equal(mockSearch(msgs, 'larger:1M deploy').warnings.length, 1)
  })
})

describe('spool-client search()', async () => {
  const { createSpoolClient } = await import('../../src/utils/spool-client.mjs')
  it('live: GET /v1/view/search with q raw, Bearer token, normalised groups', async () => {
    const calls = []
    const fetchFn = async (url, opts) => {
      calls.push({ url, opts })
      return new Response(JSON.stringify({ groups: { messages: { results: [{ msg_id: 'm1', task_id: 't1', snippet: { text: 'hi', highlights: [[0, 2]] } }], next: 'n' } } }), { status: 200, headers: { 'content-type': 'application/json' } })
    }
    const c = createSpoolClient({ mock: false, base: 'https://t1.example.com/', fetchFn, token: 'tok' })
    const r = await c.search({ q: 'from:EZB-1 is:task', cursor: 'c', sort: 'relevance' })
    const u = new URL(calls[0].url)
    assert.equal(u.origin + u.pathname, 'https://t1.example.com/v1/view/search')
    assert.equal(u.searchParams.get('q'), 'from:EZB-1 is:task')
    assert.equal(u.searchParams.get('cursor'), 'c')
    assert.equal(u.searchParams.get('sort'), 'relevance')
    assert.equal(calls[0].opts.headers.authorization, 'Bearer tok')
    assert.equal(r.groups[0].items[0].key, 'messages:m1')
    assert.equal(r.groups[0].next, 'n')
  })
  it('live: 400 bad_query surfaces status + the hub detail', async () => {
    const fetchFn = async () => new Response(JSON.stringify({ error: 'bad_query', detail: "unbalanced '('", pos: 2, token: '(' }), { status: 400, headers: { 'content-type': 'application/json' } })
    const c = createSpoolClient({ mock: false, base: 'https://h', fetchFn })
    await assert.rejects(c.search({ q: 'a (b' }), (e) => e.status === 400 && e.token === 'bad_query' && /unbalanced/.test(e.detail) && e.pos === 2 && e.badToken === '(')
  })
  it('live: 429 carries Retry-After', async () => {
    const fetchFn = async () => new Response(JSON.stringify({ error: 'rate_limited' }), { status: 429, headers: { 'content-type': 'application/json', 'retry-after': '12' } })
    const c = createSpoolClient({ mock: false, base: 'https://h', fetchFn })
    await assert.rejects(c.search({ q: 'x' }), (e) => e.status === 429 && e.retryAfter === 12)
  })
  it('live: operators come from GET /v1/view/search/operators', async () => {
    const urls = []
    const fetchFn = async (url) => { urls.push(url); return new Response(JSON.stringify({ operators: [{ name: 'from' }] }), { status: 200, headers: { 'content-type': 'application/json' } }) }
    const c = createSpoolClient({ mock: false, base: 'https://h', fetchFn })
    assert.deepEqual((await c.searchOperators()).map((o) => o.op), ['from:'])
    assert.equal(urls[0], 'https://h/v1/view/search/operators')
  })
  it('mock: searches the local corpus, no fetch', async () => {
    const c = createSpoolClient({ mock: true, fetchFn: () => { throw new Error('no fetch in mock') } })
    const r = await c.search({ q: '' })
    assert.ok(Array.isArray(r.groups))
  })
})

describe('shouldLoadOperators (signed-out gate)', () => {
  it('mock hydrates immediately, live only when session is in', () => {
    assert.equal(shouldLoadOperators({ mock: true, sessionState: 'out' }), true)
    assert.equal(shouldLoadOperators({ mock: true, sessionState: 'loading' }), true)
    assert.equal(shouldLoadOperators({ mock: false, sessionState: 'in' }), true)
  })
  it('CONTROL: live signed-out / loading / unknown / missing does not fetch', () => {
    for (const st of ['out', 'loading', 'unknown', '', undefined]) {
      assert.equal(shouldLoadOperators({ mock: false, sessionState: st }), false, st)
    }
    assert.equal(shouldLoadOperators({}), false)
  })
  it('TopBar watches the session and does not fetch on mount', () => {
    const bar = read('src/components/TopBar.vue')
    assert.match(bar, /shouldLoadOperators\(\{ mock: api\.mock, sessionState: st \}\)/)
    assert.match(bar, /watch\(\(\) => session\.state/)
    assert.match(bar, /useSessionStore\(\)/)
    assert.match(bar, /useSpoolApi\(\)/)
    assert.match(bar, /immediate: true/)
    assert.doesNotMatch(bar, /onMounted\([\s\S]*loadOperators/)
    assert.match(bar, /void search\.loadOperators\(\)/)
  })
})
