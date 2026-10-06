// Refactor round 3, B8 and B9.
// B8: the mock tenant memoizes the ws-docs-mock import. A rejected import
// (a deploy between the two asks) must be forgotten, or every later read
// fails the same way. useChannelOrder resets its chunk the same way.
// B9: TopicPane must show catalogue text. A raw Error message is English
// (for example "workspace docs 503") in every locale.
//
// Run: node tests/unit/workspace-docs-loader.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync, readdirSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (rel) => readFileSync(join(WUI, rel), 'utf8')

describe('B8: a failed mock bucket import is asked again', () => {
  it('forgets the rejected import instead of memoizing it', () => {
    const src = read('src/composables/useWorkspaceDocs.ts')
    const bucket = src.slice(src.indexOf('const bucket'), src.indexOf('async function call'))
    assert.ok(bucket.length > 0, 'the bucket loader is still above call()')
    assert.match(bucket, /mockBucket = null/, 'a rejected import is forgotten')
    assert.match(bucket, /\.catch\(\(e\) => \{/)
    assert.match(bucket, /throw e/)
    assert.doesNotMatch(bucket, /mockBucket \|\|=/)
  })
})

describe('B9: TopicPane shows catalogue text, not the English error', () => {
  const pane = read('src/components/TopicPane.vue')
  const loaders = pane.slice(pane.indexOf('async function catchUp'), pane.indexOf('async function loadOldestRow'))

  it('the three loaders map the failure to an i18n key', () => {
    assert.ok(loaders.length > 0, 'catchUp through loadOlder are still in TopicPane')
    assert.doesNotMatch(loaders, /e instanceof Error \? e\.message/)
    assert.equal((loaders.match(/loadError\.value = t\('topic\.load_failed'\)/g) || []).length, 2)
    assert.equal((loaders.match(/loadError\.value = t\('feed\.error\.load_older_failed'\)/g) || []).length, 1)
  })

  it('those keys are a non-empty string in every shipped locale', () => {
    const files = readdirSync(join(WUI, 'i18n/locales')).filter((f) => f.endsWith('.json')).sort()
    assert.ok(files.length >= 19, `shipped locales: ${files.length}`)
    for (const f of files) {
      const doc = JSON.parse(read(`i18n/locales/${f}`))
      for (const [path, value] of [
        ['topic.load_failed', doc.topic && doc.topic.load_failed],
        ['feed.error.load_older_failed', doc.feed && doc.feed.error && doc.feed.error.load_older_failed],
      ]) {
        assert.equal(typeof value, 'string', `${f} ${path}`)
        assert.ok(String(value).trim().length > 0, `${f} ${path}`)
      }
    }
  })
})
