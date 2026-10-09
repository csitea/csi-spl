// W14 (spec 047, SPL-1169): the WUI serves the help pages of
// csi-spl-doc/doc/help at /help. The WUI image builds from csi-spl-wui alone
// (its Docker context), so the pages ride along as a COPY in
// src/public/help-md/, plus pages.json (slug + title, in the index order).
// doc/help stays the one place they are written; this script copies them,
// and tests/unit/help-sync.test.mjs fails while the copy differs.
// The copy never carries the hosted domain (it lives only in csi-spl-cnf and
// csi-spl-doc: iac domain-single-source.tst.sh): `api.<domain>` becomes
// {{api}} and `<domain>` becomes {{site}}, which the /help page fills from
// the site it runs on (utils/help.mjs fillHelpHosts) - so a self-hosted
// install reads its own address.
//
// Usage:
//   node src/node/help/sync-help.mjs          # write the copy
//   node src/node/help/sync-help.mjs --check  # exit 1 and name what differs
import { existsSync, mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { docsBody } from '../../utils/docs.mjs'

const __dirname = dirname(fileURLToPath(import.meta.url))
const WUI = join(__dirname, '../../..')
export const HELP_SRC = join(WUI, '../csi-spl-doc/doc/help')
export const HELP_OUT = join(WUI, 'src/public/help-md')
export const HELP_CNF = join(WUI, '../csi-spl-cnf/csi-spl/all.env.yaml')

/** env.dns.BASE_DOMAIN from the cnf, the domain's one source ('' when unreadable). */
export function helpDomain(cnf = HELP_CNF) {
  try {
    const m = /^\s+BASE_DOMAIN:\s*["']?([a-z0-9.-]+\.[a-z]{2,})["']?\s*$/m.exec(readFileSync(cnf, 'utf8'))
    return m ? m[1] : ''
  } catch {
    return ''
  }
}

/** The page with the domain turned into the {{api}} / {{site}} tokens. */
export function tokenizeHosts(md, domain) {
  if (!domain) return md
  const d = domain.replace(/[.]/g, '\\.')
  return md
    .replace(new RegExp('\\bapi\\.' + d + '\\b', 'g'), '{{api}}')
    .replace(new RegExp('\\b' + d + '\\b', 'g'), '{{site}}')
}

/** The page title: the first "# " heading, else the slug. */
export function helpTitle(md, slug) {
  const m = /^#\s+(.+?)\s*$/m.exec(md)
  return m ? m[1] : slug
}

/** Every file the copy must hold: name -> content. */
export function helpFiles(src = HELP_SRC, domain = helpDomain()) {
  const names = readdirSync(src).filter((n) => /^[a-z0-9-]+\.md$/.test(n)).sort()
  const out = new Map()
  const pages = []
  for (const n of names) {
    /* a page's frontmatter (`public: true`, sync-public-docs.mjs) is not page text */
    const md = tokenizeHosts(docsBody(readFileSync(join(src, n), 'utf8')), domain)
    out.set(n, md)
    const slug = n.slice(0, -3)
    if (slug !== 'index') pages.push({ slug, title: helpTitle(md, slug) })
  }
  /* the index's table order first, then any page it does not list */
  const index = out.get('index.md') || ''
  const order = [...index.matchAll(/\]\(\.\/([a-z0-9-]+)\.md\)/g)].map((m) => m[1])
  const rank = (s) => { const i = order.indexOf(s); return i < 0 ? order.length : i }
  pages.sort((a, b) => rank(a.slug) - rank(b.slug) || a.slug.localeCompare(b.slug))
  out.set('pages.json', JSON.stringify({ pages }, null, 2) + '\n')
  return out
}

/** The names whose copy is missing, stale or extra. */
export function helpDrift(src = HELP_SRC, dst = HELP_OUT, domain = helpDomain()) {
  const want = helpFiles(src, domain)
  const have = existsSync(dst) ? readdirSync(dst) : []
  const bad = []
  for (const [n, body] of want) {
    const p = join(dst, n)
    if (!existsSync(p) || readFileSync(p, 'utf8') !== body) bad.push(n)
  }
  for (const n of have) if (!want.has(n)) bad.push(n)
  return bad
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  if (!helpDomain()) {
    console.error('cannot read env.dns.BASE_DOMAIN from csi-spl-cnf/csi-spl/all.env.yaml')
    process.exit(1)
  }
  if (process.argv.includes('--check')) {
    const bad = helpDrift()
    if (bad.length) {
      console.error(`help copy is stale (${bad.join(', ')}): run node src/node/help/sync-help.mjs in csi-spl-wui`)
      process.exit(1)
    }
    console.log('help copy matches csi-spl-doc/doc/help')
  } else {
    const want = helpFiles()
    rmSync(HELP_OUT, { recursive: true, force: true })
    mkdirSync(HELP_OUT, { recursive: true })
    for (const [n, body] of want) writeFileSync(join(HELP_OUT, n), body)
    console.log(`wrote ${want.size} files to src/public/help-md`)
  }
}
