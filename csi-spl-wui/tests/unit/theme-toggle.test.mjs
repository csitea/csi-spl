// Theme picker (was the GRK-3374 toggle): five themes, persisted,
// chosen from a palette-icon listbox.
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
  saveThemeToAccount,
} from '../../src/utils/theme.mjs'
import { memoryStore } from '../../src/utils/prefs.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (rel) => readFileSync(join(WUI, rel), 'utf8')

describe('theme persist + mapping', () => {
  it('seven themes, dark first, dark the default', () => {
    assert.deepEqual(THEME_IDS, ['dark', 'light', 'light-violet', 'light-green', 'light-yellow', 'light-orange', 'light-red'])
    assert.equal(THEME_DEFAULT, 'dark')
    assert.equal(THEME_KEY, 'spool-theme')
  })

  it('parseTheme accepts only the palette ids and defaults to dark', () => {
    for (const id of THEME_IDS) assert.equal(parseTheme(id), id)
    assert.equal(parseTheme(''), 'dark')
    assert.equal(parseTheme(null), 'dark')
    assert.equal(parseTheme('system'), 'dark')
    assert.equal(parseTheme('violet'), 'dark')
  })

  it('each theme has a name key and an index', () => {
    assert.equal(labelKeyForTheme('dark'), 'theme.dark')
    assert.equal(labelKeyForTheme('light'), 'theme.light')
    assert.equal(labelKeyForTheme('light-violet'), 'theme.light_violet')
    assert.equal(labelKeyForTheme('light-green'), 'theme.light_green')
    assert.equal(labelKeyForTheme('light-yellow'), 'theme.light_yellow')
    assert.equal(labelKeyForTheme('light-orange'), 'theme.light_orange')
    assert.equal(labelKeyForTheme('light-red'), 'theme.light_red')
    assert.equal(labelKeyForTheme('junk'), 'theme.dark')
    assert.equal(themeIndex('light-green'), 3)
    assert.equal(themeIndex('junk'), 0)
  })

  it('persists in storage and survives junk values', () => {
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
    assert.equal(applyThemeAttr('light-yellow', el), 'light-yellow')
    assert.equal(el.attrs['data-theme'], 'light-yellow')
    applyThemeAttr('nope', el)
    assert.equal(el.attrs['data-theme'], 'dark')
  })
})

describe('theme picker wiring', () => {
  it('uiIcons has a path-only palette glyph', () => {
    const src = read('src/utils/uiIcons.ts')
    assert.match(src, /\bpalette:\s*\[/)
    const block = src.slice(src.indexOf('palette:'), src.indexOf('],', src.indexOf('palette:')))
    assert.equal(/<circle|<rect/.test(block), false)
    assert.equal(/\bsun:\s*\[|\bmoon:\s*\[/.test(src), false, 'the toggle glyphs went with the toggle')
  })

  it('ThemeToggle is a palette button that opens a listbox of THEMES', () => {
    const src = read('src/components/ThemeToggle.vue')
    assert.match(src, /class="icon-btn/)
    assert.match(src, /data-test="theme-picker"/)
    assert.match(src, /name="palette"/)
    assert.match(src, /aria-haspopup="listbox"/)
    assert.match(src, /:aria-expanded=/)
    assert.match(src, /:aria-label="label"/)
    assert.match(src, /:title="label"/)
    assert.match(src, /role="listbox"/)
    assert.match(src, /role="option"/)
    assert.match(src, /v-for="\(opt, i\) in THEMES"/)
    assert.match(src, /:aria-selected="opt\.id === theme/)
    assert.match(src, /t\('theme\.picker'\)/)
    /* focus goes back to the button on choose and on Escape */
    assert.match(src, /function choose[\s\S]*?close\(true\)/)
    assert.match(src, /'Escape'[\s\S]*?close\(true\)/)
    /* no style attribute: the deployed CSP hashes styles */
    assert.equal(/:style=|\sstyle="/.test(src.slice(0, src.indexOf('<script'))), false)
  })

  it('each swatch class matches the theme it previews (THEMES[].swatch, variables.css)', () => {
    const src = read('src/components/ThemeToggle.vue')
    const vars = read('src/assets/css/variables.css')
    for (const t of THEMES) {
      const rule = src.match(new RegExp(`\\.theme-picker__swatch--${t.id} \\{[^}]*\\}`))
      assert.ok(rule, `swatch class for ${t.id}`)
      assert.ok(rule[0].includes(t.swatch[0]) && rule[0].includes(t.swatch[1]), `${t.id} swatch ${rule[0]}`)
      const scope = t.id === 'dark' ? ':root[data-theme="dark"]' : `:root[data-theme="${t.id}"]`
      const block = vars.slice(vars.indexOf(scope + ' {'), vars.indexOf('\n}', vars.indexOf(scope + ' {')))
      assert.match(block, new RegExp(`--color-bg: ${t.swatch[0]};`), `${t.id} bg`)
      assert.match(block, new RegExp(`--color-accent: ${t.swatch[1]};`), `${t.id} accent`)
    }
  })

  it('TopBar places the picker immediately right of the tenant drop box (the brand text is gone)', () => {
    const src = read('src/components/TopBar.vue')
    const box = src.indexOf('<TenantDropBox')
    const toggle = src.indexOf('<ThemeToggle')
    assert.ok(box > 0 && toggle > box, 'ThemeToggle after the tenant drop box')
    const between = src.slice(box, toggle)
    assert.equal(between.includes('top-bar__omnibox'), false)
    assert.doesNotMatch(src, /top-bar__brand|>spool-hub<\/NuxtLink>/)
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

  it('en catalogue names every theme and the picker (19-locale parity is i18n-parity)', () => {
    const en = JSON.parse(read('i18n/locales/en.json'))
    assert.equal(typeof en.theme.picker, 'string')
    for (const t of THEMES) {
      const leaf = t.labelKey.split('.').reduce((o, k) => (o ? o[k] : undefined), en)
      assert.equal(typeof leaf, 'string', t.labelKey)
    }
  })
})

// CLE-34994 follow-up: the pick is kept on the account (PUT preferences
// preferred_theme), the same field an operator sets with do_spl_human_theme.
describe('theme pick saved on the account', () => {
  const rig = (claims, result = { ok: true }) => {
    const calls = { save: [], apply: [] }
    const io = {
      claims,
      save: async (t) => { calls.save.push(t); if (result instanceof Error) throw result; return result },
      apply: (t) => calls.apply.push(t),
    }
    return { io, calls }
  }

  it('a signed-in member saves the pick and mirrors it in the claims', async () => {
    const { io, calls } = rig({ hum: 'HUM-27', preferred_theme: 'light' })
    assert.equal(await saveThemeToAccount('light-green', io), true)
    assert.deepEqual(calls, { save: ['light-green'], apply: ['light-green'] })
  })

  it('no call when signed out, with no member id, or already stored', async () => {
    for (const claims of [null, undefined, {}, { hum: '' }, { hum: 'HUM-27', preferred_theme: 'dark' }]) {
      const { io, calls } = rig(claims)
      assert.equal(await saveThemeToAccount('dark', io), false, JSON.stringify(claims))
      assert.deepEqual(calls.save, [], JSON.stringify(claims))
    }
  })

  it('never sends a value the hub would refuse', async () => {
    const { io, calls } = rig({ hum: 'HUM-27' })
    assert.equal(await saveThemeToAccount('navy', io), false)
    assert.deepEqual(calls.save, [])
  })

  it('a refused or failed save is silent and changes no claim', async () => {
    for (const result of [{ ok: false, status: 409 }, null, new Error('offline')]) {
      const { io, calls } = rig({ hum: 'HUM-27' }, result)
      assert.equal(await saveThemeToAccount('light', io), false)
      assert.deepEqual(calls.apply, [])
    }
  })

  it('the picker calls it on choose, through the auth client', () => {
    const src = read('src/components/ThemeToggle.vue')
    assert.match(src, /function choose[\s\S]*?saveThemeToAccount\(id,/)
    assert.match(src, /save: \(t\) => auth\.saveTheme\(t\)/)
    const client = read('src/utils/auth-client.mjs')
    assert.match(client, /saveTheme\(theme\) \{\s*return post\('\/preferences', \{ preferred_theme: /)
  })
})
