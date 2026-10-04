// SPL-951: internal links stay in this tab; only another origin opens a new one.
// The dev origin viewed from production is external, because the origins differ.
import { describe, it, before, after } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

import { classifyHref, followSameTabLink, linkOpen, MESSAGE_LINK_TAP_MAX_MS, messageLinkClick, messageLinkPointerCancel, messageLinkPointerDown, messageLinkPointerUp, NEW_TAB_REL, openMessageLink, sameTabPath, setLinkSite } from '../../src/utils/link-target.mjs'
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
  stopped: false,
  preventDefault() { this.defaultPrevented = true },
  stopPropagation() { this.stopped = true },
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
      assert.match(src, /messageLinkClick/)
      assert.match(src, /messageLinkPointerUp/)
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
  it('CONTROLS: api host, other env, nested label, and tenant hosts off', () => {
    for (const href of ['https://api.app.example/x', DEV_LINK, 'https://northwind.dev.app.example/x']) {
      assert.equal(classifyHref(href, PRD, PRD).internal, false, href)
    }
    assert.equal(classifyHref(NORTHWIND + '/x', PRD, '').internal, false)
    assert.equal(classifyHref(NORTHWIND + '/x', PRD).internal, false) // setLinkSite never called
    assert.equal(classifyHref(NORTHWIND + '/x', DEV, DEV).internal, false) // a prd tenant seen from dev
  })
})

// SPL-951 regression (CLE-001 topic e802196b): www.<fqdn> is a product host
// the owner means as this site, but "www" is a reserved tenant label and www
// has no DNS yet, so it was classed external (new tab) and could not load. A
// www or http link to a product host is now internal AND rewritten to the
// canonical https apex/tenant URL, so it loads even before any www record.
describe('www and http product links (SPL-951 regression)', () => {
  const APEX = PRD // https://app.example
  const NORTHWIND = 'https://northwind.app.example'
  // sameTabPath reads the module-global site (set in prod by tenant-host-boot);
  // set it for this block so the click-path test sees the tenant hosts on.
  before(() => setLinkSite(APEX))
  after(() => setLinkSite(''))
  it('www.<apex> is internal and rewritten to the https apex', () => {
    const c = classifyHref('https://www.app.example/issues?issue=SPL-3', APEX, APEX)
    assert.equal(c.internal, true)
    assert.equal(c.href, 'https://app.example/issues?issue=SPL-3')
  })
  it('www.<tenant>.<apex> is internal and rewritten to the https tenant host', () => {
    const c = classifyHref('https://www.northwind.app.example/x', APEX, APEX)
    assert.equal(c.internal, true)
    assert.equal(c.href, NORTHWIND + '/x')
  })
  it('an http product link is internal and upgraded to https', () => {
    const apex = classifyHref('http://app.example/issues', APEX, APEX)
    assert.equal(apex.internal, true)
    assert.equal(apex.href, 'https://app.example/issues')
    const nw = classifyHref('http://northwind.app.example/x', APEX, APEX)
    assert.equal(nw.internal, true)
    assert.equal(nw.href, NORTHWIND + '/x')
  })
  it('http+www together normalise to the https product host', () => {
    const c = classifyHref('http://www.app.example/x', APEX, APEX)
    assert.equal(c.internal, true)
    assert.equal(c.href, 'https://app.example/x')
  })
  it('a plain click on a www product link stays in this tab (rewritten path)', () => {
    // from the apex page, the rewritten href is the same origin -> SPA nav
    assert.equal(sameTabPath('https://www.app.example/issues', PRD + '/channel/lobby'), '/issues')
    assert.equal(sameTabPath('http://app.example/issues', PRD + '/channel/lobby'), '/issues')
  })
  it('every render path emits the rewritten apex href for a www product link', () => {
    // the rendered paths read the module-global site (set in prod by
    // tenant-host-boot.mjs); the direct classifyHref tests pass it explicitly.
    setLinkSite(APEX)
    try {
      // markdown link
      const mdHtml = renderMarkdown(`[go](https://www.app.example/issues?issue=SPL-3)`, PRD)
      opens(mdHtml, 'https://app.example/issues?issue=SPL-3', { internal: true })
      // auto-linked bare "www.app.example/x" in a message body
      const bodyHtml = bodyToHtml('see www.app.example/issues for more', PRD)
      opens(bodyHtml, 'https://app.example/issues', { internal: true })
      // an http product link in a message body
      const httpHtml = bodyToHtml('http://app.example/issues here', PRD)
      opens(httpHtml, 'https://app.example/issues', { internal: true })
    } finally {
      setLinkSite('')
    }
  })

  it('CONTROLS: a foreign www/http host is still external and left as written', () => {
    const ext = classifyHref('https://www.example.com/x', APEX, APEX)
    assert.equal(ext.internal, false)
    assert.equal(ext.href, 'https://www.example.com/x')
    const httpExt = classifyHref('http://example.com/x', APEX, APEX)
    assert.equal(httpExt.internal, false)
    assert.equal(httpExt.href, 'http://example.com/x')
    // a different port is a different service, never the site
    assert.equal(classifyHref('https://app.example:8443/x', APEX, APEX).internal, false)
    assert.equal(classifyHref('http://app.example:8443/x', APEX, APEX).internal, false)
    // the other env: www.<apex> seen from dev is not dev's site
    assert.equal(classifyHref('https://www.app.example/x', DEV, DEV).internal, false)
    // tenant hosts off: only the exact same origin is internal
    assert.equal(classifyHref('https://www.app.example/x', APEX, '').internal, false)
  })
})

// A phone tap on a message link: pointerup opens it, because the click is
// dropped. The click that does arrive must not open it a second time.
// A mouse never takes the pointerup path.
describe('phone tap opens a message link', () => {
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
  const el = () => ({})
  function down(node, over = {}) {
    return { pointerType: 'touch', pointerId: 1, isPrimary: true, button: 0, clientX: 20, clientY: 40, currentTarget: node, ...over }
  }
  function tap(node, href, page = PAGE, over = {}) {
    const paths = []
    const opened = []
    messageLinkPointerDown(down(node))
    const armed = messageLinkPointerUp(
      down(node, over),
      href,
      page,
      (path) => { paths.push(path) },
      (url) => { opened.push(url); return true },
    )
    return { armed, paths, opened }
  }

  it('a touch tap on an internal link navigates once, and the click that follows does not', () => {
    const node = el()
    const { armed, paths } = tap(node, REL)
    assert.equal(armed, true)
    assert.deepEqual(paths, [REL])
    const ev = click()
    ev.currentTarget = node
    const again = []
    assert.equal(messageLinkClick(ev, REL, PAGE, (path) => { again.push(path) }), false)
    assert.deepEqual(again, [])
    assert.equal(ev.defaultPrevented, true)
    assert.equal(ev.stopped, true)
  })

  it('CONTROL: a touch tap whose click is never delivered still navigates', () => {
    const { armed, paths } = tap(el(), '/people')
    assert.equal(armed, true)
    assert.deepEqual(paths, ['/people'])
  })

  it('a click on the anchor the navigation re-rendered does not navigate again', () => {
    const { armed, paths } = tap(el(), REL)
    assert.equal(armed, true)
    assert.deepEqual(paths, [REL])
    const other = click()
    other.currentTarget = el()
    const again = []
    assert.equal(messageLinkClick(other, EXT, PAGE, (path) => { again.push(path) }), false)
    assert.equal(other.defaultPrevented, false)
    const ghost = click()
    ghost.currentTarget = el()
    assert.equal(messageLinkClick(ghost, REL, PAGE, (path) => { again.push(path) }), false)
    assert.equal(ghost.defaultPrevented, true)
    assert.equal(ghost.stopped, true)
    assert.deepEqual(again, [])
  })

  it('a touch tap on an external link opens one new tab and the click does not', () => {
    const node = el()
    const { armed, opened, paths } = tap(node, EXT)
    assert.equal(armed, true)
    assert.deepEqual(paths, [])
    assert.deepEqual(opened, [EXT])
    const ev = click()
    ev.currentTarget = node
    const again = []
    messageLinkClick(ev, EXT, PAGE, (path) => { again.push(path) })
    assert.deepEqual(again, [])
    assert.equal(ev.defaultPrevented, true)
  })

  it('a blocked external open leaves the click to the anchor', () => {
    const node = el()
    messageLinkPointerDown(down(node))
    const armed = messageLinkPointerUp(down(node), EXT, PAGE, () => {}, () => false)
    assert.equal(armed, false)
    const ev = click()
    ev.currentTarget = node
    assert.equal(messageLinkClick(ev, EXT, PAGE, () => {}), false)
    assert.equal(ev.defaultPrevented, false)
  })

  it('javascript is not opened from a tap', () => {
    const opened = []
    const { armed } = tap(el(), 'javascript:alert(1)')
    assert.equal(armed, false)
    assert.deepEqual(opened, [])
    assert.equal(openMessageLink('javascript:alert(1)', PAGE, () => {}, (u) => { opened.push(u) }), false)
  })

  it('a mouse pointerup does not navigate; the click does, once', () => {
    const node = el()
    const paths = []
    messageLinkPointerDown(down(node, { pointerType: 'mouse' }))
    const armed = messageLinkPointerUp(
      down(node, { pointerType: 'mouse' }),
      REL, PAGE, (path) => { paths.push(path) }, () => {},
    )
    assert.equal(armed, false)
    assert.deepEqual(paths, [])
    const ev = click()
    ev.currentTarget = node
    assert.equal(messageLinkClick(ev, REL, PAGE, (path) => { paths.push(path) }), true)
    assert.deepEqual(paths, [REL])
    assert.equal(ev.defaultPrevented, true)
  })

  it('a finger that moved, or a second finger, is not a tap', () => {
    const node = el()
    const moved = tap(node, REL, PAGE, { clientX: 80 })
    assert.equal(moved.armed, false)
    assert.deepEqual(moved.paths, [])
    messageLinkPointerDown(down(node, { isPrimary: false }))
    const second = messageLinkPointerUp(down(node, { isPrimary: false }), REL, PAGE, () => {}, () => {})
    assert.equal(second, false)
  })

  it('a cancelled finger does not open on the next pointerup', () => {
    const node = el()
    messageLinkPointerDown(down(node))
    messageLinkPointerCancel({ currentTarget: node })
    const armed = messageLinkPointerUp(down(node), REL, PAGE, () => {}, () => {})
    assert.equal(armed, false)
  })

  it('a long press does not open from pointerup; a later click still can', async () => {
    const node = el()
    const paths = []
    messageLinkPointerDown(down(node))
    await sleep(MESSAGE_LINK_TAP_MAX_MS + 30)
    const armed = messageLinkPointerUp(down(node), REL, PAGE, (path) => { paths.push(path) }, () => {})
    assert.equal(armed, false)
    assert.deepEqual(paths, [])
    const ev = click()
    ev.currentTarget = node
    assert.equal(messageLinkClick(ev, REL, PAGE, (path) => { paths.push(path) }), true)
    assert.deepEqual(paths, [REL])
  })
})
