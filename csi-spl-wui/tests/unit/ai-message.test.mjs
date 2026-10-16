// HUM-24 (csitea ba4696c1): an AI agent's message reads apart from a person's
// (an "AI" badge beside the name; no tint and, since SPL-2173, no bar on the
// card's left edge either). The rule is one function; MessageCard and the
// browser alert both read it.
// Run: node tests/unit/ai-message.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { isAiMessage } from '../../src/utils/typed-by.mjs'
import { messageCardSrc } from './lib/message-card-src.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const src = (rel) => readFileSync(join(WUI, rel), 'utf8')
const json = (rel) => JSON.parse(src(rel))

describe('isAiMessage', () => {
  it('an agent sender is AI, whatever its CLI prefix', () => {
    for (const from of ['CLE-07', 'GRK-3', 'AGY-3494', 'QWN-1', 'ZZ-12']) {
      assert.equal(isAiMessage({ from, from_box: 'box-desk' }), true, from)
    }
  })
  it('a person is not: a member, a guest', () => {
    assert.equal(isAiMessage({ from: 'HUM-24', from_box: 'box-wui' }), false)
    assert.equal(isAiMessage({ from: 'GST-5', from_box: 'box-wui' }), false)
  })
  it('a line the owner TYPED at an agent terminal is the human, not AI', () => {
    assert.equal(isAiMessage({ from: 'CLE-07', from_box: 'box-desk', typed_by: 'HUM-9' }), false)
  })
  it('a malformed typed_by does not launder an agent row into a person', () => {
    assert.equal(isAiMessage({ from: 'CLE-07', typed_by: 'bob' }), true)
  })
  it('an empty or unknown sender is not claimed as AI', () => {
    for (const m of [null, undefined, {}, { from: '' }, { from: 'spool' }, { from: 'cle-07' }]) {
      assert.equal(isAiMessage(m), false, JSON.stringify(m))
    }
  })
})

describe('wiring', () => {
  it('MessageCard marks and badges the AI row', () => {
    const card = messageCardSrc()
    assert.match(card, /'msg--ai': ai/)
    assert.match(card, /data-testid="msg-ai-badge"/)
    assert.match(card, /const ai = computed\(\(\) => isAiMessage\(props\.msg\)\)/)
  })
  it('SPL-2173: no agent item paints a left bar or a tint, and the shading sits UNDER hover', () => {
    const css = src('src/assets/css/main.css')
    /* owner HUM-10 t1 57adfdd4 msg b0ef4dc4: "uggly left side brackets ... remove it" */
    const files = ['src/assets/css/main.css', 'src/assets/css/variables.css', 'src/components/MessageCard.vue',
      'src/components/SideHitList.vue', 'src/pages/issues.vue']
    for (const f of files) assert.doesNotMatch(src(f), /agent-bar/, `${f} carries no agent bar token`)
    const aiRule = /\.(msg|side-hit|issues-row|issues-card)--ai\b[^{]*\{([^}]*)\}/g
    for (const f of files) {
      for (const m of src(f).matchAll(aiRule)) {
        assert.doesNotMatch(m[2], /box-shadow|border|background|::?before/, `${f}: ${m[0].slice(0, 80)}`)
      }
    }
    const alt = css.indexOf('.msg:where(:nth-child(even of .msg))')
    assert.ok(alt > 0 && alt < css.indexOf('.msg:hover {'), 'the alternate shade is declared before .msg:hover, at one class')
  })
  it('the browser alert of an AI row carries the robot mark', () => {
    const store = src('src/stores/notification.ts')
    assert.match(store, /isAiMessage\(m\) \? `\\u\{1F916\} \$\{who\}`/)
  })
  it('every locale names the badge and its tooltip', () => {
    const en = json('i18n/locales/en.json').feed.ai
    assert.deepEqual(en, { badge: 'AI', title: 'AI agent' })
    for (const loc of ['bg', 'el', 'es', 'et', 'fi', 'he', 'lt', 'lv', 'mk', 'nl', 'pl', 'ro', 'ru', 'sk', 'sr', 'sv', 'tr', 'uk']) {
      const ai = json(`i18n/locales/${loc}.json`).feed.ai
      assert.ok(ai && ai.badge && ai.title, loc)
    }
    assert.deepEqual(json('i18n/locales/bg.json').feed.ai, { badge: 'ИИ', title: 'ИИ агент' })
  })
})
