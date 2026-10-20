// The Issues rail tab is third, directly after Channels (owner, 2026-09-26).
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync, readdirSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { ISSUES_TAB, SIDE_TABS, tabForPath } from '../../src/utils/sidebar-tabs.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (rel) => readFileSync(join(WUI, rel), 'utf8')

describe('Issues rail tab', () => {
  it('/issues selects the issues tab and leaves the four lists alone', () => {
    assert.equal(ISSUES_TAB, 'issues')
    assert.equal(SIDE_TABS.includes('issues'), false)
    assert.equal(tabForPath('/issues'), 'issues')
    assert.equal(tabForPath('/fi/issues'), 'issues')
    assert.equal(tabForPath('/events'), 'events')
    assert.equal(tabForPath('/channel/lobby'), 'channels')
  })

  it('is the third tab, after channels and direct messages, before flow', () => {
    /* SPL-979: the default order lives in utils/rail-order.mjs RAIL_TABS;
       owner 2026-09-27: channels, direct messages, issues, ...; the Topics
       tab that followed Issues is gone (t1 e4bfddb1), Flow follows now */
    const tabs = read('src/utils/rail-order.mjs')
    const src = read('src/components/ChannelSidebar.vue')
    const channels = tabs.indexOf("{ id: 'channels', icon: 'hash'")
    const dm = tabs.indexOf("{ id: 'dm', icon: 'messages'")
    const issues = tabs.indexOf("{ id: 'issues', icon: 'issues', labelKey: 'sidebar.issues' }")
    const flowAt = tabs.indexOf("{ id: 'flow', icon: 'waves'")
    assert.ok(channels > 0 && dm > channels && issues > dm && flowAt > issues)
    assert.equal(tabs.includes("{ id: 'topics'"), false, 'no Topics tab (t1 e4bfddb1)')
    const between = tabs.slice(dm, issues)
    assert.equal(/\{ id:/.test(between.slice(between.indexOf('\n'))), false)
    assert.match(src, /navigateTo\(localePath\('\/issues'\)\)/)
    assert.equal(src.includes('sidebar-issues-open'), false)
    assert.equal(src.includes('issues.all_issues'), false)
    assert.match(src, /LazyIssueEpicsPanel/)
    assert.match(src, /sidebar--rail/)
    const flow = tabs.indexOf("{ id: 'flow', icon: 'waves'")
    const archive = tabs.indexOf("{ id: 'archive', icon: 'archive'")
    const events = tabs.indexOf("{ id: 'events', icon: 'history', labelKey: 'sidebar.events' }")
    /* owner 2026-09-27: flow, archive, then the Event log last */
    assert.ok(archive > flow && events > archive)
    assert.equal(/\{ id:/.test(tabs.slice(archive, events).slice(1)), false)
  })

  it('the description is only in the opened issue, and the list uses the shared helpers', () => {
    const src = read('src/pages/issues.vue')
    const listAt = src.indexOf('data-test="issues-list"')
    const detailAt = src.indexOf('data-test="issues-detail"')
    assert.ok(listAt > 0 && detailAt > listAt)
    const list = src.slice(listAt, detailAt)
    assert.equal(list.includes('description'), false)
    // SPL-975: the description is IssueDescription (rendered markdown, click or e edits)
    assert.match(src.slice(detailAt), /<IssueDescription\b/)
    assert.match(read('src/components/IssueDescription.vue'), /data-test="issues-detail-body"/)
    // owner 2026-09-26 (topics 32a56460, 778ad161): a calendar plus a 24-hour time,
    // YYYY-MM-DD HH:MM, no datetime-local (AM/PM); the picker is DeadlinePicker.vue
    assert.match(src, /<DeadlinePicker[\s\S]*test-id="issues-deadline"[\s\S]*time-test-id="issues-deadline-time"/)
    assert.equal(/type="datetime-local"/.test(src), false)
    assert.equal(src.includes('issues-search'), false)
    assert.match(src, /HumanName/)
    /* r15-01: the rows the sheet shows are composables/useIssueFilters.ts */
    assert.match(read('src/composables/useIssueFilters.ts'), /groupIssues\(/)
    assert.match(src, /api\.listIssues\(/)
    // the discussion box and the phone dock share postComment (r13-06: composables/useIssueComments.ts)
    const comments = read('src/composables/useIssueComments.ts')
    assert.match(comments, /async function postComment\([^)]*\) \{\n\s+await sendToDiscussion\(/)
    const send = comments.slice(comments.indexOf('async function sendToDiscussion'))
    assert.match(send, /live\.ensure\(\)/)
    assert.match(send, /sock\.send\(/)
    assert.match(send, /api\.sendMessage\(/)
    // r13-06: opening an issue and its ?issue= entry are composables/useIssueOpen.ts
    const open = read('src/composables/useIssueOpen.ts')
    assert.match(open, /route\.query\.issue/)
    assert.match(open, /history\.replaceState/)
    assert.match(open, /api\.getIssue\(/)
    // SPL-1027: no right pane (no divider, no stored width); > 820 px the issue is a modal
    assert.doesNotMatch(src, /pane="issue"/)
    assert.doesNotMatch(src, /saveIssuePane/)
    assert.match(src, /<IssueDetailFrame[\s\S]*?:modal="!phone"/)
    assert.match(read('src/components/IssueDetailFrame.vue'), /<UiDialog v-if="modal"[^>]*size="lg"/)
    assert.match(open, /router\.push\(\{ query: \{ \.\.\.currentQuery\(\), issue: key \} \}\)/)
  })
})

describe('issues strings in all 19 locales', () => {
  const dir = join(WUI, 'i18n/locales')
  const files = readdirSync(dir).filter((f) => f.endsWith('.json')).sort()
  const en = JSON.parse(readFileSync(join(dir, 'en.json'), 'utf8'))

  function leaves(obj, prefix = '') {
    const out = {}
    for (const [k, v] of Object.entries(obj || {})) {
      const full = prefix ? `${prefix}.${k}` : k
      if (v && typeof v === 'object') Object.assign(out, leaves(v, full))
      else out[full] = v
    }
    return out
  }

  it('every locale has the same issues keys, and prose is not a copy of English', () => {
    assert.equal(files.length, 19)
    const enLeaves = leaves(en.issues)
    assert.equal(enLeaves['status.in_progress'], 'In Progress')
    assert.equal(enLeaves['priority.1'], 'Urgent')
    assert.equal(enLeaves['level.1'], 'Epic / Feature') // SPL-949: level is the tree's
    assert.equal(en.sidebar.issues, 'Issues')
    for (const f of files) {
      const data = JSON.parse(readFileSync(join(dir, f), 'utf8'))
      const got = leaves(data.issues)
      assert.deepEqual(Object.keys(got).sort(), Object.keys(enLeaves).sort(), f)
      assert.equal(typeof data.sidebar.issues, 'string', f)
      for (const [k, v] of Object.entries(got)) {
        assert.equal(typeof v, 'string', `${f} ${k}`)
        assert.equal(String(v).includes('@'), false, `${f} ${k}`)
        assert.equal(/<[A-Za-z/!]/.test(String(v)), false, `${f} ${k}`)
        const forms = (s) => String(s).split('|').length
        assert.equal(forms(v), forms(enLeaves[k]), `${f} ${k}`)
        for (const token of ['{name}', '{n}']) {
          if (String(enLeaves[k]).includes(token)) assert.equal(String(v).includes(token), true, `${f} ${k} ${token}`)
        }
      }
      if (f !== 'en.json') {
        assert.notEqual(got.title, enLeaves.title, f)
        assert.notEqual(got['status.in_progress'], enLeaves['status.in_progress'], f)
        assert.notEqual(data.sidebar.issues, en.sidebar.issues, f)
      }
    }
  })
})
