// Theme toggle: persist + destination icon (sun in dark, half-moon in light).
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  THEME_KEY,
  THEME_DEFAULT,
  parseTheme,
  nextTheme,
  iconForTheme,
  labelKeyForTheme,
  readStoredTheme,
  writeStoredTheme,
  applyThemeAttr,
} from '../../src/utils/theme.mjs'
import { memoryStore } from '../../src/utils/prefs.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (rel) => readFileSync(join(WUI, rel), 'utf8')

describe('theme persist + toggle mapping', () => {
  it('parseTheme accepts only dark|light and defaults to dark', () => {
    assert.equal(parseTheme('dark'), 'dark')
    assert.equal(parseTheme('light'), 'light')
    assert.equal(parseTheme(''), 'dark')
    assert.equal(parseTheme(null), 'dark')
    assert.equal(parseTheme('system'), 'dark')
    assert.equal(THEME_DEFAULT, 'dark')
    assert.equal(THEME_KEY, 'spool-theme')
  })

  it('toggle flips and shows the destination icon (sun in dark, moon in light)', () => {
    assert.equal(nextTheme('dark'), 'light')
    assert.equal(nextTheme('light'), 'dark')
    assert.equal(iconForTheme('dark'), 'sun')
    assert.equal(iconForTheme('light'), 'moon')
    assert.equal(labelKeyForTheme('dark'), 'theme.to_light')
    assert.equal(labelKeyForTheme('light'), 'theme.to_dark')
  })

  it('persists in storage and survives junk values', () => {
    const store = memoryStore()
    assert.equal(readStoredTheme(store), 'dark')
    assert.equal(writeStoredTheme('light', store), true)
    assert.equal(store.getItem(THEME_KEY), 'light')
    assert.equal(readStoredTheme(store), 'light')
    store.setItem(THEME_KEY, 'nope')
    assert.equal(readStoredTheme(store), 'dark')
  })

  it('private-mode store does not throw', () => {
    const boom = {
      getItem() { throw new Error('denied') },
      setItem() { throw new Error('denied') },
    }
    assert.equal(readStoredTheme(boom), 'dark')
    assert.equal(writeStoredTheme('light', boom), false)
  })

  it('applyThemeAttr sets data-theme on the root', () => {
    const el = { attrs: {}, setAttribute(k, v) { this.attrs[k] = v } }
    assert.equal(applyThemeAttr('light', el), 'light')
    assert.equal(el.attrs['data-theme'], 'light')
    applyThemeAttr('nope', el)
    assert.equal(el.attrs['data-theme'], 'dark')
  })
})

describe('theme toggle wiring', () => {
  it('uiIcons has path-only lucide sun and moon', () => {
    const src = read('src/utils/uiIcons.ts')
    assert.match(src, /\bsun:\s*\[/)
    assert.match(src, /\bmoon:\s*\[/)
    assert.match(src, /M12 8a4 4 0 1 0 0 8/)
    assert.match(src, /M12 3a6 6 0 0 0 9 9/)
    const sunBlock = src.slice(src.indexOf('sun:'), src.indexOf('moon:'))
    assert.equal(/<circle|<rect/.test(sunBlock), false)
  })

  it('ThemeToggle is an icon-only button with i18n name + aria-pressed', () => {
    const src = read('src/components/ThemeToggle.vue')
    assert.match(src, /class="icon-btn/)
    assert.match(src, /data-test="theme-toggle"/)
    assert.match(src, /:aria-label="label"/)
    assert.match(src, /:title="label"/)
    assert.match(src, /aria-pressed/)
    assert.match(src, /iconForTheme/)
    assert.match(src, /labelKeyForTheme/)
    assert.equal(src.includes("t('theme.light')"), false)
    assert.equal(src.includes("t('theme.dark')"), false)
  })

  it('TopBar places the toggle immediately right of the brand', () => {
    const src = read('src/components/TopBar.vue')
    const brand = src.indexOf('top-bar__brand')
    const toggle = src.indexOf('<ThemeToggle')
    assert.ok(brand > 0 && toggle > brand, 'ThemeToggle after brand')
    const between = src.slice(brand, toggle)
    assert.equal(between.includes('top-bar__omnibox'), false)
    assert.match(src, /top-bar__start/)
  })

  it('ChannelSidebar no longer hosts a second theme control', () => {
    const src = read('src/components/ChannelSidebar.vue')
    assert.equal(src.includes('ThemeToggle'), false)
    assert.equal(src.includes('sidebar-brand'), false)
  })

  it('settings appearance keeps a labelled ThemeToggle (same component)', () => {
    const src = read('src/pages/settings/appearance.vue')
    assert.match(src, /t\('settings\.theme'\)/)
    assert.match(src, /<ThemeToggle/)
  })

  it('en catalogue has Switch to light/dark theme (19-locale parity is i18n-parity)', () => {
    const en = JSON.parse(read('i18n/locales/en.json'))
    assert.equal(en.theme.to_light, 'Switch to light theme')
    assert.equal(en.theme.to_dark, 'Switch to dark theme')
  })
})
