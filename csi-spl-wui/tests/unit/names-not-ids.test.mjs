// SPL-1009 (owner, 2026-09-27: "but still the humans are presented with
// IDs"): a person is shown by the name they chose; the stored mention stays
// the tag; an agent, a nameless member and an unknown id keep the id.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { namedRuns, namedText } from '../../src/utils/channel-feed.mjs'
import { decodeMentions, encodeMentions, mentionFieldName } from '../../src/utils/mention-autocomplete.mjs'
import { pokeBody } from '../../src/utils/mention-poke.mjs'

const SRC = join(dirname(fileURLToPath(import.meta.url)), '../../src')
const names = { 'HUM-2': 'Ann Example', 'HUM-3': 'Bo Example', 'HUM-12': 'bo example', 'HUM-4': 'CLE-7', 'HUM-5': 'a@b' }

describe('mentionFieldName: the name a pick writes', () => {
  it('a member with a name of their own is written by name', () => {
    assert.equal(mentionFieldName('HUM-2', names), 'Ann Example')
    assert.equal(mentionFieldName('HUM-2@box-wui', names), 'Ann Example')
  })
  it('the tag stays for an agent, a nameless member, a shared name, a name that reads as a tag', () => {
    assert.equal(mentionFieldName('CLE-7', names), '')
    assert.equal(mentionFieldName('HUM-9', names), '')
    assert.equal(mentionFieldName('HUM-3', names), '')
    assert.equal(mentionFieldName('HUM-4', names), '')
    assert.equal(mentionFieldName('HUM-5', names), '')
  })
})

describe('encodeMentions / decodeMentions: shown by name, stored by tag', () => {
  it('a picked name is stored as its tag, punctuation after it kept', () => {
    assert.equal(encodeMentions('ping @Ann Example, then @Ann Example.', { 'Ann Example': 'HUM-2@box-wui' }), 'ping @HUM-2@box-wui, then @HUM-2@box-wui.')
  })
  it('only picked names change: a longer word, a name typed without @, an unpicked @word stay', () => {
    const picks = { 'Ann Example': 'HUM-2' }
    assert.equal(encodeMentions('@Ann Examples and Ann Example and @Bo', picks), '@Ann Examples and Ann Example and @Bo')
  })
  it('the longest name wins', () => {
    assert.equal(encodeMentions('@Ann Lee', { Ann: 'HUM-8', 'Ann Lee': 'HUM-2' }), '@HUM-2')
  })
  it('a stored text round-trips through the edit box unchanged', () => {
    const stored = 'hi @HUM-2@box-wui and @HUM-3, @CLE-7 and @HUM-9'
    const d = decodeMentions(stored, names)
    assert.equal(d.text, 'hi @Ann Example and @HUM-3, @CLE-7 and @HUM-9')
    assert.equal(encodeMentions(d.text, d.picks), stored)
  })
})

describe('namedRuns / namedText: a member id in plain text reads the name', () => {
  it('the poke DM line names its author; the id is the title', () => {
    const body = pokeBody({ author: 'HUM-2@box-wui', link: 'https://x/t/1', text: 'look' })
    assert.equal(body.startsWith('HUM-2 needs you in'), true, 'the STORED poke keeps the id: agents parse it')
    const runs = namedRuns(body, names)
    assert.deepEqual(runs[0], { text: 'Ann Example', title: 'HUM-2' })
    assert.equal(runs.map((r) => r.text).join(''), body.replace('HUM-2', 'Ann Example'))
  })
  it('agents, nameless and unknown ids, parts of longer tokens stay as written', () => {
    const s = 'CLE-7 HUM-9 xHUM-2 HUM-2x HUM-2@box-wui'
    assert.deepEqual(namedRuns(s, names), [{ text: s }])
  })
  it('a plain-string place (notification, snippet) reads names for tags and bare ids', () => {
    assert.equal(namedText('@HUM-2@box-wui asks HUM-2 and @HUM-9', names), '@Ann Example asks Ann Example and @HUM-9')
  })
})

describe('every @ field stores the tag', () => {
  /* a field that uses the picker and sends its text raw would store "@Ann Example" */
  const sites = {
    'components/MessageComposer.vue': /mp\.encode\(/,
    'pages/issues.vue': /commentMp\.encode\(/,
    'components/IssueSubtaskDialog.vue': /mp\.encode\(/,
    'components/ChannelSidebar.vue': /descMp\.encode\(/,
    'components/MessageCard.vue': /editMp\.encode\(/,
    'components/IssueDescription.vue': /mp\.encode\(/,
  }
  it('each file that calls useMentionPicker encodes before storing', () => {
    for (const [file, re] of Object.entries(sites)) {
      assert.match(readFileSync(join(SRC, file), 'utf8'), re, file)
    }
  })
  it('no other file uses the picker (a new one must be added above)', async () => {
    const { execFileSync } = await import('node:child_process')
    const out = execFileSync('grep', ['-rl', 'useMentionPicker(', SRC], { encoding: 'utf8' })
    const users = out.split('\n').filter(Boolean).map((f) => f.slice(SRC.length + 1)).filter((f) => f !== 'composables/useMentionPicker.ts').sort()
    assert.deepEqual(users, Object.keys(sites).sort())
  })
})
