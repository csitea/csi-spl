// SPL-951: internal links stay in this tab; only another origin opens a new one.
// The dev origin viewed from production is external, because the origins differ.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

import { classifyHref, followSameTabLink, linkOpen, NEW_TAB_REL, sameTabPath } from '../../src/utils/link-target.mjs'
import { markdownToHtml, renderMarkdown, treeToHtml } from '../../src/utils/markdown.mjs'
import { bodyToHtml, parseBody } from '../../src/utils/code-blocks.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const PRD = 'https://app.example'
const DEV = 'https://dev.app.example'
const PAGE = PRD + '/channel/lobby'
const REL = '/issues?issue=SPL-12'
const SAME = PRD + '/issues?issue=SPL-12'
const DEV_LINK = DEV + '/issues?issue=SPL-12'
const EXT = 'https://example.com/docs'

const click = () => ({
  button: 0,
  metaKey: false,
  ctrlKey: false,
  shiftKey: false,
  altKey: false,
  defaultPrevented: false,
  preventDefault() { this.defaultPrevented = true },
})

function went(href, page = PAGE) {
  const ev = click()
  let path = null
  const handled = followSameTabLink(ev, href, page, (p) => { path = p })
  return { handled, path, prevented: ev.defaultPrevented }
}

describe('classifyHref', () => {
  it('relative, same-origin, dev-from-prd, and external', () => {
    assert.deepEqual(classifyHref(REL, PRD), { href: REL, internal: true })
    assert.deepEqual(classifyHref('?topic=abc', PRD), { href: '?topic=abc', internal: true })
    assert.equal(classifyHref(SAME, PRD).internal, true)
    assert.equal(classifyHref(SAME, PRD).href, SAME)
    assert.equal(classifyHref(DEV_LINK, PRD).internal, false)
    assert.equal(classifyHref(EXT, PRD).internal, false)
    assert.equal(classifyHref('mailto:a@example.com', PRD).internal, false)
  })

  it('without a page origin every absolute URL is external and a relative URL stays internal', () => {
    assert.equal(classifyHref(SAME).internal, false)
    assert.equal(classifyHref(REL).internal, true)
    assert.equal(classifyHref(EXT, '').internal, false)
  })

  it('http and a different port are not the same origin', () => {
    assert.equal(classifyHref('http://app.example/issues', PRD).internal, false)
    assert.equal(classifyHref('https://app.example:8443/issues', PRD).internal, false)
  })

  it('a userinfo host is the parsed origin, not the text before the @', () => {
    assert.equal(classifyHref('https://app.example@evil.example/x', PRD).internal, false)
    assert.equal(classifyHref('https://evil.example@app.example/x', PRD).internal, true)
  })

  it('javascript, data, vbscript, file, protocol-relative and a backslash are not links', () => {
    for (const bad of [
      'javascript:alert(1)',
      'JavaScript:alert(1)',
      'java\tscript:alert(1)',
      'data:text/html,x',
      'vbscript:x',
      'file:///etc/passwd',
      'ftp://example.com/x',
      '//evil.example/phish',
      '/\\evil.example',
      '\\evil.example',
      'https:example.com',
      '',
      'http://',
      '%6Aavascript:alert(1)',
      'javascript%3Aalert(1)',
      '%256Aavascript:alert(1)',
    ]) {
      assert.equal(classifyHref(bad, PRD), null, bad)
    }
  })
})

describe('a plain click', () => {
  it('navigates relative, query and same-origin in this tab', () => {
    assert.deepEqual(went(REL), { handled: true, path: REL, prevented: true })
    assert.deepEqual(went('?topic=abc'), { handled: true, path: '/channel/lobby?topic=abc', prevented: true })
    assert.deepEqual(went('#section'), { handled: true, path: '/channel/lobby#section', prevented: true })
    assert.deepEqual(went(SAME), { handled: true, path: '/issues?issue=SPL-12', prevented: true })
    assert.equal(sameTabPath('./issues', PAGE), '/channel/issues')
  })

  it('leaves dev-from-prd, external and mailto to the browser', () => {
    for (const href of [DEV_LINK, EXT, 'mailto:a@example.com', 'javascript:alert(1)']) {
      const ev = click()
      let called = false
      assert.equal(followSameTabLink(ev, href, PAGE, () => { called = true }), false, href)
      assert.equal(called, false)
      assert.equal(ev.defaultPrevented, false)
    }
  })

  it('a modified click is not hijacked', () => {
    for (const extra of [{ ctrlKey: true }, { metaKey: true }, { shiftKey: true }, { altKey: true }, { button: 1 }]) {
      const ev = { ...click(), ...extra }
      assert.equal(followSameTabLink(ev, SAME, PAGE, () => { throw new Error('navigated') }), false)
      assert.equal(ev.defaultPrevented, false)
    }
  })
})

function anchor(html, href) {
  const re = new RegExp(`<a\\b[^>]*href="${href.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}"[^>]*>`)
  const m = html.match(re)
  assert.ok(m, `${href} missing in ${html}`)
  return m[0]
}

function opens(html, href, { internal }) {
  const tag = anchor(html, href)
  if (internal) {
    assert.equal(tag.includes('target='), false, tag)
    assert.equal(tag.includes('rel='), false, tag)
  } else {
    assert.match(tag, /target="_blank"/)
    assert.match(tag, new RegExp(`rel="${NEW_TAB_REL}"`))
  }
}

describe('markdown rendering', () => {
  const src = [
    `[rel](${REL})`,
    `[same](${SAME})`,
    `[dev](${DEV_LINK})`,
    `[ext](${EXT})`,
    '[mail](mailto:a@example.com)',
    '[bad](javascript:alert(1))',
  ].join(' ')

  it('relative and same-origin have no target; dev-from-prd and external open in a new tab', () => {
    const html = renderMarkdown(src, PRD)
    opens(html, REL, { internal: true })
    opens(html, SAME, { internal: true })
    opens(html, DEV_LINK, { internal: false })
    opens(html, 'https://example.com/docs', { internal: false })
    opens(html, 'mailto:a@example.com', { internal: false })
    assert.equal(/href="javascript:/i.test(html), false)
    assert.equal(markdownToHtml(src, PRD), html)
  })

  it('with no origin an absolute URL is external and a relative URL is internal', () => {
    const html = markdownToHtml(src)
    opens(html, REL, { internal: true })
    opens(html, SAME, { internal: false })
  })

  it('a smuggled javascript href is text, not an anchor', () => {
    assert.equal(treeToHtml([{ tag: 'a', attrs: { href: 'javascript:alert(1)' }, children: ['click'] }], PRD), 'click')
  })
})

describe('message-body rendering', () => {
  it('a plain URL: relative is not autolinked; same-origin, dev-from-prd and external follow the rule', () => {
    assert.equal(parseBody(REL)[0].parts.every((p) => p.type !== 'link'), true)
    const same = bodyToHtml(SAME, PRD)
    opens(same, SAME, { internal: true })
    const dev = bodyToHtml(DEV_LINK, PRD)
    opens(dev, DEV_LINK, { internal: false })
    const ext = bodyToHtml(EXT)
    opens(ext, EXT, { internal: false })
  })

  it('a wiki markdown link: relative, same-origin, dev-from-prd, external', () => {
    const src = `{{wiki}}\n[rel](${REL}) [same](${SAME}) [dev](${DEV_LINK}) [ext](${EXT}) [bad](javascript:alert(1))\n{{/wiki}}`
    const html = bodyToHtml(src, PRD)
    opens(html, REL, { internal: true })
    opens(html, SAME, { internal: true })
    opens(html, DEV_LINK, { internal: false })
    opens(html, EXT, { internal: false })
    assert.equal(/href="javascript:/i.test(html), false)
    assert.match(html, /javascript:alert/)
  })
})

describe('both live components use the helper', () => {
  for (const file of ['src/components/MessageRuns.vue', 'src/components/MarkdownBlock.vue']) {
    it(file, () => {
      const src = readFileSync(join(WUI, file), 'utf8')
      assert.match(src, /link-target\.mjs/)
      assert.match(src, /followSameTabLink/)
      assert.match(src, /linkOpen/)
      assert.doesNotMatch(src, /target="_blank"|target:\s*'_blank'/)
    })
  }
})

// SPL-959: a tenant host of the SAME env is internal (same tab; another host
// is a full load); the api host and the other env stay external.
describe('tenant hosts (SPL-959)', () => {
  const NORTHWIND = 'https://northwind.app.example'
  it('same-env tenant hosts are internal, from the apex and from a tenant host', () => {
    assert.equal(classifyHref(NORTHWIND + '/issues?issue=SPL-3', PRD, PRD).internal, true)
    assert.equal(classifyHref(PRD + '/issues', NORTHWIND, PRD).internal, true)
    assert.equal(linkOpen(NORTHWIND + '/issues', PRD, PRD).target, undefined)
  })
  it('a cross-host internal link is left to the browser (full navigation, same tab)', () => {
    assert.equal(sameTabPath(NORTHWIND + '/issues', PAGE), null)
  })
  it('CONTROLS: api host, other env, nested label, http, and tenant hosts off', () => {
    for (const href of ['https://api.app.example/x', DEV_LINK, 'https://northwind.dev.app.example/x', 'http://northwind.app.example/x']) {
      assert.equal(classifyHref(href, PRD, PRD).internal, false, href)
    }
    assert.equal(classifyHref(NORTHWIND + '/x', PRD, '').internal, false)
    assert.equal(classifyHref(NORTHWIND + '/x', PRD).internal, false) // setLinkSite never called
    assert.equal(classifyHref(NORTHWIND + '/x', DEV, DEV).internal, false) // a prd tenant seen from dev
  })
})
