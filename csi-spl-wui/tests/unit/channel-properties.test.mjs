// Properties dialog: About, People, Agents, Settings.
// Run: node tests/unit/channel-properties.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync, readdirSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  aboutChannelDescription,
  aboutChannelName,
  canAddChannelMember,
  canEditOpenInvite,
  channelAgentRows,
  channelInviteCandidates,
  signedInHuman,
} from '../../src/utils/spool-client.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const src = (rel) => readFileSync(join(WUI, rel), 'utf8')

describe('who may add, and who may change the checkbox', () => {
  it('the owner can add, and another member can add only when members_open_invite is true', () => {
    assert.equal(canAddChannelMember({ selfId: 'HUM-1', createdBy: 'HUM-1', membersOpenInvite: false }), true)
    assert.equal(canAddChannelMember({ selfId: 'HUM-2', createdBy: 'HUM-1', membersOpenInvite: false }), false)
    assert.equal(canAddChannelMember({ selfId: 'HUM-2', createdBy: 'HUM-1', membersOpenInvite: true }), true)
    assert.equal(canAddChannelMember({ selfId: 'HUM-1', createdBy: 'hub', membersOpenInvite: false }), false)
    assert.equal(canAddChannelMember({ selfId: 'HUM-1', createdBy: 'wui', membersOpenInvite: false }), false)
    assert.equal(canAddChannelMember({ selfId: '', createdBy: 'HUM-1', membersOpenInvite: true }), false)
  })

  it('a non-owner does not get an enabled checkbox', () => {
    assert.equal(canEditOpenInvite({ selfId: 'HUM-1', createdBy: 'HUM-1' }), true)
    assert.equal(canEditOpenInvite({ selfId: 'HUM-2', createdBy: 'HUM-1' }), false)
    assert.equal(canEditOpenInvite({ selfId: 'HUM-1', createdBy: 'hub' }), false)
    assert.equal(signedInHuman({ humanId: 'HUM-4' }, { mock: false, rosterMe: 'HUM-1' }), 'HUM-4')
    assert.equal(signedInHuman(null, { mock: true, rosterMe: 'HUM-1' }), 'HUM-1')
    assert.equal(signedInHuman(null, { mock: false, rosterMe: 'HUM-1' }), '')
  })
})

describe('People offers humans, Agents offers boxes', () => {
  it('People offers a HUM-* and does not offer an agent id', () => {
    const people = channelInviteCandidates(['HUM-1', 'HUM-2', 'CLE-07', 'GRK-03'], ['HUM-1'])
    assert.deepEqual(people, ['HUM-2'])
    assert.equal(people.includes('CLE-07'), false)
  })

  it('Agents shows CLE-07 with its box and does not show HUM-1', () => {
    const rows = channelAgentRows([
      { id: 'HUM-1', box: 'box-wui' },
      { id: 'CLE-07', box: 'box-b' },
      { id: 'CLE-07', box: 'box-a' },
      { id: 'AGY-02', box: 'box-wui' },
      { id: 'GRK-03', box: 'box-a' },
    ])
    assert.deepEqual(rows, [
      { id: 'CLE-07', box: 'box-a' },
      { id: 'CLE-07', box: 'box-b' },
      { id: 'GRK-03', box: 'box-a' },
    ])
    assert.equal(rows.some((r) => r.id === 'HUM-1'), false)
    assert.deepEqual(channelAgentRows(undefined), [])
  })
})

describe('About is the name and the description', () => {
  it('shows the channel name, and the id when the name is empty', () => {
    assert.equal(aboutChannelName({ name: 'Releases', channel_id: 'releases' }), 'Releases')
    assert.equal(aboutChannelName({ name: '', channel_id: 'releases' }), 'releases')
    assert.equal(aboutChannelName({ name: '   ', channel_id: 'quiet' }), 'quiet')
  })

  it('shows the description, and an empty string when there is none', () => {
    assert.equal(aboutChannelDescription({ description: 'what ships' }), 'what ships')
    assert.equal(aboutChannelDescription({ description: '' }), '')
    assert.equal(aboutChannelDescription({}), '')
  })
})

describe('the Properties dialog', () => {
  const dialog = src('src/components/ChannelPropertiesDialog.vue')
  const page = src('src/pages/channel/[name].vue')
  const sidebar = src('src/components/ChannelSidebar.vue')

  it('opens on People, in the order About, People, Agents, Settings, with no Users tab', () => {
    const about = dialog.indexOf('channels.properties.about_tab')
    const people = dialog.indexOf('channels.properties.people_tab')
    const agents = dialog.indexOf('channels.properties.agents_tab')
    const settings = dialog.indexOf('channels.properties.settings_tab')
    assert.ok(about > 0 && about < people && people < agents && agents < settings)
    assert.match(dialog, /'channel-properties-tab-' \+ item\.id/)
    assert.match(dialog, /role="tablist"/)
    assert.match(dialog, /role="tab"/)
    assert.match(dialog, /:aria-selected="tab === item\.id"/)
    assert.match(dialog, /tab\.value = 'people'/)
    assert.doesNotMatch(dialog, /users_tab/)
    assert.doesNotMatch(page, /ChannelPropertiesDialog|channel-invite|addChannelMember/)
    assert.match(sidebar, /<ChannelPropertiesDialog/)
  })

  it('About shows the name and the description and has no text input', () => {
    const about = dialog.slice(dialog.indexOf('data-testid="channel-about"'), dialog.indexOf('data-testid="channel-people"'))
    assert.match(about, /data-testid="channel-about-name"/)
    assert.match(about, /data-testid="channel-about-description"/)
    assert.match(about, /data-testid="channel-about-no-description"/)
    assert.match(about, /t\('channels\.properties\.about_no_description'\)/)
    assert.doesNotMatch(about, /<input/)
    assert.doesNotMatch(about, /<textarea/)
    assert.equal(aboutChannelDescription({ description: '' }), '')
  })

  it('the checkbox is disabled unless this human is the owner, and the label key exists', () => {
    assert.match(dialog, /data-testid="channel-open-invite"/)
    assert.match(dialog, /:disabled="!canEdit \|\| busy"/)
    assert.match(dialog, /t\('channels\.properties\.everyone_can_invite'\)/)
    assert.match(dialog, /api\.setMembersOpenInvite\(props\.channelId, next\)/)
    const dir = join(WUI, 'i18n/locales')
    const files = readdirSync(dir).filter((f) => f.endsWith('.json'))
    assert.equal(files.length, 19)
    for (const f of files) {
      const j = JSON.parse(readFileSync(join(dir, f), 'utf8'))
      const p = j.channels.properties
      assert.equal(p.everyone_can_invite, 'everyone can invite new members', f)
      assert.equal(p.settings_tab, 'Settings', f)
      assert.equal(p.about_tab, 'About', f)
      assert.equal(p.about_name, 'Name', f)
      assert.equal(p.about_description, 'Description', f)
      assert.equal(p.about_no_description, 'No description', f)
      assert.equal(p.people_tab, 'People', f)
      assert.equal(p.agents_tab, 'Agents', f)
      assert.equal(p.agents_none, 'No agents', f)
      assert.equal(p.invite_empty, 'They have to be a member of the tenant first.', f)
      assert.equal(j.sidebar.row_menu.properties, 'Properties', f)
    }
  })
})
