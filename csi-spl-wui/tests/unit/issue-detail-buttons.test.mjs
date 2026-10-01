// CLE-77854 (owner, topic 643330e5): the open issue's ☰ menu became three
// header buttons - Copy link / Archive / Delete - at the end of the dialog's
// right-side controls and in the phone's top bar, each with a tooltip and an
// aria-label in every locale. The browser half is
// tests/e2e/issues-detail-buttons.test.mjs.
// Run: node tests/unit/issue-detail-buttons.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync, readdirSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const src = (rel) => readFileSync(join(WUI, rel), 'utf8')
const page = src('src/pages/issues.vue')
const comp = src('src/components/IssueDetailActions.vue')
const tmpl = page.slice(0, page.indexOf('<script'))

describe('IssueDetailActions: Copy link, Archive, Delete, in that order', () => {
  it('draws the three buttons with the menu labels as tooltip and aria-label', () => {
    const ids = [...comp.matchAll(/\{ id: '(\w+)', icon: '(\w+)', labelKey: '([\w.]+)'/g)].map((m) => [m[1], m[2], m[3]])
    assert.deepEqual(ids, [
      ['copy', 'copy', 'issues_menu.copy_link'],
      ['archive', 'archive', 'issues_menu.archive'],
      ['delete', 'delete', 'issues_menu.delete'],
    ])
    assert.match(comp, /:aria-label="t\(label\(b\)\)"/)
    assert.match(comp, /:title="t\(label\(b\)\)"/)
  })
  it('a just-copied link reads "Copied" with a check', () => {
    assert.match(comp, /props\.copied \? 'common\.copied'/)
    assert.match(comp, /copied \? 'check' : b\.icon/)
  })
})

describe('issues.vue: the open issue has buttons, not a ☰ menu', () => {
  it('both headers (dialog tools, phone top bar) carry IssueDetailActions', () => {
    const uses = tmpl.match(/<IssueDetailActions\b[^>]*>/g) || []
    assert.equal(uses.length, 2)
    for (const u of uses) {
      assert.match(u, /@copy="detailCopy"/)
      assert.match(u, /@archive="detailArchive"/)
      assert.match(u, /@delete="detailDelete"/)
    }
    assert.match(uses[1], /\btap\b/)
  })
  it('the ☰ opener is gone', () => {
    assert.doesNotMatch(page, /openDetailMenu|ctxOverModal|issues-detail__menu/)
  })
  it('the actions are the menu\'s: copy the link, the archive confirm, the single-issue delete', () => {
    assert.match(page, /function detailCopy\(\) \{\n\s+if \(detail\.value\) void copyText\(issueLinkFor\(issueTarget\(detail\.value\)\), detail\.value\.key\)/)
    assert.match(page, /function detailArchive\(\) \{\n\s+if \(detail\.value\) askAction\('archive', issueTarget\(detail\.value\)\)/)
    assert.match(page, /function detailDelete\(\) \{\n\s+if \(detail\.value\) askDelete\(detail\.value\)/)
  })
})

describe('every locale labels the three buttons', () => {
  const dir = join(WUI, 'i18n/locales')
  const files = readdirSync(dir).filter((f) => f.endsWith('.json'))
  it('19 locales', () => assert.equal(files.length, 19))
  for (const f of files) {
    it(f, () => {
      const d = JSON.parse(readFileSync(join(dir, f), 'utf8'))
      for (const k of ['copy_link', 'archive', 'delete', 'label']) assert.ok(d.issues_menu?.[k], `${f} issues_menu.${k}`)
      assert.ok(d.common?.copied, `${f} common.copied`)
    })
  }
})
