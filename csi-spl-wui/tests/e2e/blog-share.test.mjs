// The share row on a blog post, at phone and desktop, on the mock bundle
// (or nuxi dev with the mock tenant when BASE_URL is unset).
//
//   Copy link is first and copies the post URL.
//   The other controls are plain links: target=_blank rel=noopener.
//   Substack opens Notes and also copies the link. It is not a share URL.
//
// Run:
//   pnpm run test:e2e blog-share
//   BASE_URL=<generated bundle> pnpm run test:e2e blog-share
import { mkdirSync } from 'node:fs'
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'
import { BLOG_SHARE_ORDER, SUBSTACK_NOTES } from '../../src/utils/blog-share.mjs'

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
    const row = await p.waitForSelector('[data-test=blog-share]', { visible: true, timeout: 15000 }).catch(() => null)
    ok(`${label}: the post shows the share row`, Boolean(row))
    const shape = await p.$eval('[data-test=blog-share]', (el) => {
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
      const row = document.querySelector('[data-test=blog-share]').getBoundingClientRect()
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
    const ids = await p.$$eval('[data-test^="blog-share-"] [data-test]', (els) => els.map((el) => el.getAttribute('data-test')))
    const named = ids.filter((id) => id !== 'blog-share-native-top' && id !== 'blog-share-native-end')
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
    ok(`${label}: end row has the same controls as the top row`, JSON.stringify(endNamed) === JSON.stringify(BLOG_SHARE_ORDER.map((id) => `blog-share-${id}-end`)), endNamed)
    


    const links = await p.$$eval('a[data-test^="blog-share-"]', (els) => els.map((el) => ({
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
    await p.click('[data-test=blog-share-copy]')
    const copied = await p.evaluate(() => window.__copied)
    ok(`${label}: Copy link copies one address`, copied.length === 1 && copied[0].includes(`/blog/${posts[0].id}`), copied)
    const marked = await p.waitForFunction(
      () => {
        const btn = document.querySelector('[data-test=blog-share-copy]')
        const d = btn?.querySelector('path')?.getAttribute('d') || ''
        return Boolean(btn?.classList.contains('is-copied') && d.startsWith('M20 6'))
      },
      { timeout: 3000 },
    ).then(() => true, () => false)
    ok(`${label}: Copy link shows a check`, marked)
    const pageUrl = copied[0] || ''
    const encUrl = encodeURIComponent(pageUrl)
    const encTitle = encodeURIComponent(title)
    for (const a of links) {
      if (a.id === 'blog-share-substack') {
        ok(`${label}: Substack opens Notes and is not a share URL`, a.href === SUBSTACK_NOTES && !a.href.includes(encUrl), a.href)
      } else {
        ok(`${label}: ${a.id} is built from the post URL and the title`, a.href.includes(encUrl) && a.href.includes(encTitle), a.href)
      }
    }
    await p.evaluate(() => {
      document.querySelector('[data-test=blog-share-substack]')?.addEventListener('click', (e) => e.preventDefault(), true)
    })
    await p.click('[data-test=blog-share-substack]')
    const after = await p.evaluate(() => window.__copied)
    ok(`${label}: Substack copies the same link`, after.length === 2 && after[1] === pageUrl, after)

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
