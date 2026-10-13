<!-- Spec 111 T003: the public blog, ONE route (path /blog/:slug(.*)*) for /blog,
     /blog/page/<n> and /blog/<id> (and every /<lang>/ copy). Ported and adapted from a sibling
     project's blog (spec 047/049): list and post pages, prerendered so the
     HTML holds the post with JS off. The data is the build-time copy
     sync-blog.mjs writes to public/blog-md/ (index.json + one escaped
     fragment per post copy, made ONLY by markdownToHtml); this page parses
     no markdown. Public: no layout (the login layout probes the session), no
     API call, and nuxt.config strips the session probe and the config.json
     script from these documents. A locale without its copy shows the en text
     with lang="en". Chrome strings are English literals until T013.
     The language menu (HUM-10 t1 35aea5bb) is a <details> of plain <a href>
     links: it works signed out and with JS off, a crawler follows it, and it
     lists exactly the hreflang locales (localeAlternates, public-seo.mjs).
     At <= 820 px its button shows the locale code, not the name, so the bar's
     "SPOOL-HUB" stays on one line at 390 px (t1 ff3953c1). -->
<template>
  <div class="blog-page" data-test="blog-page">
    <header class="blog-bar" data-test="blog-bar">
      <NuxtLink :to="localePath('/login')" class="blog-bar__home" data-test="blog-bar-home">
        <img src="/logo.webp" alt="" width="28" height="28" decoding="async">
        <span class="blog-bar__name">spool-hub</span>
        <span class="blog-bar__sep" aria-hidden="true">/</span>
        <span class="blog-bar__blog">Blog</span>
      </NuxtLink>
      <div class="blog-bar__end">
        <details ref="langMenuEl" class="blog-lang" data-test="blog-lang">
          <summary class="blog-lang__button" :title="t('nav.lang_label')" data-test="blog-lang-button">
            <span class="visually-hidden">{{ t('nav.lang_label') }}: </span>
            <span class="blog-lang__current">{{ localeName(locale) }}</span>
            <span class="blog-lang__code" aria-hidden="true">{{ locale }}</span>
            <span class="blog-lang__chevron" aria-hidden="true">&#9662;</span>
          </summary>
          <ul class="blog-lang__list" :aria-label="t('nav.lang_label')" data-test="blog-lang-list">
            <li v-for="l in langMenu" :key="l.code">
              <a
                :href="l.href"
                :hreflang="l.code"
                :lang="l.code"
                class="blog-lang__item"
                :aria-current="l.code === locale ? 'page' : undefined"
                :data-code="l.code"
                data-test="blog-lang-item"
                @click="persist(l.code)"
              >{{ localeName(l.code) }}</a>
            </li>
          </ul>
        </details>
        <NuxtLink :to="localePath('/login')" class="blog-bar__signin" data-test="blog-bar-signin">Sign in</NuxtLink>
      </div>
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
          <div class="bpost__share" role="group" :aria-label="t('blog.share')" data-test="blog-share">
            <template v-for="c in shareControls" :key="c.id">
              <button
                v-if="c.id === 'copy'"
                type="button"
                class="bpost__share-btn"
                data-test="blog-share-copy"
                @click="copyShareLink"
              >
                <svg class="bpost__share-icon" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" aria-hidden="true">
                  <path v-for="(d, i) in c.paths" :key="i" :d="d" />
                </svg>
                <span>{{ shareLabel(c.id) }}</span>
              </button>
              <a
                v-else
                class="bpost__share-btn"
                :data-test="'blog-share-' + c.id"
                :href="c.href"
                target="_blank"
                rel="noopener"
                @click="onShareClick(c.id)"
              >
                <svg class="bpost__share-icon" :class="{ 'is-fill': c.fill }" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" aria-hidden="true">
                  <path v-for="(d, i) in c.paths" :key="i" :d="d" />
                </svg>
                <span>{{ shareLabel(c.id) }}</span>
              </a>
            </template>
            <button
              v-if="canNativeShare"
              type="button"
              class="bpost__share-btn"
              data-test="blog-share-native"
              @click="shareNative"
            >
              <svg class="bpost__share-icon" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" aria-hidden="true">
                <circle cx="18" cy="5" r="3" />
                <circle cx="6" cy="12" r="3" />
                <circle cx="18" cy="19" r="3" />
                <line x1="8.59" y1="13.51" x2="15.42" y2="17.49" />
                <line x1="15.41" y1="6.51" x2="8.59" y2="10.49" />
              </svg>
              <span>{{ t('blog.share') }}</span>
            </button>
          </div>
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
        <!-- eslint-disable-next-line vue/no-v-html -- SAFE: SPL-1053, built by markdownToHtml, hostile copy refused at build -->
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
import { computed, onBeforeUnmount, onMounted, ref } from 'vue'
import { LOCALE_LS_KEY } from '~/composables/useLocaleSwitch'
import { DOC_READ_TIMEOUT_MS } from '~/utils/fetch-timeouts.mjs'
import { BLOG_SHARE_ORDER, SUBSTACK_NOTES, blogShareHref } from '~/utils/blog-share.mjs'
import { writeClipboard } from '~/utils/clipboard.mjs'
import { SITE_IMAGE, SITE_NAME, jsonLd, localeAlternates, localeLinks, localizedPath, seoIndexOn, socialMeta } from '~/utils/public-seo.mjs'

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
const { locale, locales, t } = useI18n({ useScope: 'global' })
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

/* Share row (HUM-10 t1 c15a822c): Copy link first, then plain share URLs.
   Substack has no share URL: it copies the link and opens Notes.
   Web Share, when the browser has it, is last and does not replace the row. */
const SHARE_ICONS: Record<string, { fill: boolean, paths: string[] }> = {
  copy: { fill: false, paths: [
    'M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71',
    'M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71',
  ] },
  linkedin: { fill: true, paths: ['M19 0h-14c-2.761 0-5 2.239-5 5v14c0 2.761 2.239 5 5 5h14c2.762 0 5-2.239 5-5v-14c0-2.761-2.238-5-5-5zm-11 19h-3v-11h3v11zm-1.5-12.268c-.966 0-1.75-.79-1.75-1.764s.784-1.764 1.75-1.764 1.75.79 1.75 1.764-.783 1.764-1.75 1.764zm13.5 12.268h-3v-5.604c0-3.368-4-3.113-4 0v5.604h-3v-11h3v1.765c1.396-2.586 7-2.777 7 2.476v6.759z'] },
  facebook: { fill: true, paths: ['M9 8h-3v4h3v12h5v-12h3.642l.358-4h-4v-1.667c0-.955.192-1.333 1.115-1.333h2.885v-5h-3.808c-3.596 0-5.192 1.583-5.192 4.615v3.385z'] },
  x: { fill: true, paths: ['M18.244 2.25h3.308l-7.227 8.26 8.502 11.24H16.21l-5.21-6.817L4.978 21.75H1.67l7.73-8.835L1.254 2.25H8.08l4.713 6.231zm-1.161 17.52h1.833L7.084 4.126H5.117z'] },
  whatsapp: { fill: true, paths: ['M.057 24l1.687-6.163c-1.041-1.804-1.588-3.849-1.587-5.946.003-6.556 5.338-11.891 11.893-11.891 3.181.001 6.167 1.24 8.413 3.488 2.245 2.248 3.481 5.236 3.48 8.414-.003 6.557-5.338 11.892-11.893 11.892-1.99-.001-3.951-.5-5.688-1.448l-6.305 1.654zm6.597-3.807c1.676.995 3.276 1.591 5.392 1.592 5.448 0 9.886-4.434 9.889-9.885.002-5.462-4.415-9.89-9.881-9.892-5.452 0-9.887 4.434-9.889 9.884-.001 2.225.651 3.891 1.746 5.634l-.999 3.648 3.742-.981zm11.387-5.464c-.074-.124-.272-.198-.57-.347-.297-.149-1.758-.868-2.031-.967-.272-.099-.47-.149-.669.149-.198.297-.768.967-.941 1.165-.173.198-.347.223-.644.074-.297-.149-1.255-.462-2.39-1.475-.883-.788-1.48-1.761-1.653-2.059-.173-.297-.018-.458.13-.606.134-.133.297-.347.446-.521.151-.172.2-.296.3-.495.099-.198.05-.372-.025-.521-.075-.148-.669-1.611-.916-2.206-.242-.579-.487-.501-.669-.51l-.57-.01c-.198 0-.52.074-.792.372s-1.04 1.016-1.04 2.479 1.065 2.876 1.213 3.074c.149.198 2.095 3.2 5.076 4.487.709.306 1.263.489 1.694.626.712.226 1.36.194 1.872.118.571-.085 1.758-.719 2.006-1.413.248-.694.248-1.289.173-1.413z'] },
  telegram: { fill: true, paths: ['M11.944 0A12 12 0 0 0 0 12a12 12 0 0 0 12 12 12 12 0 0 0 12-12A12 12 0 0 0 12 0a12 12 0 0 0-.056 0zm4.962 7.224c.1-.002.321.023.465.14a.506.506 0 0 1 .171.325c.016.093.036.306.02.472-.18 1.898-.962 6.502-1.36 8.627-.168.9-.499 1.201-.82 1.23-.696.065-1.225-.46-1.9-.902-1.056-.693-1.653-1.124-2.678-1.8-1.185-.78-.417-1.21.258-1.91.177-.184 3.247-2.977 3.307-3.23.007-.032.014-.15-.056-.212s-.174-.041-.249-.024c-.106.024-1.793 1.14-5.061 3.345-.48.33-.913.49-1.302.48-.428-.008-1.252-.241-1.865-.44-.752-.245-1.349-.374-1.297-.789.027-.216.325-.437.893-.663 3.498-1.524 5.83-2.529 6.998-3.014 3.332-1.386 4.025-1.627 4.476-1.635z'] },
  reddit: { fill: true, paths: ['M12 0A12 12 0 0 0 0 12a12 12 0 0 0 12 12 12 12 0 0 0 12-12A12 12 0 0 0 12 0zm5.01 4.744c.688 0 1.25.561 1.25 1.249a1.25 1.25 0 0 1-2.498.056l-2.597-.547-.8 3.747c1.824.07 3.48.632 4.674 1.488.308-.309.73-.491 1.207-.491.968 0 1.754.786 1.754 1.754 0 .716-.435 1.333-1.01 1.614a3.111 3.111 0 0 1 .042.52c0 2.694-3.13 4.87-7.004 4.87-3.874 0-7.004-2.176-7.004-4.87 0-.183.015-.366.043-.534A1.748 1.748 0 0 1 4.028 12c0-.968.786-1.754 1.754-1.754.463 0 .898.196 1.207.49 1.207-.883 2.878-1.43 4.744-1.487l.885-4.182a.342.342 0 0 1 .14-.197.35.35 0 0 1 .238-.042l2.906.617a1.214 1.214 0 0 1 1.108-.701zM9.25 12C8.561 12 8 12.562 8 13.25c0 .687.561 1.248 1.25 1.248.687 0 1.248-.561 1.248-1.249 0-.688-.561-1.249-1.249-1.249zm5.5 0c-.687 0-1.248.561-1.248 1.25 0 .687.561 1.248 1.249 1.248.688 0 1.249-.561 1.249-1.249 0-.687-.562-1.249-1.25-1.249zm-5.466 3.99a.327.327 0 0 0-.231.094.33.33 0 0 0 0 .463c.842.842 2.484.913 2.961.913.477 0 2.105-.056 2.961-.913a.361.361 0 0 0 .029-.463.33.33 0 0 0-.464 0c-.547.533-1.684.73-2.512.73-.828 0-1.979-.196-2.512-.73a.326.326 0 0 0-.232-.095z'] },
  substack: { fill: true, paths: ['M22.539 8.242H1.46V5.406h21.08v2.836zM1.46 10.812V24L12 18.11 22.54 24V10.812H1.46zM22.54 0H1.46v2.836h21.08V0z'] },
  email: { fill: false, paths: [
    'M4 4h16a2 2 0 0 1 2 2v12a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2z',
    'M22 6l-10 7L2 6',
  ] },
}
const canNativeShare = ref(false)
const sharePageUrl = computed(() => {
  const p = post.value
  if (!p) return ''
  const code = p.fallback ? defaultLocale : String(locale.value)
  return absolute(localizedPath(code, `/blog/${p.entry.id}`, defaultLocale))
})
const shareTitle = computed(() => post.value?.entry.title || '')
const shareControls = computed(() => BLOG_SHARE_ORDER.map((id) => {
  const icon = SHARE_ICONS[id] || { fill: false, paths: [] as string[] }
  const href = id === 'substack'
    ? SUBSTACK_NOTES
    : (blogShareHref(id, { url: sharePageUrl.value, title: shareTitle.value }) || '')
  return { id, href, fill: icon.fill, paths: icon.paths }
}))
function shareLabel(id: string): string {
  switch (id) {
    case 'copy': return t('blog.copy_link')
    case 'linkedin': return t('blog.share_linkedin')
    case 'facebook': return t('blog.share_facebook')
    case 'x': return t('blog.share_x')
    case 'whatsapp': return t('blog.share_whatsapp')
    case 'telegram': return t('blog.share_telegram')
    case 'reddit': return t('blog.share_reddit')
    case 'substack': return t('blog.share_substack')
    case 'email': return t('blog.share_email')
    default: return t('blog.share')
  }
}
async function copyShareLink() {
  const url = sharePageUrl.value
  if (!url) return
  await writeClipboard(url)
}
function onShareClick(id: string) {
  if (id === 'substack') void copyShareLink()
}
async function shareNative() {
  const p = post.value
  const url = sharePageUrl.value
  if (!p || !url) return
  try {
    await navigator.share({ title: p.entry.title, text: p.entry.summary, url })
  } catch { /* the visitor closed the sheet */ }
}
const indexOn = seoIndexOn(pub.seoIndex)

/* the page's path in no locale, and the locales it really has: a post only
   those with its copy (spec 116 T7), a list page all of them. ONE pair for
   the hreflang alternates and the language menu. */
const seoBase = computed(() => unprefixed(route.path).replace(/\/+$/, '') || '/blog')
const pageLangs = computed(() => post.value ? post.value.langs : (locales.value as Array<{ code: string }>).map((l) => l.code))
const langMenu = computed(() => localeAlternates({ siteUrl: '', base: seoBase.value, langs: pageLangs.value, defaultLocale }))
const localeName = (code: string) => (locales.value as Array<{ code: string, name?: string }>).find((l) => l.code === code)?.name || code

/* A pick is a full page load of the link (it works with JS off too); with JS
   the localStorage mirror is written here and the i18n_redirected cookie by
   plugins/locale-cookie.client.ts once the new locale's page runs. */
function persist(code: string) {
  try { localStorage.setItem(LOCALE_LS_KEY, code) } catch { /* private mode: the cookie still works */ }
}
/* with JS, a click outside or Escape closes the menu */
const langMenuEl = ref<HTMLDetailsElement | null>(null)
function closeLangMenu(e: Event) {
  const el = langMenuEl.value
  if (!el?.open) return
  if (e instanceof KeyboardEvent ? e.key === 'Escape' : !el.contains(e.target as Node)) el.open = false
}
onMounted(() => {
  canNativeShare.value = typeof navigator.share === 'function'
  document.addEventListener('click', closeLangMenu)
  document.addEventListener('keydown', closeLangMenu)
})
onBeforeUnmount(() => { document.removeEventListener('click', closeLangMenu); document.removeEventListener('keydown', closeLangMenu) })

useHead(() => {
  const base = seoBase.value
  const p = post.value
  const title = p ? p.entry.title : view.value.kind === 'list' ? 'Blog' : 'Not found'
  const description = p ? p.entry.summary : 'News and events from the spool.'
  if (view.value.kind === 'none') return { title, meta: [{ name: 'robots', content: 'noindex, nofollow' }, { name: 'description', content: description }] }
  /* spec 116 T7: a copy the locale lacks (the en text) canonicalises to the default one */
  const link = localeLinks({ siteUrl, base, canonicalCode: p?.fallback ? defaultLocale : locale.value, langs: pageLangs.value, defaultLocale })
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
.blog-bar__name { color: var(--color-accent); letter-spacing: 0.08em; text-transform: uppercase; font-size: 0.9375rem; white-space: nowrap; }
.blog-bar__sep { color: var(--color-muted); }
.blog-bar__signin { display: inline-flex; align-items: center; min-height: var(--tap, 44px); font-weight: 600; }
.blog-bar__end { display: flex; align-items: center; gap: 12px; flex-shrink: 0; }
.blog-lang { position: relative; }
.blog-lang__button {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  min-height: var(--tap, 44px);
  padding: 0 4px;
  color: var(--color-fg);
  cursor: pointer;
  list-style: none;
  user-select: none;
}
.blog-lang__button::-webkit-details-marker { display: none; }
.blog-lang__chevron { color: var(--color-muted); font-size: 0.8em; }
.blog-lang__code { display: none; text-transform: uppercase; }
.blog-lang__list {
  position: absolute;
  inset-inline-end: 0;
  top: 100%;
  z-index: 3;
  min-width: 180px;
  max-height: min(70vh, 520px);
  overflow-y: auto;
  margin: 0;
  padding: 4px 0;
  list-style: none;
  background: var(--color-surface);
  border: 1px solid var(--color-border);
  border-radius: var(--radius-md);
  box-shadow: 0 6px 20px rgba(0, 0, 0, 0.25);
}
.blog-lang__item { display: block; padding: 8px 14px; color: var(--color-fg); white-space: nowrap; }
.blog-lang__item:hover { background: var(--color-surface-hover); }
.blog-lang__item[aria-current="page"] { font-weight: 700; color: var(--color-accent); }
.visually-hidden {
  position: absolute;
  width: 1px;
  height: 1px;
  padding: 0;
  margin: -1px;
  overflow: hidden;
  clip: rect(0, 0, 0, 0);
  white-space: nowrap;
  border: 0;
}
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

.bpost__share { display: flex; flex-wrap: wrap; gap: 8px; max-width: 100%; }
.bpost__share-btn {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  min-height: 32px;
  max-width: 100%;
  padding: 0 10px;
  border: 1px solid var(--color-border);
  border-radius: var(--radius-md);
  background: var(--color-surface);
  color: var(--color-fg);
  font: inherit;
  font-size: 0.85rem;
  line-height: 1.2;
  text-decoration: none;
  cursor: pointer;
}
.bpost__share-btn:hover { background: var(--color-surface-hover); }
.bpost__share-btn span { overflow-wrap: anywhere; }
.bpost__share-icon { width: 16px; height: 16px; flex: none; fill: none; stroke: currentColor; stroke-width: 2; stroke-linecap: round; stroke-linejoin: round; }
.bpost__share-icon.is-fill { fill: currentColor; stroke: none; }
@media (max-width: 820px) {
  /* the name stays for a screen reader (the code is aria-hidden) */
  .blog-lang__current { position: absolute; width: 1px; height: 1px; overflow: hidden; clip: rect(0, 0, 0, 0); white-space: nowrap; }
  .blog-lang__code { display: inline; }
}
@media (max-width: 600px) {
  .blog-main { padding: 16px 12px 32px; }
  .blog__title, .bpost__title { font-size: 1.5rem; }
}
</style>
