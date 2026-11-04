// SPL-4798 (owner HUM-10, t1 0c2d08a2, msg ea369ab0): a lane row's discussion,
// issue and dispatch-<topic8> task render as links on Monitoring -> Lanes and
// -> Topics through the one `type:id` renderer (utils/note-links.mjs
// noteLinkHref), at render time. The row gives a typed ref
// (utils/monitoring-lanes.mjs laneTopicRef / laneIssueRef); the host is the
// lane's workspace's (tenant-host.mjs). CONTROL: the pages on master print a
// task id and another workspace's topic as plain text, and the source checks
// below fail there.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { LANE_UNKNOWN, laneIssueRef, laneTopicRef } from '../../src/utils/monitoring-lanes.mjs'
import { noteLinkHref } from '../../src/utils/note-links.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (rel) => readFileSync(join(WUI, rel), 'utf8')
const UUID = '0449a2f3-6a49-45c2-9ba2-de7a1b2c3d4e'
const SITE = 'https://spool.example.com'
/* the operator workspace's page (spool-hub), tenant hosts on, t1 at the apex */
const HOSTS = { tenant: 'spool-hub', siteUrl: SITE, apexTenant: 't1', pageOrigin: 'https://spool-hub.spool.example.com' }
const OFF = { tenant: 'mock', siteUrl: '', apexTenant: 't1', pageOrigin: 'http://localhost:3000' }
const href = (ref, ctx = HOSTS) => (ref ? noteLinkHref(ref, ctx).href : '')

describe('the discussion ref (laneTopicRef)', () => {
  it('a topic uuid the hub placed in another workspace opens on that workspace\'s host (the screenshot)', () => {
    const lane = { topicId: UUID, topicTitle: '', workspace: 'w2' }
    assert.deepEqual(laneTopicRef(lane, 'spool-hub'), { kind: 'topic', workspace_id: 'w2', ref: UUID })
    assert.equal(href(laneTopicRef(lane, 'spool-hub')), `https://w2.spool.example.com/t/${UUID}`)
  })
  it('a titled topic of the page\'s workspace opens here', () => {
    const to = noteLinkHref(laneTopicRef({ topicId: UUID, topicTitle: 'T', workspace: 'spool-hub' }, 'spool-hub'), HOSTS)
    assert.equal(to.href, `https://spool-hub.spool.example.com/t/${UUID}`)
    assert.equal(to.here, true)
  })
  it('the apex tenant\'s topic opens on the apex', () => {
    assert.equal(href(laneTopicRef({ topicId: UUID, workspace: 't1' }, 'spool-hub')), `${SITE}/t/${UUID}`)
  })
  it('dispatch-<topic8> is a spool task of the page\'s workspace: /t/<task>', () => {
    const ref = laneTopicRef({ topicId: 'dispatch-0C2D08A2', workspace: 'spool-hub' }, 'spool-hub')
    assert.deepEqual(ref, { kind: 'topic', workspace_id: 'spool-hub', ref: 'dispatch-0c2d08a2' })
    assert.equal(href(ref), 'https://spool-hub.spool.example.com/t/dispatch-0c2d08a2')
    assert.equal(href(ref, OFF), '', 'its workspace is spool-hub, not the page\'s mock: no host is guessed')
    assert.equal(href(laneTopicRef({ topicId: 'dispatch-0c2d08a2', workspace: 'mock' }, 'mock'), OFF), 'http://localhost:3000/t/dispatch-0c2d08a2')
  })
  it('the locale prefix rides the path', () => {
    const ref = laneTopicRef({ topicId: UUID, workspace: 'w2' }, 'spool-hub')
    assert.equal(noteLinkHref(ref, { ...HOSTS, pathFor: (p) => '/fi' + p }).href, `https://w2.spool.example.com/fi/t/${UUID}`)
  })
  it('CONTROL: `unknown`, an 8-hex short id, a non-task word, none and an untitled uuid of the page\'s own workspace stay text', () => {
    assert.equal(LANE_UNKNOWN, 'unknown')
    assert.equal(laneTopicRef({ topicId: 'unknown', workspace: 'spool-hub' }, 'spool-hub'), null)
    assert.equal(laneTopicRef({ topicId: 'UNKNOWN', workspace: 'w2' }, 'spool-hub'), null)
    assert.equal(laneTopicRef({ topicId: '0c2d08a2', workspace: 'spool-hub' }, 'spool-hub'), null)
    assert.equal(laneTopicRef({ topicId: 'dispatch-0c2d08a2x', workspace: 'spool-hub' }, 'spool-hub'), null)
    assert.equal(laneTopicRef({ topicId: '', workspace: 'spool-hub' }, 'spool-hub'), null)
    /* the hub found it in no workspace and sent no title: it names nothing */
    assert.equal(laneTopicRef({ topicId: UUID, topicTitle: '', workspace: 'spool-hub' }, 'spool-hub'), null)
  })
  it('CONTROL: tenant hosts off, another workspace\'s topic stays text (no host guessed)', () => {
    assert.equal(href(laneTopicRef({ topicId: UUID, workspace: 'w2' }, 'mock'), OFF), '')
  })
})

describe('the issue ref (laneIssueRef)', () => {
  const lane = { workspace: 'w2' }
  it('a key with a status is the page\'s workspace\'s: SPL-4791 opens there', () => {
    assert.equal(href(laneIssueRef({ key: 'SPL-4791', status: 'wip' }, lane, 'spool-hub')), 'https://spool-hub.spool.example.com/issues?issue=SPL-4791')
  })
  it('a key of another prefix opens in the lane\'s workspace: DVN-3 on w2', () => {
    assert.equal(href(laneIssueRef({ key: 'DVN-3', status: '' }, lane, 'spool-hub')), 'https://w2.spool.example.com/issues?issue=DVN-3')
  })
  it('CONTROL: another prefix on a lane of the page\'s own workspace, `unknown` and a bad key stay text', () => {
    assert.equal(laneIssueRef({ key: 'DVN-3', status: '' }, { workspace: 'spool-hub' }, 'spool-hub'), null)
    assert.equal(laneIssueRef({ key: 'unknown', status: '' }, lane, 'spool-hub'), null)
    assert.equal(laneIssueRef({ key: 'spl 1', status: 'wip' }, lane, 'spool-hub'), null)
    assert.equal(href(laneIssueRef({ key: 'DVN-3', status: '' }, { workspace: 'w2' }, 'mock'), OFF), '')
  })
})

describe('both pages render through that one renderer (no second one)', () => {
  const composable = read('src/composables/useLaneLinks.ts')
  it('the composable builds the href with noteLinkHref', () => {
    assert.match(composable, /import \{ noteLinkHref[^}]*\} from '~\/utils\/note-links\.mjs'/)
    assert.match(composable, /noteLinkHref\(ref, ctx\.value\)/)
  })
  for (const page of ['src/pages/monitoring/lanes/index.vue', 'src/pages/monitoring/topics/index.vue']) {
    const src = read(page)
    it(`${page}: the discussion and the issues go through laneTopicRef / laneIssueRef + useLaneLinks`, () => {
      assert.match(src, /useLaneLinks\(\)/)
      assert.match(src, /laneTopicRef\(/)
      assert.match(src, /laneIssueRef\(/)
      assert.doesNotMatch(src, /laneTopicPath|laneIssuePath/, 'the old this-workspace-only links are gone from the page')
      assert.doesNotMatch(src, /from '~\/utils\/(?:note-links|tenant-host)|tenantOrigin\(|noteLinkHref\(/, 'no host built in the page itself')
    })
  }
})
