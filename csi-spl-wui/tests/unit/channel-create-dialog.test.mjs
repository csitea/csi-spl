// Owner, 2026-09-22: "the new button should be just a plus button - next to
// the Channels title, it should be navigatable via the tab, once you click the
// plus a new modal pop up will appear where you could put the title and the
// description of the channel."
//
// What the old shape got wrong, and what is pinned here so it cannot come
// back:
//
//   1. the create affordance was an ALWAYS-OPEN text field inside the channel
//      list. It cost two tab stops before anyone had decided to create
//      anything, and it sat between the channels and the DMs;
//   2. it had nowhere to say what the channel is FOR, so a channel arrived
//      named and unexplained. The description now rides POST /v1/channels
//      (channels-v1 §5.1, rdb 0027) and comes back on every read;
//   3. keyboard reach is not a CSS affordance: the control is a real
//      <button type="button">, so Tab reaches it in document order and
//      Enter / Space activate it. A div with @click would look identical and
//      be unreachable — that is why this test reads the element, not a class.
//
// Focus trap, Escape, backdrop and restored focus are UiDialog's (013 FR-017)
// and are tested with it; this file only pins that the dialog is used.
//
// Run: node tests/unit/channel-create-dialog.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync, readdirSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { addChannelRow } from '../../src/utils/channel-feed.mjs'
import { channelsFromView } from '../../src/utils/view-api.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const src = (rel) => readFileSync(join(WUI, rel), 'utf8')

describe('the + control next to the Channels heading', () => {
  const sidebar = src('src/components/ChannelSidebar.vue')

  it('is a real button in the heading row, not a field in the channel list', () => {
    assert.match(sidebar, /<div class="sidebar-head">\s*<h2[^>]*>\s*\{\{ t\('sidebar\.channels'\) \}\}/)
    assert.match(sidebar, /type="button"[\s\S]{0,200}data-testid="create-channel"/)
    assert.match(sidebar, /<UiIcon name="plus"/)
    /* the old always-open row is gone from the markup AND from the stylesheet */
    assert.doesNotMatch(sidebar, /class="create-row"/)
    assert.doesNotMatch(src('src/assets/css/main.css'), /\.create-row/)
  })

  it('carries its name on aria-label + title, never as visible text', () => {
    assert.match(sidebar, /:aria-label="t\('sidebar\.new_channel_label'\)"/)
    assert.match(sidebar, /:title="t\('sidebar\.new_channel_label'\)"/)
  })

  it('survives the 72px rail: the heading text hides, the + does not', () => {
    const css = src('src/assets/css/main.css')
    assert.match(css, /\.sidebar h2, \.nav-item span\.label, \.version-stamp \{ display: none; \}/)
    assert.match(css, /\.sidebar-head \{ justify-content: center;/)
  })

  it('the plus glyph is a path-only lucide stroke, like every other UiIcon', () => {
    assert.match(src('src/utils/uiIcons.ts'), /plus: \["M12 5v14", "M5 12h14"\]/)
  })
})

describe('the dialog collects a title AND a description', () => {
  const sidebar = src('src/components/ChannelSidebar.vue')

  it('opens with focus in the Title field, not on the dialog Close button', () => {
    /* items[0] is the header Close; a form that opens focused there eats the
       first keystroke. The content nominates its own field. */
    assert.match(sidebar, /data-autofocus/)
    assert.match(src('src/components/UiDialog.vue'), /items\.find\(\(el\) => el\.hasAttribute\('data-autofocus'\)\) \?\? items\[0\]/)
  })

  it('opens UiDialog with both fields and a submit that is disabled without a slug', () => {
    assert.match(sidebar, /<UiDialog v-model:open="createOpen"/)
    assert.match(sidebar, /data-testid="create-channel-name"/)
    assert.match(sidebar, /data-testid="create-channel-description"/)
    assert.match(sidebar, /<textarea/)
    assert.match(sidebar, /:disabled="creating \|\| !slug"/)
  })

  it('passes the description to the store, and clears the form only on close', () => {
    assert.match(sidebar, /channel\.createChannel\(name, newDescription\.value\.trim\(\)\)/)
    assert.match(sidebar, /watch\(createOpen, \(open\) => \{/)
    assert.match(src('src/stores/channel.ts'), /async function createChannel\(name: string, description = ''\)/)
  })

  it('all 19 locales carry the dialog copy, with the {slug} slot intact', () => {
    const dir = join(WUI, 'i18n/locales')
    const files = readdirSync(dir).filter((f) => f.endsWith('.json')).sort()
    assert.equal(files.length, 19)
    for (const f of files) {
      const j = JSON.parse(readFileSync(join(dir, f), 'utf8'))
      for (const k of ['create_channel_title', 'create_channel_name_label', 'create_channel_description_label',
        'create_channel_submit', 'create_channel_busy']) {
        assert.equal(typeof j.sidebar[k], 'string', `${f}: sidebar.${k}`)
      }
      assert.equal(typeof j.common.cancel, 'string', `${f}: common.cancel`)
      assert.ok(j.sidebar.create_channel_slug_hint.includes('{slug}'), `${f}: lost the {slug} slot`)
    }
  })
})

describe('the description round-trips (channels-v1 §5.1 / §5.2, rdb 0027)', () => {
  it('is sent ONLY when there is one, so a plain create still works on an older hub', () => {
    const client = src('src/utils/spool-client.mjs')
    /* the hub rejects unknown fields (DisallowUnknownFields): an unconditional
       `description` would turn every create into 400 bad_json against a hub
       that predates rdb 0027 */
    assert.match(client, /\.\.\.\(about \? \{ description: about \} : \{\}\)/)
    assert.match(client, /String\(description \|\| ''\)\.trim\(\)\.slice\(0, 500\)/)
  })

  it('comes back from GET /v1/view/channels', () => {
    const [row] = channelsFromView({ channels: [{ channel: 'releases', name: 'Releases', description: 'what ships' }] })
    assert.equal(row.description, 'what ships')
    const [bare] = channelsFromView({ channels: [{ channel: 'quiet', name: 'quiet', description: '' }] })
    assert.equal(bare.description, undefined)
  })

  it('rides the live `channel` frame, so a sidebar that learns of it live is not left guessing', () => {
    const rows = addChannelRow([], { channel: 'releases', name: 'Releases', description: 'what ships' })
    assert.equal(rows[0].description, 'what ships')
    assert.equal(addChannelRow([], { channel: 'quiet' })[0].description, '')
  })

  it('the channel page does not show the description or the last-30 note', () => {
    const page = src('src/pages/channel/[name].vue')
    assert.doesNotMatch(page, /channel-description/)
    assert.doesNotMatch(page, /headerSub/)
    assert.doesNotMatch(page, /pages\.channel\.subtitle/)
  })
})
