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
  channelAgentCandidates,
  channelAgentRows,
  channelAgentState,
  channelFallbackLine,
  channelInviteCandidates,
  defaultChannelRows,
  filterAgentsContains,
  filterPeopleContains,
  signedInHuman,
  viewerHumanId,
} from '../../src/utils/spool-client.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const src = (rel) => readFileSync(join(WUI, rel), 'utf8')

describe('who may add, and who may change the checkbox', () => {
  it('the owner can add, and another member can add only when members_open_invite is true', () => {
    assert.equal(canAddChannelMember({ selfId: 'HUM-1', createdBy: 'HUM-1', membersOpenInvite: false }), true)
    assert.equal(canAddChannelMember({ selfId: 'HUM-2', createdBy: 'HUM-1', membersOpenInvite: false }), false)
    assert.equal(canAddChannelMember({ selfId: 'HUM-2', createdBy: 'HUM-1', membersOpenInvite: true }), true)
    assert.equal(canAddChannelMember({ selfId: 'HUM-1', createdBy: 'hub', membersOpenInvite: false }), true)
    assert.equal(canAddChannelMember({ selfId: 'HUM-1', createdBy: 'wui', membersOpenInvite: false }), true)
    assert.equal(canAddChannelMember({ selfId: 'HUM-1', createdBy: '', membersOpenInvite: false }), false)
    // No HUM-* yet: the plus stays clickable. The hub still refuses a non-owner.
    assert.equal(canAddChannelMember({ selfId: '', createdBy: 'HUM-1', membersOpenInvite: false }), true)
    assert.equal(canAddChannelMember({ selfId: '', createdBy: 'HUM-1', membersOpenInvite: true }), true)
  })

  it('a non-owner does not get an enabled checkbox', () => {
    assert.equal(canEditOpenInvite({ selfId: 'HUM-1', createdBy: 'HUM-1' }), true)
    assert.equal(canEditOpenInvite({ selfId: 'HUM-2', createdBy: 'HUM-1' }), false)
    assert.equal(canEditOpenInvite({ selfId: 'HUM-1', createdBy: 'hub' }), false)
    assert.equal(signedInHuman({ humanId: 'HUM-4' }, { mock: false, rosterMe: 'HUM-1' }), 'HUM-4')
    assert.equal(signedInHuman(null, { mock: true, rosterMe: 'HUM-1' }), 'HUM-1')
    assert.equal(signedInHuman(null, { mock: false, rosterMe: 'HUM-1' }), '')
    assert.equal(viewerHumanId({ humanId: 'HUM-9' }, 'HUM-4'), 'HUM-9')
    assert.equal(viewerHumanId(null, 'HUM-4'), 'HUM-4')
    assert.equal(viewerHumanId(null, 'GST-1'), '')
    assert.equal(viewerHumanId(null, '', { mock: true, rosterMe: 'HUM-1' }), 'HUM-1')
  })
})

describe('People offers humans, Agents offers boxes', () => {
  it('People offers a HUM-* and does not offer an agent id', () => {
    const people = channelInviteCandidates(['HUM-1', 'HUM-2', 'CLE-07', 'GRK-03'], ['HUM-1'])
    assert.deepEqual(people, ['HUM-2'])
    assert.equal(people.includes('CLE-07'), false)
  })

  it('the people dropdown matches any part of the id', () => {
    const ids = ['HUM-17', 'HUM-11', 'HUM-9', 'HUM-4']
    assert.deepEqual(filterPeopleContains(ids, ''), ids)
    assert.deepEqual(filterPeopleContains(ids, '  '), ids)
    assert.deepEqual(filterPeopleContains(ids, '17'), ['HUM-17'])
    assert.deepEqual(filterPeopleContains(ids, 'hum-1'), ['HUM-17', 'HUM-11'])
    // owner, 2026-09-26: a person is found by the display name they chose too
    const names = { 'HUM-17': 'Pat Owner', 'HUM-11': 'Sam Dev' }
    assert.deepEqual(filterPeopleContains(ids, 'pat', names), ['HUM-17'])
    assert.deepEqual(filterPeopleContains(ids, 'SAM', names), ['HUM-11'])
    // CONTROL: without names a name query matches nothing
    assert.deepEqual(filterPeopleContains(ids, 'pat'), [])
    assert.deepEqual(filterPeopleContains(ids, 'nope'), [])
    assert.deepEqual(filterPeopleContains(undefined, '1'), [])
  })

  it('the agent dropdown matches any part of the id or the box', () => {
    const rows = [
      { id: 'GRK-3503', box: 'box-desk' },
      { id: 'CLE-07', box: 'box-a' },
      { id: 'CLE-07', box: 'box-desk' },
    ]
    assert.deepEqual(filterAgentsContains(rows, ''), rows)
    assert.deepEqual(filterAgentsContains(rows, '3503'), [{ id: 'GRK-3503', box: 'box-desk' }])
    assert.deepEqual(filterAgentsContains(rows, 'desk'), [
      { id: 'GRK-3503', box: 'box-desk' },
      { id: 'CLE-07', box: 'box-desk' },
    ])
    assert.deepEqual(filterAgentsContains(rows, 'cle'), [
      { id: 'CLE-07', box: 'box-a' },
      { id: 'CLE-07', box: 'box-desk' },
    ])
    assert.deepEqual(filterAgentsContains(rows, 'nope'), [])
    assert.deepEqual(filterAgentsContains(undefined, 'a'), [])
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

  it('SPL-987: each agent row carries its online / seated state from the hub', () => {
    const rows = channelAgentRows([
      { id: 'CLE-07', box: 'box-desk', online: true, seated: true },
      { id: 'AGY-02', box: 'box-desk', online: true, seated: false },
      { id: 'GRK-03', box: 'box-a', online: false, seated: true },
      { id: 'CLE-08', box: 'box-a' },
    ])
    assert.deepEqual(rows, [
      { id: 'AGY-02', box: 'box-desk', state: 'unseated' },
      { id: 'CLE-07', box: 'box-desk', state: 'online' },
      { id: 'CLE-08', box: 'box-a' },
      { id: 'GRK-03', box: 'box-a', state: 'offline' },
    ])
    assert.equal(channelAgentState({ online: false, seated: false }), 'unseated')
    assert.equal(channelAgentState(null), '')
  })

  it('an announced agent who is not already in the channel can be invited', () => {
    const open = channelAgentCandidates(
      { 'box-desk': ['CLE-07', 'HUM-9'], 'box-wui': ['HUM-1'], 'box-a': ['GRK-03', 'CLE-07'] },
      [{ id: 'CLE-07', box: 'box-a' }],
    )
    assert.deepEqual(open, [
      { id: 'CLE-07', box: 'box-desk' },
      { id: 'GRK-03', box: 'box-a' },
    ])
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
    const tabs = dialog.slice(dialog.indexOf('const tabs = ['), dialog.indexOf('const api'))
    const about = tabs.indexOf('channels.properties.about_tab')
    const people = tabs.indexOf('channels.properties.people_tab')
    const agents = tabs.indexOf('channels.properties.agents_tab')
    const settings = tabs.indexOf('channels.properties.settings_tab')
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
    assert.match(dialog, /data-testid="channel-people-add"/)
    assert.match(dialog, /data-testid="channel-agent-add"/)
    assert.match(dialog, /data-testid="channel-agent-search"/)
    assert.match(dialog, /name="minus"/)
    assert.match(dialog, /api\.addChannelAgent\(props\.channelId, row\.id, row\.box\)/)
    assert.match(dialog, /api\.removeChannelMember\(props\.channelId, id\)/)
    assert.match(dialog, /api\.removeChannelAgent\(props\.channelId, row\.id, row\.box\)/)
    const peoplePanel = dialog.slice(dialog.indexOf('data-testid="channel-people"'), dialog.indexOf('data-testid="channel-agents"'))
    assert.match(peoplePanel, /data-testid="channel-people-search"/)
    assert.match(peoplePanel, /data-testid="channel-people-add"/)
    assert.match(peoplePanel, /data-testid="channel-agent-add"/)
    assert.match(peoplePanel, /data-testid="channel-agent-search"/)
    assert.match(peoplePanel, /name="minus"/)
    assert.match(peoplePanel, /t\('channels\.properties\.add'\)/)
    assert.match(peoplePanel, /t\('channels\.properties\.people_search'\)/)
    assert.match(peoplePanel, /t\('channels\.properties\.agents_search'\)/)
    const searchAt = peoplePanel.indexOf('data-testid="channel-people-search"')
    const addAt = peoplePanel.indexOf('data-testid="channel-people-add"')
    const membersAt = peoplePanel.indexOf('data-testid="channel-invite-members"')
    assert.ok(searchAt > 0 && searchAt < addAt && addAt < membersAt)
    assert.match(dialog, /filterPeopleContains\(candidates\.value, personQuery\.value, people\.names\.value\)/)
    assert.match(dialog, /filterAgentsContains\(agentCandidates\.value, agentQuery\.value\)/)
    assert.match(dialog, /function addChosen/)
    assert.match(dialog, /function addChosenAgent/)
    assert.match(dialog, /viewerHumanId\(access\.me, live\.identity\.value/)
    assert.doesNotMatch(dialog, /function togglePeople/)
    assert.match(src('src/stores/access.ts'), /withSessionRetry\(api, \(\) => api\.me\(\)\)/)
    assert.match(dialog, /natural \* 2/)
    assert.match(dialog, /minHeight/)
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
      assert.equal(p.invite, 'Invite', f)
      assert.equal(p.invite_person, 'Invite a person', f)
      assert.equal(p.invite_agent, 'Invite an agent', f)
      assert.equal(p.invite_owner_only, 'Only the channel owner can invite someone in.', f)
      assert.equal(p.agents_invite_empty, 'Every announced agent is already in this channel.', f)
      assert.equal(p.add_person, 'Add a person', f)
      assert.equal(p.add, 'Add', f)
      assert.equal(p.people_search, 'Search people', f)
      assert.equal(p.people_no_matches, 'No matches', f)
      assert.equal(p.agents_search, 'Search agents', f)
      assert.equal(p.agents_no_matches, 'No matches', f)
      assert.equal(p.add_agent, 'Add an agent', f)
      assert.equal(p.remove_member, 'Remove {id}', f)
      assert.equal(p.remove_agent, 'Remove {id}', f)
      assert.equal(j.sidebar.row_menu.properties, 'Properties', f)
    }
  })
})

describe('the dropdown list opens under its own input (CLE-3493)', () => {
  const dialog = src('src/components/ChannelPropertiesDialog.vue')
  const template = dialog.slice(0, dialog.indexOf('<script'))
  const style = dialog.slice(dialog.indexOf('<style'))

  it('no scoped class sits on a headlessui Combobox, whose fragment root drops it', () => {
    // headlessui's <Combobox> renders a fragment, so Vue never gives it the
    // scoped data-v attribute: a scoped rule on its class matches nothing,
    // and the absolute list anchored to the dialog backdrop instead.
    const tags = template.match(/<Combobox\s[^>]*>/g) || []
    assert.equal(tags.length, 2)
    for (const tag of tags) assert.doesNotMatch(tag, /\sclass=/, tag)
  })

  it('each list is inside a plain positioned element', () => {
    const wrapped = template.match(/<div class="invite-add__combo">\s*<Combobox\s/g) || []
    assert.equal(wrapped.length, 2)
    assert.match(style, /\.invite-add__combo\s*\{[^}]*position:\s*relative/)
    assert.match(style, /\.invite-add__options\s*\{[^}]*position:\s*absolute/)
  })
})

describe('a default channel lists every person read-only and picks its agents (CLE-3493, 2026-09-25)', () => {
  const dialog = src('src/components/ChannelPropertiesDialog.vue')
  const sidebar = src('src/components/ChannelSidebar.vue')

  it('every person, and only the agents someone added - never the whole roster', () => {
    const roster = {
      'box-wui': ['HUM-17', 'HUM-4', 'HUM-4', 'GST-2'],
      'box-a': ['CLE-07', 'GRK-03'],
      'box-b': ['CLE-07'],
    }
    const rows = defaultChannelRows(roster, [{ id: 'CLE-07', box: 'box-a' }, { id: 'AGY-02', box: 'box-c' }])
    assert.deepEqual(rows.people, ['HUM-17', 'HUM-4'])
    assert.deepEqual(rows.agents, [
      { id: 'AGY-02', box: 'box-c' },
      { id: 'CLE-07', box: 'box-a' },
    ])
    assert.deepEqual(defaultChannelRows(roster, []).agents, [], 'an announced agent is not in #lobby until added')
    assert.deepEqual(defaultChannelRows(undefined, undefined), { people: [], agents: [] })
  })

  it('the default people list has no picker and no minus; the agent picker is shared', () => {
    const start = dialog.indexOf('<template v-if="isDefault">')
    const end = dialog.indexOf('<template v-else>', start)
    assert.ok(start > 0 && end > start, 'the isDefault people branch comes before the editable one')
    const branch = dialog.slice(start, end)
    assert.match(branch, /channel-default-note/)
    assert.match(branch, /v-for="id in localMembers"/)
    assert.doesNotMatch(branch, /<button|Combobox|remove|agentRows/)
    // The agent picker and its minus sit AFTER both people branches, so a
    // default channel gets exactly the created channel's agent controls.
    const picker = dialog.indexOf('data-testid="channel-agent-picker"')
    const closePeople = dialog.indexOf('</template>', end)
    assert.ok(picker > closePeople, 'agent picker is outside the people branches')
    assert.match(dialog, /data-testid="'channel-agent-remove-' \+ row\.id"/)
    assert.doesNotMatch(dialog, /error\.value = 'channel_public'/)
    assert.match(dialog, /defaultChannelRows\(bag, mem\.agents\)/)
    assert.match(dialog, /createdByLive\.value = String\(mem\.created_by \|\| 'hub'\)/)
    assert.match(dialog, /v-if="!canAdd && !isDefault"/)
  })

  it('any signed-in member may pick the agents of a default channel (created_by hub)', () => {
    assert.equal(canAddChannelMember({ selfId: 'HUM-4', createdBy: 'hub', membersOpenInvite: false }), true)
  })

  it('the sidebar offers Properties on a default channel too', () => {
    const fn = sidebar.slice(sidebar.indexOf('function showProperties'), sidebar.indexOf('function openProperties'))
    assert.doesNotMatch(fn, /isPublicChannel|default/)
  })
})

describe('every people and agent list is vertical, one avatar per row (CLE-3493)', () => {
  const dialog = src('src/components/ChannelPropertiesDialog.vue')
  const template = dialog.slice(0, dialog.indexOf('<script'))
  const style = dialog.slice(dialog.indexOf('<style'))

  it('each row of every list and every dropdown option starts with its own SpoolAvatar', () => {
    const rows = template.match(/<li\s[^>]*v-for="[^"]*"[^>]*>\s*<SpoolAvatar\s/g) || []
    assert.equal(rows.length, 4, 'default people, members, agents, Agents tab')
    const bare = (template.match(/<li\s[^>]*v-for="[^"]*"[^>]*>\s*<(?!SpoolAvatar\s)/g) || [])
    assert.deepEqual(bare, [])
    const options = template.match(/data-testid="'channel-(invite-pick|agent-invite)-' \+ (id|row\.id)"\s*><SpoolAvatar\s/g) || []
    assert.equal(options.length, 2)
    assert.match(template, /<SpoolAvatar :id="id" :box="HUMAN_BOX"/)
    assert.match(template, /<SpoolAvatar :id="row\.id" :box="row\.box"/)
  })

  it('the lists stack: one class, a column, and no wrapping list class is left', () => {
    const lists = template.match(/<ul\s[^>]*class="[^"]*"/g) || []
    assert.ok(lists.length >= 4)
    for (const ul of lists) assert.match(ul, /class="member-rows"/, ul)
    assert.match(style, /\.member-rows\s*\{[^}]*flex-direction:\s*column/)
    assert.doesNotMatch(style, /\.invite-members|flex-wrap:\s*wrap;[^}]*list-style/)
  })
})

describe('SPL-997: the fallback responder line (spec 038 FR-035)', () => {
  it('names the agent a post goes to when no member agent is online', () => {
    assert.deepEqual(channelFallbackLine({ id: 'CLE-001', box: 'box-desk', active: true,
      recent: { count: 3, id: 'CLE-001', at: '2026-09-27T10:40:12Z' } }),
    { id: 'CLE-001', box: 'box-desk', active: true, recent: { count: 3, id: 'CLE-001', at: '2026-09-27 10:40' } })
    assert.deepEqual(channelFallbackLine({ id: 'CLE-001', box: 'box-desk', active: false, recent: { count: 0 } }),
      { id: 'CLE-001', box: 'box-desk', active: false, recent: { count: 0, id: '', at: '' } })
  })
  it('an empty id is "no agent online"; an older hub says nothing', () => {
    assert.deepEqual(channelFallbackLine({ id: '', box: '', active: true, recent: { count: 0 } }),
      { id: '', box: '', active: true, recent: { count: 0, id: '', at: '' } })
    assert.equal(channelFallbackLine(undefined), null)
    assert.equal(channelFallbackLine(null), null)
    assert.equal(channelFallbackLine({ id: 'HUM-4', box: 'box-wui' }).id, '')
  })
  it('both agent lists render the line, and every locale has its strings', () => {
    const vue = src('src/components/ChannelPropertiesDialog.vue')
    assert.match(vue, /data-testid="channel-fallback"/)
    assert.match(vue, /data-testid="channel-fallback-ro"/)
    assert.match(vue, /channelFallbackLine\(mem\.fallback\)/)
    const dir = join(WUI, 'i18n/locales')
    for (const f of readdirSync(dir).filter((n) => n.endsWith('.json'))) {
      const p = JSON.parse(readFileSync(join(dir, f), 'utf8')).channels.properties
      for (const k of ['fallback_label', 'fallback_active', 'fallback_standby', 'fallback_none', 'fallback_recent']) {
        assert.equal(typeof p[k], 'string', f + ' ' + k)
      }
      for (const v of ['{count}', '{id}', '{at}']) assert.ok(p.fallback_recent.includes(v), f + ' fallback_recent ' + v)
    }
  })
})
