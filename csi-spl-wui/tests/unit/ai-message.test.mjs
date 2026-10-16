// HUM-24 (csitea ba4696c1): an AI agent's message reads apart from a person's
// (an "AI" badge beside the name and, since SPL-2120, a bar on the card's
// left edge instead of a tint). The rule is one function; MessageCard and the
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
  it('SPL-2120: the AI row is a bar, not a tint, and the shading sits UNDER hover', () => {
    const css = src('src/assets/css/main.css')
    const rule = css.slice(css.indexOf('.msg--ai {'), css.indexOf('}', css.indexOf('.msg--ai {')))
    assert.ok(css.indexOf('.msg--ai {') > 0, 'main.css has the .msg--ai rule')
    assert.match(rule, /box-shadow: inset var\(--agent-bar-w\) 0 0 var\(--color-agent-bar\)/)
    assert.doesNotMatch(rule, /background/, 'no tint: the agent row keeps the list shade')
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
