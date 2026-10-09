import { publicPageHead, robotsContent, seoIndexOn } from '~/utils/public-seo.mjs'

/**
 * Spec 116 T7: the search-engine head of a public page that does not build
 * its own (/login, /help/**; the blog does, pages/blog.vue): robots (index
 * only on an indexable build), title, description, apex canonical,
 * hreflang, og + twitter and, on /login, the Organization + WebSite JSON-LD
 * (utils/public-seo.mjs). Called from the page, so it ships in that page's
 * chunk and never in the initial JS (perf-budgets.json ci_initial_gzip_kb).
 */
export function usePublicSeo() {
  const route = useRoute()
  const { locale, locales } = useI18n({ useScope: 'global' })
  const pub = useRuntimeConfig().public
  const codes = (locales.value as Array<{ code: string }>).map((l) => l.code)
  useHead(() => {
    const page = publicPageHead({ path: route.path, locale: locale.value, codes, defaultLocale: String(pub.defaultLocale || 'en'), siteUrl: String(pub.siteUrl || '') })
    const robots = { name: 'robots', content: robotsContent(route.path, codes, seoIndexOn(pub.seoIndex)) }
    return page ? { title: page.title, link: page.link, script: page.script, meta: [robots, ...page.meta] } : { meta: [robots] }
  })
}
