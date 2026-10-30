// Spec 153 3.10 (row B10, SPL-4421; owner HUM-10, t1 08213e0e, msg
// 8caf41ec): Monitoring -> Topics, the Lanes answer grouped by topic
// (src/utils/monitoring-topics.mjs): one row per topic with its lanes and
// issues, newest lane activity first; the Lanes sort engine and filters
// reused. RED CONTROL (master): the util and the page do not exist, so the
// imports fail and every case here fails.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { LANES_MOCK_KEY, LANES_MOCK_OPERATOR_KEY, LANES_MOCK_TOPIC, fleetLanesOf, laneDeepLink, mockFleetLanes } from '../../src/utils/monitoring-lanes.mjs'
import { TOPICS_NO_FILTER, filterTopics, sortTopics, topicFilterChoices, topicsOf } from '../../src/utils/monitoring-topics.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (rel) => readFileSync(join(WUI, rel), 'utf8')
const store = (kv) => ({ getItem: (k) => (k in kv ? kv[k] : null) })
const OP = { [LANES_MOCK_OPERATOR_KEY]: '1' }
const AS_OF = '2026-10-30T12:00:00Z'
const at = (minAgo) => new Date(Date.parse(AS_OF) - minAgo * 60000).toISOString().replace(/\.000Z$/, 'Z')
const T1 = '11111111-1111-4111-8111-111111111111'
const T2 = '22222222-2222-4222-8222-222222222222'

/** A hub body: c-1 and c-2 on T1, g-3 on T2, m-4 on no topic. */
function body() {
  return { as_of: AS_OF, fleet: 'main', lanes: [
    { agent_id: 'c-1', agent_box: 'box-a', vendor: 'claude', topic_id: T1, topic_title: 'One', topic_channel: 'dev', workspace: 'w', workspace_name: 'W',
      issues: [{ key: 'SPL-1', status: 'wip' }, { key: 'SPL-2', status: '' }], updated_at: at(30), age_s: 1800, last_active: at(20), state: 'live' },
    { agent_id: 'g-3', agent_box: 'box-b', vendor: 'grok', topic_id: T2, topic_title: 'Two', workspace: 'w', workspace_name: 'W',
      issues: [{ key: 'SPL-9', status: 'done' }], updated_at: at(5), age_s: 300, last_active: '', state: 'live' },
    { agent_id: 'c-2', agent_box: 'box-b', vendor: 'claude', topic_id: T1, topic_title: 'One', topic_channel: 'dev', workspace: 'w', workspace_name: 'W',
      issues: [{ key: 'SPL-2', status: 'eval' }, { key: 'SPL-3', status: 'wip' }], updated_at: at(90), age_s: 5400, last_active: at(2), state: 'queued' },
    { agent_id: 'm-4', agent_box: 'box-a', vendor: 'mistral', topic_id: '', topic_title: '', workspace: 'w', workspace_name: 'W',
      issues: [], updated_at: at(60 * 30), age_s: 108000, last_active: '', state: 'live' },
  ] }
}

describe('topicsOf: the lanes grouped by topic', () => {
  const rows = topicsOf(fleetLanesOf(body()))
  it('one row per topic, newest lane activity first; the no-topic lanes share one row, last here', () => {
    assert.deepEqual(rows.map((r) => r.topicId), [T1, T2, ''])
    assert.equal(rows[0].lastAt, at(2), 'T1: c-2 burned tokens 2 min ago, newer than every write')
    assert.equal(rows[1].lastAt, at(5), 'T2: no token minute, its row write')
    assert.equal(rows[0].ageS, 120)
  })
  it('a topic lists each of its lanes, id@box and state', () => {
    assert.deepEqual(rows[0].lanes.map((l) => [l.name, l.state]), [['c-1@box-a', 'live'], ['c-2@box-b', 'queued']])
    assert.deepEqual(laneDeepLink(rows[0].lanes[1]), { path: '/monitoring/lanes', query: { lane: 'c-2@box-b' } }, 'a chip links to its Lanes row')
  })
  it('a topic lists its lanes\' issues, each key once, a status filled from any lane', () => {
    assert.deepEqual(rows[0].issues, [{ key: 'SPL-1', status: 'wip' }, { key: 'SPL-2', status: 'eval' }, { key: 'SPL-3', status: 'wip' }])
    assert.deepEqual(rows[2].issues, [])
  })
  it('the title, channel and workspace come from the lanes; no channel is ""', () => {
    assert.deepEqual([rows[0].topicTitle, rows[0].topicChannel, rows[0].workspaceName], ['One', 'dev', 'W'])
    assert.equal(rows[1].topicChannel, '')
  })
  it('no lanes, no rows', () => {
    assert.deepEqual(topicsOf(fleetLanesOf({ as_of: AS_OF, lanes: [] })), [])
    assert.deepEqual(topicsOf(fleetLanesOf(null)), [])
  })
})

describe('sort and filter: the Lanes engine, reused', () => {
  const rows = topicsOf(fleetLanesOf(body()))
  const ids = (rs) => rs.map((r) => r.topicId || '-').join(',')
  it('no sort keeps newest activity first; a column sorts both ways, empties last', () => {
    assert.equal(ids(sortTopics(rows, { col: '', dir: '' })), [T1, T2, '-'].join(','))
    assert.equal(ids(sortTopics(rows, { col: 'topic', dir: 'asc' })), [T1, T2, '-'].join(','), 'One, Two, then the empty title')
    assert.equal(ids(sortTopics(rows, { col: 'lanes', dir: 'desc' })), [T1, T2, '-'].join(','))
    assert.equal(ids(sortTopics(rows, { col: 'active', dir: 'asc' })), ['-', T2, T1].join(','))
    assert.equal(ids(sortTopics(rows, { col: 'channel', dir: 'asc' })), [T1, T2, '-'].join(','), 'only T1 has a channel')
  })
  it('box, vendor and state keep a topic when one of its lanes matches', () => {
    assert.equal(ids(filterTopics(rows, { ...TOPICS_NO_FILTER, box: 'box-b' })), [T1, T2].join(','))
    assert.equal(ids(filterTopics(rows, { ...TOPICS_NO_FILTER, vendor: 'grok' })), T2)
    assert.equal(ids(filterTopics(rows, { ...TOPICS_NO_FILTER, state: 'queued' })), T1)
  })
  it('age is the newest activity\'s; text finds a lane, an issue key, a channel', () => {
    assert.equal(ids(filterTopics(rows, { ...TOPICS_NO_FILTER, age: '1h' })), [T1, T2].join(','))
    assert.equal(ids(filterTopics(rows, { ...TOPICS_NO_FILTER, age: 'older' })), '-')
    assert.equal(ids(filterTopics(rows, { ...TOPICS_NO_FILTER, text: 'spl-3' })), T1)
    assert.equal(ids(filterTopics(rows, { ...TOPICS_NO_FILTER, text: 'g-3@box-b' })), T2)
    assert.equal(ids(filterTopics(rows, { ...TOPICS_NO_FILTER, text: 'dev one' })), T1)
  })
  it('the selects offer the lanes\' values', () => {
    assert.deepEqual(topicFilterChoices(rows), { box: ['box-a', 'box-b'], vendor: ['claude', 'grok', 'mistral'], state: ['live', 'queued'] })
  })
})

describe('the mock and the page', () => {
  it('the topics mock adds a second lane to c-085\'s topic; the default answer stays three lanes', () => {
    assert.equal(fleetLanesOf(mockFleetLanes(store(OP))).lanes.length, 3)
    const rows = topicsOf(fleetLanesOf(mockFleetLanes(store({ ...OP, [LANES_MOCK_KEY]: 'topics' }))))
    assert.equal(rows.length, 3)
    const t = rows.find((r) => r.topicId === LANES_MOCK_TOPIC)
    assert.deepEqual(t.lanes.map((l) => l.name), ['c-085@box-a', 'c-733@box-a'])
    assert.deepEqual(t.issues.map((i) => i.key), ['SPL-3075', 'SPL-3215', 'SPL-4421'])
    assert.equal(t.topicChannel, 'monitoring')
  })
  const page = read('src/pages/monitoring/topics/index.vue')
  it('the page reuses the Lanes read and poll, binds no :style and sets no page meta', () => {
    assert.match(page, /readLanes\(/)
    assert.match(page, /startLanesPoll\(/)
    assert.match(page, /visibilitychange/)
    assert.doesNotMatch(page, /:style=|v-bind:style/)
    assert.doesNotMatch(page, /useHead|useSeoMeta|definePageMeta/)
  })
  it('every key the page renders is in all 19 locales', () => {
    /* t('<key>') calls and the column names' { key: '<key>' } */
    const keys = [...new Set([...page.matchAll(/\b(?:t\(|key: )'([a-z0-9_.]+)'/g)].map((m) => m[1]))]
    for (const k of ['monitoring.topics.empty', 'monitoring.topics.col_channel', 'monitoring.topics.col_active', 'monitoring.tab.lanes']) assert.ok(keys.includes(k), k)
    for (const loc of ['bg', 'el', 'en', 'es', 'et', 'fi', 'he', 'lt', 'lv', 'mk', 'nl', 'pl', 'ro', 'ru', 'sk', 'sr', 'sv', 'tr', 'uk']) {
      const cat = JSON.parse(read('i18n/locales/' + loc + '.json'))
      const get = (key) => key.split('.').reduce((o, k) => (o == null ? o : o[k]), cat)
      for (const key of [...keys, 'monitoring.tab.topics']) assert.equal(typeof get(key), 'string', loc + ': ' + key)
      assert.match(get('monitoring.topics.shown'), /\{n\}.*\{total\}|\{total\}.*\{n\}/, loc)
    }
  })
  it('nothing on the first screen imports the topics util (ci_initial_gzip_kb)', () => {
    for (const f of ['src/pages/monitoring.vue', 'src/utils/monitoring-tabs.mjs', 'src/utils/spool-client.mjs']) {
      assert.doesNotMatch(read(f), /monitoring-topics/, f)
    }
  })
})
