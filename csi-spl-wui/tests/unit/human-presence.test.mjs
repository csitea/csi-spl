// CLE-3448 — a signed-in human must reach the people pane, and stay there.
//
// The owner signed in on the deployed dev WUI and the presence/roster pane
// listed no human at all. Measured on dev (build 021d706, tenant t1, n=1):
// `/v1/view/roster` answered 5 members and the socket pushed
// `HUM-4@box-wui online`, while the rendered pane held 6 box agents and zero
// humans. Three separate defects stacked up, one per test below.
//
// Run: node tests/unit/human-presence.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync, readdirSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { mergeSnapshotOnline, peopleRows } from '../../src/utils/live-follow.mjs'
import { BROWSER_BOX, rosterFromView } from '../../src/utils/view-api.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (rel) => readFileSync(join(WUI, rel), 'utf8')

/* What the dev hub answered on 2026-09-22, trimmed to two of each. */
const VIEW = {
  boxes: [
    { box_id: 'box-desk', pubkey: 'k', revoked: false, online: true, agents: ['CLE-00', 'CLE-44'] },
    { box_id: BROWSER_BOX, pubkey: 'k', revoked: false, online: false, agents: [] },
  ],
  humans: [
    { human_id: 'HUM-9', avatar_file_id: 'a'.repeat(64) },
    { human_id: 'HUM-4', avatar_file_id: null },
  ],
}

describe('CLE-3448 a human in the people pane', () => {
  it('view-v1 §4.1 `humans` become peers on the browser box', () => {
    const r = rosterFromView(VIEW)
    assert.deepEqual(r.roster[BROWSER_BOX], ['HUM-9', 'HUM-4'])
    /* and NOT online: only the socket knows who holds a browser socket */
    assert.deepEqual(r.online, ['CLE-00@box-desk', 'CLE-44@box-desk'])
  })

  it('a tenant with no members leaves the browser box as the snapshot had it', () => {
    const r = rosterFromView({ boxes: [{ box_id: BROWSER_BOX, agents: [], online: false }], humans: [] })
    assert.deepEqual(r.roster[BROWSER_BOX], [])
    assert.deepEqual(rosterFromView({}).roster, {})
  })

  it('a roster refresh does not delete a human the socket called online', () => {
    const { roster, online } = rosterFromView(VIEW)
    /* the socket said so; box-wui always reads offline in the snapshot */
    const live = [...online, 'HUM-4@' + BROWSER_BOX]
    const after = mergeSnapshotOnline(live, online, roster)
    assert.ok(after.includes('HUM-4@' + BROWSER_BOX), 'human presence survives the snapshot')
    /* a real box the snapshot calls offline still loses its stale entry */
    const stale = mergeSnapshotOnline([...live, 'GRK-01@box-gone'], online, { ...roster, 'box-gone': ['GRK-01'] })
    assert.ok(!stale.includes('GRK-01@box-gone'), 'the snapshot still owns its boxes')
  })

  it('the reader is a row of the pane, marked `self`, not a missing one', () => {
    const { roster } = rosterFromView(VIEW)
    const rows = peopleRows(roster, ['CLE-00@box-desk', 'HUM-4@' + BROWSER_BOX], 'HUM-4')
    const mine = rows.find((r) => r.self)
    assert.ok(mine, 'the signed-in human has a row')
    assert.equal(mine.label, 'HUM-4@' + BROWSER_BOX)
    assert.equal(mine.online, true)
    assert.equal(rows.filter((r) => r.self).length, 1)
    /* the other member is listed too, offline, so a DM can be started */
    const other = rows.find((r) => r.id === 'HUM-9')
    assert.ok(other && other.online === false && other.self === false)
  })

  it('nobody is `self` until the socket has said who we are', () => {
    const { roster } = rosterFromView(VIEW)
    assert.equal(peopleRows(roster, [], '').filter((r) => r.self).length, 0)
  })

  it('a guest named only by a presence frame is still a row (003 FR-028)', () => {
    const rows = peopleRows({}, ['GST-1@' + BROWSER_BOX], 'HUM-4')
    assert.deepEqual(rows.map((r) => [r.label, r.online, r.self]), [['GST-1@' + BROWSER_BOX, true, false]])
    /* a bare label with no box is not a peer */
    assert.deepEqual(peopleRows({}, ['HUM-4'], ''), [])
  })

  it('one row per label, whichever source named it first', () => {
    const rows = peopleRows({ [BROWSER_BOX]: ['HUM-4'] }, ['HUM-4@' + BROWSER_BOX], 'HUM-9')
    assert.equal(rows.length, 1)
    assert.equal(rows[0].online, true)
  })
})

/*
 * The reader's row says WHOSE row it is. `i18n-parity.test.mjs` already
 * proves every locale holds the key; what it cannot see is a key that was
 * scaffolded into 19 files and translated in one - `add_keys.py` seeds the
 * other 18 with the ENGLISH value on purpose, so a forgotten
 * `splice_locales.py` leaves a catalogue that is complete and untranslated,
 * and every gate reads green.
 */
describe('CLE-3448 the reader\'s row is labelled', () => {
  it('the sidebar renders sidebar.you on the self row', () => {
    const vue = read('src/components/ChannelSidebar.vue')
    assert.match(vue, /self-row/)
    assert.match(vue, /t\('sidebar\.you'\)/)
  })

  it('all 19 locales translate it - none is left on the English placeholder', () => {
    const dir = join(WUI, 'i18n/locales')
    const files = readdirSync(dir).filter((f) => f.endsWith('.json')).sort()
    assert.equal(files.length, 19)
    const en = JSON.parse(read('i18n/locales/en.json')).sidebar.you
    assert.ok(en, 'en carries the key')
    const untranslated = files
      .filter((f) => f !== 'en.json')
      .filter((f) => JSON.parse(readFileSync(join(dir, f), 'utf8')).sidebar.you === en)
    assert.deepEqual(untranslated, [], 'these locales still hold the English value')
  })
})
