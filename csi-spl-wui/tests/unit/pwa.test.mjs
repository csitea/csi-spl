// PWA install (mobile step 1): a manifest, its icons and a service worker,
// so the WUI installs to a phone home screen. Since W9 the worker keeps an
// app shell that never outlives a deploy (sw-app-shell.test.mjs).
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

  it('W9: the service worker caches only the app shell, keyed by build, with its own kill switch', () => {
    const sw = src('src/public/sw.js').replace(/^\s*\/\/.*$/gm, '')
    /* behaviour: tests/unit/sw-app-shell.test.mjs drives the fetch handler */
    assert.match(sw, /const SHELL_CACHE = 'spool-shell-v1'/)
    assert.match(sw, /navigationPreload\.enable\(\)/)
    assert.match(sw, /k !== SHELL_CACHE\)\.map\(\(k\) => caches\.delete\(k\)\)/)
    assert.doesNotMatch(sw, /\.addAll\(/, 'no precache: only documents the network just served')
  })

  it('W9: a stale-shell notice from the worker moves the tab by build-watch rules', () => {
    const p = src('src/plugins/pwa.client.ts')
    assert.match(p, /const SHELL_STALE = 'spool:shell-stale'/)
    assert.match(src('src/public/sw.js'), /const SHELL_STALE = 'spool:shell-stale'/)
    assert.match(p, /decide\(\{ running: watch\.value\.running, live, busy: pageBusy\(\), guard \}\)/)
    assert.match(p, /const guard = readReloadGuard\(\)/)
    assert.match(p, /if \(act === 'reload'\) return reloadForBuild\(live\)/)
    assert.match(p, /idleSeen = pageBusy\(\) \? 0 : idleSeen \+ 1/)
  })

  it('SPL-990: the viewport covers the notch and resizes for the keyboard', () => {
    const cfg = src('nuxt.config.ts')
    assert.match(cfg, /name: "viewport", content: "width=device-width, initial-scale=1, viewport-fit=cover, interactive-widget=resizes-content"/)
    /* cover without the insets would put the bar under the status bar */
    assert.match(src('src/components/TopBar.vue'), /env\(safe-area-inset-top, 0px\)/)
    assert.doesNotMatch(cfg, /user-scalable=no|maximum-scale/, 'pinch zoom stays on')
  })

  it('the head links the apple touch icon; the manifest is linked once the first page is ready', () => {
    const cfg = src('nuxt.config.ts')
    assert.match(cfg, /rel: "apple-touch-icon", href: "\/icons\/apple-touch-icon\.png"/)
    /* CLE-77933: in the document head Chrome fetched manifest + icon-192 before the rail */
    assert.doesNotMatch(cfg, /rel: "manifest"/)
    const p = src('src/plugins/pwa.client.ts')
    assert.match(p, /const MANIFEST_HREF = '\/manifest\.webmanifest'/)
    assert.match(p, /onNuxtReady\(\(\) => \{\s*if \(!document\.querySelector\('link\[rel="manifest"\]'\)\)/)
    assert.match(p, /link\.rel = 'manifest'/)
  })

  it('the worker is registered only in a built bundle', () => {
    const p = src('src/plugins/pwa.client.ts')
    assert.match(p, /if \(import\.meta\.dev\) return/)
    assert.match(p, /register\('\/sw\.js'/)
  })
})
