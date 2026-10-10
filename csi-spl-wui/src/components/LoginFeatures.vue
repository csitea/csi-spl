<template>
  <!-- spec 116 3.2 (116-T4): the feature posts, newest 6, then "All posts".
       Mounted as LazyLoginFeatures: its own chunk, still rendered at
       prerender, so the cards are in the /login HTML. Plain links, no
       NuxtLink (layouts/login.vue: its chunk would join the first download),
       and no i18n key (one would ship in the core catalogue `/` preloads);
       the labels are the blog's own English ones. -->
  <section v-if="cards.length" class="lf" aria-labelledby="lf-title" data-test="login-features">
    <div class="lf__head">
      <h2 id="lf-title" class="lf__title">Features</h2>
      <a class="lf__all" :href="localePath('/blog')" data-test="login-features-all">All posts &rarr;</a>
    </div>
    <ul class="lf__list">
      <li v-for="c in cards" :key="c.id" class="lf__item" :lang="c.fallback ? 'en' : undefined" data-test="login-feature">
        <a class="lf__card" :href="localePath(`/blog/${c.id}`)" data-test="login-feature-link">
          <!-- the post's image when it has one, over the plain accent tile
               (sync-blog.mjs copies `image` only when set) -->
          <span class="lf__tile" aria-hidden="true">
            <img v-if="c.image" class="lf__img" :src="`/blog/img/${c.image}`" alt="" loading="lazy" decoding="async" width="320" height="180">
          </span>
          <span class="lf__text">
            <span class="lf__name">{{ c.title }}</span>
            <span class="lf__sum">{{ c.summary }}</span>
          </span>
        </a>
      </li>
    </ul>
  </section>
</template>

<script setup lang="ts">
import { computed } from 'vue'
import { DOC_READ_TIMEOUT_MS } from '~/utils/fetch-timeouts.mjs'

interface BlogEntry { id: string, title: string, summary: string, date: string, published?: string, tags?: string[], image?: string }
interface Card { id: string, title: string, summary: string, image: string, fallback: boolean }

const MAX_CARDS = 6
const localePath = useLocalePath()
const { locale } = useI18n({ useScope: 'global' })

/** The blog's build-time index: from disk while prerendering, the site's own file in the browser (never the hub, C7). */
async function readIndex(): Promise<string | null> {
  if (import.meta.server) {
    const { readFile } = await import('node:fs/promises')
    const { join } = await import('node:path')
    try { return await readFile(join(process.cwd(), 'src/public/blog-md/index.json'), 'utf8') } catch { return null }
  }
  try {
    const r = await fetch('/blog-md/index.json', { cache: 'no-cache', signal: AbortSignal.timeout(DOC_READ_TIMEOUT_MS) })
    return r.ok ? await r.text() : null
  } catch { return null }
}

/** en posts tagged `feature`, newest first, at most 6; this locale's copy where it has one (as blog.vue's copiesFor). */
function featureCards(index: { locales?: Record<string, BlogEntry[]> } | null, lang: string): Card[] {
  const stamp = (e: BlogEntry) => e.published || e.date || ''
  const own = new Map((index?.locales?.[lang] || []).map((e) => [e.id, e]))
  return (index?.locales?.en || [])
    .filter((e) => (e.tags || []).includes('feature'))
    .sort((a, b) => stamp(b).localeCompare(stamp(a)))
    .slice(0, MAX_CARDS)
    .map((e) => {
      const c = own.get(e.id) || e
      return { id: e.id, title: c.title, summary: c.summary, image: e.image || '', fallback: !own.has(e.id) && lang !== 'en' }
    })
}

const { data } = await useAsyncData(
  () => `login-features:${locale.value}`,
  async () => {
    const text = await readIndex()
    let index = null
    try { index = text ? JSON.parse(text) : null } catch { index = null }
    return featureCards(index, locale.value)
  },
  { watch: [locale] },
)
const cards = computed(() => data.value || [])
</script>

<style scoped>
.lf { width: 100%; min-width: 0; text-align: start; }
.lf__head {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  gap: 12px;
  margin: 0 0 12px;
}
.lf__title {
  margin: 0;
  font-size: 1.125rem;
  color: var(--color-heading);
}
.lf__all { font-size: 0.875rem; color: var(--color-accent); white-space: nowrap; }
.lf__list {
  list-style: none;
  margin: 0;
  padding: 0;
  display: grid;
  grid-template-columns: repeat(3, minmax(0, 1fr));
  gap: 16px;
}
.lf__item { min-width: 0; }
.lf__card {
  display: flex;
  flex-direction: column;
  height: 100%;
  border: 1px solid var(--color-border-strong);
  border-radius: var(--radius-md);
  background: var(--color-surface);
  overflow: hidden;
  color: inherit;
  text-decoration: none;
  transition: border-color 0.15s ease, transform 0.15s ease;
}
.lf__card:hover { border-color: var(--color-accent); transform: translateY(-2px); }
.lf__tile {
  display: block;
  aspect-ratio: 2 / 1;
  background: linear-gradient(135deg, color-mix(in srgb, var(--color-accent) 55%, var(--color-surface)), color-mix(in srgb, var(--color-accent) 12%, var(--color-surface)));
}
.lf__img { display: block; width: 100%; height: 100%; object-fit: cover; }
.lf__text { display: flex; flex-direction: column; gap: 4px; padding: 10px 12px 12px; min-width: 0; }
.lf__name { font-weight: 600; font-size: 0.9375rem; line-height: 1.3; color: var(--color-heading); }
.lf__sum {
  font-size: 0.8125rem;
  line-height: 1.45;
  color: var(--color-muted);
  /* one line of summary (spec 116 3.2) */
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
@media (max-width: 820px) {
  .lf__list { grid-template-columns: repeat(2, minmax(0, 1fr)); }
}
/* a phone: one column of compact rows, the picture as a thumbnail */
@media (max-width: 480px) {
  .lf__list { grid-template-columns: minmax(0, 1fr); gap: 10px; }
  .lf__card { flex-direction: row; align-items: center; }
  .lf__tile { flex: 0 0 96px; width: 96px; min-height: 72px; aspect-ratio: auto; align-self: stretch; overflow: hidden; }
  .lf__text { padding: 8px 12px; }
}
@media (prefers-reduced-motion: reduce) {
  .lf__card { transition: none; }
  .lf__card:hover { transform: none; }
}
</style>
