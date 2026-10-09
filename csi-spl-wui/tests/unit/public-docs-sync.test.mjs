// Owner HUM-10 (t1 41881574, e3ce4c34): a signed-out visitor reads the docs
// marked `public: true`, from the build-time copy sync-public-docs.mjs writes.
// Here: only `public: true` frontmatter makes a doc public (the default is
// not), the copy holds no frontmatter, skipped paths stay out, the copy of
// this repo holds the docs marked today, and the page's index reader drops
// anything that is not a docs path.
// Control: with markedPublic always true, the "not marked" checks FAIL.
//
// Run: node tests/unit/public-docs-sync.test.mjs
import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { PUBLIC_DOCS_ROOT, markedPublic, publicDocsDrift, publicDocsFiles, skippedPath, writePublicDocs } from '../../src/node/docs/sync-public-docs.mjs'
import { docsBody, publicDocsList } from '../../src/utils/docs.mjs'
import { runsInUnitSuite } from './lib/in-suite.mjs'

let failed = 0
const ok = (name, cond, why = '') => { if (cond) console.log(`  OK   ${name}`); else { failed++; console.log(`  FAIL ${name} ${why}`) } }

console.log('public-docs-sync')

// 1. the marking
ok('public: true marks a doc public', markedPublic('---\npublic: true\n---\n# A\n'))
ok('a comment after the value is fine', markedPublic('---\ntitle: x\npublic: true # owner\n---\n# A\n'))
ok('no frontmatter: not public', !markedPublic('# A\n\npublic: true\n'))
ok('public: false: not public', !markedPublic('---\npublic: false\n---\n# A\n'))
ok('public: yes: not public (only true)', !markedPublic('---\npublic: yes\n---\n# A\n'))
ok('a public: true line in the body: not public', !markedPublic('# A\n---\npublic: true\n---\n'))
ok('frontmatter not at the top: not public', !markedPublic('\n---\npublic: true\n---\n'))

// 2. the body
ok('docsBody takes the frontmatter out', docsBody('---\npublic: true\n---\n# A\n\nb\n') === '# A\n\nb\n')
ok('docsBody keeps a doc without frontmatter', docsBody('# A\n\n---\n\nb\n') === '# A\n\n---\n\nb\n')

// 3. the paths do_publish_docs skips
for (const p of ['CLAUDE.md', 'x/AGENTS.md', 'a/node_modules/b.md', 'tpl-gen/a.md', 'a/bin/b.md', 'csi-spl-wui/src/public/help-md/a.md']) {
  ok(`skipped: ${p}`, skippedPath(p))
}
ok('not skipped: a doc', !skippedPath('csi-spl-doc/doc/help/a.md'))

// 4. a fixture repo: only the marked doc is copied, without its frontmatter
{
  const root = mkdtempSync(join(tmpdir(), 'pub-docs-'))
  const put = (p, body) => { mkdirSync(dirname(join(root, p)), { recursive: true }); writeFileSync(join(root, p), body) }
  put('doc/open.md', '---\npublic: true\n---\n# Open doc\n\nPUBLIC-TEXT\n')
  put('doc/closed.md', '# Closed doc\n\nSECRET-TEXT\n')
  put('doc/no.md', '---\npublic: false\n---\n# No\n')
  put('x/CLAUDE.md', '---\npublic: true\n---\n# Agent\n')
  const want = publicDocsFiles(root, ['doc/closed.md', 'doc/no.md', 'doc/open.md', 'x/CLAUDE.md', '../up.md'])
  const index = JSON.parse(want.get('index.json'))
  ok('the index lists the marked doc only', JSON.stringify(index.files) === JSON.stringify([{ path: 'doc/open.md', title: 'Open doc' }]), want.get('index.json'))
  ok('the copy holds the marked doc without frontmatter', want.get('doc/open.md') === '# Open doc\n\nPUBLIC-TEXT\n')
  ok('the copy holds no unmarked text', ![...want.values()].some((b) => b.includes('SECRET-TEXT')))
  const out = join(root, 'out')
  writePublicDocs(want, out)
  ok('the written copy has no drift', publicDocsDrift(want, out).length === 0)
  writeFileSync(join(out, 'extra.md'), 'x')
  ok('an extra file is drift', publicDocsDrift(want, out).includes('extra.md'))
  rmSync(root, { recursive: true, force: true })
}

// 5. this repo: the docs marked public today
if (existsSync(join(PUBLIC_DOCS_ROOT, '.git'))) {
  const paths = JSON.parse(publicDocsFiles().get('index.json')).files.map((f) => f.path)
  ok('the getting-started help doc is public', paths.includes('csi-spl-doc/doc/help/getting-started.md'), JSON.stringify(paths))
  ok('the feature doc is not', !paths.includes('csi-spl-doc/doc/md/csi-spl.feature.md'))
  ok('README.md is not', !paths.includes('README.md'))
} else console.log('  SKIP no git checkout around csi-spl-wui')

// 6. the page's reader of index.json
ok('publicDocsList keeps docs paths', publicDocsList({ files: [{ path: 'a/b.md', title: 'B' }] }).length === 1)
ok('publicDocsList drops a climbing path', publicDocsList({ files: [{ path: '../a.md' }, { path: 'a/../../b.md' }] }).length === 0)
ok('publicDocsList of no copy (HTML fallback) is empty', publicDocsList(null).length === 0 && publicDocsList({}).length === 0)

const s = runsInUnitSuite(import.meta.url)
ok('pnpm test runs this suite', s.ok, s.why)

if (failed) {
  console.log(`public-docs-sync: ${failed} FAILED`)
  process.exit(1)
}
console.log('public-docs-sync: all passed')
