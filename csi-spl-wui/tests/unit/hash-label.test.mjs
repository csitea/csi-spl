// Owner t1 afb06ae8 ("convert the Git commit hashes to links to github.com"
// ... "release log" ... "Both on mobile and on desktop") and t1 da98036e
// (msg 8bfe3812: "Shorten them to 8 characters and add three dots"):
// utils/hash-label.mjs (a full-hash link reads <8>...), commit-links.ts
// shaHref (a release note's sha links, digits only included) and the one
// source-repository constant (utils/source-repo.mjs).
//
// Run: node tests/unit/hash-label.test.mjs
import { readFileSync } from 'node:fs'
import { shortHash, shortHashLabel } from '../../src/utils/hash-label.mjs'
import { importTs } from './lib/load-ts.mjs'
const { commitPrefix, linkifyCommitText, shaHref } = await importTs('src/utils/commit-links.ts')
import { runsInUnitSuite } from './lib/in-suite.mjs'

let failed = 0
const ok = (name, cond, why = '') => { if (cond) console.log(`  OK   ${name}`); else { failed++; console.log(`  FAIL ${name} ${why}`) } }

console.log('hash-label')
const FULL = '785470e9c0a1b2c3d4e5f60718293a4b5c6d7e8f'
const SHORT = '785470e9...'
ok('shortHash is 8 characters and three dots', shortHash(FULL) === SHORT)
ok('a full hash reads <8>... and the hover keeps it', JSON.stringify(shortHashLabel(FULL)) === JSON.stringify({ text: SHORT, title: FULL }))
ok('an upper-case full hash too', shortHashLabel(FULL.toUpperCase())?.text === '785470E9...')
ok('a bare /releases/<40 hex> url reads <8>...', shortHashLabel('https://spool.example.org/releases/' + FULL)?.text === SHORT)
ok('a commit url ending in one, trailing slash too', shortHashLabel('https://git.example.org/acme/spool/commit/' + FULL + '/')?.title === FULL)
ok('an all-digit full hash (a mock sha) too', shortHashLabel('00000001'.repeat(5))?.text === '00000001...')
ok('control: an 8-char hash stays', shortHashLabel('785470e9') === null)
ok('control: 39 or 41 hex stays', shortHashLabel(FULL.slice(1)) === null && shortHashLabel(FULL + 'a') === null)
ok('control: a word, an empty text, a url not ending in a hash stay', shortHashLabel('release notes') === null && shortHashLabel('') === null && shortHashLabel(undefined) === null && shortHashLabel('https://git.example.org/acme/spool/commit/' + FULL + '/files') === null)
ok('control: a hash in the query or in a longer path part stays', shortHashLabel('https://x.example.org/?sha=' + FULL) === null && shortHashLabel('https://x.example.org/v' + FULL) === null)
ok('control: prose around a hash stays', shortHashLabel('see ' + FULL) === null)

console.log('shaHref')
const P = commitPrefix('https://git.example.org/acme/spool', '/commit/')
ok('a release sha links to <web><path><sha>', shaHref(P, FULL) === P + FULL)
ok('an all-digit sha links (it is a commit by definition)', shaHref(P, '00000001'.repeat(5)) === P + '00000001'.repeat(5))
ok('a 7-char sha links, lower case', shaHref(P, '785470E') === P + '785470e')
ok('no prefix or a non-sha: no link', shaHref('', FULL) === '' && shaHref(P, 'v1.2.3') === '' && shaHref(P, '') === '' && shaHref(P, 'abc12') === '')

console.log('release note prose')
const parts = linkifyCommitText('Reverts ' + FULL + ' and fixes 785470e.\n```\n' + FULL + '\n```', P)
const links = parts.filter((x) => x.type === 'link')
ok('a hash in a note links; the one in a code fence stays text', links.length === 2 && links[0].href === P + FULL && links[1].href === P + '785470e', JSON.stringify(links))

console.log('one source repository constant')
const read = (f) => readFileSync(new URL('../../' + f, import.meta.url), 'utf8')
ok('source-repo.mjs holds the address', /SOURCE_REPO_URL = 'https:\/\/[^']+'/.test(read('src/utils/source-repo.mjs')))
for (const f of ['src/components/LogoDialog.vue', 'src/components/LoginLinks.vue', 'src/components/ReleaseNotesDialog.vue']) {
  ok(`${f} writes no repository url`, !/https?:\/\/(?:www\.)?github\.com/i.test(read(f)))
}
ok('LogoDialog and LoginLinks read the constant', /SOURCE_REPO_URL/.test(read('src/components/LogoDialog.vue')) && /SOURCE_REPO_URL/.test(read('src/components/LoginLinks.vue')))

const suite = runsInUnitSuite(import.meta.url)
ok('pnpm test runs this suite', suite.ok, suite.why)

if (failed) {
  console.log(`hash-label: ${failed} FAILED`)
  process.exit(1)
}
console.log('hash-label: all passed')
