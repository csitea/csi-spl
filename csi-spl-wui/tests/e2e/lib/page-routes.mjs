// SPL-3785 (owner HUM-10, t1 c3e53990): the WUI's routes read off the file
// tree (src/pages/**), never a hand-kept list, so a page or tab that lands
// joins every test that walks them the same day. Shared by the unit test of
// isSectionPage and the phone section strip e2e.
import { readdirSync, readFileSync } from 'node:fs'
import { join, relative, sep } from 'node:path'

function vueFiles(dir) {
  return readdirSync(dir, { withFileTypes: true }).flatMap((e) => {
    const p = join(dir, e.name)
    if (e.isDirectory()) return vueFiles(p)
    return e.name.endsWith('.vue') ? [p] : []
  })
}

/** the layout a page asks for: 'default', a named one, or 'none' (layout: false) */
export function pageLayout(src) {
  const m = /definePageMeta\(\s*\{[^}]*\blayout:\s*(false|'([\w-]+)')/.exec(src)
  if (!m) return 'default'
  return m[1] === 'false' ? 'none' : m[2]
}

/**
 * One row per page: its file, its route path (`[x]` -> `:x`, `[[x]]` and
 * `index` dropped), whether it takes a param, and its layout.
 * @param {string} pagesDir the WUI's src/pages
 */
export function pageRoutes(pagesDir) {
  return vueFiles(pagesDir).sort().map((file) => {
    const segs = relative(pagesDir, file).slice(0, -'.vue'.length).split(sep)
    const parts = segs
      .filter((s, i) => !(s === 'index' && i === segs.length - 1))
      .filter((s) => !/^\[\[.+\]\]$/.test(s))
      .map((s) => s.replace(/^\[(.+)\]$/, ':$1'))
    const path = '/' + parts.join('/')
    return { file, path, dynamic: parts.some((s) => s.startsWith(':')), layout: pageLayout(readFileSync(file, 'utf8')) }
  })
}
