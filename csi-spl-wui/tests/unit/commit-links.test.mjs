// HUM-10: git commit hashes in a message link to this instance's repository
// (utils/commit-links.mjs, utils/commit-link-hook.mjs, the code-blocks seam).
// The url pieces are cnf env.wui.repo_web_url + repo_commit_path: nothing
// here is a real repository, and unset means no link at all.
//
// Run: node tests/unit/commit-links.test.mjs
import { readFileSync } from 'node:fs'
import {
  commitHref, commitLinker, commitPrefix, isCommitHash, linkifyCommitBlocks, linkifyCommitMarkdown, linkifyCommitText,
} from '../../src/utils/commit-links.mjs'
import { activeCommitLinker, setCommitLinkProvider } from '../../src/utils/commit-link-hook.mjs'
import { markdownSource, parseBody } from '../../src/utils/code-blocks.mjs'
import { runsInUnitSuite } from './lib/in-suite.mjs'

let failed = 0
const ok = (name, cond, why = '') => { if (cond) console.log(`  OK   ${name}`); else { failed++; console.log(`  FAIL ${name} ${why}`) } }
const links = (parts) => parts.filter((p) => p.type === 'link').map((p) => p.text)

console.log('commit-links')
const WEB = 'https://git.example.org/acme/spool'
const P = commitPrefix(WEB + '/', '/commit/')
ok('the prefix is the two cnf values joined', P === 'https://git.example.org/acme/spool/commit/')
ok('a GitLab-shaped path is the cnf\'s choice', commitPrefix(WEB, '/-/commit/') === WEB + '/-/commit/')
ok('either value unset: no prefix (feature off)', commitPrefix('', '/commit/') === '' && commitPrefix(WEB, '') === '' && commitPrefix(undefined, undefined) === '')
ok('a malformed value is unset', commitPrefix('git.example.org/x', '/commit/') === '' && commitPrefix(WEB, 'commit/') === '' && commitPrefix(WEB, '/commit') === '')
ok('no linker without both values', commitLinker('', '/commit/') === null && commitLinker(WEB, '') === null)

ok('7..40 hex with a digit and a letter is a hash', isCommitHash('785470e') && isCommitHash('785470e9c') && isCommitHash('a'.repeat(39) + '1'))
ok('a plain number, a hex word, too short or too long is not', !isCommitHash('1234567') && !isCommitHash('deadbeef') && !isCommitHash('abc123') && !isCommitHash('a1'.repeat(21)))
ok('the href is lower case', commitHref(P, '785470E9C') === P + '785470e9c')

const t = (s) => links(linkifyCommitText(s, P))
ok('a short hash in prose links', t('landed in 785470e9c on master').join() === '785470e9c')
ok('a full sha links', t('sha 785470e9c0a1b2c3d4e5f60718293a4b5c6d7e8f.').join() === '785470e9c0a1b2c3d4e5f60718293a4b5c6d7e8f')
ok('it ends at punctuation', t('(785470e9c), 785470e9c; 785470e9c.').length === 3)
ok('the link target is <web><path><hash>', linkifyCommitText('see 785470e9c', P)[1].href === P + '785470e9c')
ok('a uuid and its parts never link', t('topic b62c0ad6-e537-4f25-9323-dcd30b582393 here').length === 0)
ok('an id with a hyphen never links', t('msg-785470e9c and 785470e9c-x').length === 0)
ok('inside a word, a path or a host never links', t('x785470e9c 785470e9cx a/785470e9c 785470e9c.example.org #785470e9c @785470e9c').length === 0)
ok('inside a bare url never links', t('https://git.example.org/acme/spool/commit/785470e9c').length === 0)
ok('inside inline code or a fence never links', t('`785470e9c` and ```\n785470e9c\n```').length === 0)
ok('an existing markdown link is left alone', t('[785470e9c](https://x.example.org/c)').length === 0)
ok('a plain number or hex word stays text', t('build 20261004 and deadbeef cafebabe').length === 0)
ok('no prefix: one text part, unchanged', JSON.stringify(linkifyCommitText('785470e9c', '')) === JSON.stringify([{ type: 'text', text: '785470e9c' }]))

ok('markdown: a hash becomes a markdown link', linkifyCommitMarkdown('fixed in 785470e9c', P) === 'fixed in [785470e9c](' + P + '785470e9c)')
ok('a text that is only a hash links', t('785470e9c').join() === '785470e9c' && linkifyCommitMarkdown('785470e9c', P) === '[785470e9c](' + P + '785470e9c)')
ok('markdown: code and links untouched', linkifyCommitMarkdown('`785470e9c` [785470e9c](/t/x)', P) === '`785470e9c` [785470e9c](/t/x)')

const blocks = [
  { type: 'para', parts: [{ type: 'text', text: 'see 785470e9c' }, { type: 'inline', text: '785470e9c' }, { type: 'link', text: 'a1b2c3d4', href: '/t/x' }] },
  { type: 'code', lang: 'bash', text: 'git show 785470e9c' },
  { type: 'list', items: [{ parts: [{ type: 'strong', text: '785470e9c' }] }] },
]
const out = linkifyCommitBlocks(blocks, P)
ok('blocks: text links, inline code and an id link stay', links(out[0].parts).join() === '785470e9c,a1b2c3d4' && out[0].parts.find((p) => p.type === 'inline').text === '785470e9c')
ok('blocks: a code block stays code', out[1] === blocks[1])
ok('blocks: list items link', out[2].items[0].parts[0].type === 'link')
ok('blocks: no prefix returns the same tree', linkifyCommitBlocks(blocks, '') === blocks)

/* the seam: nothing registered (a unit test, the cnf unset, chunk not loaded) = the old tree */
setCommitLinkProvider(null)
ok('hook: no provider is null', activeCommitLinker() === null)
const plain = parseBody('fixed in 785470e9c')
ok('parseBody unchanged without a linker', links(plain[0].parts).length === 0)
setCommitLinkProvider(() => { throw new Error('x') })
ok('hook: a throwing provider is null (the body still renders)', activeCommitLinker() === null)
setCommitLinkProvider(() => commitLinker(WEB, '/commit/'))
ok('parseBody links a hash once a linker is registered', links(parseBody('fixed in 785470e9c')[0].parts).join() === '785470e9c')
ok('markdownSource links a hash in prose, not in code', markdownSource('# x\nfixed in 785470e9c `785470e9c`') === '# x\nfixed in [785470e9c](' + P + '785470e9c) `785470e9c`')
setCommitLinkProvider(null)

/* no repository literal in the three url users: every piece comes from cnf */
for (const f of ['src/utils/commit-links.mjs', 'src/utils/help.mjs', 'src/utils/connect-agent.mjs']) {
  const src = readFileSync(new URL('../../' + f, import.meta.url), 'utf8')
  ok(`${f} names no repository url`, !/https?:\/\/(?!\/)[a-z0-9.-]+\.[a-z]{2,}\//i.test(src))
}

const suite = runsInUnitSuite(import.meta.url)
ok('pnpm test runs this suite', suite.ok, suite.why)

if (failed) {
  console.log(`commit-links: ${failed} FAILED`)
  process.exit(1)
}
console.log('commit-links: all passed')
