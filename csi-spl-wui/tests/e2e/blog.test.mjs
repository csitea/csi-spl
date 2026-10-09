// Spec 111 T003 (9-d, 9-f): the public blog. In a fresh browser context (no
// cookie, no storage), as an anonymous visitor would arrive:
//   - /blog renders the list with no move to /login and no session probe
//     (no request to /api/v1/auth/);
//   - list -> post -> back, in dark and in light, at desktop and phone width,
//     with no sideways scroll;
//   - /fi/blog/<id> without a fi copy shows the en text, lang="en";
//   - the sign-in page's footer links the blog.
//   - spec 116 T7: the public pages' SEO (publicSeo below).
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

  await publicSeo()
} finally {
  await browser.close()
  await server.stop()
}

/* spec 116 T7: the public pages' SEO, as the build made it. robots.txt says
   which build this is: a Sitemap line = indexable (prd, NUXT_PUBLIC_SEO_INDEX=1),
   else (dev, the mock bundle) no document may be indexed. The raw document
   (what a crawler fetches) and the hydrated one (what it renders) are both
   read; /, /lobby (product screens) stay noindex on either. Run against a
   prd-like build (NUXT_PUBLIC_SEO_INDEX=1 NUXT_PUBLIC_SITE_URL=https://<apex>)
   with SEO_EXPECT=index. */
async function publicSeo() {
  console.log('-- public SEO (spec 116 T7)')
  const get = (u) => fetch(server.base + u).then(async (r) => ({ status: r.status, text: r.ok ? await r.text() : '' }), () => ({ status: 0, text: '' }))
  const head = (html) => ({
    robots: /<meta name="robots" content="([^"]*)"/.exec(html)?.[1] || '',
    canonical: /<link rel="canonical" href="([^"]*)"/.exec(html)?.[1] || '',
    og: /<meta property="og:title" content="[^"]+"/.test(html),
    twitter: /<meta name="twitter:card" content="summary_large_image"/.test(html),
    description: /<meta name="description" content="[^"]+"/.test(html),
  })
  const robotsTxt = (await get('/robots.txt')).text
  ok('robots.txt is served', /^User-agent: \*$/m.test(robotsTxt), robotsTxt.slice(0, 60))
  ok('robots.txt disallows the app', /^Disallow: \/$/m.test(robotsTxt) && !/^Allow: \/(?:lobby|channel|dm|t|settings|search)\b/m.test(robotsTxt))
  const apex = /^Sitemap: (https:\/\/[^/\s]+)\/sitemap\.xml$/m.exec(robotsTxt)?.[1] || ''
  const posts = (await get('/blog-md/index.json').then((r) => JSON.parse(r.text || '{}'), () => ({}))).locales?.en || []
  const pub = ['/login', '/fi/login', '/blog', '/help', ...posts.slice(0, 1).map((e) => `/blog/${e.id}`)]
  for (const u of ['/', '/lobby']) {
    const h = head((await get(u)).text)
    ok(`${u} stays noindex`, h.robots === 'noindex, nofollow', h)
  }
  /* SEO_EXPECT=index: this bundle is a prd-like build, so no Sitemap line is a failure */
  if (process.env.SEO_EXPECT === 'index') ok('an indexable build (SEO_EXPECT=index) names its sitemap in robots.txt', Boolean(apex))
  if (!apex) {
    console.log('  (not an indexable build: every public page must be noindex too)')
    for (const u of pub) {
      const h = head((await get(u)).text)
      ok(`${u} is noindex on this build`, h.robots === 'noindex, nofollow', h)
    }
    ok('no sitemap on this build', !(await get('/sitemap.xml')).text.includes('<urlset'))
    return
  }
  for (const u of pub) {
    const h = head((await get(u)).text)
    ok(`${u}: index, follow, apex canonical, og, twitter, description`, h.robots === 'index, follow' && h.canonical.startsWith(apex + '/') && h.og && h.twitter && h.description, h)
  }
  for (const u of ['/login', '/fi/login', '/help']) ok(`${u} canonical is itself on the apex`, head((await get(u)).text).canonical === apex + u)
  ok('/login holds Organization + WebSite JSON-LD', /"@type":"Organization".*"@type":"WebSite"/.test((await get('/login')).text))
  if (posts.length) ok('a post holds BlogPosting JSON-LD', /"@type":"BlogPosting"/.test((await get(`/blog/${posts[0].id}`)).text))
  const sitemap = (await get('/sitemap.xml')).text
  const locs = [...sitemap.matchAll(/<loc>([^<]+)<\/loc>/g)].map((m) => m[1])
  const want = [...pub.map((u) => apex + u), ...posts.map((e) => `${apex}/blog/${e.id}`)]
  ok('sitemap.xml lists every public route and post', want.every((u) => locs.includes(u)), want.filter((u) => !locs.includes(u)))
  ok('sitemap.xml lists no app URL and only the apex', locs.every((u) => u.startsWith(apex + '/') && /\/(?:[a-z]{2}\/)?(?:login|help|blog)(?:\/|$)/.test(u.slice(apex.length))), locs.length)
  ok('every sitemap URL has a lastmod', (sitemap.match(/<lastmod>\d{4}-\d{2}-\d{2}<\/lastmod>/g) || []).length === locs.length)
  /* the query variants are the same file: the hydrated head keeps the bare
     apex canonical (an invite email in login_hint never reaches the index) */
  const { ctx, p } = await anonymousPage(browser, { width: 1280, height: 800 })
  await p.goto(server.base + '/login?redirect=%2Flobby&ended=1&login_hint=someone%40example.com', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  const live = await p.evaluate(() => ({
    robots: document.querySelector('meta[name=robots]')?.getAttribute('content') || '',
    canonical: [...document.querySelectorAll('link[rel=canonical]')].map((l) => l.getAttribute('href')),
  }))
  ok('/login?login_hint=… keeps index and the bare apex canonical after hydration', live.robots === 'index, follow' && live.canonical.length === 1 && live.canonical[0] === apex + '/login', live)
  /* /help renders client-only: the build wrote its head, the page then sets
     the same keyed tags - still one canonical, one robots */
  await p.goto(server.base + '/help/getting-started', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('[data-test=help-content]', { visible: true, timeout: 15000 }).catch(() => null)
  const help = await p.evaluate(() => ({
    robots: [...document.querySelectorAll('meta[name=robots]')].map((m) => m.getAttribute('content')),
    canonical: [...document.querySelectorAll('link[rel=canonical]')].map((l) => l.getAttribute('href')),
    og: document.querySelectorAll('meta[property="og:title"]').length,
  }))
  ok('/help/<page> after hydration: one robots (index), one apex canonical, one og:title', help.robots.join() === 'index, follow' && help.canonical.join() === apex + '/help/getting-started' && help.og === 1, help)
  await ctx.close()
}

const failed = results.filter((r) => !r.ok).length
console.log(failed ? `blog: ${failed} FAILED` : `blog: all ${results.length} passed`)
process.exit(failed ? 1 : 0)
