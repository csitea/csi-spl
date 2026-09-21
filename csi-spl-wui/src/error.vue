<!-- WUI error page (404 + friends), ported from the donor WUI's error.vue.
     Rendered by Nuxt's error boundary, so the HTTP status stays what the
     server / Hosting 404.html carries — this is NOT a catch-all route. Uses
     the centred `login` layout so it renders without the hub. -->
<template>
  <NuxtLayout name="login">
    <section class="err login-card" data-test="error-page">
      <h1 class="err__title" data-test="error-title">
        {{ is404 ? t('error.title_404') : t('error.title_other') }}
      </h1>

      <p class="err__desc">
        {{ is404 ? t('error.desc_404') : t('error.desc_other', { status: statusCode }) }}
      </p>

      <p v-if="is404 && requestedPath" class="err__path" data-test="error-requested-path">
        {{ t('error.requested_path') }}: <code dir="ltr">{{ requestedPath }}</code>
      </p>

      <ErrorNotice
        v-if="!is404"
        :message="String(props.error?.message || '')"
        :error="props.error"
        source="error-page"
        test-id="error-page-notice"
      />

      <nav class="err__suggest" :aria-label="t('error.suggestions_title')" data-test="error-suggestions">
        <h2 class="err__suggest-title">{{ t('error.suggestions_title') }}</h2>
        <ul class="err__suggest-list">
          <li v-for="s in suggestions" :key="s.path">
            <a :href="localePath(s.path)" class="err__link">{{ t(s.label) }}</a>
          </li>
        </ul>
      </nav>

      <a :href="localePath('/')" class="err__home" data-test="error-home-link">
        {{ t('error.back_home') }}
      </a>
    </section>
  </NuxtLayout>
</template>

<script setup lang="ts">
import type { NuxtError } from '#app'
import ErrorNotice from '@/components/common/ErrorNotice.vue'

const props = defineProps<{ error: NuxtError }>()

const { t, locales } = useI18n({ useScope: 'global' })
const localePath = useLocalePath()

const statusCode = computed(() => Number(props.error?.statusCode) || 404)
const is404 = computed(() => statusCode.value === 404)

// The spool's top-level pages — the always-safe fallback suggestions (labels
// are nav.* i18n keys, paths are real pages/ routes).
interface Suggestion {
  path: string
  label: string
}
const MAIN_SECTIONS: Suggestion[] = [
  { path: '/', label: 'nav.threads' },
  { path: '/lobby', label: 'nav.lobby' },
  { path: '/channel/general', label: 'nav.general' },
]
const EXTRA_ROUTES: Suggestion[] = [
  { path: '/login', label: 'nav.login' },
]
const CANDIDATES: Suggestion[] = [...MAIN_SECTIONS, ...EXTRA_ROUTES]

// Requested path is only known client-side (the prerendered 404.html is one
// static file for every unknown URL). Filled in onMounted to keep hydration
// identical to the server markup.
const requestedPath = ref('')

function levenshtein(a: string, b: string): number {
  const m = a.length
  const n = b.length
  if (m === 0) return n
  if (n === 0) return m
  let prev = Array.from({ length: n + 1 }, (_, i) => i)
  for (let i = 1; i <= m; i++) {
    const cur = [i]
    for (let j = 1; j <= n; j++) {
      cur[j] = Math.min(
        prev[j]! + 1,
        cur[j - 1]! + 1,
        prev[j - 1]! + (a[i - 1] === b[j - 1] ? 0 : 1),
      )
    }
    prev = cur
  }
  return prev[n]!
}

// "/Lobyy/" → "lobyy" (slashes and case stripped); a leading locale prefix
// ("/fi/lobyy", spec 021) is dropped so it does not count as a typo.
const LOCALE_CODES = computed(() => new Set<string>(locales.value.map((l) => (typeof l === 'string' ? l : l.code))))
function normalize(path: string): string {
  const p = path.toLowerCase().replace(/\/+$/, '').replace(/^\/+/, '')
  const head = p.split('/')[0] || ''
  return LOCALE_CODES.value.has(head) ? p.slice(head.length).replace(/^\/+/, '') : p
}

// Naive similarity: prefix/substring match wins, else relative edit distance.
// Purely client-side over the static route list — no hub involved.
const suggestions = computed<Suggestion[]>(() => {
  const wanted = normalize(requestedPath.value)
  if (!is404.value || !wanted) return MAIN_SECTIONS
  const scored = CANDIDATES
    .map((s) => {
      const cand = normalize(s.path) || 'threads'
      let score: number
      if (cand.startsWith(wanted) || wanted.startsWith(cand)) {
        score = 0.1
      } else {
        score = levenshtein(wanted, cand) / Math.max(wanted.length, cand.length)
      }
      return { s, score }
    })
    .filter((x) => x.score <= 0.5)
    .sort((a, b) => a.score - b.score)
    .slice(0, 3)
    .map((x) => x.s)
  return scored.length > 0 ? scored : MAIN_SECTIONS
})

onMounted(() => {
  requestedPath.value = window.location.pathname
})

useHead({
  title: () => (is404.value ? t('error.title_404') : t('error.title_other')),
  meta: [{ name: 'robots', content: 'noindex' }],
})
</script>

<style scoped>
.err {
  display: flex;
  flex-direction: column;
  align-items: center;
  text-align: center;
  gap: var(--spacing-sm);
  min-width: 0;
}
.err__title {
  font-size: 1.6rem;
  margin: 0;
}
.err__desc {
  margin: 0;
}
.err__path {
  margin: 0;
  font-size: 0.9rem;
  max-width: 100%;
  overflow-wrap: anywhere;
}
.err__path code {
  background: var(--color-surface-hover);
  border: 1px solid var(--color-border);
  border-radius: var(--radius-sm);
  padding: 2px 6px;
}
.err__suggest {
  margin-top: var(--spacing-md);
  width: 100%;
}
.err__suggest-title {
  font-size: 1rem;
  margin: 0 0 var(--spacing-sm);
}
.err__suggest-list {
  list-style: none;
  margin: 0;
  padding: 0;
  display: flex;
  flex-wrap: wrap;
  justify-content: center;
  gap: var(--spacing-sm);
}
.err__link {
  display: inline-block;
  padding: 8px 16px;
  min-height: var(--tap);
  line-height: 28px;
  box-sizing: border-box;
  border: 1px solid var(--color-border);
  border-radius: var(--radius-pill);
  background: var(--color-surface);
  color: var(--color-accent);
  text-decoration: none;
  font-weight: 600;
}
.err__link:hover {
  background: var(--color-surface-hover);
}
.err__home {
  margin-top: var(--spacing-md);
  display: inline-block;
  padding: 10px 22px;
  min-height: var(--tap);
  box-sizing: border-box;
  border-radius: var(--radius-pill);
  background: var(--color-accent);
  color: var(--color-on-accent);
  text-decoration: none;
  font-weight: 600;
}
.err__home:hover {
  filter: brightness(1.08);
}
</style>
