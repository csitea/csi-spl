// Spec 111 T003 (9-d, 9-f): the public blog. In a fresh browser context (no
// cookie, no storage), as an anonymous visitor would arrive:
//   - /blog renders the list with no move to /login and no session probe
//     (no request to /api/v1/auth/);
//   - list -> post -> back, in dark and in light, at desktop and phone width,
//     with no sideways scroll;
//   - /fi/blog/<id> without a fi copy shows the en text, lang="en";
//   - the sign-in page's footer links the blog.
// The posts are the build's own (public/blog-md/index.json): with none, the
// empty list is checked and the post steps say they did not run.
//
// Run:
//   pnpm run test:e2e blog
//   BASE_URL=<generated bundle> pnpm run test:e2e blog
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
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

const path = (p) => new URL(p.url()).pathname

/** A page in a fresh context (no cookie, no storage), its hub auth requests counted. */
async function anonymousPage(browser, { width, height, theme }) {
  const ctx = await browser.createBrowserContext()
  const p = await ctx.newPage()
  await p.setViewport({ width, height })
  const auth = []
  p.on('request', (r) => { if (r.url().includes('/api/v1/auth/')) auth.push(r.url()) })
  if (theme === 'light') await p.evaluateOnNewDocument(() => { try { localStorage.setItem('spool-theme', 'light') } catch { /* none */ } })
  return { ctx, p, auth }
}

const server = await startServer()
const browser = await launch()
try {
  const index = await fetch(server.base + '/blog-md/index.json').then((r) => (r.ok ? r.json() : null), () => null)
  const posts = index?.locales?.en || []
  ok('the bundle carries the blog copy (blog-md/index.json)', Boolean(index && index.locales), posts.length)
  const bgs = {}

  for (const [label, size, theme] of [['desktop dark', { width: 1280, height: 800 }, 'dark'], ['phone light', { width: 390, height: 844 }, 'light']]) {
    console.log(`-- ${label}`)
    const { ctx, p, auth } = await anonymousPage(browser, { ...size, theme })
    const res = await p.goto(server.base + '/blog', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    ok('/blog answers 200', Boolean(res && res.status() === 200), res && res.status())
    const list = await p.waitForSelector('[data-test=blog-list-page]', { visible: true, timeout: 15000 }).catch(() => null)
    ok('/blog shows the list to an anonymous visitor', Boolean(list))
    ok('no move to /login', path(p) === '/blog', p.url())
    bgs[theme] = await p.$eval('[data-test=blog-page]', (el) => getComputedStyle(el).backgroundColor).catch(() => '')
    const items = await p.$$eval('[data-test=blog-item]', (els) => els.length)
    ok('the list holds the copy\'s posts', items === Math.min(posts.length, 20), { items, posts: posts.length })
    if (!posts.length) {
      ok('an empty blog says so', Boolean(await p.$('[data-test=blog-empty]')))
      console.log('  (no posts in this build: the post steps did not run)')
    } else {
      await Promise.all([p.waitForSelector('[data-test=blog-post-title]', { visible: true, timeout: 15000 }).catch(() => null), p.click('[data-test=blog-item-link]')])
      ok('a click opens the newest post', path(p) === `/blog/${posts[0].id}`, p.url())
      const title = await p.$eval('[data-test=blog-post-title]', (el) => el.textContent.trim()).catch(() => '')
      ok('the post shows its title', title === posts[0].title, title)
      const words = await p.$eval('[data-test=blog-post-body]', (el) => el.textContent.trim().split(/\s+/).length).catch(() => 0)
      ok('the post shows its body', words > 5, words)
      const wide = await p.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth)
      ok('no sideways scroll on the post', wide <= 0, wide)
      await p.click('[data-test=blog-post-back]')
      await p.waitForSelector('[data-test=blog-list-page]', { visible: true, timeout: 15000 }).catch(() => null)
      ok('back returns to the list', path(p) === '/blog', p.url())
      const direct = await p.goto(server.base + `/blog/${posts[0].id}`, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
      ok('the post opens directly (prerendered)', Boolean(direct && direct.status() === 200 && await p.$('[data-test=blog-post-title]')), direct && direct.status())
    }
    ok('no session probe: no /api/v1/auth/ request', auth.length === 0, auth)
    await ctx.close()
  }
  ok('dark and light differ', Boolean(bgs.dark && bgs.light && bgs.dark !== bgs.light), bgs)

  if (posts.length && !(index.locales.fi || []).some((e) => e.id === posts[0].id)) {
    console.log('-- /fi fallback')
    const { ctx, p } = await anonymousPage(browser, { width: 1280, height: 800 })
    await p.goto(server.base + `/fi/blog/${posts[0].id}`, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    const art = await p.$eval('[data-test=blog-post]', (el) => ({ lang: el.getAttribute('lang'), pending: Boolean(el.querySelector('[data-test=blog-post-pending]')) })).catch(() => null)
    ok('a locale without its copy shows the en text with lang="en"', Boolean(art && art.lang === 'en' && art.pending), art)
    await ctx.close()
  }

  console.log('-- /login footer')
  const { ctx, p } = await anonymousPage(browser, { width: 1280, height: 800 })
  await p.goto(server.base + '/login', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  const link = await p.waitForSelector('[data-test=login-foot-blog]', { visible: true, timeout: 15000 }).catch(() => null)
  ok('the sign-in page links the blog', Boolean(link))
  if (link) {
    await link.click()
    await p.waitForSelector('[data-test=blog-list-page]', { visible: true, timeout: 15000 }).catch(() => null)
    ok('the link opens /blog', path(p) === '/blog', p.url())
  }
  await ctx.close()
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok).length
console.log(failed ? `blog: ${failed} FAILED` : `blog: all ${results.length} passed`)
process.exit(failed ? 1 : 0)
