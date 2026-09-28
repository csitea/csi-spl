// Owner 2026-09-27 (topic 38ba1dae): the top-bar logo is small; a click opens
// it at its true size in a centred dialog with the slogan "spool-hub - where
// humans and ai meet". The dialog is the shared UiDialog, loaded lazily, and
// the slogan is in every locale.
//
// Run: node tests/unit/logo-dialog.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { existsSync, readFileSync, readdirSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const src = (rel) => readFileSync(join(WUI, rel), 'utf8')

describe('the logo dialog', () => {
  const topBar = src('src/components/TopBar.vue')
  const dialog = src('src/components/LogoDialog.vue')

  it('the top-bar logo is a button that opens the dialog, mounted only when asked for', () => {
    assert.match(topBar, /<button type="button" class="top-bar__logo" data-test="top-bar-logo"[^>]*@click="logoOpen = true"/)
    assert.match(topBar, /<LazyLogoDialog v-if="logoOpen" v-model:open="logoOpen" \/>/)
    assert.match(topBar, /const logoOpen = ref\(false\)/)
  })

  it('shows the true-size picture and the slogan in the shared UiDialog', () => {
    assert.match(dialog, /<UiDialog :open="open"/)
    assert.match(dialog, /src="\/spool-hub-emblem\.webp"/)
    assert.match(dialog, /data-testid="logo-dialog-slogan"/)
    assert.match(dialog, /t\('logo\.slogan'\)/)
    assert.ok(existsSync(join(WUI, 'src/public/spool-hub-emblem.webp')))
    assert.ok(existsSync(join(WUI, 'src/public/logo.webp')))
  })

  it('SPL-1150: a compact card - what spool-hub is, the version, the source and the docs', () => {
    assert.match(dialog, /size="card"/)
    for (const id of ['logo-dialog-about', 'logo-dialog-version', 'logo-dialog-source', 'logo-dialog-docs']) assert.match(dialog, new RegExp(`data-testid="${id}"`))
    assert.match(dialog, /'https:\/\/github\.com\/csitea\/csi-spl'/)
    assert.match(dialog, /useRuntimeConfig\(\)\.public\.appVersion/)
    assert.match(dialog, /rel="noopener noreferrer"/)
    const ui = src('src/components/UiDialog.vue')
    assert.match(ui, /<Transition :name="size === 'card' \? 'ui-dialog-pop' : 'ui-dialog-none'" appear>/)
    assert.match(ui, /\.ui-dialog\.card \{\n  max-width: 720px;/)
    assert.match(ui, /@media \(prefers-reduced-motion: reduce\) \{\n  \.ui-dialog-pop-enter-active,/)
    assert.match(topBar, /\.top-bar__logo:hover img,/)
  })

  it('every locale has the slogan and the button label', () => {
    const dir = join(WUI, 'i18n/locales')
    const files = readdirSync(dir).filter((f) => f.endsWith('.json'))
    assert.ok(files.length >= 19)
    for (const f of files) {
      const d = JSON.parse(readFileSync(join(dir, f), 'utf8'))
      assert.ok(d.logo && d.logo.slogan && d.logo.open, `${f}: logo.slogan + logo.open`)
      for (const k of ['about', 'version', 'source', 'docs']) assert.ok(d.logo[k], `${f}: logo.${k}`)
    }
    assert.equal(JSON.parse(src('i18n/locales/en.json')).logo.slogan, 'where humans and AI meet')
  })
})
