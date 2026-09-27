// `/` focuses the top Omnibox (Gmail/GitHub); ignored in inputs/modals/with
// modifiers; Escape restores the previous focus. Pure helpers + wiring greps.
// Run: node tests/unit/slash-focus.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync, readdirSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  MOBILE_MAX,
  eventInOmnibox,
  isMobileViewport,
  isOpenModal,
  isTypingTarget,
  slashFocusAction,
  slashFocusContext,
} from '../../src/utils/slash-focus.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (rel) => readFileSync(join(WUI, rel), 'utf8')

function el(tag, extra = {}) {
  const node = {
    tagName: String(tag).toUpperCase(),
    type: extra.type,
    isContentEditable: Boolean(extra.isContentEditable),
    role: extra.role,
    getAttribute: (name) => {
      if (name === 'role') return extra.role || null
      if (name === extra.attr) return extra.attrValue
      return null
    },
    closest: extra.closest || (() => extra.closestHost || null),
    classList: { contains: (c) => (extra.className || '').split(/\s+/).includes(c) },
    contains: extra.contains || (() => false),
    querySelector: extra.querySelector || (() => extra.child || null),
    ...extra,
  }
  return node
}

function ev(key, extra = {}) {
  return {
    key,
    defaultPrevented: Boolean(extra.defaultPrevented),
    isComposing: Boolean(extra.isComposing),
    repeat: Boolean(extra.repeat),
    ctrlKey: Boolean(extra.ctrlKey),
    metaKey: Boolean(extra.metaKey),
    altKey: Boolean(extra.altKey),
    shiftKey: Boolean(extra.shiftKey),
    target: extra.target || null,
  }
}

describe('isTypingTarget', () => {
  it('treats textarea, select, text-like inputs and contenteditable as typing', () => {
    assert.equal(isTypingTarget(el('textarea')), true)
    assert.equal(isTypingTarget(el('select')), true)
    assert.equal(isTypingTarget(el('input')), true)
    assert.equal(isTypingTarget(el('input', { type: 'search' })), true)
    assert.equal(isTypingTarget(el('input', { type: 'password' })), true)
    assert.equal(isTypingTarget(el('input', { type: 'email' })), true)
    assert.equal(isTypingTarget(el('div', { isContentEditable: true })), true)
    assert.equal(isTypingTarget(el('span', { closestHost: el('div') })), true)
    assert.equal(isTypingTarget(el('div', { role: 'textbox' })), true)
    assert.equal(isTypingTarget(el('div', { role: 'combobox' })), true)
    assert.equal(isTypingTarget(el('div', { role: 'searchbox' })), true)
  })
  it('CONTROL: buttons, checkboxes, links, body are not typing targets', () => {
    assert.equal(isTypingTarget(null), false)
    assert.equal(isTypingTarget(el('button')), false)
    assert.equal(isTypingTarget(el('input', { type: 'button' })), false)
    assert.equal(isTypingTarget(el('input', { type: 'checkbox' })), false)
    assert.equal(isTypingTarget(el('input', { type: 'radio' })), false)
    assert.equal(isTypingTarget(el('input', { type: 'submit' })), false)
    assert.equal(isTypingTarget(el('a')), false)
    assert.equal(isTypingTarget(el('div')), false)
    assert.equal(isTypingTarget(el('body')), false)
  })
})

describe('isOpenModal / isMobileViewport', () => {
  it('detects aria-modal dialogs', () => {
    const open = { querySelector: (s) => (String(s).includes('aria-modal') ? el('div') : null) }
    const closed = { querySelector: () => null }
    assert.equal(isOpenModal(open), true)
    assert.equal(isOpenModal(closed), false)
    assert.equal(isOpenModal(null), false)
  })
  it('phones are ≤ 820px, matching the Omnibox fold (SPL-990)', () => {
    assert.equal(MOBILE_MAX, 820)
    assert.equal(isMobileViewport(390), true)
    assert.equal(isMobileViewport(820), true)
    assert.equal(isMobileViewport(821), false)
    assert.match(read('src/components/TopBar.vue'), /@media \(max-width: 820px\)/)
    assert.equal(isMobileViewport(1280), false)
    assert.equal(isMobileViewport(undefined), false)
  })
})

describe('slashFocusAction: /', () => {
  it('fires on / with no modifiers outside a field', () => {
    assert.equal(slashFocusAction(ev('/')), 'focus')
    assert.equal(slashFocusAction(ev('/', { shiftKey: true })), 'focus')
  })
  it('does not insert: ignored in typing targets, the Omnibox itself, modals, mobile, modifiers', () => {
    assert.equal(slashFocusAction(ev('/', { target: el('textarea') }), { inTypingTarget: true }), 'ignore')
    assert.equal(slashFocusAction(ev('/'), { inOmnibox: true }), 'ignore')
    assert.equal(slashFocusAction(ev('/'), { inModal: true }), 'ignore')
    assert.equal(slashFocusAction(ev('/'), { isMobile: true }), 'ignore')
    assert.equal(slashFocusAction(ev('/', { ctrlKey: true })), 'ignore')
    assert.equal(slashFocusAction(ev('/', { metaKey: true })), 'ignore')
    assert.equal(slashFocusAction(ev('/', { altKey: true })), 'ignore')
    assert.equal(slashFocusAction(ev('/', { defaultPrevented: true })), 'ignore')
    assert.equal(slashFocusAction(ev('/', { isComposing: true })), 'ignore')
    assert.equal(slashFocusAction(ev('/', { repeat: true })), 'ignore')
    assert.equal(slashFocusAction(ev('?')), 'ignore')
    assert.equal(slashFocusAction(ev('s')), 'ignore')
    assert.equal(slashFocusAction(ev('Slash')), 'ignore')
  })
})

describe('slashFocusAction: Escape restores', () => {
  it('restores when the Omnibox is focused after a / jump', () => {
    assert.equal(slashFocusAction(ev('Escape'), { inOmnibox: true, hasRestore: true }), 'restore')
  })
  it('CONTROL: leaves pickers, code blocks, and a clicked-in Omnibox alone', () => {
    assert.equal(slashFocusAction(ev('Escape'), { inOmnibox: true, hasRestore: true, pickerOpen: true }), 'ignore')
    assert.equal(slashFocusAction(ev('Escape'), { inOmnibox: true, hasRestore: true, inCode: true }), 'ignore')
    assert.equal(slashFocusAction(ev('Escape'), { inOmnibox: true, hasRestore: false }), 'ignore')
    assert.equal(slashFocusAction(ev('Escape'), { inOmnibox: false, hasRestore: true }), 'ignore')
  })
})

describe('slashFocusContext', () => {
  it('treats only the Omnibox textarea as inOmnibox (send button is not)', () => {
    const ta = el('textarea')
    const btn = el('button')
    const root = el('div', {
      querySelector: (sel) => (sel === 'textarea' ? ta : sel === '[role="listbox"]' ? null : null),
      contains: (n) => n === ta || n === btn,
    })
    ta.contains = (n) => n === ta
    assert.equal(eventInOmnibox(ta, root), true)
    assert.equal(eventInOmnibox(btn, root), false)
    const ctx = slashFocusContext(ev('/', { target: ta }), {
      omniboxRoot: root,
      document: { querySelector: () => null },
      viewportWidth: 1280,
    })
    assert.equal(ctx.inOmnibox, true)
    assert.equal(ctx.inTypingTarget, true)
    assert.equal(ctx.inModal, false)
    assert.equal(ctx.isMobile, false)
    assert.equal(slashFocusAction(ev('/', { target: ta }), ctx), 'ignore')
  })
  it('flags an open dialog as inModal', () => {
    const ctx = slashFocusContext(ev('/', { target: el('div') }), {
      document: { querySelector: () => el('div') },
      viewportWidth: 1280,
    })
    assert.equal(ctx.inModal, true)
    assert.equal(slashFocusAction(ev('/'), ctx), 'ignore')
  })
})

describe('wiring: TopBar + MessageComposer + i18n', () => {
  it('TopBar listens in capture, focuses the composer, and restores on Escape', () => {
    const bar = read('src/components/TopBar.vue')
    assert.match(bar, /from '~\/utils\/slash-focus\.mjs'/)
    assert.match(bar, /slashFocusAction/)
    assert.match(bar, /slashFocusContext/)
    assert.match(bar, /addEventListener\('keydown', onDocKey, true\)/)
    assert.match(bar, /removeEventListener\('keydown', onDocKey, true\)/)
    assert.match(bar, /composer\.value\?\.focus\(\)/)
    assert.match(bar, /data-test="slash-shortcut-hint"/)
    assert.match(bar, /t\('search\.slash_shortcut'\)/)
    assert.doesNotMatch(bar, /slash-badge/)
    assert.doesNotMatch(bar, /slash_badge_title/)
  })
  it('the omnibox stays a flex row and the composer grows inside it', () => {
    const bar = read('src/components/TopBar.vue')
    const omni = bar.slice(bar.indexOf('.top-bar__omnibox {'))
    assert.match(omni.slice(0, omni.indexOf('}')), /display:\s*flex/)
    assert.match(bar, /\.top-bar__omnibox > \.composer \{[\s\S]*?flex: 1 1 auto/)
  })
  it('the global Omnibox exposes the shortcut to assistive tech', () => {
    const src = read('src/components/MessageComposer.vue')
    assert.match(src, /:aria-keyshortcuts="global \? '\/' : undefined"/)
    assert.match(src, /search\.slash_shortcut/)
    assert.match(src, /slashHintId/)
  })
  it('CONTROL: /search mode helpers are unchanged', () => {
    const search = read('src/utils/search.mjs')
    assert.match(search, /export function omniboxMode/)
    assert.match(search, /export function searchQueryOf/)
  })
  it('all 19 locales have the slash-shortcut strings (non-en are machine drafts)', () => {
    const dir = join(WUI, 'i18n/locales')
    const files = readdirSync(dir).filter((f) => f.endsWith('.json')).sort()
    assert.equal(files.length, 19)
    const en = JSON.parse(read('i18n/locales/en.json'))
    assert.equal(en.search.slash_shortcut, 'Press / to focus the omnibox. Escape returns to where you were.')
    assert.equal(en.search.slash_badge_title, undefined)
    for (const f of files) {
      const data = JSON.parse(read(`i18n/locales/${f}`))
      assert.equal(typeof data.search.slash_shortcut, 'string', f)
      assert.ok(data.search.slash_shortcut.trim().length > 0, f)
      assert.equal(data.search.slash_badge_title, undefined, f)
    }
  })
})
