// 022 top-bar global search — pure helpers (src/utils/search.mjs).
// Run: node tests/unit/search.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import {
  SEARCH_GROUPS,
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
  ensureSearchOperators,
  OP_PICKER_CAP,
  operatorHelpRows,
  searchTarget,
  shouldLoadOperators,
} from '../../src/utils/search.mjs'
import { readFileSync, readdirSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (rel) => readFileSync(join(WUI, rel), 'utf8')

describe('omnibox mode switch', () => {
  it('/search and /s switch to search, with or without a query', () => {
    for (const s of ['/search', '/search ', '/search from:EZB-1 is:task', '/s foo', '/SEARCH x', '/search\nx', '/search:test', '/s:foo', '/SEARCH:x']) {
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
    assert.equal(searchQueryOf('/search:test'), 'test')
    assert.equal(searchQueryOf('/search:from:EZB-1 is:task'), 'from:EZB-1 is:task')
    assert.equal(searchQueryOf('/search:'), '')
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
    assert.deepEqual(operatorTokenAt('/search:fr', 10), { token: 'fr', start: 8, end: 10 })
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
  it('any part of an operator, example, or value matches', () => {
    assert.deepEqual(completeOperators('f').map((c) => c.insert), ['from:', 'is:offline ', 'has:file ', 'type:file ', 'kind:file ', 'before:', 'after:', 'filename:', 'ext:'])
    assert.deepEqual(completeOperators('task').map((c) => c.insert), ['is:task ', 'topic:'])
    assert.ok(completeOperators('Is').some((c) => c.insert === 'is:'))
  })
  it('closed values after the colon', () => {
    assert.deepEqual(completeOperators('is:r').map((c) => c.insert), ['is:result ', 'is:reject ', 'is:root ', 'is:revoked '])
    assert.deepEqual(completeOperators('type:r').map((c) => c.insert), ['type:robot ', 'type:user ', 'type:thread ', 'type:person ', 'type:workspace '])
    assert.deepEqual(completeOperators('type:ten').map((c) => c.insert), ['type:tenant '])
    assert.deepEqual(completeOperators('type:ev').map((c) => c.insert), ['type:event '])
    assert.deepEqual(completeOperators('kind:ten').map((c) => c.insert), ['kind:tenant '])
    assert.deepEqual(completeOperators('channel:').map((c) => c.insert), ['channel:dm '])
    assert.deepEqual(completeOperators('type:top').map((c) => c.insert), ['type:topic '])
    assert.deepEqual(completeOperators('has:c').map((c) => c.insert), ['has:attachment ', 'has:code '])
  })
  it('CONTROL: a finished closed value and an unknown prefix offer nothing', () => {
    assert.deepEqual(completeOperators('is:task'), [])
    assert.deepEqual(completeOperators('to:'), [])
    assert.deepEqual(completeOperators('zz'), [])
    assert.deepEqual(completeOperators(''), [])
  })
  it('from: lists roster ids by contains, and a miss invents nothing', () => {
    const roster = [
      { id: 'CLE-3994', label: 'CLE-3994@box-desk' },
      { id: 'CLE-07', label: 'CLE-07@box-a' },
      { id: 'CLE-07', label: 'CLE-07@box-b' },
      { id: 'HUM-1', label: 'HUM-1@box-wui' },
      { id: 'GRK-03', label: 'GRK-03@box-a' },
      { id: 'AGY-02', label: 'AGY-02@box-b' },
      { id: 'GST-3', label: 'GST-3@box-wui' },
      { id: 'EZB-1', label: 'EZB-1@box-a' },
      { id: 'ALL-0', label: 'ALL-0' },
    ]
    const inserts = (token) => completeOperators(token, SEARCH_OPERATORS, roster).map((c) => c.insert)
    assert.deepEqual(completeOperators('from:'), [])
    assert.deepEqual(inserts('from:'), [
      'from:CLE-3994 ',
      'from:CLE-07 ',
      'from:HUM-1 ',
      'from:GRK-03 ',
      'from:AGY-02 ',
      'from:GST-3 ',
    ])
    assert.deepEqual(inserts('from:cle'), ['from:CLE-3994 ', 'from:CLE-07 '])
    assert.deepEqual(inserts('from:hum-1'), ['from:HUM-1 '])
    assert.deepEqual(inserts('from:3994'), ['from:CLE-3994 '])
    assert.equal(inserts('from:3994').includes('from:CLE-07 '), false)
    assert.deepEqual(inserts('from:desk'), ['from:CLE-3994 '])
    assert.deepEqual(inserts('from:nomatch'), [])
    assert.deepEqual(inserts('from:ezb'), [])
    assert.deepEqual(completeOperators('to:', SEARCH_OPERATORS, roster), [])
    assert.deepEqual(completeOperators('to:hum', SEARCH_OPERATORS, roster), [])
    assert.deepEqual(
      completeOperators('is:r', SEARCH_OPERATORS, roster).map((c) => c.insert),
      ['is:result ', 'is:reject ', 'is:root ', 'is:revoked '],
    )
    assert.deepEqual(
      completeOperators('f', SEARCH_OPERATORS, roster).map((c) => c.insert),
      ['from:', 'is:offline ', 'has:file ', 'type:file ', 'kind:file ', 'before:', 'after:', 'filename:', 'ext:'],
    )
    const many = Array.from({ length: 9 }, (_, n) => ({ id: `CLE-${n + 1}` }))
    const capped = completeOperators('from:', SEARCH_OPERATORS, many)
    assert.equal(capped.length, 8)
    assert.deepEqual(capped.map((c) => c.insert), many.slice(0, 8).map((peer) => `from:${peer.id} `))
    const line = '/search from:3994 is:task'
    const tok = operatorTokenAt(line, '/search from:3994'.length)
    assert.equal(tok.token, 'from:3994')
    const hit = completeOperators(tok.token, SEARCH_OPERATORS, roster)[0]
    assert.equal(hit.label, 'from:CLE-3994')
    assert.deepEqual(applyCompletion(line, tok, hit.insert), {
      text: '/search from:CLE-3994 is:task',
      cursor: '/search from:CLE-3994'.length,
    })
    const endLine = '/s from:3994'
    const endTok = operatorTokenAt(endLine, endLine.length)
    assert.equal(endTok.token, 'from:3994')
    assert.deepEqual(applyCompletion(endLine, endTok, hit.insert), {
      text: '/s from:CLE-3994 ',
      cursor: '/s from:CLE-3994 '.length,
    })
  })
  it('the composer passes the roster into from: completions', () => {
    const src = read('src/components/MessageComposer.vue')
    assert.match(src, /completeOperators\(opTok\.value\.token, props\.operators, roster\.peers\)/)
    assert.match(src, /data-test="search-syntax-help"/)
    assert.match(src, /OP_PICKER_CAP/)
    assert.match(read('src/pages/search.vue'), /data-test="search-operator-help"/)
    assert.match(read('src/pages/events.vue'), /scrollRowToTop/)
  })
  it('the catalogue carries every operator the brief names', () => {
    const ops = SEARCH_OPERATORS.map((o) => o.op)
    for (const op of ['from:', 'to:', 'in:', 'channel:', 'is:', 'has:', 'before:', 'after:', 'on:', 'type:', 'kind:', 'title:', 'subject:', 'name:', 'filename:', 'ext:', 'larger:', 'smaller:', 'box:', 'topic:']) {
      assert.ok(ops.includes(op), op)
    }
    const types = SEARCH_OPERATORS.find((o) => o.op === 'type:').values
    for (const v of ['tenant', 'event', 'issue', 'issues', 'ticket', 'tickets']) assert.ok(types.includes(v), v)
    const shown = completeOperators('type:').map((c) => c.insert).slice(0, OP_PICKER_CAP)
    assert.ok(shown.includes('type:tenant '))
    assert.ok(shown.includes('type:event '))
    assert.ok(shown.includes('type:issue '))
    assert.equal(operatorHelpRows().some((r) => r.op === 'name:' && r.hintKey === 'search.op.name'), true)
    const en = JSON.parse(read('i18n/locales/en.json'))
    assert.match(en.search.help_content, /deploy\*/)
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
    types: ['message', 'topic', 'file', 'robot', 'user', 'channel', 'box'],
    warnings: [{ token: 'foo:bar', pos: 7, detail: 'unknown operator foo: searched as text' }],
    groups: {
      messages: { results: [{ msg_id: 'm1', task_id: 't1', snippet: { text: 'we deploy', highlights: [[3, 9]] } }], next: 'cm' },
      topics: { results: [{ task_id: 't1', title: { text: 'Deploy plan', highlights: [[0, 6]] }, count: 2 }], next: null },
      files: { results: [{ file_id: null, name: { text: 'deploy.pdf', highlights: [] }, msg_id: 'm1', task_id: 't1' }, { file_id: null, name: { text: 'b.txt', highlights: [] }, msg_id: 'm1', task_id: 't1' }], next: null },
      robots: { results: [{ id: 'CLE-07', box: 'box-a', online: true, name: { text: 'CLE-07@box-a', highlights: [[0, 3]] } }], next: null },
      users: { results: [], next: null },
      channels: { results: [{ channel: 'tasks', name: { text: 'tasks', highlights: [] } }], next: null },
      boxes: { results: [{ box_id: 'box-a', name: { text: 'box-a', highlights: [] } }], next: null },
      tenants: { results: [{ tenant_id: 't1', name: { text: 'csitea (t1)', highlights: [] } }], next: null },
      events: { results: [{ event_id: 4, code: 'network', message: 'Failed to fetch', name: { text: 'network', highlights: [] } }], next: null },
    },
  }
  it('groups in render order, per-group next, empty groups dropped', () => {
    const r = normalizeSearchResponse(answer)
    assert.deepEqual(r.groups.map((g) => g.type), ['robots', 'channels', 'boxes', 'tenants', 'topics', 'files', 'messages', 'events'])
    assert.equal(r.groups.find((g) => g.type === 'messages').next, 'cm')
    assert.equal(r.groups.find((g) => g.type === 'topics').next, null)
    assert.deepEqual(r.warnings, [{ token: 'foo:bar', pos: 7, detail: 'unknown operator foo: searched as text' }])
  })
  it('display text per type: snippet / title / name', () => {
    const r = normalizeSearchResponse(answer)
    const by = Object.fromEntries(r.groups.map((g) => [g.type, g.items[0].display]))
    assert.deepEqual(by.messages, { text: 'we deploy', highlights: [[3, 9]] })
    assert.deepEqual(by.topics, { text: 'Deploy plan', highlights: [[0, 6]] })
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

describe('1.1 operators on an older catalogue', () => {
  it('adds tenant, event, kind: and channel: without duplicating them', () => {
    const older = [
      { op: 'type:', values: ['message', 'topic'] },
      { op: 'in:', example: 'in:#lobby', values: ['dm'] },
    ]
    const once = ensureSearchOperators(older)
    assert.deepEqual(once.find((o) => o.op === 'type:').values.slice(0, 2), ['message', 'topic'])
    for (const v of ['tenant', 'event', 'issue', 'thread', 'person', 'workspace', 'log', 'issues', 'ticket', 'tickets']) {
      assert.ok(once.find((o) => o.op === 'type:').values.includes(v), v)
    }
    assert.equal(once.find((o) => o.op === 'kind:').example, 'kind:message')
    assert.equal(once.find((o) => o.op === 'channel:').example, 'channel:#lobby')
    assert.equal(once.find((o) => o.op === 'status:').example, 'status:in_progress')
    assert.deepEqual(once.find((o) => o.op === 'priority:').values, ['0', '1', '2', '3', '4'])
    assert.deepEqual(once.find((o) => o.op === 'assignee:').values, ['me', 'none'])
    assert.equal(once.find((o) => o.op === 'label:').example, 'label:bug')
    assert.equal(ensureSearchOperators(once), once)
    assert.equal(ensureSearchOperators(SEARCH_OPERATORS), SEARCH_OPERATORS)
  })
  it('folds type aliases after the canonical names, and accepts hl', () => {
    const ops = normalizeOperators({
      types: [
        { type: 'message', aliases: ['msg'] },
        { type: 'topic', aliases: ['thread'] },
        { type: 'tenant', aliases: ['workspace'] },
        { type: 'event', aliases: ['log'] },
      ],
      operators: [{ name: 'type', aliases: ['kind'], values: 'type' }],
    })
    const values = ops.find((o) => o.op === 'type:').values
    assert.deepEqual(values.slice(0, 4), ['message', 'topic', 'tenant', 'event'])
    assert.ok(values.indexOf('thread') > values.indexOf('event'))
    assert.ok(completeOperators('type:per', ensureSearchOperators(ops)).some((c) => c.insert === 'type:person '))
    const row = normalizeSearchResponse({
      groups: { tenants: { results: [{ tenant_id: 't1', name: { text: 'acme', hl: [[0, 2]] } }] } },
    }).groups[0].items[0]
    assert.deepEqual(row.display, { text: 'acme', highlights: [[0, 2]] })
    assert.equal(row.key, 'tenants:t1')
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
    assert.deepEqual(searchTarget({ type: 'messages', task_id: 't', msg_id: 'm' }), { topic: 't', focus: 'm' })
    assert.deepEqual(searchTarget({ type: 'messages', task_id: 'r', parent_task_id: 'p', msg_id: 'm' }), { topic: 'p', focus: 'm' })
    assert.deepEqual(searchTarget({ type: 'topics', task_id: 't' }), { topic: 't', focus: '' })
    assert.deepEqual(searchTarget({ type: 'files', task_id: 't', msg_id: 'm' }), { topic: 't', focus: 'm' })
    assert.deepEqual(searchTarget({ type: 'robots', id: 'CLE-07', box: 'box-a' }), { path: '/dm/CLE-07%40box-a' })
    assert.deepEqual(searchTarget({ type: 'users', id: 'HUM-1' }), { path: '/dm/HUM-1' })
    assert.deepEqual(searchTarget({ type: 'channels', channel: 'lobby' }), { path: '/channel/lobby' })
    assert.deepEqual(searchTarget({ type: 'boxes', box_id: 'box-a' }), { search: 'box:box-a' })
    assert.deepEqual(searchTarget({ type: 'tenants', tenant_id: 't1' }), { tenant: 't1' })
    assert.deepEqual(searchTarget({ type: 'events', event_id: 4 }), { path: '/events#4' })
    assert.deepEqual(searchTarget({ type: 'events', id: 9 }), { path: '/events#9' })
    assert.deepEqual(searchTarget({ type: 'events' }), { path: '/events' })
  })
  it('CONTROL: a row without an id goes nowhere', () => {
    for (const r of [null, {}, { type: 'messages' }, { type: 'robots' }, { type: 'channels' }, { type: 'boxes' }, { type: 'tenants' }, { type: 'nope', id: 'x' }]) {
      assert.equal(searchTarget(r), null)
    }
  })
})

describe('issue hits (grammar 1.2)', () => {
  it('issues is the group after events', () => {
    assert.equal(SEARCH_GROUPS[SEARCH_GROUPS.indexOf('events') + 1], 'issues')
    const r = normalizeSearchResponse({
      groups: {
        events: { results: [{ event_id: 1, name: { text: 'network', highlights: [] } }], next: null },
        issues: { results: [{ key: 'SPL-4', number: 4, title: { text: 'Scan hub', highlights: [[0, 4]] }, status: 'in_progress', priority: 0, assignee: null, task_id: 't-shared' }], next: 'ci' },
      },
    })
    assert.deepEqual(r.groups.map((g) => g.type), ['events', 'issues'])
    const hit = r.groups.find((g) => g.type === 'issues').items[0]
    assert.equal(hit.display.text, 'Scan hub')
    assert.equal(hit.key, 'issues:SPL-4')
    assert.equal(hit.issue_key, 'SPL-4')
    assert.equal(r.groups.find((g) => g.type === 'issues').next, 'ci')
    assert.deepEqual(searchTarget(hit), { path: '/issues?issue=SPL-4' })
  })
  it('two issues that share a thread stay two hits', () => {
    const r = normalizeSearchResponse({
      groups: {
        issues: {
          results: [
            { key: 'SPL-1', task_id: 'same', title: { text: 'A', highlights: [] } },
            { key: 'SPL-2', task_id: 'same', title: { text: 'B', highlights: [] } },
          ],
          next: null,
        },
      },
    })
    assert.deepEqual(r.groups[0].items.map((x) => x.key), ['issues:SPL-1', 'issues:SPL-2'])
    assert.deepEqual(r.groups[0].items.map((x) => searchTarget(x)), [
      { path: '/issues?issue=SPL-1' },
      { path: '/issues?issue=SPL-2' },
    ])
  })
  it('a row with only a key shows that key', () => {
    const hit = normalizeSearchResponse({ groups: { issues: { results: [{ key: 'SPL-9' }] } } }).groups[0].items[0]
    assert.equal(hit.display.text, 'SPL-9')
    assert.deepEqual(searchTarget(hit), { path: '/issues?issue=SPL-9' })
    assert.deepEqual(searchTarget({ type: 'issues', key: 'SPL-4' }), { path: '/issues?issue=SPL-4' })
  })
  it('CONTROL: a row without a key goes nowhere', () => {
    for (const row of [{ type: 'issues' }, { type: 'issues', key: '' }, { type: 'issues', key: '   ' }, { type: 'issues', issue_key: '' }]) {
      assert.equal(searchTarget(row), null)
    }
    const bare = normalizeSearchResponse({ groups: { issues: { results: [{ status: 'todo' }] } } }).groups[0].items[0]
    assert.equal(searchTarget(bare), null)
  })
  it('the fallback catalogue offers issue operators', () => {
    const ops = SEARCH_OPERATORS.map((o) => o.op)
    for (const op of ['status:', 'priority:', 'assignee:', 'label:']) assert.ok(ops.includes(op), op)
    assert.ok(SEARCH_OPERATORS.find((o) => o.op === 'type:').values.includes('issue'))
    assert.deepEqual(completeOperators('status:in').map((c) => c.insert), ['status:in_progress ', 'status:in_review '])
    assert.deepEqual(completeOperators('priority:').map((c) => c.insert), ['priority:0 ', 'priority:1 ', 'priority:2 ', 'priority:3 ', 'priority:4 '])
    assert.deepEqual(completeOperators('assignee:').map((c) => c.insert), ['assignee:me ', 'assignee:none '])
    assert.deepEqual(completeOperators('label:'), [])
    const page = read('src/pages/search.vue')
    assert.match(page, /status:in_progress/)
    assert.match(page, /case 'issues'/)
  })
  it('every locale names the issues group and the issue operators', () => {
    const files = readdirSync(join(WUI, 'i18n/locales')).filter((f) => f.endsWith('.json')).sort()
    assert.equal(files.length, 19)
    const en = JSON.parse(read('i18n/locales/en.json')).search.group.issues
    for (const f of files) {
      const data = JSON.parse(read('i18n/locales/' + f))
      const label = data.search.group.issues
      assert.equal(typeof label, 'string', f)
      assert.ok(label.trim(), f)
      const help = data.search.help_content
      for (const tok of ['status:', 'priority:', 'assignee:', 'label:']) assert.ok(help.includes(tok), f + ' ' + tok)
      if (f !== 'en.json') assert.notEqual(label, en, f)
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
