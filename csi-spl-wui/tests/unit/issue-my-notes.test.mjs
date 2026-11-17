// Spec 155 2.12 (SPL-5769): the open issue lists the person's own notes that
// link it, under the comment box. The wiring: where it sits, that it is its
// own chunk, that it reads the hub's issue filter through the notes store,
// and that the mock answers only the notes that link that issue.
//
// Run: node tests/unit/issue-my-notes.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const src = (rel) => readFileSync(join(WUI, rel), 'utf8')

describe('the issue view lists my notes on the issue', () => {
  it('under the comment box, above the discussions, as a lazy chunk', () => {
    const page = src('src/pages/issues.vue')
    const box = page.search(/<label class="issues-field issues-comment-field"/)
    const mine = page.search(/<LazyIssueMyNotes :issue-key="form\.key" \/>/)
    const disc = page.search(/<LazyIssueDiscussions :issue-key="form\.key" :stamp="historyStamp" \/>/)
    assert.ok(box > 0 && mine > box && disc > mine, `order: box ${box} < my notes ${mine} < discussions ${disc}`)
    assert.doesNotMatch(page, /import IssueMyNotes|<IssueMyNotes/, 'only the Lazy form, so the initial JS does not grow')
  })
  it('reads ?workspace=&issue= through the notes store, and leaves archived notes out', () => {
    const store = src('src/stores/notes.ts')
    assert.match(store, /\?workspace=\$\{encodeURIComponent\(ws\)\}&issue=\$\{encodeURIComponent\(key\)\}/)
    const vue = src('src/components/IssueMyNotes.vue')
    assert.match(vue, /store\.onIssue\(ws, key\)/)
    assert.match(vue, /got\.filter\(\(n\) => !n\.archived\)/)
    assert.match(vue, /t\('issue_my_notes\.title'\)/)
    assert.doesNotMatch(vue, /:style=/, 'no inline :style (CSP)')
  })
  it('every locale names the list', () => {
    for (const lang of ['bg', 'el', 'en', 'es', 'et', 'fi', 'he', 'lt', 'lv', 'mk', 'nl', 'pl', 'ro', 'ru', 'sk', 'sr', 'sv', 'tr', 'uk']) {
      const title = JSON.parse(src(`i18n/locales/${lang}.json`)).issue_my_notes?.title
      assert.ok(typeof title === 'string' && title.length > 0, `${lang}: issue_my_notes.title`)
    }
  })
})
