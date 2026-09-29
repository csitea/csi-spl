// W14 (spec 047, SPL-1169): the help pages the WUI serves at /help are a copy
// of csi-spl-doc/doc/help (src/public/help-md). This fails while the copy is
// stale, and names the command that refreshes it.
//
// Run: node tests/unit/help-sync.test.mjs
import { cpSync, existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { HELP_OUT, HELP_SRC, helpDomain, helpDrift, helpFiles, helpTitle, tokenizeHosts } from '../../src/node/help/sync-help.mjs'
import { runsInUnitSuite } from './lib/in-suite.mjs'

let failed = 0
const ok = (name, cond, why = '') => { if (cond) console.log(`  OK   ${name}`); else { failed++; console.log(`  FAIL ${name} ${why}`) } }

console.log('help-sync')
if (!existsSync(HELP_SRC)) {
  /* a csi-spl-wui-only checkout (the image build) has no doc tree to compare */
  console.log('  SKIP csi-spl-doc/doc/help is not in this checkout')
} else {
  const drift = helpDrift()
  ok('src/public/help-md matches csi-spl-doc/doc/help', drift.length === 0,
    `stale: ${drift.join(', ')} - run: node src/node/help/sync-help.mjs (in csi-spl-wui)`)
  const pages = JSON.parse(helpFiles().get('pages.json')).pages
  ok('pages.json lists every page but the index', pages.length >= 11 && !pages.some((p) => p.slug === 'index'))
  ok('pages.json follows the index order', pages[0]?.slug === 'getting-started', JSON.stringify(pages.slice(0, 2)))
  ok('every page has a title', pages.every((p) => p.title && p.title !== p.slug))
  ok('no per-tenant host in the help (W14: the host is fixed)',
    ![...helpFiles().values()].some((b) => /<tenant(-name)?>\./.test(b)))
  /* the domain lives only in csi-spl-cnf and csi-spl-doc (iac domain-single-source) */
  const domain = helpDomain()
  ok('the domain is read from the cnf', /^[a-z0-9-]+(\.[a-z0-9-]+)+$/.test(domain), domain)
  ok('the copy never names the domain: {{api}} / {{site}} instead',
    ![...helpFiles().values()].some((b) => b.includes(domain)) && [...helpFiles().values()].some((b) => b.includes('{{site}}')))
  ok('CONTROL a page that names the domain is tokenized', tokenizeHosts(`https://api.${domain}/x and ${domain}`, domain) === 'https://{{api}}/x and {{site}}')

  /* CONTROL: an edited source page must read as drift (needs a copy to edit) */
  const tmp = existsSync(HELP_OUT) ? mkdtempSync(join(tmpdir(), 'help-sync-')) : ''
  if (tmp) try {
    const src = join(tmp, 'src')
    const dst = join(tmp, 'dst')
    cpSync(HELP_SRC, src, { recursive: true })
    cpSync(HELP_OUT, dst, { recursive: true })
    ok('CONTROL an identical copy reads clean', helpDrift(src, dst).length === 0)
    writeFileSync(join(src, 'how-to-post.md'), readFileSync(join(src, 'how-to-post.md'), 'utf8') + '\nedited\n')
    const d = helpDrift(src, dst)
    ok('CONTROL an edited page reads as drift', d.includes('how-to-post.md'), JSON.stringify(d))
    writeFileSync(join(dst, 'gone.md'), 'x')
    ok('CONTROL an extra copied file reads as drift', helpDrift(src, dst).includes('gone.md'))
  } finally {
    rmSync(tmp, { recursive: true, force: true })
  }
}
const suite = runsInUnitSuite(import.meta.url)
ok('pnpm test runs this suite', suite.ok, suite.why)
ok('title is the first # heading', helpTitle('intro\n# How to Post\n## x', 'how-to-post') === 'How to Post' && helpTitle('none', 'x') === 'x')

if (failed) {
  console.log(`help-sync: ${failed} FAILED`)
  process.exit(1)
}
console.log('help-sync: all passed')
