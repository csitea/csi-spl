// perf round 3 P3-01: each prerendered document modulepreloads its first
// screen's scripts and preloads their CSS, from the client build's chunk
// graph (src/utils/first-screen-hints.mjs, wired in nuxt.config.ts).
//
// Pins: the set is the static-import closure of page + layout + locale (never
// a dynamic import, which would over-fetch), a hinted file loses its prefetch,
// nothing the document already names is added twice, the entry's own
// modulepreloads stay first, and the wiring skips 200.html / 404.html.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  DEFERRED_PREFETCH_ID, addFirstScreenHints, deferDocumentPrefetch, firstScreenChunkGraph, firstScreenFiles, firstScreenPageLayout, firstScreenRoutePage,
} from '../../src/utils/first-screen-hints.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')

const bundle = {
  '_nuxt/entry.js': { type: 'chunk', fileName: '_nuxt/entry.js', moduleIds: ['/w/entry.js'], imports: ['_nuxt/vue.js'], viteMetadata: { importedCss: new Set() } },
  '_nuxt/vue.js': { type: 'chunk', fileName: '_nuxt/vue.js', moduleIds: ['/w/node_modules/vue/index.js'], imports: [], viteMetadata: { importedCss: new Set() } },
  '_nuxt/index.js': { type: 'chunk', fileName: '_nuxt/index.js', moduleIds: ['/w/src/pages/index.vue', '/w/src/pages/index.vue?vue&type=style'], imports: ['_nuxt/shared.js', '_nuxt/vue.js'], dynamicImports: ['_nuxt/lazy.js'], viteMetadata: { importedCss: new Set(['_nuxt/index.css']) } },
  '_nuxt/shared.js': { type: 'chunk', fileName: '_nuxt/shared.js', moduleIds: ['/w/src/utils/a.mjs', '/w/src/layouts/default.vue'], imports: ['_nuxt/vue.js'], viteMetadata: { importedCss: new Set(['_nuxt/default.css', '_nuxt/index.css']) } },
  '_nuxt/lazy.js': { type: 'chunk', fileName: '_nuxt/lazy.js', moduleIds: ['/w/src/components/Lazy.vue'], imports: [], viteMetadata: { importedCss: new Set(['_nuxt/lazy.css']) } },
  '_nuxt/en.js': { type: 'chunk', fileName: '_nuxt/en.js', moduleIds: ['/w/i18n/locales/en.json?hash=1&locale=en'], imports: [], viteMetadata: { importedCss: new Set() } },
  '_nuxt/index.css': { type: 'asset', fileName: '_nuxt/index.css' },
}

describe('first-screen hints: the static closure from the chunk graph', () => {
  const graph = firstScreenChunkGraph(bundle)

  it('maps each module (query stripped) to its chunk', () => {
    assert.equal(graph.moduleChunk['/w/src/layouts/default.vue'], '_nuxt/shared.js')
    assert.equal(graph.moduleChunk['/w/i18n/locales/en.json'], '_nuxt/en.js')
    assert.equal(Object.keys(graph.chunks).length, 6, 'assets are not chunks')
  })

  it('walks static imports only: a dynamic import is never hinted', () => {
    const f = firstScreenFiles(graph, ['/w/src/pages/index.vue', '/w/src/layouts/default.vue', '/w/i18n/locales/en.json'])
    assert.deepEqual(f.scripts, ['_nuxt/index.js', '_nuxt/shared.js', '_nuxt/en.js', '_nuxt/vue.js'])
    assert.deepEqual(f.styles, ['_nuxt/index.css', '_nuxt/default.css'])
    assert.ok(!f.scripts.includes('_nuxt/lazy.js') && !f.styles.includes('_nuxt/lazy.css'))
  })

  it('an unknown root adds nothing', () => {
    assert.deepEqual(firstScreenFiles(graph, ['/w/src/pages/nope.vue']), { scripts: [], styles: [] })
  })
})

describe('first-screen hints: route -> page, layout', () => {
  const pages = [{ path: '/', file: '/w/src/pages/index.vue' }, { path: '/login', file: '/w/src/pages/login.vue' }, { path: '/channel/:name()', file: '/w/src/pages/channel/[name].vue' }, { path: '/help/:page?', file: '/w/src/pages/help/[[page]].vue' }]
  const codes = ['bg', 'en', 'fi']

  it('strips the locale prefix and names the locale', () => {
    assert.deepEqual(firstScreenRoutePage('/', pages, codes, 'en'), { file: '/w/src/pages/index.vue', locale: 'en' })
    assert.deepEqual(firstScreenRoutePage('/fi', pages, codes, 'en'), { file: '/w/src/pages/index.vue', locale: 'fi' })
    assert.deepEqual(firstScreenRoutePage('/fi/login', pages, codes, 'en'), { file: '/w/src/pages/login.vue', locale: 'fi' })
    assert.deepEqual(firstScreenRoutePage('/login/', pages, codes, 'en'), { file: '/w/src/pages/login.vue', locale: 'en' })
    assert.deepEqual(firstScreenRoutePage('/channel/general', pages, codes, 'en'), { file: '/w/src/pages/channel/[name].vue', locale: 'en' })
    assert.equal(firstScreenRoutePage('/nope', pages, codes, 'en'), null)
  })

  it('matches an optional param with and without its segment (spec 116 T7: /help prerenders)', () => {
    assert.deepEqual(firstScreenRoutePage('/help', pages, codes, 'en'), { file: '/w/src/pages/help/[[page]].vue', locale: 'en' })
    assert.deepEqual(firstScreenRoutePage('/help/agents', pages, codes, 'en'), { file: '/w/src/pages/help/[[page]].vue', locale: 'en' })
    assert.equal(firstScreenRoutePage('/help/a/b', pages, codes, 'en'), null)
  })

  it('reads the layout from definePageMeta, else default', () => {
    assert.equal(firstScreenPageLayout("definePageMeta({ layout: 'login', scrollToTop: false })"), 'login')
    assert.equal(firstScreenPageLayout('definePageMeta({ middleware: [] })'), 'default')
    assert.equal(firstScreenPageLayout(''), 'default')
    assert.equal(firstScreenPageLayout(readFileSync(join(WUI, 'src/pages/login.vue'), 'utf8')), 'login')
    assert.equal(firstScreenPageLayout(readFileSync(join(WUI, 'src/pages/index.vue'), 'utf8')), 'default')
  })
})

describe('first-screen hints: the document rewrite', () => {
  const doc = '<head><style>x</style>'
    + '<link rel="modulepreload" as="script" crossorigin href="/_nuxt/entry.js">'
    + '<link rel="modulepreload" as="script" crossorigin href="/_nuxt/vue.js">'
    + '<script type="module" src="/_nuxt/entry.js" crossorigin></script>'
    + '<link rel="prefetch" as="script" crossorigin href="/_nuxt/index.js">'
    + '<link rel="prefetch" as="style" crossorigin href="/_nuxt/index.css">'
    + '<link rel="prefetch" as="script" crossorigin href="/_nuxt/lazy.js">'
    + '<link rel="stylesheet" href="/_nuxt/default.css" crossorigin>'
    + '</head><body></body>'
  const files = { scripts: ['_nuxt/index.js', '_nuxt/vue.js'], styles: ['_nuxt/index.css', '_nuxt/default.css'] }
  const { html, added } = addFirstScreenHints(doc, files, '/')

  it('adds a modulepreload / style preload once, after the entry modulepreloads', () => {
    assert.equal(added, 2)
    assert.equal((html.match(/href="\/_nuxt\/vue\.js"/g) || []).length, 1, 'already modulepreloaded')
    assert.equal((html.match(/href="\/_nuxt\/default\.css"/g) || []).length, 1, 'already a stylesheet')
    assert.ok(html.indexOf('href="/_nuxt/vue.js"') < html.indexOf('rel="modulepreload" as="script" crossorigin href="/_nuxt/index.js"'))
    assert.match(html, /<link rel="preload" as="style" crossorigin href="\/_nuxt\/index\.css">/)
  })

  it('drops the prefetch of a hinted file and keeps every other prefetch', () => {
    assert.doesNotMatch(html, /rel="prefetch"[^>]*index\.(js|css)/)
    assert.match(html, /<link rel="prefetch" as="script" crossorigin href="\/_nuxt\/lazy\.js">/)
  })

  it('a document with nothing to add is returned as is', () => {
    assert.deepEqual(addFirstScreenHints(doc, { scripts: [], styles: [] }, '/'), { html: doc, added: 0 })
  })
})

describe('first-screen hints: nuxt.config wiring', () => {
  const cfg = readFileSync(join(WUI, 'nuxt.config.ts'), 'utf8')

  it('the module is registered and collects the CLIENT graph only', () => {
    assert.match(cfg, /modules: \[[^\]]*firstScreenHintsModule[^\]]*\]/)
    assert.match(cfg, /generateBundle\(_opts, bundle\) \{\s*graph = firstScreenChunkGraph\(bundle\)/)
    assert.match(cfg, /\}, \{ server: false \}\)/)
  })

  it('200.html and 404.html are never rewritten, and a miss fails the generate', () => {
    assert.match(cfg, /\/\^\\\/\(200\|404\)\\\.html\$\/\.test\(name\)/)
    assert.match(cfg, /"prerender:done", \(\) => \{\s*if \(failed\.length\) throw/)
  })
})

describe('P3-04: a signed-out document holds its prefetch until ready', () => {
  const doc = '<head><link rel="modulepreload" as="script" crossorigin href="/_nuxt/e.js">'
    + '<link rel="prefetch" as="script" crossorigin href="/_nuxt/a.js">'
    + '<link rel="prefetch" as="style" crossorigin href="/_nuxt/b.css"></head><body></body>'

  it('moves every prefetch link into one inert template, nothing else', () => {
    const { html, moved } = deferDocumentPrefetch(doc)
    assert.equal(moved, 2)
    assert.equal(html, '<head><link rel="modulepreload" as="script" crossorigin href="/_nuxt/e.js">'
      + `<template id="${DEFERRED_PREFETCH_ID}"><link rel="prefetch" as="script" crossorigin href="/_nuxt/a.js">`
      + '<link rel="prefetch" as="style" crossorigin href="/_nuxt/b.css"></template></head><body></body>')
  })

  it('a document without prefetch is returned as is', () => {
    assert.deepEqual(deferDocumentPrefetch('<head></head>'), { html: '<head></head>', moved: 0 })
  })

  it('only login-layout documents defer, and the plugin puts the links back on ready', () => {
    const cfg = readFileSync(join(WUI, 'nuxt.config.ts'), 'utf8')
    assert.match(cfg, /if \(layout === "login"\) route\.contents = deferDocumentPrefetch\(route\.contents\)\.html/)
    const plugin = readFileSync(join(WUI, 'src/plugins/prefetch-on-ready.client.ts'), 'utf8')
    assert.match(plugin, /onNuxtReady\(\(\) => \{[\s\S]*getElementById\(DEFERRED_PREFETCH_ID\)[\s\S]*document\.head\.appendChild\(held\.content\)/)
  })
})
