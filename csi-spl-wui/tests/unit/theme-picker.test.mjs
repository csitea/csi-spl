// Palette picker: the five options, persistence, and keyboard.
// The component (ThemeToggle.vue) and theme-toggle.test.mjs are CLE-34994's.
// This file locks the contract the live proof drives.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  THEME_KEY,
  THEME_DEFAULT,
  THEMES,
  THEME_IDS,
  parseTheme,
  labelKeyForTheme,
  themeIndex,
  readStoredTheme,
  writeStoredTheme,
  applyThemeAttr,
} from '../../src/utils/theme.mjs'
import { memoryStore } from '../../src/utils/prefs.mjs'
import { nextMenuIndex } from '../../src/utils/user-menu.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (rel) => readFileSync(join(WUI, rel), 'utf8')

const NAMES = {
  dark: 'theme.dark',
  light: 'theme.light',
  'light-violet': 'theme.light_violet',
  'light-green': 'theme.light_green',
  'light-yellow': 'theme.light_yellow',
}

describe('palette options', () => {
  it('lists dark, light, light-violet, light-green, light-yellow', () => {
    assert.deepEqual(THEME_IDS, ['dark', 'light', 'light-violet', 'light-green', 'light-yellow'])
    assert.equal(THEMES.length, 5)
    assert.equal(THEME_DEFAULT, 'dark')
    assert.equal(THEME_KEY, 'spool-theme')
  })

  it('names each option from the theme catalogue', () => {
    for (const id of THEME_IDS) {
      assert.equal(labelKeyForTheme(id), NAMES[id])
      assert.equal(themeIndex(id), THEME_IDS.indexOf(id))
    }
    assert.equal(labelKeyForTheme('nope'), 'theme.dark')
    assert.equal(themeIndex('nope'), 0)
    const en = JSON.parse(read('i18n/locales/en.json')).theme
    assert.equal(en.picker, 'Choose a theme')
    assert.equal(en.dark, 'Dark')
    assert.equal(en.light, 'Light')
    assert.equal(en.light_violet, 'Light violet')
    assert.equal(en.light_green, 'Light green')
    assert.equal(en.light_yellow, 'Light yellow')
  })

  it('each swatch background is that theme\'s --color-bg', () => {
    const vars = read('src/assets/css/variables.css')
    for (const t of THEMES) {
      assert.equal(t.swatch.length, 2)
      const scope = `:root[data-theme="${t.id}"]`
      const at = vars.indexOf(scope + ' {')
      assert.ok(at > 0, scope)
      const block = vars.slice(at, vars.indexOf('\n}', at))
      assert.match(block, new RegExp(`--color-bg: ${t.swatch[0]};`))
      assert.match(block, new RegExp(`--color-accent: ${t.swatch[1]};`))
    }
  })
})

describe('palette persistence', () => {
  it('parseTheme keeps the five ids and drops anything else to dark', () => {
    for (const id of THEME_IDS) assert.equal(parseTheme(id), id)
    for (const junk of ['', null, 'system', 'violet', 'light-purple']) {
      assert.equal(parseTheme(junk), 'dark')
    }
  })

  it('stores every theme and forgets a junk value', () => {
    const store = memoryStore()
    assert.equal(readStoredTheme(store), 'dark')
    for (const id of THEME_IDS) {
      assert.equal(writeStoredTheme(id, store), true)
      assert.equal(store.getItem(THEME_KEY), id)
      assert.equal(readStoredTheme(store), id)
    }
    store.setItem(THEME_KEY, 'nope')
    assert.equal(readStoredTheme(store), 'dark')
  })

  it('a private-mode store does not throw', () => {
    const boom = {
      getItem() { throw new Error('denied') },
      setItem() { throw new Error('denied') },
    }
    assert.equal(readStoredTheme(boom), 'dark')
    assert.equal(writeStoredTheme('light-green', boom), false)
  })

  it('applyThemeAttr writes data-theme and rejects junk', () => {
    const el = { attrs: {}, setAttribute(k, v) { this.attrs[k] = v } }
    assert.equal(applyThemeAttr('light-violet', el), 'light-violet')
    assert.equal(el.attrs['data-theme'], 'light-violet')
    applyThemeAttr('nope', el)
    assert.equal(el.attrs['data-theme'], 'dark')
  })
})

describe('palette keyboard', () => {
  it('arrows wrap, Home and End jump, Escape and Tab close', () => {
    const n = THEMES.length
    assert.equal(nextMenuIndex(0, 'ArrowDown', n), 1)
    assert.equal(nextMenuIndex(n - 1, 'ArrowDown', n), 0)
    assert.equal(nextMenuIndex(0, 'ArrowUp', n), n - 1)
    assert.equal(nextMenuIndex(2, 'ArrowUp', n), 1)
    assert.equal(nextMenuIndex(3, 'Home', n), 0)
    assert.equal(nextMenuIndex(0, 'End', n), n - 1)
    assert.equal(nextMenuIndex(2, 'Escape', n), -1)
    assert.equal(nextMenuIndex(2, 'Tab', n), -1)
    assert.equal(nextMenuIndex(2, 'a', n), 2)
    assert.equal(nextMenuIndex(-1, 'ArrowDown', n), 0)
    assert.equal(nextMenuIndex(-1, 'ArrowUp', n), n - 1)
  })

  it('the button opens on the current theme; Enter or Space chooses it', () => {
    const src = read('src/components/ThemeToggle.vue')
    assert.match(src, /data-test="theme-picker"/)
    assert.match(src, /data-test="theme-picker-list"/)
    assert.match(src, /:data-test="'theme-option-' \+ opt\.id"/)
    assert.match(src, /aria-haspopup="listbox"/)
    assert.match(src, /role="listbox"/)
    assert.match(src, /role="option"/)
    assert.match(src, /type="button"/)
    assert.match(src, /@click="toggleOpen"/)
    assert.match(src, /openAt\(themeIndex\(theme\.value\)\)/)
    assert.match(src, /e\.key === 'ArrowDown' \|\| e\.key === 'ArrowUp'/)
    assert.match(src, /e\.key === 'Enter' \|\| e\.key === ' '/)
    assert.match(src, /const opt = THEMES\[focused\.value\]/)
    assert.match(src, /choose\(opt\.id\)/)
    assert.match(src, /nextMenuIndex\(focused\.value, e\.key, THEMES\.length\)/)
    assert.match(src, /e\.key === 'Escape'\) \{ e\.preventDefault\(\); close\(true\) \} else close\(false\)/)
    assert.match(src, /pointerdown/)
    assert.match(src, /!root\.value\.contains\(e\.target as Node\)\) close\(false\)/)
    assert.match(src, /name="palette"/)
    assert.match(src, /t\('theme\.picker'\)/)
    for (const id of THEME_IDS) {
      assert.equal(THEMES[themeIndex(id)].id, id)
    }
  })

  it('settings opens the same picker toward the end of the row', () => {
    const src = read('src/pages/settings/appearance.vue')
    assert.match(src, /<ThemeToggle align="end"/)
  })
})
