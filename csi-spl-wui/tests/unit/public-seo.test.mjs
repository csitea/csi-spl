// Spec 116 T7: which pages search engines may index, and what the build
// writes for them (src/utils/public-seo.mjs). The documents themselves are
// checked by the generate (nuxt.config publicSeoModule) and by
// tests/e2e/blog.test.mjs (publicSeo).
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import {
  buildRobotsTxt, buildSitemapXml, injectPublicHead, isPublicSeoPath, jsonLd, localeLinks, publicPageHead, robotsContent, seoBasePath, sitemapEntries,
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
  it('JSON-LD cannot close its script element', () => {
    assert.ok(!jsonLd({ t: '</script><script>x' }).includes('</'))
  })
})

describe('public SEO: robots.txt and sitemap.xml', () => {
  it('an indexable build allows the public pages, disallows the rest, names the sitemap', () => {
    const r = buildRobotsTxt({ siteUrl: site, codes: ['bg', 'en', 'fi'], defaultLocale: 'en', indexOn: true })
    for (const l of ['Disallow: /', 'Allow: /login', 'Allow: /fi/login', 'Allow: /blog', 'Allow: /help', 'Allow: /_nuxt/', `Sitemap: ${site}/sitemap.xml`]) {
      assert.ok(r.split('\n').includes(l), l)
    }
    assert.ok(!/Allow: \/(lobby|channel|dm\/|t\/|settings)/.test(r))
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
