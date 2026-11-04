// SPL-4789 (owner HUM-10, t1 ef94396b msgs 61bf7791, dd164168): a release
// note's issues and the discussions they came from, as links into the
// workspace that owns them; "unknown" for a commit with neither.
// utils/release-issue-links.mjs is pure:
//   1 an issue and its discussion in the page's own workspace -> app paths
//   2 another workspace's issue -> an absolute URL on its host (tenant hosts
//     on), none with tenant hosts off; never the page's own path
//   3 a discussion the viewer may not open -> no id, no title, no href
//   4 unknown: no issues, or none found with a discussion; a missing key
//     beside a real one is not unknown
//   5 the same topic under two issues shows once
//
// Run: node tests/unit/release-issue-links.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { releaseIssueLinks } from '../../src/utils/release-issue-links.mjs'

const TOPIC = 'ef94396b-ea67-445b-a9d5-9f6070177e08'
const OTHER = '0b1c2d3e-4f50-4617-8293-a4b5c6d7e8f9'
const issue = (key, tenant, ds, found = true) => ({ key, tenant, found, member: true, discussions: ds })
const open = (id, title) => ({ task_id: id, title, state: 'live', can_open: true })
const CTX = { pageTenant: 't1', siteUrl: 'https://spool.example.com', apexTenant: 't1', pathFor: (p) => '/fi' + p }

describe('releaseIssueLinks', () => {
  it('1 the page\'s own workspace: app paths through pathFor', () => {
    const l = releaseIssueLinks([issue('SPL-4789', 't1', [open(TOPIC, 'we need to enforce the linking')])], CTX)
    assert.equal(l.unknown, false)
    assert.deepEqual(l.issues, [{ key: 'SPL-4789', tenant: 't1', found: true, href: '/fi/issues?issue=SPL-4789', external: false }])
    assert.equal(l.discussions.length, 1)
    assert.equal(l.discussions[0].href, '/fi/t/' + TOPIC)
    assert.equal(l.discussions[0].title, 'we need to enforce the linking')
    assert.equal(l.discussions[0].external, false)
  })

  it('2 another workspace: its own host, never the viewer\'s path', () => {
    const l = releaseIssueLinks([issue('SPL-4789', 't1', [open(TOPIC, 'x')])], { ...CTX, pageTenant: 'csitea' })
    assert.equal(l.issues[0].href, 'https://spool.example.com/issues?issue=SPL-4789')
    assert.equal(l.issues[0].external, true)
    assert.equal(l.discussions[0].href, 'https://spool.example.com/t/' + TOPIC)
    const ws = releaseIssueLinks([issue('SPL-1', 'ws-b', [open(TOPIC, 'x')])], { ...CTX, pageTenant: 'csitea' })
    assert.equal(ws.issues[0].href, 'https://ws-b.spool.example.com/issues?issue=SPL-1')
    // CONTROL: tenant hosts off -> no URL at all, not a path into the wrong workspace
    const off = releaseIssueLinks([issue('SPL-1', 't1', [open(TOPIC, 'x')])], { ...CTX, pageTenant: 'csitea', siteUrl: '' })
    assert.equal(off.issues[0].href, '')
    assert.equal(off.discussions[0].href, '')
  })

  it('3 a discussion the viewer may not open: no id, no title, no link', () => {
    const l = releaseIssueLinks([issue('SPL-7', 't1', [{ can_open: false }, { task_id: TOPIC, title: 'leaked?', can_open: false }])], { ...CTX, pageTenant: 'csitea' })
    assert.equal(l.unknown, false, 'the issue has discussions, the viewer just cannot open them')
    assert.equal(l.discussions.length, 2)
    for (const d of l.discussions) {
      assert.equal(d.canOpen, false)
      assert.equal(d.href, '')
      assert.equal(d.title, '')
    }
  })

  it('4 unknown: nothing cited, or nothing that resolves', () => {
    assert.equal(releaseIssueLinks([], CTX).unknown, true)
    assert.equal(releaseIssueLinks(undefined, CTX).unknown, true)
    assert.equal(releaseIssueLinks(null, CTX).issues.length, 0)
    const miss = releaseIssueLinks([issue('SPL-99999', 't1', [], false)], CTX)
    assert.equal(miss.unknown, true)
    assert.equal(miss.issues[0].href, '', 'a key with no issue links nowhere')
    const mix = releaseIssueLinks([issue('SPL-99999', 't1', [], false), issue('SPL-10', 't1', [open(TOPIC, 'x')])], CTX)
    assert.equal(mix.unknown, false)
    assert.deepEqual(mix.issues.map((i) => i.found), [false, true])
  })

  it('5 one topic under two issues shows once', () => {
    const l = releaseIssueLinks([issue('SPL-1', 't1', [open(TOPIC, 'a')]), issue('SPL-2', 't1', [open(TOPIC, 'a'), open(OTHER, 'b')])], CTX)
    assert.deepEqual(l.discussions.map((d) => d.id), [TOPIC, OTHER])
  })
})
