// Spec 111 T003 (9-d, 9-f): the public blog. In a fresh browser context (no
// cookie, no storage), as an anonymous visitor would arrive:
//   - /blog renders the list with no move to /login and no session probe
//     (no request to /api/v1/auth/);
//   - list -> post -> back, in dark and in light, at desktop and phone width,
//     with no sideways scroll;
//   - /fi/blog/<id> without a fi copy shows the en text, lang="en";
//   - the sign-in page's footer links the blog.
//   - spec 116 T7: the public pages' SEO (publicSeo below).
//   - HUM-10 t1 35aea5bb: the language menu (langMenu below), with JS off
//     and on, its links the page's hreflang set.
//   - HUM-10 t1 4d6bc718 (SPL-3871): with JS the menu is the app's own
//     flagged LanguageSwitcher (blogSwitcher below).
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
    /* t1 ff3953c1: the bar's name stays on one line beside the language menu */
    const name = await p.$eval('.blog-bar__name', (el) => ({ rects: el.getClientRects().length, h: el.getBoundingClientRect().height, lh: parseFloat(getComputedStyle(el).lineHeight) || 1.5 * parseFloat(getComputedStyle(el).fontSize) })).catch(() => null)
    ok('the bar keeps "SPOOL-HUB" on one line', Boolean(name && name.rects === 1 && name.h <= name.lh * 1.2), name)
    ok('no move to /login', path(p) === '/blog', p.url())
    ok('the blog-bar-home link goes to /login', await p.$eval('[data-test=blog-bar-home]', (el) => el.getAttribute('href')) === '/login', await p.$eval('[data-test=blog-bar-home]', (el) => el.getAttribute('href')))
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
  await langMenu()
  await blogSwitcher()
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
  const pub = ['/login', '/fi/login', '/public-calendar', '/fi/public-calendar', '/blog', '/help', ...posts.slice(0, 1).map((e) => `/blog/${e.id}`)]
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
  for (const u of ['/login', '/fi/login', '/public-calendar', '/fi/public-calendar', '/help']) ok(`${u} canonical is itself on the apex`, head((await get(u)).text).canonical === apex + u)
  ok('/login holds Organization + WebSite JSON-LD', /"@type":"Organization".*"@type":"WebSite"/.test((await get('/login')).text))
  if (posts.length) ok('a post holds BlogPosting JSON-LD', /"@type":"BlogPosting"/.test((await get(`/blog/${posts[0].id}`)).text))
  const sitemap = (await get('/sitemap.xml')).text
  const locs = [...sitemap.matchAll(/<loc>([^<]+)<\/loc>/g)].map((m) => m[1])
  const want = [...pub.map((u) => apex + u), ...posts.map((e) => `${apex}/blog/${e.id}`)]
  ok('sitemap.xml lists every public route and post', want.every((u) => locs.includes(u)), want.filter((u) => !locs.includes(u)))
  ok('sitemap.xml lists no app URL and only the apex', locs.every((u) => u.startsWith(apex + '/') && /\/(?:[a-z]{2}\/)?(?:login|public-calendar|help|blog)(?:\/|$)/.test(u.slice(apex.length))), locs.length)
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

/* HUM-10 t1 35aea5bb: the blog's language menu, signed out. The raw
   document (JS off, what a crawler reads) holds one <a href> per locale the
   page has - all of them on the list, the hreflang set on a post - and the
   current one is aria-current. A click works with JS off (a plain link) and
   with JS on also leaves the locale cookie. */
async function langMenu() {
  console.log('-- language menu (HUM-10 t1 35aea5bb)')
  const raw = (u) => fetch(server.base + u).then((r) => (r.ok ? r.text() : ''), () => '')
  const attr = (a, n) => new RegExp(`\\b${n}="([^"]*)"`).exec(a)?.[1]
  const items = (html) => [...html.matchAll(/<a\b([^>]*\bdata-test="blog-lang-item"[^>]*)>/g)].map((m) => ({ href: attr(m[1], 'href'), code: attr(m[1], 'hreflang'), current: attr(m[1], 'aria-current') === 'page' }))
  const alternates = (html) => [...html.matchAll(/<link rel="alternate" hreflang="([^"]+)"/g)].map((m) => m[1]).filter((c) => c !== 'x-default')
  const index = await raw('/blog-md/index.json').then((t) => JSON.parse(t || '{}'), () => ({}))
  const locs = Object.keys(index.locales || {})
  const posts = index.locales?.en || []
  const blogOnly = Array.isArray(index.blog_only) ? index.blog_only : []
  const codes = items(await raw('/blog')).map((i) => i.code)
  const nCodes = 19 + blogOnly.length
  ok(`JS off: /blog lists the 19 UI locales and the blog-only ones (${blogOnly.join() || 'none'}) as links`, codes.length === nCodes && new Set(codes).size === nCodes && blogOnly.every((c) => codes.includes(c)), codes)
  await blogOnlyLocales(raw, items, index, blogOnly)
  const fi = items(await raw('/fi/blog'))
  ok('JS off: /fi/blog links fi to /fi/blog and en to /blog, fi current', fi.find((i) => i.code === 'fi')?.href === '/fi/blog' && fi.find((i) => i.code === 'en')?.href === '/blog' && fi.filter((i) => i.current).map((i) => i.code).join() === 'fi', fi.filter((i) => i.code === 'fi' || i.code === 'en'))
  /* control: the parser sees no menu in a page that has none */
  ok('control: /login has no blog language menu', items(await raw('/login')).length === 0)
  const fiDoc = await raw('/fi/blog')
  ok('the /fi/blog document is public-clean (no auth path, no config.json)', fiDoc.length > 0 && !/\/api\/v1\/auth\//.test(fiDoc) && !/config\.json/.test(fiDoc))
  ok('the /fi/blog document says lang="fi…"', /<html[^>]* lang="fi(?:-[A-Z]{2})?"/.test(fiDoc), /<html[^>]*>/.exec(fiDoc)?.[0])
  if (!posts.length) { console.log('  (no posts in this build: the post steps did not run)'); return }
  const has = (id) => ['en', ...locs.filter((l) => l !== 'en' && (index.locales[l] || []).some((e) => e.id === id))]
  const many = posts.find((e) => has(e.id).length > 1)
  const one = posts.find((e) => has(e.id).length === 1)
  for (const e of [many, one].filter(Boolean)) {
    const html = await raw(`/blog/${e.id}`)
    const menu = items(html)
    const want = has(e.id)
    const alt = alternates(html)
    ok(`${e.id}: the menu lists exactly the locales with this post (${want.length})`, menu.map((i) => i.code).sort().join() === [...want].sort().join(), menu.map((i) => i.code))
    ok(`${e.id}: the menu equals the hreflang set`, want.length === 1 ? alt.length === 0 && menu.length === 1 && menu[0].code === 'en' : menu.map((i) => i.code).join() === alt.join(), { alt })
    ok(`${e.id}: each link is /<lang>/blog/<id> (en unprefixed)`, menu.every((i) => i.href === (i.code === 'en' ? `/blog/${e.id}` : `/${i.code}/blog/${e.id}`)))
  }
  if (!one) console.log('  (every post has a translation: the one-locale case did not run)')
  if (!many) console.log('  (no post has a translation: the many-locale case did not run)')
  const target = many || posts[0]
  /* a UI locale: a blog-only one (de) writes no locale cookie */
  const to = has(target.id).find((c) => c !== 'en' && !blogOnly.includes(c)) || 'en'
  for (const js of [false, true]) {
    const { ctx, p } = await anonymousPage(browser, { width: 390, height: 844 })
    await p.setJavaScriptEnabled(js)
    await p.goto(server.base + `/blog/${target.id}`, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    /* JS off: the <details> links; JS on: the app's switcher over the same hrefs (SPL-3871) */
    const [button, item] = js ? ['.blog-bar [data-test=lang-switcher-button]', '.blog-bar [data-test^=lang-item-]'] : ['[data-test=blog-lang-button]', '[data-test=blog-lang-item]']
    if (js) await p.waitForSelector(button, { visible: true, timeout: 15000 }).catch(() => null)
    await p.click(button).catch(() => null)
    const link = await p.waitForSelector(js ? `.blog-bar [data-test=lang-item-${to}]` : `${item}[data-code=${to}]`, { visible: true, timeout: 5000 }).catch(() => null)
    ok(`JS ${js ? 'on' : 'off'}: the menu opens on a tap`, Boolean(link))
    const listed = await p.$$eval(item, (els) => els.filter((el) => el.getBoundingClientRect().height > 0).length)
    ok(`JS ${js ? 'on' : 'off'}: the open menu lists its links at 390 px`, listed === has(target.id).length, listed)
    if (link) await Promise.all([p.waitForNavigation({ waitUntil: 'networkidle2', timeout: NAV_TIMEOUT }).catch(() => null), link.click()])
    const want = to === 'en' ? `/blog/${target.id}` : `/${to}/blog/${target.id}`
    ok(`JS ${js ? 'on' : 'off'}: picking ${to} opens ${want}`, path(p) === want, p.url())
    if (js) {
      const cookie = (await p.cookies()).find((c) => c.name === 'i18n_redirected')
      ok('JS on: the pick leaves the locale cookie', cookie?.value === to, cookie)
    }
    await ctx.close()
  }
}

/* HUM-10 t1 4d6bc718 (SPL-3871): with JS the blog's language control is the
   app's LanguageSwitcher (flags, search, keyboard), at desktop and phone
   width, over the post's own languages: the blog-only de with its flag, a
   pick a full load of /<code>/blog/<id>. The <details> menu is gone once it
   mounts; the raw document keeps the links (langMenu above). */
async function blogSwitcher() {
  console.log('-- the app language switcher on the blog (SPL-3871)')
  const index = await fetch(server.base + '/blog-md/index.json').then((r) => r.json(), () => ({}))
  const id = '2026-10-26-kids-human-experience'
  const has = (code) => code === 'en' || (index.locales?.[code] || []).some((e) => e.id === id)
  if (!has('en') || !(index.locales?.en || []).some((e) => e.id === id)) { console.log(`  (no ${id} in this build: the switcher steps did not run)`); return }
  const want = Object.keys(index.locales || {}).filter(has)
  for (const [label, size, pick] of [['desktop', { width: 1280, height: 800 }, 'keys'], ['phone', { width: 390, height: 844 }, 'tap']]) {
    const { ctx, p } = await anonymousPage(browser, size)
    await p.goto(server.base + `/blog/${id}`, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    const input = await p.waitForSelector('.blog-bar [data-test=lang-switcher-input]', { visible: true, timeout: 15000 }).catch(() => null)
    ok(`${label}: the blog bar shows the app's language switcher`, Boolean(input))
    ok(`${label}: the plain <details> menu is gone`, !(await p.$('[data-test=blog-lang]')))
    const shown = await p.$eval('.blog-bar [data-test=lang-switcher-input]', (el) => el.value).catch(() => '')
    ok(`${label}: it shows the current language with its flag`, shown === '🇬🇧 English', shown)
    const name = await p.$eval('.blog-bar__name', (el) => ({ rects: el.getClientRects().length, h: el.getBoundingClientRect().height, lh: parseFloat(getComputedStyle(el).lineHeight) || 1.5 * parseFloat(getComputedStyle(el).fontSize) })).catch(() => null)
    ok(`${label}: the bar keeps "SPOOL-HUB" on one line beside it`, Boolean(name && name.rects === 1 && name.h <= name.lh * 1.2), name)
    const gap = await p.evaluate(() => {
      const n = document.querySelector('.blog-bar__name')?.getBoundingClientRect()
      const c = document.querySelector('.blog-bar .lang-switcher__control')?.getBoundingClientRect()
      return n && c ? { nameEnd: Math.round(n.right), switcherStart: Math.round(c.left) } : null
    })
    ok(`${label}: the switcher never covers "SPOOL-HUB"`, Boolean(gap && gap.nameEnd <= gap.switcherStart), gap)
    const wide = await p.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth)
    ok(`${label}: no sideways scroll`, wide <= 0, wide)
    /* the current name fits its field, not cut off */
    const fit = await p.$eval('.blog-bar [data-test=lang-switcher-input]', (el) => ({ scroll: el.scrollWidth, client: el.clientWidth })).catch(() => null)
    ok(`${label}: the current language fits its field`, Boolean(fit && fit.scroll <= fit.client), fit)
    await p.click('.blog-bar [data-test=lang-switcher-button]').catch(() => null)
    await p.waitForSelector('.blog-bar [data-test=lang-switcher-options]', { visible: true, timeout: 5000 }).catch(() => null)
    const opts = await p.$$eval('.blog-bar [data-test^=lang-item-]', (els) => els.map((el) => ({ code: el.dataset.test.slice(10), flag: el.querySelector('.lang-switcher__flag')?.textContent.trim(), href: el.dataset.href })))
    ok(`${label}: the list is the post's ${want.length} languages`, opts.map((o) => o.code).sort().join() === [...want].sort().join(), opts.map((o) => o.code))
    ok(`${label}: every language has its flag`, opts.length > 0 && opts.every((o) => o.flag && o.flag !== '🌐'), opts.filter((o) => !o.flag || o.flag === '🌐'))
    ok(`${label}: each choice opens /<code>/blog/${id} (en unprefixed)`, opts.every((o) => o.href === (o.code === 'en' ? `/blog/${id}` : `/${o.code}/blog/${id}`)))
    if (has('de')) ok(`${label}: the blog-only de is listed with its flag`, opts.find((o) => o.code === 'de')?.flag === '🇩🇪', opts.find((o) => o.code === 'de'))
    if (pick === 'keys') {
      /* search + keyboard, as in the app: type, Enter picks the one match */
      await p.focus('.blog-bar [data-test=lang-switcher-input]')
      await p.keyboard.type('bulg')
      const left = await p.$$eval('.blog-bar [data-test^=lang-item-]', (els) => els.map((el) => el.dataset.test.slice(10)))
      ok(`${label}: typing "bulg" leaves only bg`, left.join() === 'bg', left)
      await Promise.all([p.waitForNavigation({ waitUntil: 'networkidle2', timeout: NAV_TIMEOUT }).catch(() => null), p.keyboard.press('ArrowDown').then(() => p.keyboard.press('Enter'))])
    } else {
      const bg = await p.$('.blog-bar [data-test=lang-item-bg]')
      await Promise.all([p.waitForNavigation({ waitUntil: 'networkidle2', timeout: NAV_TIMEOUT }).catch(() => null), bg?.click()])
    }
    ok(`${label}: picking bg lands on /bg/blog/${id}`, path(p) === `/bg/blog/${id}`, p.url())
    await p.waitForSelector('.blog-bar [data-test=lang-switcher-input]', { visible: true, timeout: 15000 }).catch(() => null)
    const now = await p.$eval('.blog-bar [data-test=lang-switcher-input]', (el) => el.value).catch(() => '')
    ok(`${label}: there bg is the current language`, now === '🇧🇬 Български', now)
    const fitBg = await p.$eval('.blog-bar [data-test=lang-switcher-input]', (el) => ({ scroll: el.scrollWidth, client: el.clientWidth })).catch(() => null)
    ok(`${label}: "Български" fits its field too`, Boolean(fitBg && fitBg.scroll <= fitBg.client), fitBg)
    await ctx.close()
  }
}

/* owner poll 6bace52f B: German is a blog-only locale (cnf env.blog.extra_locales):
   /de/blog/** is prerendered with the posts in German and the chrome in en. */
async function blogOnlyLocales(raw, items, index, blogOnly) {
  for (const code of blogOnly) {
    const list = await raw(`/${code}/blog`)
    ok(`/${code}/blog is a prerendered blog list, public-clean`, /data-test="blog-list-page"/.test(list) && !/\/api\/v1\/auth\//.test(list) && !/config\.json/.test(list))
    ok(`/${code}/blog: ${code} is current in the menu, <main lang="${code}">`, items(list).filter((i) => i.current).map((i) => i.code).join() === code && new RegExp(`<main[^>]*lang="${code}"`).test(list), items(list).filter((i) => i.current))
    const own = (index.locales?.[code] || [])[0]
    if (!own) { console.log(`  (no live ${code} copy in this build: the ${code} post step did not run)`); continue }
    const doc = await raw(`/${code}/blog/${own.id}`)
    ok(`/${code}/blog/${own.id} shows the ${code} title, not the pending line`, doc.includes(`<title>${own.title.replace(/&/g, '&amp;')}`) && !/data-test="blog-post-pending"/.test(doc), /<title>[^<]*/.exec(doc)?.[0])
  }
  /* control: a blog-only prefix the build does not know is no blog page */
  ok('control: /xx/blog is not a prerendered blog page', !/data-test="blog-list-page"/.test(await raw('/xx/blog')))
}

const failed = results.filter((r) => !r.ok).length
console.log(failed ? `blog: ${failed} FAILED` : `blog: all ${results.length} passed`)
process.exit(failed ? 1 : 0)
