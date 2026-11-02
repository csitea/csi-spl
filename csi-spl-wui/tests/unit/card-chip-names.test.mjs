// Refactor round 21 row 04 (SPL-4592): the names useCardReactions gives a
// reaction chip, run on the SHIPPED composable (typescript + the real utils +
// en.json, with the emoji store faked). replies-count-link pins the source text
// of these calls, emoji.test the glyph table; this reads what comes back.
//
// Run: node tests/unit/card-chip-names.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import ts from 'typescript'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const UTILS_URL = pathToFileURL(join(WUI, 'src/utils')).href
const VUE_URL = import.meta.resolve('vue')
const read = (p) => readFileSync(join(WUI, p), 'utf8')
const dataUrl = (code) => 'data:text/javascript;base64,' + Buffer.from(code).toString('base64')
const tsToJs = (src) => ts.transpileModule(src, { compilerOptions: { module: ts.ModuleKind.ESNext, target: ts.ScriptTarget.ES2022, verbatimModuleSyntax: false } }).outputText

const en = JSON.parse(read('i18n/locales/en.json'))
const tr = (key, params = {}) => Object.entries(params).reduce((s, [k, v]) => s.replace(`{${k}}`, v), key.split('.').reduce((o, k) => o?.[k], en))

/* Nuxt auto-imports and the composables this file imports */
const PRELUDE = 'const useI18n = () => ({ t: globalThis.__cc.t });\n'
  + 'const useHumanNames = () => globalThis.__cc.people;\n'
  + 'const useMessageEmoji = () => globalThis.__cc.emoji;\n'

const js = tsToJs(read('src/composables/useCardReactions.ts'))
  .replace(/^import .* from '~\/composables\/.*$/gm, '')
  .replaceAll("'~/utils/", `'${UTILS_URL}/`)
  .replace("from 'vue'", `from '${VUE_URL}'`)
const { useCardReactions } = await import(dataUrl(PRELUDE + js))

const VIEWER = 'HUM-7'
const NAME = 'FirstName LastName'

function card(reactions = [], mobile = false) {
  const people = { names: { value: { [VIEWER]: NAME } } }
  globalThis.__cc = { t: tr, people, emoji: { viewerId: { value: VIEWER }, setReaction: async () => ({}), applyEverywhere() {} } }
  const c = useCardReactions({ msg: { msg_id: 'm1', reactions } }, () => {}, { value: null }, { value: mobile }, { close() {} })
  return { c, people }
}

describe('a reaction chip names its glyph, then who reacted', () => {
  it('emojiLabel is the localized short name, the glyph itself when unknown', () => {
    const { c } = card()
    assert.equal(c.emojiLabel('🔥'), en.feed.emoji.name.fire)
    assert.equal(c.emojiLabel('🛸'), '🛸')
  })

  it('chipTitle is the name, then who reacted by the name the row shows', () => {
    const { c } = card()
    assert.equal(c.chipTitle({ emoji: '🔥', actors: [VIEWER] }), `${en.feed.emoji.name.fire} · ${NAME}`)
    assert.equal(c.chipTitle({ emoji: '🔥', actors: [VIEWER, 'HUM-8'] }), `${en.feed.emoji.name.fire} · ${NAME}, HUM-8`)
  })

  it('chipTitle with nobody named is the name alone', () => {
    const { c } = card()
    assert.equal(c.chipTitle({ emoji: '✅', actors: [] }), en.feed.emoji.name.check)
  })

  it('chipTitle reads the names list at call time, a name set later shows', () => {
    const { c, people } = card()
    people.names.value = { 'HUM-8': 'Other Name' }
    assert.equal(c.chipTitle({ emoji: '🔥', actors: ['HUM-8'] }), `${en.feed.emoji.name.fire} · Other Name`)
  })

  it('the phone button reads the chips out by the same names', () => {
    const { c } = card([{ emoji: '🔥', actors: ['HUM-8'] }, { emoji: '✅', actors: [VIEWER] }], true)
    const name = c.emojiBtnName.value
    assert.ok(name.startsWith(en.feed.emoji.add), name)
    assert.ok(name.includes(en.feed.emoji.chip.replace('{emoji}', en.feed.emoji.name.fire).replace('{n}', '1')), name)
    assert.ok(name.includes(en.feed.emoji.mine.replace('{emoji}', en.feed.emoji.name.check)), name)
  })
})
