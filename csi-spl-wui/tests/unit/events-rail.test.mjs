// The Event log rail button (005 FR-017): directly after Flow,
// /events selects it, and the shipper plugin is wired to the journal.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

import { EVENTS_TAB, tabForPath } from '../../src/utils/sidebar-tabs.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (rel) => readFileSync(join(WUI, rel), 'utf8')

describe('Event log rail tab', () => {
  it('/events selects the events tab', () => {
    assert.equal(EVENTS_TAB, 'events')
    assert.equal(tabForPath('/events'), 'events')
    assert.equal(tabForPath('/fi/events'), 'events')
  })

  it('follows flow and archive; People and Agents follow it (CLE-77794)', () => {
    /* SPL-979: the default order lives in utils/rail-order.mjs RAIL_TABS;
       owner 2026-09-27 (topic 116646c8) left events out of the named order, so
       it sits after archive; CLE-77794 added People and Agents after it. */
    const tabs = read('src/utils/rail-order.mjs')
    const flow = tabs.indexOf("{ id: 'flow', icon: 'waves'")
    const archive = tabs.indexOf("{ id: 'archive', icon: 'archive'")
    const events = tabs.indexOf("{ id: 'events', icon: 'history', labelKey: 'sidebar.events' }")
    const people = tabs.indexOf("{ id: 'people', icon: 'users'")
    const agents = tabs.indexOf("{ id: 'agents', icon: 'bot'")
    assert.ok(flow > 0 && archive > flow && events > archive, 'events entry follows archive')
    assert.ok(people > events && agents > people, 'People then Agents follow events')
    const src = read('src/components/ChannelSidebar.vue')
    assert.match(src, /navigateTo\(localePath\('\/events'\)\)/)
  })

  it('the shipper plugin feeds from the journal and follows the session', () => {
    const src = read('src/plugins/event-log.client.ts')
    assert.match(src, /bindShipperToJournal\(shipper, \{ getErrors, subscribeErrors \}\)/)
    assert.match(src, /session: \(\) => session\.state/)
    assert.match(src, /shipper\.sessionChanged\(\)/)
    assert.equal(/noteError/.test(src.replace(/^\s*\/\/.*$/gm, '')), false, 'the plugin never writes the journal')
  })
})
