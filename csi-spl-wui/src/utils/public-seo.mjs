/**
 * Spec 116 T7 (HUM-10, t1 598f2807): the public, signed-out pages a search
 * engine may index, and the head they carry. Public = /login (the front page:
 * a signed-out visitor at / is sent there), /help and /help/<page>, and the
 * blog (/blog, /blog/page/<n>, /blog/<id>), each also under /<lang>/. Every
 * other screen, / included, stays `noindex, nofollow`.
 *
 * Indexing is on only where the build says so: cnf env.wui.seo_index (prd)
 * -> NUXT_PUBLIC_SEO_INDEX=1. Canonical, hreflang and og:url are ALWAYS on
 * the apex (NUXT_PUBLIC_SITE_URL), never the request host: the same files
 * are served on every tenant host and on the bare Hosting site.
 *
 * Shared by app.vue (/login, /help), pages/blog.vue and nuxt.config.ts
 * (publicSeoModule: the checks, robots.txt and sitemap.xml).
 */

export const SITE_NAME = 'spool-hub'
/** the og/twitter picture of a page with none of its own */
export const SITE_IMAGE = '/spool-hub-emblem-1120.webp'
const PUBLIC_RE = /^\/(?:login|help(?:\/[a-z0-9][a-z0-9-]*)?|blog(?:\/.*)?)$/

/**
 * Pathname with the locale prefix, query, hash and trailing slash taken off.
 * @param {string} path
 * @param {string[]} codes the shipped locale codes
 */
export function seoBasePath(path, codes) {
  let p = String(path || '/').split('#')[0].split('?')[0] || '/'
  if (p.length > 1) p = p.replace(/\/+$/, '')
  const m = /^\/([a-z]{2,3})(\/.*|$)/.exec(p)
  if (m && codes.includes(m[1])) p = m[2] || '/'
  return p
}

/** @param {string} path @param {string[]} codes */
export function isPublicSeoPath(path, codes) {
  return PUBLIC_RE.test(seoBasePath(path, codes))
}

/** @param {unknown} flag runtimeConfig.public.seoIndex */
export function seoIndexOn(flag) {
  return String(flag) === '1' || flag === true
}

/**
 * The robots meta of a path: index only for a public page on an indexable build.
 * @param {string} path @param {string[]} codes @param {boolean} indexOn
 */
export function robotsContent(path, codes, indexOn) {
  return indexOn && isPublicSeoPath(path, codes) ? 'index, follow' : 'noindex, nofollow'
}

/**
 * `path` in locale `code` (the default locale is unprefixed).
 * @param {string} code @param {string} path @param {string} defaultLocale
 */
export function localizedPath(code, path, defaultLocale) {
  return code === defaultLocale ? path : `/${code}${path === '/' ? '' : path}`
}

/**
 * A JSON-LD body that cannot close its <script> element.
 * @param {unknown} value
 */
export function jsonLd(value) {
  return JSON.stringify(value).replace(/</g, '\\u003c')
}

/**
 * og + twitter card tags of one page.
 * @param {{ title: string, description: string, url: string, image: string, type?: string }} p
 * @returns {Array<Record<string, string>>}
 */
export function socialMeta(p) {
  return [
    { property: 'og:site_name', content: SITE_NAME },
    { property: 'og:type', content: p.type || 'website' },
    { property: 'og:title', content: p.title },
    { property: 'og:description', content: p.description },
    { property: 'og:url', content: p.url },
    { property: 'og:image', content: p.image },
    { name: 'twitter:card', content: 'summary_large_image' },
    { name: 'twitter:title', content: p.title },
    { name: 'twitter:description', content: p.description },
    { name: 'twitter:image', content: p.image },
  ]
}

/**
 * canonical + hreflang links: canonical on `canonicalCode`'s copy, one
 * alternate per locale in `langs` (the locales the page really has) and
 * x-default on the default-locale copy. One language = no alternates.
 * @param {{ siteUrl: string, base: string, canonicalCode: string, langs: string[], defaultLocale: string }} o
 */
export function localeLinks(o) {
  /** @param {string} code */
  const abs = (code) => `${o.siteUrl}${localizedPath(code, o.base, o.defaultLocale)}`
  const out = [{ rel: 'canonical', href: abs(o.canonicalCode) }]
  if (o.langs.length > 1) {
    for (const c of o.langs) out.push({ rel: 'alternate', hreflang: c, href: abs(c) })
    out.push({ rel: 'alternate', hreflang: 'x-default', href: abs(o.defaultLocale) })
  }
  return out
}

const FRONT = {
  title: 'Agents and people, one channel feed',
  description: 'spool-hub is a channel feed where AI agents and people work side by side: channels, topics, direct messages, a calendar, help and release notes, in 19 languages.',
}
const HELP = {
  title: 'Help',
  description: 'How to use spool-hub: channels, topics, direct messages, agents, boxes, the calendar and the rest of the app.',
}

/**
 * The head of /login and /help/** (the blog builds its own, pages/blog.vue),
 * or null for any other path. /login exists in every locale; the help text
 * is one language, so every /<lang>/help copy canonicalises to the default one.
 * @param {{ path: string, locale: string, codes: string[], defaultLocale: string, siteUrl: string }} o
 */
export function publicPageHead(o) {
  const base = seoBasePath(o.path, o.codes)
  const site = String(o.siteUrl || '').replace(/\/+$/, '')
  const login = base === '/login'
  if (!login && !/^\/help(?:\/|$)/.test(base)) return null
  const page = login ? FRONT : HELP
  const link = localeLinks(login
    ? { siteUrl: site, base, canonicalCode: o.locale, langs: o.codes, defaultLocale: o.defaultLocale }
    : { siteUrl: site, base, canonicalCode: o.defaultLocale, langs: [], defaultLocale: o.defaultLocale })
  const meta = [
    { name: 'description', content: page.description },
    ...socialMeta({ title: `${page.title} · ${SITE_NAME}`, description: page.description, url: link[0].href, image: `${site}${SITE_IMAGE}` }),
  ]
  const script = login
    ? [{
        type: 'application/ld+json',
        key: 'ld-site',
        innerHTML: jsonLd([
          { '@context': 'https://schema.org', '@type': 'Organization', '@id': `${site}/#organization`, name: SITE_NAME, url: `${site}/`, logo: `${site}/logo.webp` },
          { '@context': 'https://schema.org', '@type': 'WebSite', '@id': `${site}/#website`, name: SITE_NAME, url: `${site}/`, inLanguage: o.locale, publisher: { '@id': `${site}/#organization` } },
        ]),
      }]
    : []
  return { title: page.title, meta, link, script }
}

/** @param {string} s */
const attr = (s) => String(s).replace(/&/g, '&amp;').replace(/"/g, '&quot;').replace(/</g, '&lt;')

/**
 * Write a page's publicPageHead into its prerendered document (build time).
 * For a page whose layout renders it client-only (/help: layouts/default.vue),
 * so no head of its own reaches the document; once hydrated the page sets the
 * same tags, which unhead matches by key. Title, robots and description are
 * replaced, the rest added before </head>. A document that already has a
 * canonical is returned as is.
 * @param {string} html
 * @param {{ title: string, meta: Array<Record<string, string>>, link: Array<Record<string, string>>, script: Array<{ type: string, key: string, innerHTML: string }> }} head
 * @param {string} robots
 */
export function injectPublicHead(html, head, robots) {
  if (/<link\b[^>]*\brel="canonical"/.test(html)) return html
  /** @param {string} name @param {Record<string, string>} a */
  const tag = (name, a) => `<${name} ${Object.entries(a).map(([k, v]) => `${k}="${attr(v)}"`).join(' ')}>`
  const description = head.meta.find((m) => m.name === 'description')?.content || ''
  let out = html
    .replace(/<title>[^<]*<\/title>/, `<title>${attr(`${head.title} · ${SITE_NAME}`)}</title>`)
    .replace(/(<meta\b[^>]*\bname="robots"[^>]*\bcontent=")[^"]*"/, `$1${robots}"`)
    .replace(/(<meta\b[^>]*\bname="description"[^>]*\bcontent=")[^"]*"/, `$1${attr(description)}"`)
  const add = [
    ...head.link.map((l) => tag('link', l)),
    ...head.meta.filter((m) => m.name !== 'description').map((m) => tag('meta', m)),
    ...head.script.map((x) => `<script type="${x.type}">${x.innerHTML}</script>`),
  ]
  out = out.replace('</head>', add.join('') + '</head>')
  return out
}

// ── robots.txt + sitemap.xml (build time, nuxt.config publicSeoModule) ──────
// Shapes taken from the two SEO sites on the fleet box: robots = the
// generate-seo.js buildRobots of one (crawl rules + an absolute Sitemap
// line), sitemap = the gen-sitemap of the other (every <url> carries its
// whole hreflang group plus x-default).

/** Static files a crawler needs to render a public page. */
const ROBOTS_ASSETS = ['/_nuxt/', '/blog-md/', '/help-md/', '/icons/', '/config.json', '/build.json', '/manifest.webmanifest', '/*.webp$', '/*.avif$']

/**
 * robots.txt: on an indexable build only the public pages (and the files
 * they render with) are crawlable, plus / itself (a noindex page that sends
 * a visitor to /login); anything else is the app. Off = nothing is.
 * @param {{ siteUrl: string, codes: string[], defaultLocale: string, indexOn: boolean }} o
 */
export function buildRobotsTxt(o) {
  if (!o.indexOn || !o.siteUrl) return 'User-agent: *\nDisallow: /\n'
  const lines = ['User-agent: *', 'Disallow: /', 'Allow: /$']
  for (const c of o.codes) {
    for (const p of ['/login', '/blog', '/help']) lines.push(`Allow: ${localizedPath(c, p, o.defaultLocale)}`)
  }
  for (const a of ROBOTS_ASSETS) lines.push(`Allow: ${a}`)
  lines.push('', `Sitemap: ${o.siteUrl}/sitemap.xml`, '')
  return lines.join('\n')
}

/** @param {string} s */
const xmlEscape = (s) => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;')

/**
 * The sitemap's pages: every canonical public URL with its lastmod and
 * hreflang group, as the pages themselves declare them.
 * @param {{ codes: string[], defaultLocale: string, today: string, help: string[], pageSize: number,
 *   blog: { locales?: Record<string, Array<{ id: string, date?: string, published?: string }>> } | null }} o
 * @returns {Array<{ base: string, code: string, langs: string[], lastmod: string }>}
 */
export function sitemapEntries(o) {
  /** @type {Array<{ base: string, code: string, langs: string[], lastmod: string }>} */
  const out = []
  /** @param {string} base @param {string} lastmod */
  const all = (base, lastmod) => { for (const c of o.codes) out.push({ base, code: c, langs: o.codes, lastmod }) }
  all('/login', o.today)
  for (const h of ['', ...o.help]) out.push({ base: h ? `/help/${h}` : '/help', code: o.defaultLocale, langs: [], lastmod: o.today })
  const locales = o.blog?.locales || {}
  const en = locales.en || []
  /** @param {{ date?: string, published?: string }} e */
  const day = (e) => String(e.published || e.date || o.today).slice(0, 10)
  const newest = en.length ? en.map(day).sort().pop() || o.today : o.today
  const pages = Math.max(1, Math.ceil(en.length / o.pageSize))
  for (let n = 1; n <= pages; n++) all(n === 1 ? '/blog' : `/blog/page/${n}`, newest)
  for (const e of en) {
    const langs = o.codes.filter((c) => c === 'en' || (locales[c] || []).some((x) => x.id === e.id))
    for (const c of langs) out.push({ base: `/blog/${e.id}`, code: c, langs, lastmod: day(e) })
  }
  return out
}

/**
 * sitemap.xml of sitemapEntries, every URL on the apex.
 * @param {{ siteUrl: string, defaultLocale: string, entries: Array<{ base: string, code: string, langs: string[], lastmod: string }> }} o
 */
export function buildSitemapXml(o) {
  /** @param {string} code @param {string} base */
  const abs = (code, base) => xmlEscape(`${o.siteUrl}${localizedPath(code, base, o.defaultLocale)}`)
  const out = [
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" xmlns:xhtml="http://www.w3.org/1999/xhtml">',
  ]
  for (const e of o.entries) {
    out.push('  <url>', `    <loc>${abs(e.code, e.base)}</loc>`, `    <lastmod>${e.lastmod}</lastmod>`)
    if (e.langs.length > 1) {
      for (const c of e.langs) out.push(`    <xhtml:link rel="alternate" hreflang="${c}" href="${abs(c, e.base)}"/>`)
      out.push(`    <xhtml:link rel="alternate" hreflang="x-default" href="${abs(o.defaultLocale, e.base)}"/>`)
    }
    out.push('  </url>')
  }
  out.push('</urlset>', '')
  return out.join('\n')
}
