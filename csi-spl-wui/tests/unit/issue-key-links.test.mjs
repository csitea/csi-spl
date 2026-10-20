// HUM-10 t1 0f2ed820: an issue key of this workspace links to the issue
// (msg 98b9fae0), and a commit hash written as inline code links to the
// commit like a plain one (msg 8847e183). utils/issue-key-links.mjs,
// utils/issue-link-hook.mjs, the commit-links code-span rule and the
// code-blocks seam. The prefix and the repository are example values.
//
// Run: node tests/unit/issue-key-links.test.mjs
import {
  inlineIssueHref, isIssueKey, issueHref, issueKeyPrefix, issueLinker, linkifyIssueBlocks, linkifyIssueMarkdown, linkifyIssueText,
} from '../../src/utils/issue-key-links.mjs'
import { activeIssueLinker, setIssueLinkProvider } from '../../src/utils/issue-link-hook.mjs'
import { importTs } from './lib/load-ts.mjs'
const { commitLinker, commitPrefix, inlineCommitHref, linkifyCommitBlocks } = await importTs('src/utils/commit-links.ts')
import { setCommitLinkProvider } from '../../src/utils/commit-link-hook.mjs'
import { setIdCatalogProvider } from '../../src/utils/id-links.mjs'
import { bodyToHtml, markdownSource, parseBody } from '../../src/utils/code-blocks.mjs'
import { runsInUnitSuite } from './lib/in-suite.mjs'

let failed = 0
const ok = (name, cond, why = '') => { if (cond) console.log(`  OK   ${name}`); else { failed++; console.log(`  FAIL ${name} ${why}`) } }
const links = (parts) => parts.filter((p) => p.type === 'link')
const texts = (parts) => links(parts).map((p) => p.text)

console.log('issue-key-links')
const PFX = 'ACME'
const at = (p) => '/fi' + p
ok('the prefix is upper case, or empty when the hub would refuse it', issueKeyPrefix('acme') === 'ACME' && issueKeyPrefix('') === '' && issueKeyPrefix('1X') === '' && issueKeyPrefix('A-B') === '')
ok('a key is <PREFIX>-<n>', isIssueKey(PFX, 'ACME-12') && !isIssueKey(PFX, 'ACME-0') && !isIssueKey(PFX, 'ACME-12a') && !isIssueKey(PFX, 'OTHER-1') && !isIssueKey('', 'ACME-1'))
ok('the href is /issues?issue=<KEY> through the locale path', issueHref(PFX, 'ACME-12', at) === '/fi/issues?issue=ACME-12' && issueHref(PFX, 'ACME-12') === '/issues?issue=ACME-12')
ok('no linker without a prefix', issueLinker('', at) === null && issueLinker(undefined) === null)

const t = (s) => texts(linkifyIssueText(s, PFX, at))
ok('a plain key links', t('fixed ACME-12 today').join() === 'ACME-12')
ok('the link target is the issue', linkifyIssueText('see ACME-7.', PFX, at)[1].href === '/fi/issues?issue=ACME-7')
ok('keys at punctuation and in a table cell link', t('(ACME-1), ACME-2; | ACME-3 | ACME-4.').join() === 'ACME-1,ACME-2,ACME-3,ACME-4')
ok('another prefix stays text', t('OTHER-12 and SPL-3').length === 0)
ok('part of a longer word stays text', t('XACME-1 ACME-12a ACME-1_x ACME-1-2 a/ACME-1 ACME-1.example.org #ACME-1 @ACME-1').length === 0)
ok('a key in a bare url stays text', t('https://x.example.org/issues?issue=ACME-12').length === 0)
ok('a key in a fence stays text', t('```\nACME-12\n```').length === 0)
ok('a key in an existing link stays text', t('[ACME-12](/issues?issue=ACME-12)').length === 0)
ok('a key in an inline span (text level) is the span\'s, not the text\'s', t('`ACME-12`').length === 0)
ok('markdown: a key becomes a markdown link', linkifyIssueMarkdown('see ACME-3', PFX, at) === 'see [ACME-3](/fi/issues?issue=ACME-3)')
ok('a code span that is only a key links', inlineIssueHref(PFX, 'ACME-3', at) === '/fi/issues?issue=ACME-3' && inlineIssueHref(PFX, 'ACME-3 x', at) === '')

const blocks = [
  { type: 'para', parts: [{ type: 'text', text: 'see ACME-1' }, { type: 'inline', text: 'ACME-2' }, { type: 'inline', text: 'git show ACME-3' }] },
  { type: 'code', lang: 'bash', text: 'ACME-4' },
  { type: 'list', items: [{ parts: [{ type: 'strong', text: 'ACME-5' }] }] },
]
const out = linkifyIssueBlocks(blocks, PFX, at)
ok('blocks: text and a key-only code span link', texts(out[0].parts).join() === 'ACME-1,ACME-2')
ok('blocks: the code-span link stays code', links(out[0].parts)[1].code === true && !links(out[0].parts)[0].code)
ok('blocks: a longer code span stays code', out[0].parts[3].type === 'inline')
ok('blocks: a fence stays code', out[1] === blocks[1])
ok('blocks: list items link', out[2].items[0].parts[0].type === 'link')
ok('blocks: no prefix returns the same tree', linkifyIssueBlocks(blocks, '') === blocks)

console.log('commit hash in a code span')
const WEB = 'https://git.example.org/acme/spool'
const P = commitPrefix(WEB, '/commit/')
ok('a code span that is only a hash has its href', inlineCommitHref(P, '368450c92') === P + '368450c92')
ok('a code span that is more than a hash has none', inlineCommitHref(P, 'git show 368450c92') === '' && inlineCommitHref(P, 'deadbeef') === '')
ok('an id the id linker owns has none', inlineCommitHref(P, '1f5e074b', (k) => k === '1f5e074b') === '')
const cb = linkifyCommitBlocks([{ type: 'para', parts: [{ type: 'inline', text: '368450c92' }] }, { type: 'code', lang: '', text: '368450c92' }], P)
ok('blocks: a hash-only code span links, shown as code', links(cb[0].parts)[0]?.href === P + '368450c92' && links(cb[0].parts)[0]?.code === true)
ok('blocks: a hash in a fence stays code', cb[1].type === 'code' && cb[1].text === '368450c92')

console.log('the seam (code-blocks)')
setIssueLinkProvider(null)
ok('hook: no provider is null', activeIssueLinker() === null)
ok('parseBody unchanged without a linker', links(parseBody('fixed ACME-1')[0].parts).length === 0)
setIssueLinkProvider(() => { throw new Error('x') })
ok('hook: a throwing provider is null (the body still renders)', activeIssueLinker() === null)
setIssueLinkProvider(() => issueLinker(PFX, at))
setCommitLinkProvider(() => commitLinker(WEB, '/commit/'))
const body = 'ACME-1 in `ACME-2`, sha `368450c92`\n```\nACME-3 368450c92\n```'
const parsed = parseBody(body)
ok('parseBody: plain key, code-span key, code-span sha link', texts(parsed[0].parts).join() === 'ACME-1,ACME-2,368450c92', JSON.stringify(parsed[0].parts))
ok('parseBody: a fence stays text', parsed[1].type === 'code' && parsed[1].text === 'ACME-3 368450c92')
ok('bodyToHtml: a linked code span is <a><code>', bodyToHtml('`368450c92`').includes(`<a class="msg-link" href="${P}368450c92" target="_blank" rel="noopener noreferrer nofollow"><code>368450c92</code></a>`), bodyToHtml('`368450c92`'))
ok('markdownSource: code-span key and sha link, fence stays', markdownSource('# x\n`ACME-2` `368450c92` ACME-1') === `# x\n[\`ACME-2\`](/fi/issues?issue=ACME-2) [\`368450c92\`](${P}368450c92) [ACME-1](/fi/issues?issue=ACME-1)`, markdownSource('# x\n`ACME-2` `368450c92` ACME-1'))

/* an 8-hex message id in a code span stays an id: the commit linker skips it */
const msgId = '1f5e074b-0000-4000-8000-000000000001'
setIdCatalogProvider(() => ({
  empty: false,
  topicsById: new Map(),
  topicsByPrefix: new Map(),
  messagesById: new Map([[msgId, { href: '/m/' + msgId, label: 'x' }]]),
  messagesByPrefix: new Map([['1f5e074b', [{ href: '/m/' + msgId, label: 'x' }]]]),
}))
const withIds = parseBody('msg `1f5e074b` sha `368450c92`')
ok('a known 8-hex message id in a code span never becomes a commit link', !links(withIds[0].parts).some((l) => l.text === '1f5e074b') && texts(withIds[0].parts).includes('368450c92'), JSON.stringify(withIds[0].parts))
setIdCatalogProvider(null)
setIssueLinkProvider(null)
setCommitLinkProvider(null)

const suite = runsInUnitSuite(import.meta.url)
ok('pnpm test runs this suite', suite.ok, suite.why)

if (failed) {
  console.log(`issue-key-links: ${failed} FAILED`)
  process.exit(1)
}
console.log('issue-key-links: all passed')
