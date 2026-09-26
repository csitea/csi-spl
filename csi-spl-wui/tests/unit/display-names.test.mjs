// Owner, 2026-09-25: "the display name should be visible and not the member
// id", and "each user should be able to change their display name".
// Run: node --test tests/unit/display-names.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { humanNamesFromView, loadAvatarFiles, loadHumanNames, resetAvatarFiles } from '../../src/utils/avatar.mjs'
import { personLabel } from '../../src/utils/channel-feed.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (rel) => readFileSync(join(WUI, rel), 'utf8')

describe('humanNamesFromView', () => {
  it('maps each member to the name they chose, and leaves out a member with none', () => {
    const data = { humans: [
      { human_id: 'HUM-9', display_name: '  FirstName  ', avatar_file_id: null },
      { human_id: 'HUM-4', display_name: null },
      { human_id: 'HUM-5', display_name: '' },
      { human_id: 'CLE-1', display_name: 'not a member' },
    ] }
    assert.deepEqual(humanNamesFromView(data), { 'HUM-9': 'FirstName' })
    assert.deepEqual(humanNamesFromView(null), {})
  })
})

describe('personLabel', () => {
  it('CLE-34987: a chosen name loses its bidi controls, so it cannot reorder the row', () => {
    const RLO = String.fromCharCode(0x202e)
    const PDI = String.fromCharCode(0x2069)
    assert.equal(personLabel('HUM-7', 'box-wui', { 'HUM-7': `${RLO}nimda${PDI}` }), 'nimda')
    // only controls: nothing left -> the id, never an empty label
    assert.equal(personLabel('HUM-7', 'box-wui', { 'HUM-7': `${RLO}${PDI}` }), 'HUM-7@box-wui')
  })

  const names = { 'HUM-9': 'FirstName' }
  it('is the chosen name for a human on the browser box, or with no box', () => {
    assert.equal(personLabel('HUM-9', 'box-wui', names), 'FirstName')
    assert.equal(personLabel('HUM-9', undefined, names), 'FirstName')
  })
  it('is the id when there is no name, and always for an agent', () => {
    assert.equal(personLabel('HUM-4', 'box-wui', names), 'HUM-4@box-wui')
    assert.equal(personLabel('CLE-120', 'box-desk', { 'CLE-120': 'x' }), 'CLE-120@box-desk')
    assert.equal(personLabel('HUM-9', 'box-desk', names), 'HUM-9@box-desk')
    assert.equal(personLabel('HUM-9', 'box-wui', null), 'HUM-9@box-wui')
  })
})

describe('loadHumanNames', () => {
  it('reads the names from the same roster fetch as the pictures', async () => {
    resetAvatarFiles()
    const calls = []
    const fetchFn = async (url) => {
      calls.push(url)
      return { ok: true, json: async () => ({ humans: [{ human_id: 'HUM-3', display_name: 'Alice' }] }) }
    }
    const o = { base: 'http://t1.test', fetchFn }
    const [files, names] = await Promise.all([loadAvatarFiles(o), loadHumanNames(o)])
    assert.deepEqual(files, {})
    assert.deepEqual(names, { 'HUM-3': 'Alice' })
    assert.equal(calls.length, 1)
    resetAvatarFiles()
  })

  it('is empty, never a rejection, when the roster cannot be read', async () => {
    resetAvatarFiles()
    assert.deepEqual(await loadHumanNames({ base: 'http://x', fetchFn: async () => ({ ok: false, status: 401 }) }), {})
    assert.deepEqual(await loadHumanNames({ base: 'http://y', fetchFn: async () => { throw new Error('down') } }), {})
    resetAvatarFiles()
  })
})

describe('a failed roster read is not cached', () => {
  it('a 401 before sign-in is retried by the next read, not kept for the TTL', async () => {
    resetAvatarFiles()
    let signedIn = false
    const fetchFn = async () => (signedIn
      ? { ok: true, json: async () => ({ humans: [{ human_id: 'HUM-3', display_name: 'Alice' }] }) }
      : { ok: false, status: 401 })
    const o = { base: 'http://t1.test', fetchFn, now: () => 1000 }
    assert.deepEqual(await loadHumanNames(o), {})
    await new Promise((r) => setTimeout(r, 0))
    signedIn = true
    assert.deepEqual(await loadHumanNames(o), { 'HUM-3': 'Alice' })
    resetAvatarFiles()
  })

  it('the names are re-read when the session signs in', () => {
    assert.match(read('src/composables/useHumanNames.ts'), /now === 'in' && before !== 'in'\) void load\(true\)/)
  })
})

describe('the name is shown where the id was', () => {
  it('message cards, the DM list, the self row, flow DMs and the DM header use the name; the id stays in the popup', () => {
    const badge = read('src/components/AgentBadge.vue')
    assert.match(badge, /people\.label\(props\.id, props\.box\)/)
    const side = read('src/components/ChannelSidebar.vue')
    assert.match(side, /<HumanName class="label" :id="p\.id" :box="p\.box" \/>/)
    assert.match(side, /<HumanName class="label" :id="roster\.self\.id" :box="roster\.self\.box" \/>/)
    assert.match(side, /<HumanName class="label" :id="row\.id" :box="row\.box" \/>/)
    const name = read('src/components/HumanName.vue')
    assert.match(name, /personTitle/)
    assert.match(name, /shownPerson/)
    assert.match(name, /scrollWidth > node\.clientWidth/)
    assert.match(read('src/pages/dm/[peer].vue'), /<FeedHeader[\s\S]*?:title="peerName"/)
    assert.match(read('src/components/ChannelPropertiesDialog.vue'), /remove_member', \{ id: personLabel\(id\) \}/)
    assert.match(read('src/components/MentionList.vue'), /<HumanName class="mention-label"/)
    assert.doesNotMatch(read('src/components/MentionList.vue'), /people\.label\(p\.id, p\.box\) !== p\.label/)
  })

  it('each member changes their own name in Settings > Profile, and it shows at once', () => {
    assert.match(read('src/pages/settings/profile.vue'), /DisplayNameSetting/)
    assert.match(read('src/components/DisplayNameSetting.vue'), /void people\.refresh\(\)/)
  })
})
