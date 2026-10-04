// The Docs section (owner, prd t1 9f0d751c): the repo's .md, published to
// the env's docs bucket at each WUI deploy and read through the hub. A doc's
// address is /docs/<repo path> (the contract the git-spec linking lane
// resolves "spec 072" to); a relative .md link opens the target doc in the
// app; the explorer tree is built from tree.json's flat file list.
//
// Run: node tests/unit/docs.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync, readdirSync } from 'node:fs'
import { DOCS_REPO_BASE, buildDocsTree, docsAncestors, docsHref, rewriteDocsLinks, validDocsPath, visibleDocsRows } from '../../src/utils/docs.mjs'
import { mockDocs } from '../../src/utils/docs-mock.mjs'

const FROM = 'csi-spl-doc/doc/md/csi-spl.feature.md'

describe('validDocsPath', () => {
  it('takes a repo .md path, as the hub does', () => {
    for (const p of ['README.md', 'csi-spl-doc/specs/072-rapid-deployability/spec.md', 'a_b/c-d.v2.md']) assert.equal(validDocsPath(p), true, p)
  })
  it('CONTROL refuses a climb, a hidden segment, a non-.md and an empty segment', () => {
    for (const p of ['../a.md', 'a/../b.md', '.git/x.md', 'a/.b/c.md', 'a.txt', 'a//b.md', '/a.md', 'a b.md', '', null]) assert.equal(validDocsPath(p), false, String(p))
  })
})

describe('docsHref', () => {
  it('a relative .md link becomes the /docs route of the target, resolved from the doc', () => {
    assert.equal(docsHref('../help/how-to-post.md', FROM), '/docs/csi-spl-doc/doc/help/how-to-post.md')
    assert.equal(docsHref('./other.md#part', FROM), '/docs/csi-spl-doc/doc/md/other.md')
    assert.equal(docsHref('../../specs/072-x/spec.md', FROM), '/docs/csi-spl-doc/specs/072-x/spec.md')
    assert.equal(docsHref('csi-spl-doc/README.md', 'README.md'), '/docs/csi-spl-doc/README.md')
  })
  it('the page passes its locale-aware route', () => {
    assert.equal(docsHref('../help/a.md', FROM, (p) => '/fi/docs/' + p), '/fi/docs/csi-spl-doc/doc/help/a.md')
  })
  it('a relative link to a repo file that is not a doc points at the public repo', () => {
    assert.equal(docsHref('../../../csi-spl-iac/run', FROM), DOCS_REPO_BASE + 'csi-spl-iac/run')
    assert.equal(docsHref('./img/x.png#a', FROM), DOCS_REPO_BASE + 'csi-spl-doc/doc/md/img/x.png#a')
  })
  it('absolute, mailto, anchors and site paths stay; a climb above the root stays as written', () => {
    for (const s of ['https://example.com/a.md', 'mailto:a@example.com', '#top', '/help']) assert.equal(docsHref(s, FROM), s)
    assert.equal(docsHref('../../../../x.md', FROM), '../../../../x.md')
  })
})

describe('rewriteDocsLinks', () => {
  it('rewrites every inline link, keeps a link title, leaves text alone', () => {
    const md = 'See [post](../help/how-to-post.md) and [x](https://example.com "t") and [m](./m.md "Title").'
    assert.equal(rewriteDocsLinks(md, FROM),
      'See [post](/docs/csi-spl-doc/doc/help/how-to-post.md) and [x](https://example.com "t") and [m](/docs/csi-spl-doc/doc/md/m.md "Title").')
  })
})

describe('buildDocsTree', () => {
  const tree = buildDocsTree([
    { path: 'README.md', title: 'Spool' },
    { path: 'csi-spl-doc/specs/072-x/spec.md', title: 'Spec 072' },
    { path: 'csi-spl-doc/doc/md/a.md' },
    { path: 'csi-spl-doc/doc/help/how-to-post.md', title: 'How to Post' },
    { path: '../evil.md', title: 'x' },
  ])
  it('folders nest by repo path, folders before files, each by name', () => {
    assert.deepEqual(tree.dirs.map((d) => d.name), ['csi-spl-doc'])
    assert.deepEqual(tree.files.map((f) => f.path), ['README.md'])
    const doc = tree.dirs[0]
    assert.deepEqual(doc.dirs.map((d) => d.path), ['csi-spl-doc/doc', 'csi-spl-doc/specs'])
    assert.deepEqual(doc.dirs[0].dirs.map((d) => d.name), ['help', 'md'])
  })
  it('a file without a title shows its name; CONTROL a bad path never enters the tree', () => {
    assert.equal(tree.dirs[0].dirs[0].dirs[1].files[0].title, 'a.md')
    assert.equal(JSON.stringify(tree).includes('evil'), false)
  })
  it('visibleDocsRows shows only the open folders\' contents', () => {
    const closed = visibleDocsRows(tree, new Set())
    assert.deepEqual(closed.map((r) => r.path), ['csi-spl-doc', 'README.md'])
    const open = visibleDocsRows(tree, new Set(['csi-spl-doc', 'csi-spl-doc/specs']))
    assert.deepEqual(open.map((r) => [r.kind, r.path, r.depth]), [
      ['dir', 'csi-spl-doc', 0], ['dir', 'csi-spl-doc/doc', 1], ['dir', 'csi-spl-doc/specs', 1],
      ['dir', 'csi-spl-doc/specs/072-x', 2], ['file', 'README.md', 0],
    ])
  })
  it('docsAncestors opens the folders a doc sits in', () => {
    assert.deepEqual(docsAncestors('csi-spl-doc/specs/072-x/spec.md'), ['csi-spl-doc', 'csi-spl-doc/specs', 'csi-spl-doc/specs/072-x'])
    assert.deepEqual(docsAncestors('README.md'), [])
  })
})

describe('the mock tenant', () => {
  it('its tree lists doc/md, doc/help and specs, and every listed doc answers', () => {
    const files = JSON.parse(mockDocs('tree.json')).files
    for (const d of ['csi-spl-doc/doc/md/', 'csi-spl-doc/doc/help/', 'csi-spl-doc/specs/']) assert.ok(files.some((f) => f.path.startsWith(d)), d)
    for (const f of files) assert.equal(typeof mockDocs(f.path), 'string', f.path)
    assert.equal(mockDocs('nope.md'), null)
  })
})

describe('wiring', () => {
  const read = (p) => readFileSync(new URL('../../' + p, import.meta.url), 'utf8')
  it('the rail links Docs (desktop + the phone strip copy)', () => {
    const s = read('src/components/ChannelSidebar.vue')
    assert.match(s, /class="sidebar-rail__docs"\s+data-testid="docs-open"/)
    assert.match(s, /class="sidebar-rail__docs" tabindex="-1" :to="localePath\('\/docs'\)"/)
  })
  it('every locale names the section', () => {
    for (const loc of ['en', 'fi', 'he', 'ru', 'uk', 'bg']) {
      const d = JSON.parse(read(`i18n/locales/${loc}.json`)).docs
      for (const k of ['title', 'tree_label', 'folders', 'off', 'not_found', 'load_failed']) assert.ok(d && d[k], `${loc} docs.${k}`)
    }
  })
  it('no page file name puts "..." in a chunk name (a ".."-refusing server loops the reload)', () => {
    const walk = (d) => readdirSync(new URL('../../' + d, import.meta.url), { withFileTypes: true })
      .flatMap((e) => e.isDirectory() ? walk(d + '/' + e.name) : [d + '/' + e.name])
    assert.deepEqual(walk('src/pages').filter((f) => f.includes('..')), [])
    assert.match(read('src/pages/docs.vue'), /definePageMeta\(\{ path: '\/docs\/:path\(\.\*\)\*' \}\)/)
  })
  it('the page reads the hub, never a bundled copy', () => {
    const s = read('src/pages/docs.vue')
    assert.match(s, /\/v1\/docs\//)
    assert.equal(/docs-md|import\s+.*docs-mock/.test(s.replace(/await import\('~\/utils\/docs-mock\.mjs'\)/, '')), false)
  })
})
