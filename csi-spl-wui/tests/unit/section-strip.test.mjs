// CLE-77886 (owner, t1 topic ac0fa400): on a phone every section keeps the
// one section strip; a section page shows it instead of a bare title, and
// the strip rolls endlessly.
//
// Run: node tests/unit/section-strip.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { chatKind, isSectionPage, loopPosition, railLinkSection, sectionExitPath } from '../../src/utils/section-strip.mjs'
import { MONITORING_TABS } from '../../src/utils/monitoring-tabs.mjs'
import { REPORTING_TABS } from '../../src/utils/reporting-tabs.mjs'
import { COSTS_PAGES } from '../../src/utils/reporting-costs.mjs'
import { pageRoutes } from '../e2e/lib/page-routes.mjs'

const PAGES = join(dirname(fileURLToPath(import.meta.url)), '../../src/pages')

describe('isSectionPage', () => {
  it('every section page the owner named, with or without a locale', () => {
    for (const p of ['/issues', '/people', '/monitoring/boxes', '/monitoring/agents', '/monitoring/events', '/help', '/docs', '/tenant-settings', '/archive', '/', '/fi/issues', '/issues?epic=SPL-1', '/people/']) {
      assert.equal(isSectionPage(p), true, p)
    }
  })
  it('a drill-down keeps its own header and Back', () => {
    for (const p of ['/channel/general', '/dm/HUM-2', '/people/HUM-2', '/monitoring/agents/CLE-1', '/monitoring/boxes/b1', '/agents', '/boxes', '/help/how-to-post', '/docs/README.md', '/tenant-settings/members', '/t/abc', '/search']) {
      assert.equal(isSectionPage(p), false, p)
    }
  })
})

/* SPL-3785 (owner HUM-10, t1 c3e53990: not "jump on and off based on the
   tab"): every tab of a section is its own page, read off the tab lists and
   the file tree, never a list kept by hand */
describe('isSectionPage covers every tab, derived', () => {
  it('every Monitoring and Reporting tab is a section page; one level under it is a drill-down', () => {
    const tabs = [...MONITORING_TABS, ...REPORTING_TABS]
    assert.ok(tabs.length >= 12, `tab lists read: ${tabs.length}`)
    for (const t of tabs) {
      assert.equal(isSectionPage(t.path), true, t.path)
      assert.equal(isSectionPage(`/fi${t.path}`), true, `/fi${t.path}`)
      assert.equal(isSectionPage(`${t.path}/some-id`), false, `${t.path}/some-id`)
    }
  })
  it('each page of the Costs tab bar (/reporting/costs/paid, two segments) is a section page; under it a drill-down', () => {
    assert.ok(COSTS_PAGES.length >= 4, `costs pages read: ${COSTS_PAGES.length}`)
    assert.equal(isSectionPage('/reporting/costs/paid'), true, '/reporting/costs/paid')
    for (const c of COSTS_PAGES) {
      assert.equal(isSectionPage(c.path), true, c.path)
      assert.equal(isSectionPage(`/fi${c.path}`), true, `/fi${c.path}`)
      assert.equal(isSectionPage(`${c.path}/some-id`), false, `${c.path}/some-id`)
    }
  })
  it('every page file under Monitoring and Reporting: a plain page is the section, a [param] page a drill-down', () => {
    const rows = pageRoutes(PAGES).filter((r) => /^\/(monitoring|reporting)(\/|$)/.test(r.path))
    assert.ok(rows.length >= MONITORING_TABS.length + REPORTING_TABS.length, `pages walked: ${rows.length}`)
    for (const r of rows) {
      const sample = r.path.replace(/:[^/]+/g, 'x-1')
      assert.equal(isSectionPage(sample), !r.dynamic, `${r.file} -> ${sample}`)
    }
  })
})

describe('railLinkSection', () => {
  it('names the rail link a route belongs to', () => {
    assert.equal(railLinkSection('/help'), 'help')
    assert.equal(railLinkSection('/fi/help/how-to-post'), 'help')
    assert.equal(railLinkSection('/tenant-settings/members'), 'settings')
    assert.equal(railLinkSection('/docs'), 'docs')
    assert.equal(railLinkSection('/fi/docs/csi-spl-doc/specs/072-x/spec.md'), 'docs')
    assert.equal(railLinkSection('/workspace/docs'), 'docs')
    assert.equal(railLinkSection('/fi/workspace/docs'), 'docs')
    assert.equal(railLinkSection('/workspace'), '')
    assert.equal(railLinkSection('/issues'), '')
  })
})

describe('loopPosition', () => {
  it('keeps the view inside the middle copy, never at an end', () => {
    assert.equal(loopPosition(500, 700), 500)
    assert.equal(loopPosition(100, 700), 800)
    assert.equal(loopPosition(1100, 700), 400)
    assert.equal(loopPosition(350, 700), 350)
    assert.equal(loopPosition(1050, 700), 1050)
  })
  it('no set width (not measured / nothing overflows) leaves it alone', () => {
    assert.equal(loopPosition(5, 0), 5)
    assert.equal(loopPosition(5, NaN), 5)
  })
})

describe('the way out of a section page (HUM-24, 7930dfbf)', () => {
  it('chatKind names the conversation a reader left', () => {
    assert.equal(chatKind('/channel/general'), 'channel')
    assert.equal(chatKind('/fi/lobby'), 'channel')
    assert.equal(chatKind('/dm/HUM-2'), 'dm')
    assert.equal(chatKind('/issues'), '')
    assert.equal(chatKind('/people/HUM-2'), '')
  })
  it('Channels -> the last channel, DMs -> the last DM, Flow / X -> the last conversation, else the lobby', () => {
    const last = { channel: '/channel/alerts?topic=a', dm: '/dm/HUM-2', chat: '/dm/HUM-2' }
    assert.equal(sectionExitPath(last, 'channels'), '/channel/alerts?topic=a')
    assert.equal(sectionExitPath(last, 'dm'), '/dm/HUM-2')
    assert.equal(sectionExitPath(last, 'flow'), '/dm/HUM-2')
    assert.equal(sectionExitPath(last), '/dm/HUM-2')
    assert.equal(sectionExitPath({}, 'channels'), '/lobby')
    assert.equal(sectionExitPath({}), '/lobby')
    assert.equal(sectionExitPath({}, 'dm'), '')
  })
})
