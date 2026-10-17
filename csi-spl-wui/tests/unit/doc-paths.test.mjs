// SPL-1592 (owner HUM-10, t1 cda174ef): a repo doc path written as text in a
// message, an issue field or a doc links to its /docs page
// (utils/doc-paths.mjs, utils/doc-path-hook.mjs, the parseBody and markdown
// seams). Only a doc the store lists links; an unknown path stays text.
//
// Run: node tests/unit/doc-paths.test.mjs
import {
  codeDocHref, docPathLinker, docPathParts, docPathResolver, linkDocPathBlocks, mayHoldDocPath,
} from '../../src/utils/doc-paths.mjs'
import { activeDocPathLinker, docPathEpoch, setDocPathLinker, setDocPathLoader } from '../../src/utils/doc-path-hook.mjs'
import { parseBody } from '../../src/utils/code-blocks.mjs'
import { markdownToHtml } from '../../src/utils/markdown.mjs'
import { runsInUnitSuite } from './lib/in-suite.mjs'

let failed = 0
const ok = (name, cond, why = '') => { if (cond) console.log(`  OK   ${name}`); else { failed++; console.log(`  FAIL ${name} ${why}`) } }
const links = (parts) => parts.filter((p) => p.type === 'link').map((p) => p.href)

console.log('doc-paths')
const TASKS = 'csi-spl-doc/specs/002-box-agent-messaging/tasks.md'
const SPEC = 'csi-spl-doc/specs/072-rapid-deployability/spec.md'
const PAIR_A = 'csi-spl-doc/doc/md/README.md'
const PAIR_B = 'csi-spl-wui/doc/md/README.md'
const LISTED = [TASKS, SPEC, PAIR_A, PAIR_B, 'README.md', 'not a path', '../escape.md']
const r = docPathResolver(LISTED)

/* positive */
ok('the owner\'s case: a full repo path', r(TASKS) === '/docs/' + TASKS)
ok('the anchor is kept', r(TASKS + '#t001') === '/docs/' + TASKS + '#t001')
ok('a leading /, ./ or ../ is dropped', r('/' + TASKS) === '/docs/' + TASKS && r('./' + TASKS) === '/docs/' + TASKS && r('../../' + SPEC) === '/docs/' + SPEC)
ok('a tail of exactly one listed doc resolves to it', r('specs/072-rapid-deployability/spec.md') === '/docs/' + SPEC)
ok('an absolute checkout path ends in a listed doc', r('/opt/x/csi-spl/' + TASKS) === '/docs/' + TASKS)
const said = docPathParts(`Source: ${TASKS}`, r)
ok('docPathParts: text then the link', said.length === 2 && said[0].text === 'Source: ' && said[1].type === 'link' && said[1].text === TASKS && said[1].href === '/docs/' + TASKS, JSON.stringify(said))
ok('a sentence stop after the path stays text', links(docPathParts(`see ${SPEC}.`, r)).join() === '/docs/' + SPEC)
ok('in parentheses and after a comma', links(docPathParts(`(${SPEC}), ${TASKS}`, r)).length === 2)

/* negative */
ok('an unknown path stays text (no dead link)', r('csi-spl-doc/specs/999-nope/spec.md') === '' && docPathParts('csi-spl-doc/specs/999-nope/spec.md', r).length === 1)
ok('a tail that ends two listed docs stays text', r('doc/md/README.md') === '')
ok('a bare file name stays text', docPathParts('read README.md first', r).length === 1)
ok('a glob stays text', docPathParts('specs/NNN-*/tasks.md', r).length === 1)
ok('a path inside a url stays text', docPathParts(`https://git.example.org/acme/blob/master/${TASKS}`, r).length === 1)
ok('a longer file name stays text', docPathParts(`${TASKS}.bak and x${TASKS}`, r).length === 1)
ok('no .md: no link and no work', !mayHoldDocPath('plain words, csi-spl-doc/specs/') && docPathParts('a/b.txt', r).length === 1)
ok('no resolver: text as written', docPathParts(TASKS, null).length === 1)
ok('a path that climbs out of the repo never resolves', r('../escape.md') === '')

/* inline code */
ok('a code span that is wholly a listed path links', codeDocHref(` ${TASKS} `, r) === '/docs/' + TASKS)
ok('a code span with more than the path stays code', codeDocHref(`cat ${TASKS}`, r) === '')

/* parseBody blocks */
const blocks = linkDocPathBlocks([
  { type: 'para', parts: [{ type: 'text', text: `Source: ${TASKS}` }, { type: 'inline', text: SPEC }, { type: 'link', text: 'x', href: 'https://example.com/' + SPEC }] },
  { type: 'code', text: TASKS, lang: '' },
  { type: 'list', ordered: false, items: [{ parts: [{ type: 'strong', text: SPEC }] }] },
], r)
const p0 = blocks[0].parts
ok('blocks: text path linked', p0[1].type === 'link' && p0[1].href === '/docs/' + TASKS)
ok('blocks: a whole code span is a code link', p0[2].type === 'link' && p0[2].code === true && p0[2].href === '/docs/' + SPEC)
ok('blocks: an existing link is untouched', p0[3].href === 'https://example.com/' + SPEC)
ok('blocks: a fenced code block is untouched', blocks[1].type === 'code' && blocks[1].text === TASKS)
ok('blocks: a list item links', blocks[2].items[0].parts[0].type === 'link')

/* markdown tree */
const opts = { breaks: true, html: true, docsRepo: '', docPath: r }
const md = markdownToHtml(`Source: ${TASKS}\n\nSee \`${SPEC}\` and [the spec](https://example.com/${SPEC}) and [${TASKS}](https://example.com/x).\n\n\`\`\`\n${TASKS}\n\`\`\``, undefined, opts)
ok('markdown: a text path is a link', md.includes(`Source: <a href="/docs/${TASKS}" title="/docs/${TASKS}">${TASKS}</a>`), md)
ok('markdown: a whole code span is a link round the code', md.includes(`<a href="/docs/${SPEC}" title="/docs/${SPEC}"><code>${SPEC}</code></a>`), md)
ok('markdown: an existing link keeps its href and its text', md.includes(`<a href="https://example.com/${SPEC}"`) && md.includes(`<a href="https://example.com/x" title="https://example.com/x" target="_blank" rel="noopener noreferrer nofollow">${TASKS}</a>`), md)
ok('markdown: a fenced block stays code', md.includes(`<pre><code>${TASKS}</code></pre>`), md)
ok('markdown: no resolver, no doc link', !markdownToHtml(`Source: ${TASKS}`, undefined, { docsRepo: '' }).includes('<a '))
const md2 = markdownToHtml(`**${TASKS}** in a | table |\n|---|---|\n| ${SPEC} | x |`, undefined, opts)
ok('markdown: in bold and in a table cell', md2.includes(`<strong><a href="/docs/${TASKS}"`) && md2.includes(`<td><a href="/docs/${SPEC}"`), md2)

/* SPL-2425 (owner HUM-10, t1 cb8a9c73): a spec folder links to its spec.md */
const DIR = 'csi-spl-doc/specs/072-rapid-deployability'
ok('spec folder: the folder opens its spec.md', r(DIR) === '/docs/' + SPEC && r(DIR + '/') === '/docs/' + SPEC)
ok('spec folder: a tail of the folder resolves too', r('specs/072-rapid-deployability') === '/docs/' + SPEC)
const both = docPathParts(`spec: ${DIR}\nSpec: ${DIR}/spec.md`, r)
ok('spec folder: the restart line and the Spec: line both link', links(both).join() === `/docs/${SPEC},/docs/${SPEC}` && both[1].text === DIR, JSON.stringify(both))
ok('spec folder: a sentence stop after it stays text', links(docPathParts(`see ${DIR}.`, r)).join() === '/docs/' + SPEC)
ok('spec folder: an unlisted spec stays text', r('csi-spl-doc/specs/999-nope') === '' && docPathParts('Spec: csi-spl-doc/specs/999-nope', r).length === 1)
ok('spec folder: a file in it that is not .md stays text', docPathParts(`${DIR}/plan.txt`, r).length === 1)
ok('spec folder: a non-spec folder stays text', docPathParts('csi-spl-doc/doc/md and specs/72-x', r).length === 1)
ok('spec folder: inside a url it stays text', docPathParts(`https://git.example.org/acme/tree/master/${DIR}`, r).length === 1)
ok('spec folder: the pre-check sees it', mayHoldDocPath(`Spec: ${DIR}`))
ok('spec folder: a code span that is wholly the folder links, more stays code', codeDocHref(DIR, r) === '/docs/' + SPEC && codeDocHref(`ls ${DIR}`, r) === '')
const mdDir = markdownToHtml(`Spec: ${DIR}\n\n- spec: \`${DIR}\``, undefined, opts)
ok('spec folder: markdown links the text and the code span', mdDir.includes(`Spec: <a href="/docs/${SPEC}" title="/docs/${SPEC}">${DIR}</a>`) && mdDir.includes(`<a href="/docs/${SPEC}" title="/docs/${SPEC}"><code>${DIR}</code></a>`), mdDir)

/* the hook */
let loads = 0
const before = docPathEpoch.value
setDocPathLoader(() => { loads++; setDocPathLinker(docPathLinker(LISTED)) })
ok('hook: no linker before the list', activeDocPathLinker('nothing here') === null)
ok('hook: a text with no path asks nothing', (await new Promise((res) => setTimeout(res, 5)), loads === 0))
activeDocPathLinker(TASKS)
activeDocPathLinker(TASKS)
await new Promise((res) => setTimeout(res, 5))
ok('hook: a path asks the list once', loads === 1)
ok('hook: the list in bumps the epoch', docPathEpoch.value > before)
ok('parseBody links a doc path once the list is in', links(parseBody(`Source: ${TASKS}`)[0].parts).join() === '/docs/' + TASKS)
ok('parseBody leaves a fence alone', parseBody('```\n' + TASKS + '\n```')[0].type === 'code')
setDocPathLinker(null)
setDocPathLoader(null)
ok('parseBody without the list: text as written', links(parseBody(`Source: ${TASKS}`)[0].parts).length === 0)
let dirLoads = 0
setDocPathLoader(() => { dirLoads++; setDocPathLinker(docPathLinker(LISTED)) })
activeDocPathLinker(`Spec: ${DIR}`)
await new Promise((res) => setTimeout(res, 5))
ok('hook: a spec folder alone asks the list', dirLoads === 1)
ok('parseBody links a spec folder once the list is in', links(parseBody(`Spec: ${DIR}`)[0].parts).join() === '/docs/' + SPEC)
setDocPathLinker(null)
setDocPathLoader(null)

const suite = runsInUnitSuite(import.meta.url)
ok('pnpm test runs this suite', suite.ok, suite.why)

if (failed) {
  console.log(`doc-paths: ${failed} FAILED`)
  process.exit(1)
}
console.log('doc-paths: all passed')
