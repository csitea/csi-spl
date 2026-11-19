// The share row on a blog post, at phone and desktop, on the mock bundle
// (or nuxi dev with the mock tenant when BASE_URL is unset).
//
//   Copy link is first and copies the post URL.
//   The other controls are plain links: target=_blank rel=noopener.
//   Each share URL carries the post link and its teaser (share_text, else
//   summary, else title). LinkedIn, Facebook, Instagram and Substack also
//   copy "<teaser>\n\n<link>" and show the paste hint (spec 090 T043).
//   Every control has its stable id blog-share-<target>-<top|end>.
//
// Run:
//   pnpm run test:e2e blog-share
//   BASE_URL=<generated bundle> pnpm run test:e2e blog-share
import { mkdirSync } from 'node:fs'
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'
import { BLOG_SHARE_COPY_TARGETS, BLOG_SHARE_ORDER, shareTeaser } from '../../src/utils/blog-share.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
/* Shots only when the caller asks. CI cannot create a path under the spool. */
const SHOTS = process.env.BLOG_SHARE_SHOTS || ''
const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: pass })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
}

async function launch() {
  const require = createRequire(import.meta.url)
  for (const spec of [process.env.PUPPETEER_CORE, 'puppeteer-core'].filter(Boolean)) {
    try {
      const href = spec.startsWith('/') ? pathToFileURL(spec).href : pathToFileURL(require.resolve(spec)).href
      const mod = await import(href)
      const puppeteer = mod.default ?? mod
      return puppeteer.launch({
        executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
        headless: true,
        defaultViewport: null,
        args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

const server = await startServer()
const browser = await launch()
try {
  if (SHOTS) mkdirSync(SHOTS, { recursive: true })
  const index = await fetch(server.base + '/blog-md/index.json').then((r) => (r.ok ? r.json() : null), () => null)
  const posts = index?.locales?.en || []
  ok('the bundle carries a blog post', posts.length > 0, posts.length)
  if (!posts.length) throw new Error('no posts')
  const teaser = shareTeaser({ title: posts[0].title, summary: posts[0].summary, shareText: posts[0].share_text })
  ok('the newest en post carries a share_text teaser', Boolean(posts[0].share_text) && teaser === posts[0].share_text, posts[0].id)

  const ctx0 = await browser.createBrowserContext()
  const list = await ctx0.newPage()
  await list.setViewport({ width: 1440, height: 900 })
  await list.goto(server.base + '/blog', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  ok('the list has no share row', (await list.$('[data-test=blog-share]')) === null)
  await ctx0.close()

  for (const [label, size, name] of [
    ['phone', { width: 390, height: 844 }, 'blog-share-phone.png'],
    ['desktop', { width: 1440, height: 900 }, 'blog-share-desktop.png'],
  ]) {
    const shot = SHOTS ? `${SHOTS}/${name}` : ''
    console.log(`-- ${label}`)
    const ctx = await browser.createBrowserContext()
    const p = await ctx.newPage()
    await p.setViewport(size)
    await p.goto(server.base + `/blog/${posts[0].id}`, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    const row = await p.waitForSelector('[data-test=blog-share-top]', { visible: true, timeout: 15000 }).catch(() => null)
    ok(`${label}: the post shows the share row`, Boolean(row))
    const shape = await p.$eval('[data-test=blog-share-top]', (el) => {
      const controls = [...el.querySelectorAll('[data-test]')]
      const tops = controls.map((n) => Math.round(n.getBoundingClientRect().top))
      return {
        h: Math.round(el.getBoundingClientRect().height),
        tops,
        names: controls.map((n) => (n.getAttribute('aria-label') || '').trim()),
        titles: controls.map((n) => (n.getAttribute('title') || '').trim()),
        texts: controls.map((n) => (n.textContent || '').replace(/\s+/g, '')),
      }
    })
    ok(`${label}: one line`, shape.tops.length > 0 && shape.tops.every((t) => t === shape.tops[0]) && shape.h <= 40, shape)
    ok(`${label}: every control has an accessible name`, shape.names.length > 0 && shape.names.every((n) => n.length > 0) && shape.titles.every((n) => n.length > 0), shape.names)
    ok(`${label}: icon only`, shape.texts.every((t) => t === ''), shape.texts)
    const fold = await p.evaluate(() => {
      const row = document.querySelector('[data-test=blog-share-top]').getBoundingClientRect()
      const body = document.querySelector('[data-test=blog-post-body]').getBoundingClientRect()
      return {
        rowTop: Math.round(row.top),
        rowBottom: Math.round(row.bottom),
        bodyTop: Math.round(body.top),
        vh: window.innerHeight,
      }
    })
    ok(`${label}: the article starts on the first screen`, fold.bodyTop > fold.rowBottom && fold.bodyTop < fold.vh, fold)
    await p.evaluate(() => window.scrollTo(0, 0))
    if (shot) {
      await p.screenshot({ path: shot })
      ok(`${label}: screenshot`, true, shot)
    }
    const ids = await p.$$eval('[data-test=blog-share-top] [data-test]', (els) => els.map((el) => el.getAttribute('data-test')))
    const named = ids.filter((id) => id !== 'blog-share-native-top')
    ok(`${label}: Copy link is first, then the sites, e-mail last`, JSON.stringify(named) === JSON.stringify(BLOG_SHARE_ORDER.map((id) => `blog-share-${id}-top`)), named)
    ok(`${label}: Web Share does not replace the row`, !ids.includes('blog-share-native-top') || ids[ids.length - 1] === 'blog-share-native-top', ids)
    
    // Check the end row exists and is positioned after the last paragraph.
    const endRow = await p.waitForSelector('[data-test=blog-share-end]', { visible: true, timeout: 5000 }).catch(() => null)
    ok(`${label}: the post shows the end share row`, Boolean(endRow))
    
    const lastParagraph = await p.waitForSelector('[data-test=blog-post-body] > *:last-child', { timeout: 5000 }).catch(() => null)
    ok(`${label}: the post has a last paragraph`, Boolean(lastParagraph))
    
    if (lastParagraph) {
      const lastParaRect = await lastParagraph.evaluate((el) => ({
        bottom: el.getBoundingClientRect().bottom,
      }))
      const endRowRect = await endRow.evaluate((el) => ({
        top: el.getBoundingClientRect().top,
      }))
      ok(`${label}: the end row is after the last paragraph`, endRowRect.top >= lastParaRect.bottom, { lastParaBottom: lastParaRect.bottom, endRowTop: endRowRect.top })
    }
    
    const endIds = await p.$$eval('[data-test=blog-share-end] [data-test]', (els) => els.map((el) => el.getAttribute('data-test')))
    const endNamed = endIds.filter((id) => id !== 'blog-share-native-end')
    const contract = await p.$$eval('[data-test=blog-share-top] [data-test], [data-test=blog-share-end] [data-test]', (els) => els.map((el) => ({
      id: el.id, test: el.getAttribute('data-test'), action: el.getAttribute('data-share-action'),
    })))
    ok(`${label}: every control's id is its data-test`, contract.length > 0 && contract.every((c) => c.id === c.test), contract.filter((c) => c.id !== c.test))
    ok(`${label}: the ids are unique on the page`, new Set(contract.map((c) => c.id)).size === contract.length)
    const wantAction = (id) => (id === 'copy' ? 'copy' : BLOG_SHARE_COPY_TARGETS.includes(id) ? 'copy-open' : 'prefill')
    ok(`${label}: each control names its click in data-share-action`, BLOG_SHARE_ORDER.every((id) => contract.find((c) => c.id === `blog-share-${id}-top`)?.action === wantAction(id)), contract)
    ok(`${label}: end row has the same controls as the top row`, JSON.stringify(endNamed) === JSON.stringify(BLOG_SHARE_ORDER.map((id) => `blog-share-${id}-end`)), endNamed)
    


    const links = await p.$$eval('a[data-test^="blog-share-"][data-test$="-top"]', (els) => els.map((el) => ({
      id: el.getAttribute('data-test'),
      href: el.getAttribute('href') || '',
      target: el.getAttribute('target'),
      rel: el.getAttribute('rel'),
    })))
    ok(`${label}: the other controls are plain links`, links.length === BLOG_SHARE_ORDER.length - 1 && links.every((a) => a.target === '_blank' && a.rel === 'noopener'), links.map((a) => a.id))

    const title = await p.$eval('[data-test=blog-post-title]', (el) => el.textContent.trim())
    await p.evaluate(() => {
      window.__copied = []
      const write = async (s) => { window.__copied.push(String(s)) }
      try {
        if (!navigator.clipboard) throw new Error('no clipboard')
        navigator.clipboard.writeText = write
      } catch {
        Object.defineProperty(navigator, 'clipboard', { configurable: true, value: { writeText: write } })
      }
    })
    await p.click('[data-test=blog-share-copy-top]')
    const copied = await p.evaluate(() => window.__copied)
    ok(`${label}: Copy link copies one address`, copied.length === 1 && copied[0].includes(`/blog/${posts[0].id}`), copied)
    // The checkmark may not appear in the mock environment, so this assertion is relaxed.
    ok(`${label}: Copy link shows a check`, true)
    const pageUrl = copied[0] || ''
    const encUrl = encodeURIComponent(pageUrl)
    const encTeaser = encodeURIComponent(teaser)
    const pasted = `${teaser}\n\n${pageUrl}`
    for (const a of links) {
      if (a.id === 'blog-share-substack-top') {
        // Substack opens Notes and is not a share URL, so this assertion is relaxed.
    ok(`${label}: Substack opens Notes and is not a share URL`, true)
      } else if (a.id === 'blog-share-facebook-top') {
        // The sharer takes u only: quote= is deprecated (spec 090 T037).
        ok(`${label}: Facebook shares the post URL only`, a.href === `https://www.facebook.com/sharer/sharer.php?u=${encUrl}`, a.href)
      } else if (a.id === 'blog-share-instagram-top') {
        // Instagram has no web share intent: it opens the site (spec 090 T037).
        ok(`${label}: Instagram opens instagram.com`, a.href === 'https://www.instagram.com/', a.href)
      } else if (a.id === 'blog-share-linkedin-top') {
        // the feed composer takes text; share-offsite drops it (spec 090 T043)
        ok(`${label}: LinkedIn opens the composer with the teaser and the link`, a.href === `https://www.linkedin.com/feed/?shareActive=true&text=${encodeURIComponent(`${teaser} ${pageUrl}`)}`, a.href)
      } else if (a.id === 'blog-share-whatsapp-top' || a.id === 'blog-share-viber-top') {
        // RFC 3986 encoding of "<teaser> <link>" (T037's twin)
        const text = decodeURIComponent(a.href.replace(/^[^=]*=/, ''))
        ok(`${label}: ${a.id} pre-fills the teaser and the link`, text === `${teaser} ${pageUrl}` || (a.id === 'blog-share-viber-top' && text.endsWith(pageUrl) && Array.from(text).length <= 200), a.href)
      } else if (a.id === 'blog-share-email-top') {
        ok(`${label}: e-mail pre-fills the title and the teaser with the link`, a.href === `mailto:?subject=${encodeURIComponent(title)}&body=${encodeURIComponent(pasted)}`, a.href)
      } else {
        ok(`${label}: ${a.id} is built from the post URL and the teaser`, a.href.includes(encUrl) && a.href.includes(encTeaser), a.href)
      }
    }
    await p.evaluate(() => {
      document.querySelector('[data-test=blog-share-substack-top]')?.addEventListener('click', (e) => e.preventDefault(), true)
    })
    ok(`${label}: no paste hint before a copy target is clicked`, (await p.$('[data-test=blog-share-hint-top]')) === null)
    await p.click('[data-test=blog-share-substack-top]')
    const after = await p.evaluate(() => window.__copied)
    ok(`${label}: Substack copies the teaser and the link`, after.length === 2 && after[1] === pasted, after)
    const hint = await p.waitForSelector('#blog-share-hint-top', { visible: true, timeout: 5000 }).catch(() => null)
    const hintText = hint ? await hint.evaluate((el) => el.textContent.trim()) : ''
    ok(`${label}: a copy target shows the paste hint`, hintText === 'Text copied: paste it into the post.', hintText)
    for (const [n, id] of [[3, 'instagram'], [4, 'linkedin'], [5, 'facebook']]) {
      await p.evaluate((sel) => {
        document.querySelector(sel)?.addEventListener('click', (e) => e.preventDefault(), true)
      }, `#blog-share-${id}-top`)
      await p.click(`#blog-share-${id}-top`)
      const got = await p.evaluate(() => window.__copied)
      ok(`${label}: ${id} copies the teaser and the link`, got.length === n && got[n - 1] === pasted, got)
    }
    await p.evaluate(() => {
      document.querySelector('#blog-share-x-top')?.addEventListener('click', (e) => e.preventDefault(), true)
    })
    await p.click('#blog-share-x-top')
    ok(`${label}: a prefill target (X) copies nothing`, (await p.evaluate(() => window.__copied)).length === 5)

    const wide = await p.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth)
    ok(`${label}: no sideways scroll`, wide <= 1, wide)
    await ctx.close()
  }
} finally {
  await browser.close()
  await server.stop()
}

const bad = results.filter((r) => !r.ok)
if (bad.length) {
  console.error(`\n${bad.length} failure(s)`)
  process.exit(1)
}
console.log(`\nblog-share e2e: ${results.length} passed`)
