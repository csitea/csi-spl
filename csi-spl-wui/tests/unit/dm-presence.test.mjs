// CLE-77862 (HUM-24): "isn't this green dot MY status? to see the other
// person's I have to scroll back up". A DM header prints the PEER's presence
// in words beside the peer's name (online / last seen ... / offline · queued),
// and the reader's own dot in the sidebar's "you" row says it is the reader's.
// Run: node --test tests/unit/dm-presence.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync, readdirSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { dmPresence } from '../../src/utils/dm-presence.mjs'
import { isoDateTime } from '../../src/utils/date-iso.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (p) => readFileSync(join(WUI, p), 'utf8')

describe('dmPresence: what the DM header says about the peer', () => {
  it('online wins over any last-seen time', () => {
    assert.deepEqual(dmPresence({ online: true, lastSeen: '2026-09-30T10:00:00Z' }), { status: 'on', key: 'pages.dm.online', params: {} })
  })

  it('offline with a last-seen time names it, as YYYY-MM-DD HH:MM', () => {
    const at = '2026-09-30T10:05:00Z'
    assert.deepEqual(dmPresence({ online: false, lastSeen: at }), { status: 'off', key: 'pages.dm.last_seen', params: { when: isoDateTime(at) } })
  })

  it('offline and never seen (or an unreadable time) keeps "offline · queued"', () => {
    for (const lastSeen of ['', undefined, 'not-a-time']) {
      assert.deepEqual(dmPresence({ online: false, lastSeen }), { status: 'off', key: 'pages.dm.offline_queued', params: {} })
    }
  })
})

describe('the DM page and the sidebar', () => {
  const dm = read('src/pages/dm/[peer].vue')
  const side = read('src/components/ChannelSidebar.vue')

  it('the DM header reads the peer: online set, a member last_seen, an agent box hello', () => {
    assert.match(dm, /roster\.humansDetail\[String\(id \|\| ''\)\]\?\.last_seen/)
    assert.match(dm, /box !== BROWSER_BOX \? roster\.boxes\[box\]\?\.last_hello_at/)
    assert.match(dm, /dmPresence\(\{ online: online\.value, lastSeen: lastSeen \|\| '' \}\)/)
  })

  it("the reader's own dot is labelled as theirs (tooltip + accessible name)", () => {
    assert.match(side, /data-test="self-status-dot"[\s\S]{0,80}:title="selfStatus"[\s\S]{0,40}:aria-label="selfStatus"/)
    assert.match(side, /sidebar\.your_status_online' : 'sidebar\.your_status_offline'/)
  })

  it('every locale carries the new words, {when} kept', () => {
    const dir = join(WUI, 'i18n/locales')
    const files = readdirSync(dir).filter((f) => f.endsWith('.json'))
    assert.equal(files.length, 19)
    for (const f of files) {
      const d = JSON.parse(readFileSync(join(dir, f), 'utf8'))
      assert.match(d.pages.dm.last_seen, /\{when\}/, f)
      assert.ok(d.sidebar.your_status_online && d.sidebar.your_status_offline, f)
      assert.notEqual(d.sidebar.your_status_online, d.sidebar.your_status_offline, f)
    }
  })
})
