// SPL-1291 (owner, t1 2b25c535): a link to a doc in a message opens our own
// docs store, /docs/<path>, instead of the code host. The repository is cnf
// repo_web_url (here an example host, as wf 10's mock bundle bakes); a link
// to a .md file of it, or a bare repo-relative .md path, becomes the in-app
// route with its anchor kept. A commit, PR, tree, non-.md, ?query or
// foreign-host link stays as written (the CONTROL rows). A doc the store has
// not published is offered on the repository (docsRepoUrl).
//
// Run: node tests/unit/docs-links.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { docsLinkHref, docsRepoUrl } from '../../src/utils/docs.mjs'
import { markdownToHtml } from '../../src/utils/markdown.mjs'

const REPO = 'https://git.example.org/acme/spool'
const HELP = '/blob/master/csi-spl-doc/doc/help/'
const DOC = 'csi-spl-doc/doc/help/how-to-post.md'

describe('docsLinkHref', () => {
  it('a blob link to a .md of the repository becomes /docs/<path>, any ref', () => {
    assert.equal(docsLinkHref(`${REPO}/blob/master/${DOC}`, REPO), '/docs/' + DOC)
    assert.equal(docsLinkHref(`${REPO}/blob/0c6c9e0f/README.md`, REPO), '/docs/README.md')
    assert.equal(docsLinkHref(`${REPO}/-/blob/main/${DOC}`, REPO), '/docs/' + DOC)
    assert.equal(docsLinkHref(`http://www.git.example.org/acme/spool/blob/master/${DOC}`, REPO), '/docs/' + DOC)
  })
  it('the anchor is kept', () => {
    assert.equal(docsLinkHref(`${REPO}/blob/master/${DOC}#a-post-is-markdown`, REPO), '/docs/' + DOC + '#a-post-is-markdown')
  })
  it('a bare repo-relative .md path becomes /docs/<path>, with or without ./ and an anchor', () => {
    assert.equal(docsLinkHref(DOC, REPO), '/docs/' + DOC)
    assert.equal(docsLinkHref('./' + DOC + '#x', ''), '/docs/' + DOC + '#x')
  })
  it('the route builder is the caller\'s (a locale prefix)', () => {
    assert.equal(docsLinkHref(DOC, REPO, (p) => '/fi/docs/' + p), '/fi/docs/' + DOC)
  })
  it('CONTROL a commit, PR, tree, raw, compare and issues link stays as written', () => {
    for (const u of [
      `${REPO}/commit/0c6c9e0f`, `${REPO}/pull/12`, `${REPO}/tree/master/csi-spl-doc`,
      `${REPO}/raw/master/${DOC}`, `${REPO}/compare/a...b`, `${REPO}/issues/3`, `${REPO}/blob/master/csi-spl-doc`,
    ]) assert.equal(docsLinkHref(u, REPO), null, u)
  })
  it('CONTROL a non-.md file, a ?query and a climb stay as written', () => {
    for (const u of [`${REPO}/blob/master/csi-spl-iac/run`, `${REPO}/blob/master/${DOC}?plain=1#L3`,
      `${REPO}/blob/master/a%2F..%2Fb.md`, 'csi-spl-iac/run', '../x.md', 'x.md?y=1']) assert.equal(docsLinkHref(u, REPO), null, u)
  })
  it('CONTROL another host, another repo and no repository configured stay as written', () => {
    assert.equal(docsLinkHref(`https://other.example.net/acme/spool/blob/master/${DOC}`, REPO), null)
    assert.equal(docsLinkHref(`https://git.example.org/acme/spool-other/blob/master/${DOC}`, REPO), null)
    assert.equal(docsLinkHref(`${REPO}/blob/master/${DOC}`, ''), null)
    assert.equal(docsLinkHref(`${REPO}/blob/master/${DOC}`, undefined), null)
  })
  it('CONTROL a site path, an anchor, mailto and junk stay as written', () => {
    for (const u of ['/docs/' + DOC, '/' + DOC, '#x', '?topic=1', 'mailto:a@example.com', 'javascript:alert(1)//x.md', '', null]) {
      assert.equal(docsLinkHref(u, REPO), null, String(u))
    }
  })
})

describe('the message renderer (markdown.mjs, docsRepo)', () => {
  const html = (src) => markdownToHtml(src, 'https://site.example.com', { breaks: true, html: true, docsRepo: REPO })
  it('a markdown link and a bare URL to a doc open /docs in this tab, anchor kept', () => {
    const out = html(`See [how to post](${REPO}/blob/master/${DOC}#tables) and ${REPO}/blob/master/README.md`)
    assert.match(out, new RegExp(`<a href="/docs/${DOC}#tables" title="/docs/${DOC}#tables">how to post</a>`))
    assert.match(out, /<a href="\/docs\/README\.md"[^>]*>https:\/\/git\.example\.org\/acme\/spool\/blob\/master\/README\.md<\/a>/)
    assert.equal(/target="_blank"[^>]*>how to post/.test(out), false)
  })
  it('a repo-relative .md link opens /docs, not a path under the current page', () => {
    assert.match(html(`[post](${DOC})`), new RegExp(`href="/docs/${DOC}"`))
  })
  it('CONTROL a commit link stays on the repository, in a new tab', () => {
    const out = html(`landed in [0c6c9e0f](${REPO}/commit/0c6c9e0f)`)
    assert.match(out, /href="https:\/\/git\.example\.org\/acme\/spool\/commit\/0c6c9e0f"[^>]*target="_blank"/)
  })
  it('CONTROL without docsRepo (a caller that did not opt in) every link is as written', () => {
    const out = markdownToHtml(`[p](${REPO}/blob/master/${DOC})`, 'https://site.example.com')
    assert.match(out, /href="https:\/\/git\.example\.org\/acme\/spool\/blob\/master\//)
  })
})

describe('docsRepoUrl', () => {
  it('the doc on the repository, on repo_help_path\'s branch', () => {
    assert.equal(docsRepoUrl(DOC, REPO + '/', HELP), `${REPO}/blob/master/${DOC}`)
    assert.equal(docsRepoUrl(DOC, REPO, '/-/blob/main/doc/help/'), `${REPO}/-/blob/main/${DOC}`)
  })
  it('CONTROL no repository, no branch or a bad path gives no link', () => {
    assert.equal(docsRepoUrl(DOC, '', HELP), '')
    assert.equal(docsRepoUrl(DOC, REPO, ''), '')
    assert.equal(docsRepoUrl('../x.md', REPO, HELP), '')
    assert.equal(docsRepoUrl(DOC, 'javascript:alert(1)', HELP), '')
  })
})
