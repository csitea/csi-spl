// perf round 3 P3-01: declare a document's first-screen chunks up front.
//
// A prerendered document names the entry chunk and its two static imports;
// everything else the first screen executes before the rail shows (the page,
// the layout, the locale catalogue and ~85 small chunks they import) is
// discovered one import wave at a time - about 6 round trips before the rail
// (perf-audit-round3-2026-10-02.md §3.2). This module turns the client build's
// own chunk graph into <link rel="modulepreload"> for those scripts and
// <link rel="preload" as="style"> for their CSS, per document, and drops the
// <link rel="prefetch"> Nuxt wrote for the same files (a file is fetched once,
// at the higher priority).
//
// Nothing here is hand-kept: the set is the static-import closure of the
// page's module, its layout's module and the document locale's catalogue, as
// Rollup emitted them. nuxt.config.ts collects the graph (generateBundle) and
// rewrites each prerendered .html (nitro prerender:generate). 200.html (the
// SPA fallback for every route that is not prerendered) is left alone: it
// cannot know its page. Build-time only (no client code imports this).
// Unit-tested by tests/unit/first-screen-hints.test.mjs.

/** A module id without its query (`/x/en.json?hash=1&locale=en` -> `/x/en.json`). */
function bareId(id) {
  const q = id.indexOf('?')
  return q < 0 ? id : id.slice(0, q)
}

function escapeRe(s) {
  return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
}

/**
 * The chunk graph of a Rollup output bundle: which chunk holds each module,
 * and each chunk's static imports and imported CSS.
 * @param {Record<string, any>} bundle
 * @returns {{ moduleChunk: Record<string, string>, chunks: Record<string, { imports: string[], css: string[] }> }}
 */
export function firstScreenChunkGraph(bundle) {
  /** @type {Record<string, string>} */
  const moduleChunk = {}
  /** @type {Record<string, { imports: string[], css: string[] }>} */
  const chunks = {}
  for (const out of Object.values(bundle)) {
    if (!out || out.type !== 'chunk') continue
    for (const id of out.moduleIds || Object.keys(out.modules || {})) {
      const bare = bareId(id)
      if (!(bare in moduleChunk)) moduleChunk[bare] = out.fileName
    }
    chunks[out.fileName] = {
      imports: [...(out.imports || [])],
      css: [...(out.viteMetadata?.importedCss || [])],
    }
  }
  return { moduleChunk, chunks }
}

/**
 * The static-import closure of the chunks holding `moduleIds`: scripts in
 * walk order (roots first), and the CSS those scripts import.
 * @param {{ moduleChunk: Record<string,string>, chunks: Record<string,{imports:string[],css:string[]}> }} graph
 * @param {string[]} moduleIds
 */
export function firstScreenFiles(graph, moduleIds) {
  const scripts = []
  const styles = []
  const seen = new Set()
  const queue = []
  for (const id of moduleIds) {
    const file = graph.moduleChunk[bareId(id)]
    if (file) queue.push(file)
  }
  while (queue.length) {
    const file = queue.shift()
    if (seen.has(file)) continue
    seen.add(file)
    const chunk = graph.chunks[file]
    if (!chunk) continue
    scripts.push(file)
    for (const css of chunk.css) if (!styles.includes(css)) styles.push(css)
    for (const dep of chunk.imports) if (!seen.has(dep)) queue.push(dep)
  }
  return { scripts, styles }
}

/**
 * The page a prerendered route renders, and the locale it is in.
 * @param {string} route e.g. "/", "/fi", "/fi/login"
 * @param {{ path: string, file?: string }[]} pages default-locale page records
 * @param {string[]} localeCodes
 * @param {string} defaultLocale
 * @returns {{ file: string, locale: string } | null}
 */
export function firstScreenRoutePage(route, pages, localeCodes, defaultLocale) {
  let path = route.replace(/\/index\.html$|\.html$/, '') || '/'
  let locale = defaultLocale
  const seg = path.split('/')[1] || ''
  if (seg !== defaultLocale && localeCodes.includes(seg)) {
    locale = seg
    path = path.slice(seg.length + 1) || '/'
  }
  if (path.length > 1) path = path.replace(/\/+$/, '')
  const exact = pages.find((p) => p.path === path)
  const page = exact || pages.find((p) => p.path.includes(':')
    && new RegExp('^' + p.path.replace(/\/:[^/]+\?/g, '(?:/[^/]+)?').replace(/:[^/]+/g, '[^/]+') + '$').test(path))
  return page ? { file: page.file || '', locale } : null
}

/** The layout a page's definePageMeta names, "" for `layout: false` (no layout), else "default". */
export function firstScreenPageLayout(source) {
  const meta = /definePageMeta\(\s*\{[^}]*\blayout:\s*(false\b|['"]([\w-]+)['"])/.exec(source || '')
  return meta ? meta[2] || '' : 'default'
}

/**
 * Add the first screen's hints to a document and drop its prefetch of the
 * same files. A file the document already names (script, modulepreload,
 * stylesheet) is not added twice. Returns the new html and how many hints
 * it added.
 * @param {string} html
 * @param {{ scripts: string[], styles: string[] }} files
 * @param {string} [base] the app base URL; a Rollup fileName ("_nuxt/x.js") follows it
 */
export function addFirstScreenHints(html, files, base = '/') {
  let out = html
  const tags = []
  const add = (f, tag) => {
    const href = base + f
    out = out.replace(new RegExp(`<link rel="prefetch"[^>]*href="${escapeRe(href)}"[^>]*>`, 'g'), '')
    if (!out.includes(`href="${href}"`)) tags.push(tag(href))
  }
  for (const f of files.scripts) add(f, (href) => `<link rel="modulepreload" as="script" crossorigin href="${href}">`)
  for (const f of files.styles) add(f, (href) => `<link rel="preload" as="style" crossorigin href="${href}">`)
  if (!tags.length) return { html: out, added: 0 }
  // after the entry's own modulepreloads, so the entry is still asked first
  const last = out.lastIndexOf('<link rel="modulepreload"')
  const i = last >= 0 ? out.indexOf('>', last) + 1 : out.indexOf('</head>')
  if (i <= 0) return { html: out, added: 0 }
  return { html: out.slice(0, i) + tags.join('') + out.slice(i), added: tags.length }
}

/** The id of the inert <template> that holds a signed-out document's prefetch links. */
export const DEFERRED_PREFETCH_ID = 'spl-prefetch'

/**
 * perf round 3 P3-04: a signed-out document (the /login screens) must not
 * spend the visitor's first seconds on ~83 app chunks it cannot use yet. Move
 * every <link rel="prefetch"> into an inert <template> (neither the parser
 * nor the preload scanner fetches inside one); plugins/prefetch-on-ready
 * puts them back once the page is ready, so a sign-in still finds them cached.
 * @param {string} html
 */
export function deferDocumentPrefetch(html) {
  const links = []
  const out = html.replace(/<link rel="prefetch"[^>]*>/g, (tag) => {
    links.push(tag)
    return ''
  })
  if (!links.length) return { html, moved: 0 }
  const i = out.indexOf('</head>')
  if (i < 0) return { html, moved: 0 }
  return {
    html: out.slice(0, i) + `<template id="${DEFERRED_PREFETCH_ID}">${links.join('')}</template>` + out.slice(i),
    moved: links.length,
  }
}
