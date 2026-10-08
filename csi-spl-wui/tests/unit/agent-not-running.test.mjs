// t1 bc1a43e1 (fix A): an agent whose machine is online but which does not
// run must not read green. c-001@<box> showed green while its box's desk
// socket was up and no c-001 process ran there, and nobody answered the
// owner. The hub now serves agent_presence.state "not_running"; the WUI maps
// it to `idle` - a hollow grey dot titled "machine online, agent not running"
// in the DM list and the @ mention list.
//
// Run: node tests/unit/agent-not-running.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync, readdirSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { applyIdle, applyPresence, peopleRows } from '../../src/utils/live-follow.mjs'
import { rosterFromView } from '../../src/utils/view-api.mjs'
import { mentionCandidates } from '../../src/utils/mention-autocomplete.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (rel) => readFileSync(join(WUI, rel), 'utf8')

const VIEW = {
  boxes: [
    { box_id: 'box-a', online: true, agents: ['c-001', 'c-002', 'c-003'],
      agent_presence: { 'c-001': { state: 'not_running' }, 'c-002': { state: 'online' } } },
    { box_id: 'box-b', online: false, agents: ['c-004'], agent_presence: { 'c-004': { state: 'offline' } } },
  ],
}

// The mapping before the fix: every agent of an online box is online.
const preFix = (data) => data.boxes.flatMap((b) => (b.online ? b.agents.map((a) => `${a}@${b.box_id}`) : []))

describe('agent_presence not_running (t1 bc1a43e1)', () => {
  it('an agent its online box says does not run is idle, not online; an unreported one stays online', () => {
    const r = rosterFromView(VIEW)
    assert.deepEqual(r.online, ['c-002@box-a', 'c-003@box-a'])
    assert.deepEqual(r.idle, ['c-001@box-a'])
  })

  it('CONTROL: the pre-fix mapping reads the not-running agent green', () => {
    assert.ok(preFix(VIEW).includes('c-001@box-a'))
    assert.ok(!rosterFromView(VIEW).online.includes('c-001@box-a'))
  })

  it('an offline box reads offline, never idle', () => {
    const r = rosterFromView(VIEW)
    assert.ok(!r.online.includes('c-004@box-b') && !r.idle.includes('c-004@box-b'))
  })

  it('people rows: exactly the idle agent is idle (count 1 of 4)', () => {
    const r = rosterFromView(VIEW)
    const rows = peopleRows(r.roster, r.online, '', 'box-wui', r.idle)
    assert.deepEqual(rows.filter((p) => p.idle).map((p) => p.label), ['c-001@box-a'])
    assert.equal(rows.filter((p) => p.online).length, 2)
  })

  it('presence frames: not_running drops online and sets idle; online clears idle', () => {
    let online = ['c-001@box-a']
    let idle = []
    const f = { type: 'presence', peer: 'c-001@box-a', status: 'not_running' }
    online = applyPresence(online, f)
    idle = applyIdle(idle, f)
    assert.deepEqual([online, idle], [[], ['c-001@box-a']])
    const g = { type: 'presence', peer: 'c-001@box-a', status: 'online' }
    online = applyPresence(online, g)
    idle = applyIdle(idle, g)
    assert.deepEqual([online, idle], [['c-001@box-a'], []])
    assert.deepEqual(applyIdle(['c-001@box-a'], { type: 'presence', peer: 'c-001@box-a', status: 'offline' }), [])
  })

  it('the @ mention list keeps the idle flag on the agent row', () => {
    const r = rosterFromView(VIEW)
    const peers = peopleRows(r.roster, r.online, '', 'box-wui', r.idle)
    const rows = mentionCandidates({ peers, query: 'c-00' })
    const row = rows.find((p) => p.id === 'c-001')
    assert.ok(row && row.idle === true && row.online === false)
  })

  it('the dot and the mention list render it: hollow grey + the words', () => {
    const dot = read('src/components/StatusDot.vue')
    assert.match(dot, /'dot--idle': notRunning/)
    assert.match(dot, /t\('people\.not_running'\)/)
    assert.match(read('src/components/MentionList.vue'), /:idle="Boolean\(p\.idle\)"/)
    assert.match(read('src/components/ChannelSidebar.vue'), /<StatusDot :id="p\.id" :online="p\.online" :idle="p\.idle" \/>/)
    assert.match(read('src/assets/css/main.css'), /\.dot\.dot--idle \{/)
  })

  it('every locale names the state; en says "Machine online, agent not running"', () => {
    const dir = join(WUI, 'i18n/locales')
    for (const f of readdirSync(dir)) {
      const v = JSON.parse(readFileSync(join(dir, f), 'utf8')).people.not_running
      assert.ok(typeof v === 'string' && v.length > 0, f)
    }
    assert.equal(JSON.parse(read('i18n/locales/en.json')).people.not_running, 'Machine online, agent not running')
  })
})
