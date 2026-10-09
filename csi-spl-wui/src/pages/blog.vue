<!-- Spec 111 T003: the public blog, ONE route (path /blog/:slug(.*)*) for /blog,
     /blog/page/<n> and /blog/<id> (and every /<lang>/ copy). Ported and adapted from a sibling
     project's blog (spec 047/049): list and post pages, prerendered so the
     HTML holds the post with JS off. The data is the build-time copy
     sync-blog.mjs writes to public/blog-md/ (index.json + one escaped
     fragment per post copy, made ONLY by markdownToHtml); this page parses
     no markdown. Public: no layout (the login layout probes the session), no
     API call, and nuxt.config strips the session probe and the config.json
     script from these documents. A locale without its copy shows the en text
     with lang="en". Chrome strings are English literals until T013. -->
<template>
  <div class="blog-page" data-test="blog-page">
    <header class="blog-bar" data-test="blog-bar">
      <NuxtLink :to="localePath('/blog')" class="blog-bar__home" data-test="blog-bar-home">
        <img src="/logo.webp" alt="" width="28" height="28" decoding="async">
        <span class="blog-bar__name">spool-hub</span>
        <span class="blog-bar__sep" aria-hidden="true">/</span>
        <span class="blog-bar__blog">Blog</span>
      </NuxtLink>
      <NuxtLink :to="localePath('/login')" class="blog-bar__signin" data-test="blog-bar-signin">Sign in</NuxtLink>
    </header>

    <main class="blog-main">
      <article v-if="view.kind === 'post' && post" class="bpost" :lang="post.fallback ? 'en' : undefined" data-test="blog-post">
        <nav class="bpost__crumb" aria-label="Breadcrumb">
          <NuxtLink :to="localePath('/blog')" data-test="blog-post-crumb">Blog</NuxtLink>
          <span aria-hidden="true"> / </span>
          <span>{{ post.entry.title }}</span>
        </nav>
        <header class="bpost__head">
          <h1 class="bpost__title" data-test="blog-post-title">{{ post.entry.title }}</h1>
          <p class="bpost__meta" data-test="blog-post-meta">
            <time :datetime="post.entry.published || post.entry.date">{{ post.entry.date }}</time>
            <span class="bpost__type" :data-type="post.entry.type">{{ post.entry.type }}</span>
            <span class="bpost__author">{{ post.entry.author }}</span>
          </p>
          <p v-if="post.fallback" class="bpost__pending" data-test="blog-post-pending">English text; the translation is pending.</p>
        </header>
        <img
          v-if="post.entry.image"
          class="bpost__cover"
          :src="`/blog/img/${post.entry.image}`"
          :alt="post.entry.image_alt || ''"
          data-test="blog-post-cover"
        >
        <!-- the one v-html sink: a fragment escaped and allow-listed at build
             time (sync-blog.mjs, markdownToHtml) and refused there and in
             render-wui-firebase-json.sh when it holds a script or handler -->
        <div class="bpost__body" data-test="blog-post-body" v-html="post.html" />
        <nav class="bpost__pager" aria-label="More posts">
          <NuxtLink v-if="post.newer" :to="localePath(`/blog/${post.newer.id}`)" rel="prev" data-test="blog-post-newer">&larr; {{ post.newer.title }}</NuxtLink>
          <NuxtLink :to="localePath('/blog')" class="bpost__all" data-test="blog-post-back">All posts</NuxtLink>
          <NuxtLink v-if="post.older" :to="localePath(`/blog/${post.older.id}`)" rel="next" data-test="blog-post-older">{{ post.older.title }} &rarr;</NuxtLink>
        </nav>
      </article>

      <section v-else-if="view.kind === 'list' && list" class="blog" data-test="blog-list-page">
        <header class="blog__head">
          <h1 class="blog__title" data-test="blog-title">Blog</h1>
          <p class="blog__lede">News and events from the spool: what the agents and the fleet built, released and learned.</p>
        </header>
        <div v-if="list.total" class="blog__chips" role="group" aria-label="Post type">
          <button
            v-for="c in TYPE_CHIPS"
            :key="c"
            type="button"
            class="blog__chip"
            :aria-pressed="typeFilter === c"
            :data-test="`blog-chip-${c}`"
            @click="typeFilter = c"
          >{{ c }}</button>
        </div>
        <p v-if="!list.total" class="blog__empty" data-test="blog-empty">No posts yet.</p>
        <ul v-else class="blog__list" data-test="blog-list">
          <li v-for="p in shown" :key="p.entry.id" class="blog__item" :lang="p.fallback ? 'en' : undefined" data-test="blog-item">
            <NuxtLink :to="localePath(`/blog/${p.entry.id}`)" class="blog__card" data-test="blog-item-link">
              <h2 class="blog__card-title">{{ p.entry.title }}</h2>
              <p class="blog__card-meta">
                <time :datetime="p.entry.published || p.entry.date">{{ p.entry.date }}</time>
                <span class="bpost__type" :data-type="p.entry.type">{{ p.entry.type }}</span>
              </p>
              <p class="blog__card-summary">{{ p.entry.summary }}</p>
            </NuxtLink>
          </li>
        </ul>
        <nav v-if="list.pages > 1" class="blog__pager" aria-label="Pages" data-test="blog-pager">
          <NuxtLink v-if="list.page > 1" :to="localePath(pagePath(list.page - 1))" rel="prev" data-test="blog-page-newer">&larr; Newer</NuxtLink>
          <span>Page {{ list.page }} of {{ list.pages }}</span>
          <NuxtLink v-if="list.page < list.pages" :to="localePath(pagePath(list.page + 1))" rel="next" data-test="blog-page-older">Older &rarr;</NuxtLink>
        </nav>
      </section>

      <section v-else class="blog" data-test="blog-not-found">
        <h1 class="blog__title">Not found</h1>
        <p>There is no such post. <NuxtLink :to="localePath('/blog')">All posts</NuxtLink></p>
      </section>
    </main>
  </div>
</template>

<script setup lang="ts">
import { computed, ref } from 'vue'
import { DOC_READ_TIMEOUT_MS } from '~/utils/fetch-timeouts.mjs'
import { SITE_IMAGE, SITE_NAME, jsonLd, localeLinks, seoIndexOn, socialMeta } from '~/utils/public-seo.mjs'

/* one record for all three paths (spec 111 3.1): nuxt.config sets its path
   to /blog/:slug(.*)* (blogDocumentsModule); a "..." file name would put
   "..." in a chunk name, which a ".."-refusing server loops on (docs.vue) */
definePageMeta({ layout: false })

interface BlogEntry {
  id: string
  type: string
  title: string
  summary: string
  date: string
  published?: string
  author: string
  tags?: string[]
  image?: string
  image_alt?: string
}
interface Copy { entry: BlogEntry, fallback: boolean }

const PAGE_SIZE = 20
const TYPE_CHIPS = ['all', 'digest', 'news', 'event'] as const
const ID_RE = /^\d{4}-\d{2}-\d{2}-[a-z0-9]+(?:-[a-z0-9]+)*$/

const route = useRoute()
const localePath = useLocalePath()
const { locale, locales } = useI18n({ useScope: 'global' })
const pub = useRuntimeConfig().public
const siteUrl = String(pub.siteUrl || '').replace(/\/+$/, '')
const defaultLocale = String(pub.defaultLocale || 'en')

/** /blog -> list 1, /blog/page/<n> -> list n, /blog/<id> -> post, else none. */
const view = computed(() => {
  const raw = route.params.slug
  const seg = (Array.isArray(raw) ? raw : [raw]).filter((s): s is string => typeof s === 'string' && s !== '')
  if (seg.length === 0) return { kind: 'list' as const, page: 1, id: '' }
  if (seg.length === 2 && seg[0] === 'page' && /^[1-9]\d{0,4}$/.test(seg[1])) return { kind: 'list' as const, page: Number(seg[1]), id: '' }
  if (seg.length === 1 && ID_RE.test(seg[0])) return { kind: 'post' as const, page: 0, id: seg[0] }
  return { kind: 'none' as const, page: 0, id: '' }
})
const pagePath = (n: number) => (n <= 1 ? '/blog' : `/blog/page/${n}`)

/** A file of the build-time copy: read from disk while prerendering, fetched in the browser. */
async function readBlog(name: string): Promise<string | null> {
  if (import.meta.server) {
    const { readFile } = await import('node:fs/promises')
    const { join } = await import('node:path')
    try { return await readFile(join(process.cwd(), 'src/public/blog-md', name), 'utf8') } catch { return null }
  }
  try {
    const r = await fetch(`/blog-md/${name}`, { cache: 'no-cache', signal: AbortSignal.timeout(DOC_READ_TIMEOUT_MS) })
    return r.ok ? await r.text() : null
  } catch { return null }
}

/** The list in this locale: every en post, as this locale's copy where it has one. */
function copiesFor(index: { locales?: Record<string, BlogEntry[]> } | null, lang: string): Copy[] {
  const en = index?.locales?.en || []
  const own = new Map((index?.locales?.[lang] || []).map((e) => [e.id, e]))
  return en.map((e) => (own.has(e.id) ? { entry: own.get(e.id)!, fallback: false } : { entry: e, fallback: lang !== 'en' }))
}

const { data } = await useAsyncData(
  () => `blog:${locale.value}:${route.path}`,
  async () => {
    const v = view.value
    if (v.kind === 'none') return null
    const text = await readBlog('index.json')
    let index = null
    try { index = text ? JSON.parse(text) : null } catch { index = null }
    const all = copiesFor(index, locale.value)
    if (v.kind === 'list') {
      const pages = Math.max(1, Math.ceil(all.length / PAGE_SIZE))
      if (v.page > pages) return null
      return { list: { page: v.page, pages, total: all.length, items: all.slice((v.page - 1) * PAGE_SIZE, v.page * PAGE_SIZE) } }
    }
    const i = all.findIndex((c) => c.entry.id === v.id)
    if (i < 0) return null
    const c = all[i]
    const html = await readBlog(`${c.fallback ? 'en' : locale.value}/${v.id}.html`)
    if (html === null) return null
    const brief = (x?: Copy) => (x ? { id: x.entry.id, title: x.entry.title } : null)
    /* spec 116 T7: hreflang only for the locales that have this post */
    const langs = Object.keys(index?.locales || {}).filter((l) => l === 'en' || (index.locales[l] || []).some((e: BlogEntry) => e.id === v.id))
    return { post: { ...c, html, langs, newer: brief(all[i - 1]), older: brief(all[i + 1]) } }
  },
  { watch: [locale] },
)

const post = computed(() => data.value?.post || null)
const list = computed(() => data.value?.list || null)
const typeFilter = ref<(typeof TYPE_CHIPS)[number]>('all')
const shown = computed(() => (list.value?.items || []).filter((p) => typeFilter.value === 'all' || p.entry.type === typeFilter.value))

/* canonical + hreflang on the apex (NUXT_PUBLIC_SITE_URL), never the request host */
function unprefixed(path: string): string {
  const codes = (locales.value as Array<{ code: string }>).map((l) => l.code)
  const m = /^\/([a-z]{2,3})(\/.*|$)/.exec(path)
  return m && codes.includes(m[1]) ? (m[2] || '/') : path
}
const absolute = (path: string) => `${siteUrl}${path}`
const indexOn = seoIndexOn(pub.seoIndex)

useHead(() => {
  const base = unprefixed(route.path).replace(/\/+$/, '') || '/blog'
  const p = post.value
  const title = p ? p.entry.title : view.value.kind === 'list' ? 'Blog' : 'Not found'
  const description = p ? p.entry.summary : 'News and events from the spool.'
  const codes = (locales.value as Array<{ code: string }>).map((l) => l.code)
  if (view.value.kind === 'none') return { title, meta: [{ name: 'robots', content: 'noindex, nofollow' }, { name: 'description', content: description }] }
  /* spec 116 T7: a copy the locale lacks (the en text) canonicalises to the default one */
  const link = localeLinks({ siteUrl, base, canonicalCode: p?.fallback ? defaultLocale : locale.value, langs: p ? p.langs : codes, defaultLocale })
  const url = link[0].href
  const image = p?.entry.image ? absolute(`/blog/img/${p.entry.image.replace(/\.webp$/, '-og.webp')}`) : absolute(SITE_IMAGE)
  const meta: Array<Record<string, string>> = [
    /* spec 111 3.1 + 116 T7: the blog is indexable on an indexable build only (the app default is noindex) */
    { name: 'robots', content: indexOn ? 'index, follow' : 'noindex, nofollow' },
    { name: 'description', content: description },
    ...socialMeta({ title, description, url, image, type: p ? 'article' : 'website' }),
  ]
  if (p?.entry.published) meta.push({ property: 'article:published_time', content: p.entry.published })
  const script = p
    ? [{
        type: 'application/ld+json',
        key: 'ld-post',
        innerHTML: jsonLd({
          '@context': 'https://schema.org',
          '@type': 'BlogPosting',
          headline: p.entry.title,
          description,
          datePublished: p.entry.published || p.entry.date,
          inLanguage: p.fallback ? 'en' : locale.value,
          author: { '@type': 'Person', name: p.entry.author },
          publisher: { '@type': 'Organization', '@id': `${siteUrl}/#organization`, name: SITE_NAME, logo: absolute('/logo.webp') },
          image,
          mainEntityOfPage: url,
          ...(p.entry.tags?.length ? { keywords: p.entry.tags.join(', ') } : {}),
        }),
      }]
    : []
  return { title, meta, link, script }
})
</script>

<style scoped>
.blog-page {
  height: 100%;
  overflow-x: clip;
  overflow-y: auto;
  background: var(--color-bg);
  color: var(--color-fg);
}
.blog-bar {
  position: sticky;
  top: 0;
  z-index: 2;
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
  min-height: var(--top-bar-h);
  padding: 4px 16px;
  background: var(--color-sidebar);
  border-bottom: 1px solid var(--color-border);
}
.blog-bar__home { display: inline-flex; align-items: center; gap: 8px; min-width: 0; color: var(--color-fg); font-weight: 700; }
.blog-bar__home img { display: block; width: 28px; height: 28px; border-radius: var(--radius-sm); }
.blog-bar__name { color: var(--color-accent); letter-spacing: 0.08em; text-transform: uppercase; font-size: 0.9375rem; }
.blog-bar__sep { color: var(--color-muted); }
.blog-bar__signin { display: inline-flex; align-items: center; min-height: var(--tap, 44px); font-weight: 600; }
.blog-main { max-width: 720px; margin: 0 auto; padding: 24px 16px 48px; }
.blog, .bpost { display: grid; gap: 16px; min-width: 0; }
.blog__title, .bpost__title { margin: 0; font-size: 1.85rem; font-weight: 700; line-height: 1.2; overflow-wrap: anywhere; }
.blog__lede { margin: 0.35rem 0 0; color: var(--color-muted); }
.blog__chips { display: flex; flex-wrap: wrap; gap: 8px; }
.blog__chip {
  min-height: 32px;
  padding: 0 12px;
  border: 1px solid var(--color-border);
  background: var(--color-surface);
  color: var(--color-fg);
  cursor: pointer;
  text-transform: capitalize;
}
.blog__chip[aria-pressed="true"] { background: var(--color-accent); border-color: var(--color-accent); color: var(--color-on-accent); }
.blog__empty { margin: 0; color: var(--color-muted); }
.blog__list { list-style: none; margin: 0; padding: 0; display: grid; gap: 12px; }
.blog__card {
  display: grid;
  gap: 6px;
  padding: 16px 18px;
  border: 1px solid var(--color-border);
  border-radius: var(--radius-md);
  background: var(--color-surface);
  color: inherit;
}
.blog__card:hover { background: var(--color-surface-hover); }
.blog__card-title { margin: 0; font-size: 1.2rem; font-weight: 700; color: var(--color-fg); overflow-wrap: anywhere; }
.blog__card-meta, .bpost__meta { display: flex; flex-wrap: wrap; align-items: center; gap: 10px; margin: 0; font-size: 0.85rem; color: var(--color-muted); }
.blog__card-summary { margin: 0; color: var(--color-fg); overflow-wrap: anywhere; }
.bpost__type { padding: 1px 8px; border: 1px solid var(--color-border); border-radius: var(--radius-pill); text-transform: capitalize; }
.blog__pager, .bpost__pager { display: flex; flex-wrap: wrap; justify-content: space-between; align-items: center; gap: 12px; }
.bpost__crumb { font-size: 0.9rem; color: var(--color-muted); overflow-wrap: anywhere; }
.bpost__crumb a { color: inherit; }
.bpost__head { display: grid; gap: 8px; }
.bpost__pending { margin: 0; font-size: 0.85rem; color: var(--color-muted); }
.bpost__cover { display: block; width: 100%; max-height: 420px; object-fit: cover; border-radius: var(--radius-md); }
.bpost__body { line-height: 1.6; overflow-wrap: anywhere; }
.bpost__body :deep(img) { max-width: 100%; }
.bpost__body :deep(pre) { white-space: pre-wrap; overflow-wrap: anywhere; }
.bpost__pager { padding-top: 16px; border-top: 1px solid var(--color-border); }
.bpost__all { font-weight: 600; }
@media (max-width: 600px) {
  .blog-main { padding: 16px 12px 32px; }
  .blog__title, .bpost__title { font-size: 1.5rem; }
}
</style>
