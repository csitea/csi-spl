// SPL-1593 (rdb 0194, issues-v1 §2.2): every issue links to one or more
// discussions. The link helpers, the mock hub's rules (a create needs one,
// the last one stays, a short id must be unique) and the wiring of the
// bottom-panel section into the issue view.
//
// Run: node tests/unit/issue-discussions.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { existsSync, readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  MOCK_GONE_TOPIC, discussionErrorKey, discussionPath, discussionRef, normalizeDiscussions, shortTopic,
} from '../../src/utils/issue-discussions.mjs'
import { createMockIssues, issueQuery, normalizeIssue } from '../../src/utils/issues.mjs'
import { aiIssueBody } from '../../src/utils/msg-ai-actions.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const src = (rel) => readFileSync(join(WUI, rel), 'utf8')
const LIVE = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
const LOBBY = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'

describe('discussionRef reads what a member pastes', () => {
  it('a topic id, its short id, a /t/ link (any host), case-folded', () => {
    assert.equal(discussionRef(LIVE.toUpperCase()), LIVE)
    assert.equal(discussionRef('bbbbbbbb'), 'bbbbbbbb')
    assert.equal(discussionRef(`https://wui.example.com/en/t/${LIVE}?x=1`), LIVE)
    assert.equal(discussionRef('  /t/bbbbbbbb  '), 'bbbbbbbb')
  })
  it('anything else is none', () => {
    for (const bad of ['', 'SPL-1', 'bbbbbbb', `/m/${LIVE}`, 'not a link']) assert.equal(discussionRef(bad), '', bad)
  })
})

describe('a link opens its topic, a deleted one the "no longer exists" note in place', () => {
  it('live and archived open /t/<id>', () => {
    assert.equal(discussionPath({ task_id: LIVE, state: 'live' }), `/t/${LIVE}`)
    assert.equal(discussionPath({ task_id: LIVE, state: 'archived' }), `/t/${LIVE}`)
  })
  it('no route of its own for a deleted one: a route record ships in the initial JS (ci_initial_gzip_kb)', () => {
    assert.ok(!existsSync(join(WUI, 'src/pages/discussion-gone.vue')))
    assert.match(src('src/components/IssueDiscussions.vue'), /data-test="discussion-gone"/)
  })
  it('normalizes the hub rows, a list row reading as live', () => {
    const ds = normalizeDiscussions([{ task_id: LIVE }, { task_id: '' }, null, { task_id: LOBBY, state: 'gone', title: 'x' }])
    assert.deepEqual(ds.map((d) => [d.task_id, d.state]), [[LIVE, 'live'], [LOBBY, 'gone']])
    assert.equal(shortTopic(LIVE), 'bbbbbbbb')
    assert.deepEqual(normalizeIssue({ key: 'SPL-1' }).discussions, [])
  })
  it('each refusal token has its own message', () => {
    assert.equal(discussionErrorKey({ token: 'last_discussion' }), 'issue_discussions.error_last')
    assert.equal(discussionErrorKey({ token: 'ambiguous_discussion' }), 'issue_discussions.error_ambiguous')
    assert.equal(discussionErrorKey({ token: 'unknown_discussion' }), 'issue_discussions.error_unknown')
    assert.equal(discussionErrorKey({ token: 'discussion_required' }), 'issue_discussions.required')
    assert.equal(discussionErrorKey({ status: 500 }), 'issue_discussions.error_failed')
  })
})

describe('the mock hub keeps the rule', () => {
  it('a create needs a discussion; a short id resolves', () => {
    const m = createMockIssues()
    assert.throws(() => m.create({ title: 'x' }), (e) => e.token === 'discussion_required')
    assert.throws(() => m.create({ title: 'x', discussions: ['12345678'] }), (e) => e.token === 'unknown_discussion')
    const { issue } = m.create({ title: 'x', discussions: ['bbbbbbbb'] })
    assert.deepEqual(issue.discussions.map((d) => [d.task_id, d.state]), [[LIVE, 'live']])
  })
  it('SPL-1 links a live and a deleted topic; the last one stays', () => {
    const m = createMockIssues()
    const one = m.get('SPL-1').issue
    assert.deepEqual(one.discussions.map((d) => d.state), ['live', 'gone'])
    assert.ok(one.discussions[0].title.startsWith('Review the spool WUI'))
    m.unlink('SPL-1', MOCK_GONE_TOPIC)
    assert.throws(() => m.unlink('SPL-1', LIVE), (e) => e.token === 'last_discussion' && e.status === 409)
    const after = m.link('SPL-1', `/t/${LOBBY}`).issue
    assert.deepEqual(after.discussions.map((d) => d.task_id), [LIVE, LOBBY])
  })
})

describe('the WUI sends discussions on every create', () => {
  it('"make an issue" from a message links its topic', () => {
    assert.deepEqual(aiIssueBody({ msg_id: 'm-1', task_id: LIVE, body: 'Fix it', from: 'HUM-1' }).discussions, [LIVE])
  })
  it('the issue view: the section above the comment box, the create forms, the subtask dialog', () => {
    const page = src('src/pages/issues.vue')
    assert.match(page, /<LazyIssueDiscussions :issue-key="form\.key" :stamp="historyStamp" \/>\s*<label class="issues-field">/)
    assert.match(page, /data-test="issues-newrow-discussions"/)
    /* r15-01: the create body is composables/useIssueDetailForm.ts */
    assert.match(src('src/composables/useIssueDetailForm.ts'), /body\.discussions = draft\.discussions\.slice\(\)/)
    assert.match(page, /:discussions="parentDiscussions"/)
    assert.match(src('src/components/IssueSubtaskDialog.vue'), /body\.discussions = props\.discussions\.slice\(\)/)
  })
  it('no inline :style in the section (CSP)', () => {
    assert.doesNotMatch(src('src/components/IssueDiscussions.vue'), /:style=/)
  })
})

/* spec 153 row B5b (C23-C24): a topic shows the issues linked to it as
   chips, read through B5a's ?discussion=<task_id> filter. CONTROL: on
   origin/master before B5b issueQuery dropped `discussion` and the mock
   list did not filter by it, so the first two cases fail. */
describe('topic issue chips (spec 153 B5b)', () => {
  const DEFAULT = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
  it('issueQuery sends the discussion filter', () => {
    assert.equal(new URLSearchParams(issueQuery({ discussion: LIVE })).get('discussion'), LIVE)
    assert.equal(new URLSearchParams(issueQuery({})).has('discussion'), false)
  })
  it('the mock hub keeps only the issues linked to that topic', () => {
    const m = createMockIssues()
    assert.deepEqual(m.list(issueQuery({ discussion: LIVE })).issues.map((i) => i.key), ['SPL-1'])
    assert.deepEqual(m.list(issueQuery({ discussion: DEFAULT })).issues, [])
    assert.ok(m.list('').issues.length >= 1, 'no filter = every issue')
  })
  it('the topic page mounts the chips lazily, no :style, and the keys exist', () => {
    assert.match(src('src/pages/t/[task_id].vue'), /<LazyTopicIssueChips :task-id="taskId" \/>/)
    const chips = src('src/components/TopicIssueChips.vue')
    assert.doesNotMatch(chips, /:style=/)
    assert.match(chips, /filter: \{ discussion: id \}/)
    assert.match(chips, /t\('topic\.issue_chip_aria', \{ key: c\.key, status: c\.status \}\)/)
    const en = JSON.parse(src('i18n/locales/en.json'))
    assert.equal(en.topic.issue_chip_aria, 'Linked issue {key}: {status}')
    assert.ok(en.topic.issue_chips_label)
  })
})
