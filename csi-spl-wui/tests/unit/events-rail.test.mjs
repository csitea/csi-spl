// The Event log (005 FR-017): SPL-3250 (owner HUM-10, t1 463d7692, msgs
// 24316f72 + ac1c95f9: "the event log section should be come just one tab of
// the monitoring section", "on both mobile and the desktop") took it off the
// rail into Monitoring -> Events; /events selects Monitoring, and the shipper
// plugin is wired to the journal.
// Control: on origin/master a1d2ced73 the first two cases fail (the rail has
// an Events entry, /events selects 'events', the sidebar opens /events).
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

import * as sidebarTabs from '../../src/utils/sidebar-tabs.mjs'
import { channelSidebarSrc } from './lib/channel-sidebar-src.mjs'
import { importTs } from './lib/load-ts.mjs'
const { RAIL_TABS, RAIL_RETIRED, DEFAULT_RAIL_ORDER, parseRailOrder, wireRailOrder } = await importTs('src/utils/rail-order.ts')

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (rel) => readFileSync(join(WUI, rel), 'utf8')

describe('Event log: a Monitoring tab, no rail tab (SPL-3250)', () => {
  it('case 1: the rail has no Events entry, on phone and desktop; the hub keeps its id', () => {
    assert.ok(!RAIL_TABS.some((t) => t.id === 'events'), 'no Events rail tab')
    assert.ok(!DEFAULT_RAIL_ORDER.includes('events'))
    assert.ok(RAIL_RETIRED.includes('events'), 'retired like agents/boxes: the hub still admits it')
    /* a stored order that holds events is drawn without it, and saved with it back */
    const stored = ['events', 'channels', 'dm', 'issues', 'topics', 'flow', 'people', 'agents', 'boxes', 'calendar', 'monitoring', 'reporting', 'archive']
    assert.ok(!parseRailOrder(stored).includes('events'))
    assert.equal(wireRailOrder(parseRailOrder(stored)).filter((id) => id === 'events').length, 1)
    assert.equal(sidebarTabs.EVENTS_TAB, undefined)
    const src = channelSidebarSrc()
    assert.doesNotMatch(src, /sidebar-panel-events|EventLogPane|localePath\('\/events'\)/)
    assert.doesNotMatch(read('src/composables/useSidebarRailNav.ts'), /'\/events'/)
  })

  it('case 4: /events (any locale) selects Monitoring; it is no tab of its own', () => {
    assert.equal(sidebarTabs.tabForPath('/events'), 'monitoring')
    assert.equal(sidebarTabs.tabForPath('/fi/events'), 'monitoring')
    assert.equal(sidebarTabs.tabForPath('/monitoring/events'), 'monitoring')
    assert.equal(sidebarTabs.routeForTab('events'), null)
  })

  it('the shipper plugin feeds from the journal and follows the session', () => {
    const src = read('src/plugins/event-log.client.ts')
    assert.match(src, /bindShipperToJournal\(shipper, \{ getErrors, subscribeErrors \}\)/)
    assert.match(src, /session: \(\) => session\.state/)
    assert.match(src, /shipper\.sessionChanged\(\)/)
    assert.equal(/noteError/.test(src.replace(/^\s*\/\/.*$/gm, '')), false, 'the plugin never writes the journal')
  })
})
