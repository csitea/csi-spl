// The page never scrolls. A row menu on the last visible message stays inside
// the viewport, and focusing it does not move the document.
// Run: node tests/unit/page-never-scrolls.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { placePopover } from '../../src/utils/place-popover.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (rel) => readFileSync(join(WUI, rel), 'utf8')

describe('placePopover', () => {
  const view = { width: 1200, height: 640 }

  it('keeps a menu that fits where it was asked', () => {
    const box = placePopover({ x: 40, y: 80 }, { width: 180, height: 120 }, view)
    assert.equal(box.flipped, false)
    assert.equal(box.left, 40)
    assert.equal(box.top, 80)
    assert.ok(box.top + 120 <= view.height - 8)
  })

  it('pulls a menu back inside the right and left edges', () => {
    const right = placePopover({ x: 1100, y: 40 }, { width: 180, height: 80 }, view)
    assert.equal(right.left, 1200 - 8 - 180)
    const left = placePopover({ x: -40, y: 40 }, { width: 180, height: 80 }, view)
    assert.equal(left.left, 8)
  })

  it('the menu on the last visible row opens upward and stays inside the viewport', () => {
    const buttonBottom = 620
    const menuH = 220
    const box = placePopover(
      { x: 900, y: buttonBottom + 4, flipFrom: buttonBottom + 4 },
      { width: 180, height: menuH },
      view,
    )
    assert.equal(box.flipped, true)
    assert.ok(box.top >= 8)
    assert.ok(box.left >= 8)
    assert.ok(box.left + Math.min(180, box.maxWidth) <= view.width - 8)
    assert.ok(box.top + Math.min(menuH, box.maxHeight) <= view.height - 8)
    assert.ok(box.top < buttonBottom)
  })

  it('a menu taller than the viewport is pinned to the margin', () => {
    const box = placePopover({ x: 10, y: 400 }, { width: 100, height: 2000 }, { width: 800, height: 600 })
    assert.equal(box.top, 8)
    assert.equal(box.maxHeight, 600 - 16)
    assert.ok(box.top + box.maxHeight <= 600 - 8)
  })

  it('opens above a trigger when the caller names the trigger top', () => {
    const box = placePopover(
      { x: 20, y: 590, flipFrom: 540 },
      { width: 160, height: 200 },
      view,
    )
    assert.equal(box.flipped, true)
    assert.equal(box.top, 340)
  })
})

describe('the document never scrolls', () => {
  it('html and body are one viewport and do not scroll', () => {
    const css = read('src/assets/css/base.css')
    assert.match(css, /Document horizontal scroll on mobile is FORBIDDEN/)
    assert.match(css, /overflow-x:\s*clip/)
    assert.match(css, /overflow:\s*hidden/)
    assert.match(css, /overscroll-behavior:\s*none/)
    assert.match(css, /height:\s*100dvh/)
    assert.match(css, /#__nuxt \{[^}]*overflow:\s*hidden/)
    assert.doesNotMatch(css, /min-height:\s*100vh/)
  })

  it('the shell fills that viewport and the login body scrolls inside it', () => {
    const layout = read('src/layouts/default.vue')
    const login = read('src/layouts/login.vue')
    const main = read('src/assets/css/main.css')
    assert.match(layout, /height:\s*100%/)
    assert.match(layout, /overflow:\s*hidden/)
    assert.match(login, /\.login-body \{[^}]*overflow-y:\s*auto/)
    assert.match(login, /\.login-body \{[^}]*overscroll-behavior:\s*contain/)
    assert.doesNotMatch(main, /min-height:\s*100vh/)
  })
})

describe('menus are placed before they take focus', () => {
  const menus = [
    'src/components/MessageMenu.vue',
    'src/components/SidebarRowMenu.vue',
    'src/components/EmojiPicker.vue',
    'src/components/KindPicker.vue',
  ]

  it('the row menu, the emoji picker and the kind picker use the shared placer', () => {
    for (const rel of menus) {
      const src = read(rel)
      assert.match(src, /focusWithoutScroll\(/, rel)
      assert.match(src, /applyPopover/, rel)
      assert.match(src, /position:\s*fixed/, rel)
      assert.doesNotMatch(src, /\.focus\(/, rel)
    }
  })

  it('the message menu is placed, then focused, and it does not paint off-screen first', () => {
    const src = read('src/components/MessageMenu.vue')
    const open = src.slice(src.indexOf('async function onOpen'), src.indexOf('watch(() => props.open'))
    assert.match(open, /await place\(\)[\s\S]*focusItem\(0\)/)
    assert.doesNotMatch(src, /left\.value = props/)
    assert.match(src, /visibility:\s*hidden/)
  })

  it('the user menu, the theme list and the locale lists focus without scrolling the page', () => {
    for (const rel of ['src/components/UserMenu.vue', 'src/components/ThemeToggle.vue']) {
      const src = read(rel)
      assert.match(src, /focusWithoutScroll\(/, rel)
      assert.match(src, /applyPopover\(/, rel)
      assert.doesNotMatch(src, /\.focus\(/, rel)
    }
    assert.match(read('src/components/LanguageSwitcher.vue'), /observePopover\(/)
    assert.match(read('src/components/LocaleCombobox.vue'), /observePopover\(/)
  })
})
