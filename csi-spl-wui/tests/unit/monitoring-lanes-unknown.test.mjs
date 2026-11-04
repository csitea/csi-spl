// Spec 153 3.20 (SPL-4797; owner HUM-10, t1 0c2d08a2 msg 937e89a4: "for the
// already nulls , do not use resources to search what they were related to
// -, use the unknown string"): a lane row whose discussion or issue is the
// literal `unknown` shows `unknown` as plain text on Monitoring -> Lanes and
// -> Topics: never a link, never "No discussion", never the role-seat label.
// RED CONTROL (run on 022055fe6): laneTopicPath planted as
// `lane.topicId ? '/t/' + lane.topicId : ''` (a link for any id) -> U1
// fails, 2 of 3 pass; reverted -> 3 of 3. Since SPL-4798 the row hands typed
// refs to the one renderer: U1 asks laneTopicRef / laneIssueRef for none.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { fleetLanesOf, laneIssueRef, laneTopicRef } from '../../src/utils/monitoring-lanes.mjs'
import { topicsOf } from '../../src/utils/monitoring-topics.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (rel) => readFileSync(join(WUI, rel), 'utf8')
const AS_OF = '2026-11-04T12:00:00Z'

function view() {
  return fleetLanesOf({ as_of: AS_OF, fleet: 'main', lanes: [
    { agent_id: 'c-501', agent_box: 'sat', vendor: 'claude', topic_id: 'unknown', topic_title: '', workspace: 't1', workspace_name: 'spool-hub',
      issues: [{ key: 'unknown', status: '' }], updated_at: AS_OF, age_s: 0, last_active: '', state: 'live' },
    { agent_id: 'c-502', agent_box: 'sat', vendor: 'claude', topic_id: '', topic_title: '', workspace: 't1', workspace_name: 'spool-hub',
      issues: [], updated_at: AS_OF, age_s: 0, last_active: '', state: 'live' },
  ] })
}

describe('C96: a lane whose discussion and issue are `unknown`', () => {
  it('U1: the discussion and the issue are no links', () => {
    const l = view().lanes.find((x) => x.agent === 'c-501' || x.topicId === 'unknown')
    assert.equal(l.topicId, 'unknown')
    assert.equal(laneTopicRef(l, 't1'), null)
    assert.equal(laneIssueRef(l.issues[0], l, 't1'), null)
    assert.equal(laneTopicRef({ ...l, workspace: 'w2' }, 't1'), null)
    assert.equal(laneIssueRef(l.issues[0], { ...l, workspace: 'w2' }, 't1'), null)
    assert.equal(l.roleSeat, false)
  })
  it('U2: Topics keeps `unknown` as its own row, apart from the no-discussion row', () => {
    const rows = topicsOf(view())
    assert.deepEqual(rows.map((r) => r.topicId).sort(), ['', 'unknown'])
  })
  it('U3: both pages print a non-empty topic id as plain text before the empty-topic label', () => {
    const topics = read('src/pages/monitoring/topics/index.vue')
    assert.match(topics, /v-else-if="r\.topicId" class="tp-mono">\{\{ r\.topicId \}\}<\/span>\s*<span v-else class="muted" data-test="topics-none">/)
    const lanes = read('src/pages/monitoring/lanes/index.vue')
    assert.match(lanes, /v-else-if="l\.topicId" class="ln-mono">\{\{ l\.topicId \}\}<\/span>\s*<span v-else-if="l\.roleSeat"/)
  })
})
