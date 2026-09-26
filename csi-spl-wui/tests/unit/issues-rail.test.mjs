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

  it('sits directly after channels in the rail, before topics', () => {
    const src = read('src/components/ChannelSidebar.vue')
    const channels = src.indexOf("{ id: 'channels', icon: 'hash'")
    const issues = src.indexOf("{ id: ISSUES_TAB, icon: 'issues', labelKey: 'sidebar.issues' }")
    const topics = src.indexOf("{ id: 'topics', icon: 'list'")
    assert.ok(channels > 0 && issues > channels && topics > issues)
    const between = src.slice(channels, issues)
    assert.equal(/\{ id:/.test(between.slice(between.indexOf('\n'))), false)
    assert.match(src, /navigateTo\(localePath\('\/issues'\)\)/)
    const flow = src.indexOf("{ id: 'flow', icon: 'waves'")
    const events = src.indexOf("{ id: EVENTS_TAB, icon: 'history', labelKey: 'sidebar.events' }")
    assert.ok(events > flow)
    assert.equal(/\{ id:/.test(src.slice(flow, events).slice(1)), false)
  })

  it('the description is only in the right pane, and the list uses the shared helpers', () => {
    const src = read('src/pages/issues.vue')
    const listAt = src.indexOf('data-test="issues-list"')
    const detailAt = src.indexOf('data-test="issues-detail"')
    assert.ok(listAt > 0 && detailAt > listAt)
    const list = src.slice(listAt, detailAt)
    assert.equal(list.includes('description'), false)
    assert.match(src.slice(detailAt), /data-test="issues-detail-body"/)
    assert.match(src, /type="datetime-local"/)
    assert.match(src, /HumanName/)
    assert.match(src, /groupIssues\(/)
    assert.match(src, /api\.listIssues\(/)
    const send = src.slice(src.indexOf('async function sendComment'))
    assert.match(send, /live\.ensure\(\)/)
    assert.match(send, /sock\.send\(/)
    assert.match(send, /api\.sendMessage\(/)
    assert.match(src, /route\.query\.issue/)
    assert.match(src, /history\.replaceState/)
    assert.match(src, /api\.getIssue\(/)
    assert.match(src, /pane="issue"/)
    assert.match(src, /saveIssuePane/)
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
    assert.equal(enLeaves['level.1'], 'XS')
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
