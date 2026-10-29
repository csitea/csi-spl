// Properties dialog: About, People, Agents, Settings.
// Run: node tests/unit/channel-properties.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync, readdirSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { setTimeZoneSource } from '../../src/utils/date-iso.mjs'
import { ref } from 'vue'
import { importTs } from './lib/load-ts.mjs'
const { aboutChannelDescription, aboutChannelName, canAddChannelMember, canEditOpenInvite, channelAgentCandidates, channelAgentRows, channelAgentState, channelFallbackLine, channelInviteCandidates, defaultChannelRows, filterAgentsContains, filterPeopleContains, signedInHuman, viewerHumanId } = await importTs('src/utils/channel-members.ts')
const { channelAgentsLive } = await importTs('src/utils/channel-agents-live.ts')

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

  it('SPL-3717: the badge follows the live roster presence, not the members snapshot', () => {
    const rows = channelAgentRows([
      { id: 'CLE-07', box: 'box-a', online: false, seated: true },
      { id: 'GRK-03', box: 'box-b', online: true, seated: true },
      { id: 'AGY-02', box: 'box-a', online: true, seated: false },
      { id: 'CLE-11', box: 'box-desk', online: false, seated: true },
      { id: 'CLE-09', box: 'box-gone' },
    ])
    const live = {
      roster: { 'box-a': ['CLE-07', 'AGY-02', 'CLE-08'], 'box-b': ['GRK-03'], 'box-desk': ['CLE-11'] },
      online: ['CLE-08@box-a'],
      idle: ['CLE-11@box-desk'],
    }
    assert.deepEqual(channelAgentsLive(rows, live), [
      { id: 'AGY-02', box: 'box-a', state: 'unseated' },
      // its box is online: another agent of box-a is (the badge is the box's)
      { id: 'CLE-07', box: 'box-a', state: 'online' },
      // the roster does not know the box: the hub's answer stands
      { id: 'CLE-09', box: 'box-gone' },
      // machine online, agent not running: the box is not offline
      { id: 'CLE-11', box: 'box-desk', state: 'online' },
      // a presence frame took box-b offline after the dialog opened
      { id: 'GRK-03', box: 'box-b', state: 'offline' },
    ])
    assert.deepEqual(channelAgentsLive(rows, null), rows)
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

  // SPL-1233 regression: SPL-1204 gates the dialog behind v-if in the sidebar,
  // so it now mounts with open already true. The member load lives in a
  // watch(() => props.open) which never sees a false->true transition after
  // mount, so it MUST be immediate or People stays on "Loading…" and nobody can
  // be invited. This test pins both halves together so neither can drift back.
  it('mounts already-open (sidebar v-if) so the member-load watcher is immediate', () => {
    assert.match(sidebar, /<ChannelPropertiesDialog\s+v-if="propertiesChannel\.channel_id"/)
    assert.match(
      dialog,
      /watch\(\(\) => props\.open, async[\s\S]*?api\.listChannelMembers\(props\.channelId\)[\s\S]*?\}, \{ immediate: true \}\)/,
    )
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

  it('SPL-1684: the AI agents switch is the owner\'s or a workspace admin\'s, and says what off means', () => {
    assert.match(dialog, /data-testid="channel-ai-agents"/)
    assert.match(dialog, /:disabled="!loaded \|\| !canEditAIAgents \|\| busy"/)
    assert.match(dialog, /canEdit\.value \|\| access\.can\('tenant\.settings'\)/)
    assert.match(dialog, /api\.setChannelAIAgents\(props\.channelId, next\)/)
    assert.match(dialog, /aiAgentsOn\.value = mem\.ai_agents_off !== true/)
    for (const k of ['ai_agents', 'ai_agents_on_hint', 'ai_agents_off_hint', 'ai_agents_off_note', 'ai_agents_edit_only']) {
      assert.match(dialog, new RegExp(`channels\\.properties\\.${k}'`))
    }
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
    assert.match(src('src/composables/useChannelAgentPick.ts'), /api\.addChannelAgent\(channelId\(\), row\.id, row\.box\)/)
    assert.match(src('src/composables/useChannelPersonPick.ts'), /api\.removeChannelMember\(props\.channelId, id\)/)
    assert.match(src('src/composables/useChannelAgentPick.ts'), /api\.removeChannelAgent\(channelId\(\), row\.id, row\.box\)/)
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
    assert.match(src('src/composables/useChannelPersonPick.ts'), /function addChosen/)
    assert.match(src('src/composables/useChannelAgentPick.ts'), /function addChosenAgent/)
    assert.match(dialog, /viewerHumanId\(access\.me, live\.identity\.value/)
    assert.doesNotMatch(dialog, /function togglePeople/)
    assert.match(src('src/stores/access.ts'), /withSessionRetry\(api, \(\) => api\.me\(\)\)/)
    // t1 1d657ae8: the dialog hugs its content; no fixed or doubled floor
    assert.doesNotMatch(dialog, /minHeight/)
    assert.doesNotMatch(dialog, /natural \* 2/)
    assert.doesNotMatch(dialog, /\.ui-dialog[^{]*\{[^}]*\bheight:/)
    const dir = join(WUI, 'i18n/locales')
    const files = readdirSync(dir).filter((f) => f.endsWith('.json'))
    assert.equal(files.length, 19)
    for (const f of files) {
      const j = JSON.parse(readFileSync(join(dir, f), 'utf8'))
      const p = j.channels?.properties || {}
      if (f === 'en.json') {
        assert.equal(p.everyone_can_invite, 'everyone can invite new members', f)
        assert.equal(p.settings_tab, 'Settings', f)
        assert.equal(p.about_tab, 'About', f)
        assert.equal(p.about_name, 'Name', f)
        assert.equal(p.about_description, 'Description', f)
        assert.equal(p.about_no_description, 'No description', f)
        assert.equal(p.people_tab, 'People', f)
        assert.equal(p.agents_tab, 'Agents', f)
        assert.equal(p.agents_none, 'No agents', f)
        // spec 025 section 11 (SPL-3686): a person who has not joined can be added by address
        assert.equal(p.invite_empty, 'Type an email address to add someone who has not joined the workspace yet.', f)
        assert.equal(p.invite_email, 'Invite {email}', f)
        assert.equal(p.invited, 'invited', f)
        assert.equal(p.remove_invited, 'Remove the invite of {email}', f)
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
        assert.equal(j.sidebar?.row_menu?.properties, 'Properties', f)
      } else {
        assert.equal(typeof p.everyone_can_invite, 'string', f)
        assert.ok(p.everyone_can_invite.length > 0, f)
        assert.equal(typeof p.settings_tab, 'string', f)
        assert.ok(p.settings_tab.length > 0, f)
        assert.equal(typeof p.about_tab, 'string', f)
        assert.ok(p.about_tab.length > 0, f)
        assert.equal(typeof p.about_name, 'string', f)
        assert.ok(p.about_name.length > 0, f)
        assert.equal(typeof p.about_description, 'string', f)
        assert.ok(p.about_description.length > 0, f)
        assert.equal(typeof p.about_no_description, 'string', f)
        assert.ok(p.about_no_description.length > 0, f)
        assert.equal(typeof p.people_tab, 'string', f)
        assert.ok(p.people_tab.length > 0, f)
        assert.equal(typeof p.agents_tab, 'string', f)
        assert.ok(p.agents_tab.length > 0, f)
        assert.equal(typeof p.agents_none, 'string', f)
        assert.ok(p.agents_none.length > 0, f)
        assert.equal(typeof p.invite_empty, 'string', f)
        assert.ok(p.invite_empty.length > 0, f)
        for (const k of ['invite_email', 'invited', 'invited_hint', 'remove_invited']) {
          assert.ok(typeof p[k] === 'string' && p[k].length > 0, `${f} ${k}`)
        }
        assert.ok(p.invite_email.includes('{email}') && p.remove_invited.includes('{email}'), f)
        assert.equal(typeof p.invite, 'string', f)
        assert.ok(p.invite.length > 0, f)
        assert.equal(typeof p.invite_person, 'string', f)
        assert.ok(p.invite_person.length > 0, f)
        assert.equal(typeof p.invite_agent, 'string', f)
        assert.ok(p.invite_agent.length > 0, f)
        assert.equal(typeof p.invite_owner_only, 'string', f)
        assert.ok(p.invite_owner_only.length > 0, f)
        assert.equal(typeof p.agents_invite_empty, 'string', f)
        assert.ok(p.agents_invite_empty.length > 0, f)
        assert.equal(typeof p.add_person, 'string', f)
        assert.ok(p.add_person.length > 0, f)
        assert.equal(typeof p.add, 'string', f)
        assert.ok(p.add.length > 0, f)
        assert.equal(typeof p.people_search, 'string', f)
        assert.ok(p.people_search.length > 0, f)
        assert.equal(typeof p.people_no_matches, 'string', f)
        assert.ok(p.people_no_matches.length > 0, f)
        assert.equal(typeof p.agents_search, 'string', f)
        assert.ok(p.agents_search.length > 0, f)
        assert.equal(typeof p.agents_no_matches, 'string', f)
        assert.ok(p.agents_no_matches.length > 0, f)
        assert.equal(typeof p.add_agent, 'string', f)
        assert.ok(p.add_agent.length > 0, f)
        assert.equal(typeof p.remove_member, 'string', f)
        assert.ok(p.remove_member.includes('{id}'), f)
        assert.equal(typeof p.remove_agent, 'string', f)
        assert.ok(p.remove_agent.includes('{id}'), f)
        assert.equal(typeof j.sidebar?.row_menu?.properties, 'string', f)
        assert.ok(j.sidebar?.row_menu?.properties.length > 0, f)
      }
    }
  })
})

describe('the dropdown list opens under its own input', () => {
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

  it('each list is inside a plain element and pinned to its own input', () => {
    const wrapped = template.match(/<div class="invite-add__combo">\s*<Combobox\s/g) || []
    assert.equal(wrapped.length, 2)
    assert.match(style, /\.invite-add__combo\s*\{[^}]*position:\s*relative/)
    // t1 1d657ae8: the dialog hugs its rows, so the body would clip an
    // absolute list: it is a fixed overlay placed from its own input's box
    assert.match(style, /\.invite-add__options\s*\{[^}]*position:\s*fixed/)
    assert.match(dialog, /list\.closest\('\.invite-add__combo'\)\?\.querySelector\('\.invite-add__control'\)/)
    assert.match(dialog, /new MutationObserver\(placeOptions\)/)
    assert.match(dialog, /addEventListener\('scroll', placeOptions, true\)/)
  })
})

describe('a default channel lists every person read-only and picks its agents (2026-09-25)', () => {
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

describe('every people and agent list is vertical, one avatar per row', () => {
  const dialog = src('src/components/ChannelPropertiesDialog.vue')
  const template = dialog.slice(0, dialog.indexOf('<script'))
  const style = dialog.slice(dialog.indexOf('<style'))

  it('each row of every list and every dropdown option starts with its own SpoolAvatar', () => {
    const rows = template.match(/<li\s[^>]*v-for="[^"]*"[^>]*>\s*<SpoolAvatar\s/g) || []
    assert.equal(rows.length, 5, 'default people, members, invited addresses (spec 025 section 11), agents, Agents tab')
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
    setTimeZoneSource(() => 'UTC')
    try {
      assert.deepEqual(channelFallbackLine({ id: 'CLE-001', box: 'box-desk', active: true,
        recent: { count: 3, id: 'CLE-001', at: '2026-09-27T10:40:12Z' } }),
      { id: 'CLE-001', box: 'box-desk', active: true, off: false, recent: { count: 3, id: 'CLE-001', at: '2026-09-27 10:40' } })
      /* SPL-2144: the time reads in the person's zone, not the hub's UTC digits */
      setTimeZoneSource(() => 'Pacific/Kiritimati')
      assert.equal(channelFallbackLine({ id: 'CLE-001', active: true, recent: { count: 1, at: '2026-09-27T10:40:12Z' } }).recent.at, '2026-09-28 00:40')
    } finally {
      setTimeZoneSource(() => '')
    }
    assert.deepEqual(channelFallbackLine({ id: 'CLE-001', box: 'box-desk', active: false, recent: { count: 0 } }),
      { id: 'CLE-001', box: 'box-desk', active: false, off: false, recent: { count: 0, id: '', at: '' } })
  })
  it('an empty id is "no agent online"; an older hub says nothing', () => {
    assert.deepEqual(channelFallbackLine({ id: '', box: '', active: true, recent: { count: 0 } }),
      { id: '', box: '', active: true, off: false, recent: { count: 0, id: '', at: '' } })
    assert.equal(channelFallbackLine(undefined), null)
    assert.equal(channelFallbackLine(null), null)
    assert.equal(channelFallbackLine({ id: 'HUM-4', box: 'box-wui' }).id, '')
  })
  it('a channel that opted out (FR-039) is off and never active', () => {
    const l = channelFallbackLine({ id: 'CLE-001', box: 'box-desk', active: true, off: true, recent: { count: 0 } })
    assert.equal(l.off, true)
    assert.equal(l.active, false)
    assert.match(src('src/components/ChannelPropertiesDialog.vue'), /data-testid="channel-fallback-off"/)
  })
  it('both agent lists render the line, and every locale has its strings', () => {
    const vue = src('src/components/ChannelPropertiesDialog.vue')
    assert.match(vue, /data-testid="channel-fallback"/)
    assert.match(vue, /data-testid="channel-fallback-ro"/)
    assert.match(vue, /channelFallbackLine\(mem\.fallback\)/)
    const dir = join(WUI, 'i18n/locales')
    for (const f of readdirSync(dir).filter((n) => n.endsWith('.json'))) {
      const p = JSON.parse(readFileSync(join(dir, f), 'utf8')).channels.properties
      for (const k of ['fallback_label', 'fallback_active', 'fallback_standby', 'fallback_none', 'fallback_recent', 'fallback_off']) {
        assert.equal(typeof p[k], 'string', f + ' ' + k)
      }
      for (const v of ['{count}', '{id}', '{at}']) assert.ok(p.fallback_recent.includes(v), f + ' fallback_recent ' + v)
    }
  })
})

// r17-07: the agent pick (useChannelAgentPick), driven with a fake api. A
// pick adds the row and reads the list again for its state; a remove drops
// only that row; both use the channel id the getter gives at call time.
describe('the agent pick', async () => {
  const { useChannelAgentPick } = await importTs('src/composables/useChannelAgentPick.ts')
  const setup = () => {
    const calls = []
    const api = {
      addChannelAgent: async (...a) => { calls.push(['add', ...a]) },
      removeChannelAgent: async (...a) => { calls.push(['remove', ...a]) },
      listChannelMembers: async (id) => {
        calls.push(['list', id])
        return { agents: [{ id: 'CLE-1', box: 'box-a', online: true }] }
      },
    }
    const r = {
      busy: ref(false), canAdd: ref(true), error: ref(''), fallback: ref(null),
      agents: ref([{ id: 'CLE-2', box: 'box-b' }]), chosenAgent: ref(null), agentQuery: ref(''),
    }
    let channel = 'one'
    const fn = useChannelAgentPick({ api, channelId: () => channel, ...r })
    return { calls, r, fn, move: (id) => { channel = id } }
  }

  it('a pick adds the row, then shows the state the hub reads back', async () => {
    const { calls, r, fn, move } = setup()
    move('two')
    r.chosenAgent.value = { id: 'CLE-1', box: 'box-a', key: 'CLE-1@box-a' }
    r.agentQuery.value = 'cle'
    await fn.addChosenAgent()
    await new Promise((res) => setTimeout(res, 0))
    assert.deepEqual(calls, [['add', 'two', 'CLE-1', 'box-a'], ['list', 'two']])
    assert.deepEqual(r.agents.value, [{ id: 'CLE-2', box: 'box-b' }, { id: 'CLE-1', box: 'box-a', online: true }])
    assert.equal(r.chosenAgent.value, null)
    assert.equal(r.agentQuery.value, '')
    assert.equal(r.busy.value, false)
  })

  it('a remove drops only that row', async () => {
    const { calls, r, fn } = setup()
    r.agents.value = [...r.agents.value, { id: 'CLE-3', box: 'box-c' }]
    await fn.removeAgent({ id: 'CLE-2', box: 'box-b' })
    assert.deepEqual(calls, [['remove', 'one', 'CLE-2', 'box-b']])
    assert.deepEqual(r.agents.value, [{ id: 'CLE-3', box: 'box-c' }])
  })

  it('nothing moves without the right to add', async () => {
    const { calls, r, fn } = setup()
    r.canAdd.value = false
    await fn.pickAgent({ id: 'CLE-1', box: 'box-a' })
    await fn.removeAgent({ id: 'CLE-2', box: 'box-b' })
    assert.deepEqual(calls, [])
    assert.equal(fn.agentLabel({ id: 'CLE-1', box: 'box-a' }), 'CLE-1 box-a')
  })

  // r39-01: the hub refuses the add with a token.
  const refusing = () => {
    const s = setup()
    const api = {
      addChannelAgent: async (...a) => {
        s.calls.push(['add', ...a])
        throw Object.assign(new Error('x'), { token: 'not_allowed' })
      },
    }
    return { ...s, fn: useChannelAgentPick({ api, channelId: () => 'one', ...s.r }) }
  }

  it('a refused add keeps the chosen agent and the query', async () => {
    const { r, fn } = refusing()
    r.chosenAgent.value = { id: 'CLE-9', box: 'box-z', key: 'CLE-9@box-z' }
    r.agentQuery.value = 'cle'
    await fn.addChosenAgent()
    assert.deepEqual(r.chosenAgent.value, { id: 'CLE-9', box: 'box-z', key: 'CLE-9@box-z' })
    assert.equal(r.agentQuery.value, 'cle')
  })

  it('a refused pick shows the hub token and adds no row', async () => {
    const { calls, r, fn } = refusing()
    await fn.pickAgent({ id: 'CLE-9', box: 'box-z' })
    assert.equal(r.error.value, 'not_allowed')
    assert.deepEqual(r.agents.value, [{ id: 'CLE-2', box: 'box-b' }])
    assert.deepEqual(calls, [['add', 'one', 'CLE-9', 'box-z']])
    assert.equal(r.busy.value, false)
  })

  it('a pick while busy sends nothing', async () => {
    const { calls, r, fn } = setup()
    r.busy.value = true
    await fn.pickAgent({ id: 'CLE-9', box: 'box-z' })
    assert.deepEqual(calls, [])
    assert.deepEqual(r.agents.value, [{ id: 'CLE-2', box: 'box-b' }])
  })
})
