// PWA install (mobile step 1): a manifest, its icons and a service worker
// that caches nothing, so the WUI installs to a phone home screen without
// ever serving a stale bundle after a deploy.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync, existsSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const src = (rel) => readFileSync(join(WUI, rel), 'utf8')

describe('pwa', () => {
  const manifest = JSON.parse(src('src/public/manifest.webmanifest'))

  it('the manifest is installable: name, start_url, standalone, 192 + 512 icons', () => {
    assert.equal(manifest.name, 'spool-hub')
    assert.equal(manifest.short_name, 'spool-hub')
    assert.equal(manifest.start_url, '/')
    assert.equal(manifest.display, 'standalone')
    const sizes = manifest.icons.map((i) => i.sizes)
    assert.ok(sizes.includes('192x192'))
    assert.ok(sizes.includes('512x512'))
    assert.ok(manifest.icons.some((i) => i.purpose === 'maskable'))
  })

  it('every icon the manifest names ships in public/', () => {
    for (const i of manifest.icons) assert.ok(existsSync(join(WUI, 'src/public', i.src)), i.src)
    assert.ok(existsSync(join(WUI, 'src/public/icons/apple-touch-icon.png')))
  })

  it('the service worker caches nothing and serves nothing', () => {
    const sw = src('src/public/sw.js').replace(/^\s*\/\/.*$/gm, '')
    assert.doesNotMatch(sw, /addEventListener\(\s*['"]fetch['"]/)
    assert.doesNotMatch(sw, /\.put\(|\.addAll\(|respondWith/)
    assert.match(sw, /caches\.delete/)
  })

  it('SPL-990: the viewport covers the notch and resizes for the keyboard', () => {
    const cfg = src('nuxt.config.ts')
    assert.match(cfg, /name: "viewport", content: "width=device-width, initial-scale=1, viewport-fit=cover, interactive-widget=resizes-content"/)
    /* cover without the insets would put the bar under the status bar */
    assert.match(src('src/components/TopBar.vue'), /env\(safe-area-inset-top, 0px\)/)
    assert.doesNotMatch(cfg, /user-scalable=no|maximum-scale/, 'pinch zoom stays on')
  })

  it('the head links the manifest and the apple touch icon', () => {
    const cfg = src('nuxt.config.ts')
    assert.match(cfg, /rel: "manifest", href: "\/manifest\.webmanifest"/)
    assert.match(cfg, /rel: "apple-touch-icon", href: "\/icons\/apple-touch-icon\.png"/)
  })

  it('the worker is registered only in a built bundle', () => {
    const p = src('src/plugins/pwa.client.ts')
    assert.match(p, /if \(import\.meta\.dev\) return/)
    assert.match(p, /register\('\/sw\.js'/)
  })
})
