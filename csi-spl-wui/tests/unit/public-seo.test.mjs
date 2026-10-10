// Spec 116 T7: which pages search engines may index, and what the build
// writes for them (src/utils/public-seo.mjs). The documents themselves are
// checked by the generate (nuxt.config publicSeoModule) and by
// tests/e2e/blog.test.mjs (publicSeo).
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  buildRobotsTxt, buildSitemapXml, injectPublicHead, isPublicSeoPath, jsonLd, localeAlternates, localeLinks, publicPageHead, robotsContent, seoBasePath, sitemapEntries,
} from '../../src/utils/public-seo.mjs'

const codes = ['bg', 'en', 'fi', 'dm']
const site = 'https://apex.example.com'

describe('public SEO: which paths', () => {
  it('the public pages, in any locale, are public', () => {
    for (const p of ['/login', '/fi/login', '/login?login_hint=a%40b.example', '/help', '/help/agents', '/fi/help', '/blog', '/blog/page/2', '/fi/blog/2026-10-09-x', '/blog/']) {
      assert.equal(isPublicSeoPath(p, codes), true, p)
    }
  })
  it('every product screen, / first, is not', () => {
    for (const p of ['/', '/fi', '/lobby', '/channel/general', '/dm/x', '/t/abc', '/settings', '/search', '/releases/v1.2.3', '/help/a/b', '/loginx', '/blogx']) {
      assert.equal(isPublicSeoPath(p, codes), false, p)
    }
  })
  it('/public-calendar, in any locale, is public; nothing under it or beside it is', () => {
    for (const p of ['/public-calendar', '/fi/public-calendar', '/public-calendar/', '/public-calendar?m=2026-10']) {
      assert.equal(isPublicSeoPath(p, codes), true, p)
    }
    for (const p of ['/public-calendar/x', '/public-calendarx', '/calendar', '/fi/calendar']) {
      assert.equal(isPublicSeoPath(p, codes), false, p)
    }
    assert.equal(robotsContent('/fi/public-calendar', codes, true), 'index, follow')
    assert.equal(robotsContent('/public-calendar', codes, false), 'noindex, nofollow')
  })
  it('/docs is not public by path: which docs are is a build-time list', () => {
    for (const p of ['/docs', '/fi/docs', '/docs/README.md', '/docs/csi-spl-doc/doc/md/x.md']) {
      assert.equal(isPublicSeoPath(p, codes), false, p)
    }
  })
  it('a route named like a locale is not a prefix unless it is one', () => {
    assert.equal(seoBasePath('/dm/login', ['bg', 'en']), '/dm/login')
    assert.equal(seoBasePath('/fi/login/', codes), '/login')
  })
  it('index only for a public page on an indexable build', () => {
    assert.equal(robotsContent('/login', codes, true), 'index, follow')
    assert.equal(robotsContent('/login', codes, false), 'noindex, nofollow')
    assert.equal(robotsContent('/lobby', codes, true), 'noindex, nofollow')
    assert.equal(robotsContent('/', codes, true), 'noindex, nofollow')
  })
})

describe('public SEO: head', () => {
  it('/login: apex canonical without the query, hreflang per locale + x-default, og, twitter, JSON-LD', () => {
    const h = publicPageHead({ path: '/fi/login?login_hint=a%40b.example', locale: 'fi', codes, defaultLocale: 'en', siteUrl: site + '/' })
    assert.ok(h)
    assert.deepEqual(h.link[0], { rel: 'canonical', href: `${site}/fi/login` })
    assert.equal(h.link.filter((l) => l.rel === 'alternate').length, codes.length + 1)
    assert.ok(h.link.some((l) => l.hreflang === 'x-default' && l.href === `${site}/login`))
    assert.ok(!JSON.stringify(h).includes('login_hint'))
    const meta = Object.fromEntries(h.meta.map((m) => [m.property || m.name, m.content]))
    assert.equal(meta['og:url'], `${site}/fi/login`)
    assert.equal(meta['twitter:card'], 'summary_large_image')
    assert.ok(meta['og:image'].startsWith(site + '/'))
    assert.match(h.script[0].innerHTML, /"@type":"Organization".*"@type":"WebSite"/)
  })
  it('/public-calendar: apex canonical per locale, hreflang per locale + x-default, og, twitter, no JSON-LD', () => {
    const h = publicPageHead({ path: '/fi/public-calendar?m=2026-10', locale: 'fi', codes, defaultLocale: 'en', siteUrl: site + '/' })
    assert.ok(h)
    assert.deepEqual(h.link[0], { rel: 'canonical', href: `${site}/fi/public-calendar` })
    assert.equal(h.link.filter((l) => l.rel === 'alternate').length, codes.length + 1)
    assert.ok(h.link.some((l) => l.hreflang === 'x-default' && l.href === `${site}/public-calendar`))
    assert.ok(h.link.some((l) => l.hreflang === 'bg' && l.href === `${site}/bg/public-calendar`))
    const meta = Object.fromEntries(h.meta.map((m) => [m.property || m.name, m.content]))
    assert.equal(meta['og:url'], `${site}/fi/public-calendar`)
    assert.equal(meta['og:title'], `${h.title} · spool-hub`)
    assert.equal(meta['twitter:card'], 'summary_large_image')
    assert.ok(meta.description)
    assert.ok(meta['og:image'].startsWith(`${site}/`))
    assert.deepEqual(h.script, [])
  })
  it('/<lang>/help canonicalises to the default copy, no alternates (one language)', () => {
    const h = publicPageHead({ path: '/fi/help/agents', locale: 'fi', codes, defaultLocale: 'en', siteUrl: site })
    assert.ok(h)
    assert.deepEqual(h.link, [{ rel: 'canonical', href: `${site}/help/agents` }])
    assert.deepEqual(h.script, [])
  })
  it('no head of its own for the blog or a product screen', () => {
    for (const p of ['/blog', '/lobby', '/']) assert.equal(publicPageHead({ path: p, locale: 'en', codes, defaultLocale: 'en', siteUrl: site }), null, p)
  })
  it('hreflang only for the locales given', () => {
    const l = localeLinks({ siteUrl: site, base: '/blog/x', canonicalCode: 'en', langs: ['en', 'fi'], defaultLocale: 'en' })
    assert.deepEqual(l.map((x) => x.hreflang || x.rel), ['canonical', 'en', 'fi', 'x-default'])
  })
  it('the language menu and the hreflang alternates are one list', () => {
    const o = { siteUrl: site, base: '/blog/x', canonicalCode: 'en', langs: ['en', 'fi', 'sv'], defaultLocale: 'en' }
    const alt = localeLinks(o).filter((x) => x.hreflang && x.hreflang !== 'x-default').map((x) => [x.hreflang, x.href])
    assert.deepEqual(localeAlternates(o).map((a) => [a.code, a.href]), alt)
    assert.deepEqual(localeAlternates({ ...o, siteUrl: '' }).map((a) => a.href), ['/blog/x', '/fi/blog/x', '/sv/blog/x'])
    /* control: one locale = no hreflang at all, yet the menu still has en */
    const one = { ...o, langs: ['en'] }
    assert.equal(localeLinks(one).length, 1)
    assert.deepEqual(localeAlternates({ ...one, siteUrl: '' }), [{ code: 'en', href: '/blog/x' }])
  })
  it('JSON-LD cannot close its script element', () => {
    assert.ok(!jsonLd({ t: '</script><script>x' }).includes('</'))
  })
})

describe('public SEO: robots.txt and sitemap.xml', () => {
  it('an indexable build allows the public pages, disallows the rest, names the sitemap', () => {
    const r = buildRobotsTxt({ siteUrl: site, codes: ['bg', 'en', 'fi'], defaultLocale: 'en', indexOn: true })
    for (const l of ['Disallow: /', 'Allow: /login', 'Allow: /fi/login', 'Allow: /public-calendar', 'Allow: /fi/public-calendar', 'Allow: /blog', 'Allow: /help', 'Allow: /_nuxt/', `Sitemap: ${site}/sitemap.xml`]) {
      assert.ok(r.split('\n').includes(l), l)
    }
    assert.ok(!/Allow: \/(lobby|channel|dm\/|t\/|settings|docs|calendar)/.test(r))
  })
  it('any other build disallows everything and names no sitemap', () => {
    assert.equal(buildRobotsTxt({ siteUrl: site, codes, defaultLocale: 'en', indexOn: false }), 'User-agent: *\nDisallow: /\n')
    assert.equal(buildRobotsTxt({ siteUrl: '', codes, defaultLocale: 'en', indexOn: true }), 'User-agent: *\nDisallow: /\n')
  })
  it('the sitemap: login per locale, help once, blog lists per locale, each post in the locales that have it, lastmod', () => {
    const blog = { locales: { en: [{ id: '2026-10-09-a', published: '2026-10-09T14:18:00Z' }, { id: '2026-10-08-b', date: '2026-10-08' }], fi: [{ id: '2026-10-09-a' }] } }
    const entries = sitemapEntries({ codes: ['en', 'fi'], defaultLocale: 'en', today: '2026-10-10', help: ['agents'], pageSize: 1, blog })
    const xml = buildSitemapXml({ siteUrl: site, defaultLocale: 'en', entries })
    const locs = [...xml.matchAll(/<loc>([^<]+)<\/loc>/g)].map((m) => m[1].slice(site.length))
    assert.deepEqual(locs, ['/login', '/fi/login', '/help', '/help/agents', '/blog', '/fi/blog', '/blog/page/2', '/fi/blog/page/2', '/blog/2026-10-09-a', '/fi/blog/2026-10-09-a', '/blog/2026-10-08-b'])
    assert.equal((xml.match(/<lastmod>/g) || []).length, locs.length)
    assert.match(xml, /<loc>https:\/\/apex\.example\.com\/blog\/2026-10-09-a<\/loc>\n {4}<lastmod>2026-10-09<\/lastmod>/)
    assert.match(xml, /<loc>https:\/\/apex\.example\.com\/blog<\/loc>\n {4}<lastmod>2026-10-09<\/lastmod>/)
    // a one-language page carries no hreflang group; a post in two does
    assert.ok(!/<loc>[^<]*\/blog\/2026-10-08-b<\/loc>\n {4}<lastmod>[^<]*<\/lastmod>\n {4}<xhtml/.test(xml))
    assert.match(xml, /hreflang="fi" href="https:\/\/apex\.example\.com\/fi\/blog\/2026-10-09-a"/)
  })
})

describe('public SEO: a client-only page head written at build time', () => {
  const doc = '<html><head><title>spool-hub</title><meta name="robots" content="noindex, nofollow"><meta name="description" content="generic"></head><body></body></html>'
  const head = publicPageHead({ path: '/help/agents', locale: 'en', codes, defaultLocale: 'en', siteUrl: site })
  it('replaces title, robots and description, adds canonical + og once', () => {
    const out = injectPublicHead(doc, head, 'index, follow')
    assert.match(out, /<title>Help · spool-hub<\/title>/)
    assert.match(out, /<meta name="robots" content="index, follow">/)
    assert.equal((out.match(/name="description"/g) || []).length, 1)
    assert.ok(!out.includes('content="generic"'))
    assert.match(out, /<link rel="canonical" href="https:\/\/apex\.example\.com\/help\/agents">/)
    assert.match(out, /<meta property="og:title" content="Help · spool-hub">/)
    assert.equal(injectPublicHead(out, head, 'index, follow'), out)
  })
})

/* c-652's follow-up (dispatch-598f2807): /public-calendar was public on paper
   only - not prerendered, no head of its own, not in the sitemap - so its
   document was 200.html's noindex on prd too. */
describe('public SEO: /public-calendar is a prerendered, indexable page', () => {
  const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
  const src = (f) => readFileSync(join(WUI, f), 'utf8')
  it('is prerendered in every locale (nuxt.config PRERENDER_PAGES) and the sitemap takes it from there', () => {
    const pages = /const PRERENDER_PAGES = (\[[^\]]*\])/.exec(src('nuxt.config.ts'))?.[1] || '[]'
    assert.deepEqual(JSON.parse(pages).filter((p) => isPublicSeoPath(p, codes)), ['/login', '/public-calendar'])
    assert.match(src('nuxt.config.ts'), /pages: PRERENDER_PAGES\.filter\(\(p\) => isPublicSeoPath\(p, LOCALE_CODES\)\)/)
  })
  it('sets its own head (usePublicSeo), in its page chunk', () => {
    assert.match(src('src/pages/public-calendar.vue'), /^usePublicSeo\(\)$/m)
  })
  it('the sitemap lists it in every locale with its hreflang group + x-default', () => {
    const entries = sitemapEntries({ codes: ['en', 'fi'], defaultLocale: 'en', today: '2026-10-10', help: [], pageSize: 10, pages: ['/login', '/public-calendar'], blog: null })
    const xml = buildSitemapXml({ siteUrl: site, defaultLocale: 'en', entries })
    const locs = [...xml.matchAll(/<loc>([^<]+)<\/loc>/g)].map((m) => m[1].slice(site.length))
    assert.deepEqual(locs, ['/login', '/fi/login', '/public-calendar', '/fi/public-calendar', '/help', '/blog', '/fi/blog'])
    assert.match(xml, /<loc>https:\/\/apex\.example\.com\/fi\/public-calendar<\/loc>\n {4}<lastmod>2026-10-10<\/lastmod>\n {4}<xhtml:link rel="alternate" hreflang="en" href="https:\/\/apex\.example\.com\/public-calendar"\/>/)
    assert.match(xml, /hreflang="x-default" href="https:\/\/apex\.example\.com\/public-calendar"/)
  })
})
