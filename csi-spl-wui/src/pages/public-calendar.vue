<!-- HUM-10 (t1 ef57739c, a8e3d31d): the public calendar. A signed-out
     visitor sees the product's own events: each live `feature` blog post
     (linking /blog/<id>) and one line per day of releases ("n releases,
     v<first> … v<last>", as text: /releases/<tag> needs a signed-in session). Never a tenant calendar entry: the tenant audience `public`
     is "everyone in the workspace", not the internet (rdb 0125), so this page
     reads no store and no hub API, only /pub-cal/events.json, written at
     build time (src/node/pubcal/public-calendar-data.mjs).
     Its own route rather than a branch of /calendar: /calendar runs the
     workspace shell (rail, live feed, the calendar store), and a signed-out
     visitor of /calendar is sent here (middleware/signed-out-redirect).
     The shown month lives in the URL (?m=YYYY-MM); dates print as ISO
     (YYYY-MM, YYYY-MM-DD), like every absolute date (tests/unit/date-iso). -->
<template>
  <div class="pubcal-page" data-test="public-calendar">
    <header class="pubcal-bar">
      <NuxtLink :to="localePath('/blog')" class="pubcal-bar__home">
        <img src="/logo.webp" alt="" width="28" height="28" decoding="async">
        <span class="pubcal-bar__name">spool-hub</span>
        <span class="pubcal-bar__sep" aria-hidden="true">/</span>
        <span>{{ t('public_calendar.title') }}</span>
      </NuxtLink>
      <NuxtLink :to="localePath('/login')" class="pubcal-bar__signin" data-test="public-calendar-signin">{{ t('public_calendar.sign_in') }}</NuxtLink>
    </header>

    <main class="pubcal-main">
      <h1 class="pubcal-title" data-test="public-calendar-heading">{{ t('public_calendar.title') }}</h1>
      <p class="pubcal-lede">{{ t('public_calendar.lede') }}</p>

      <nav class="pubcal-nav" :aria-label="t('public_calendar.month_nav')">
        <button type="button" class="btn ghost" data-test="public-calendar-prev" @click="go(-1)">&larr; {{ t('public_calendar.prev_month') }}</button>
        <h2 class="pubcal-month" data-test="public-calendar-month" :data-month="month">{{ month }}</h2>
        <button type="button" class="btn ghost" data-test="public-calendar-next" @click="go(1)">{{ t('public_calendar.next_month') }} &rarr;</button>
      </nav>

      <p v-if="state === 'loading'" class="pubcal-note" data-test="public-calendar-loading">{{ t('public_calendar.loading') }}</p>
      <p v-else-if="state === 'error'" class="pubcal-note" data-test="public-calendar-error">{{ t('public_calendar.error') }}</p>
      <p v-else-if="!days.length" class="pubcal-note" data-test="public-calendar-empty">{{ t('public_calendar.empty_month') }}</p>
      <ol v-else class="pubcal-days" data-test="public-calendar-days" :data-state="state">
        <li v-for="d in days" :key="d.day" class="pubcal-day" data-test="public-calendar-day" :data-day="d.day">
          <h3 class="pubcal-day__date"><time :datetime="d.day">{{ d.day }}</time></h3>
          <ul v-if="d.features.length" class="pubcal-features">
            <li v-for="f in d.features" :key="f.href">
              <NuxtLink :to="localePath(f.href)" class="pubcal-feature" data-test="public-calendar-feature">
                <span class="pubcal-kind">{{ t('public_calendar.feature') }}</span>
                <span class="pubcal-feature__title">{{ f.title }}</span>
              </NuxtLink>
            </li>
          </ul>
          <!-- one entry per day, plain text: /releases/<ref> reads
               /v1/release-notes, which the hub refuses signed out -->
          <p
            v-for="r in d.releases"
            :key="r.id"
            class="pubcal-releases"
            data-test="public-calendar-release"
            :data-n="r.n"
            :data-first="r.first"
            :data-last="r.last"
          >
            <span class="pubcal-kind">{{ t('public_calendar.releases', { n: r.n }) }}</span>
            <span class="pubcal-release">{{ r.n === 1 ? r.first : `${r.first} … ${r.last}` }}</span>
          </p>
        </li>
      </ol>
    </main>
  </div>
</template>

<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { DOC_READ_TIMEOUT_MS } from '~/utils/fetch-timeouts.mjs'
import {
  mergePublicCalendar, pubCalAddMonths, pubCalMonthDays, pubCalShownMonth,
} from '~/utils/public-calendar.mjs'

definePageMeta({ layout: false })

const { t } = useI18n({ useScope: 'global' })
const route = useRoute()
const router = useRouter()
const localePath = useLocalePath()

const events = ref<ReturnType<typeof mergePublicCalendar>>([])
const state = ref<'loading' | 'ready' | 'error'>('loading')
const today = new Date().toISOString().slice(0, 10)

/* the build's file only (PUBLIC_CALENDAR_SOURCES): no store, no hub API */
async function load() {
  try {
    const r = await fetch('/pub-cal/events.json', { cache: 'no-cache', signal: AbortSignal.timeout(DOC_READ_TIMEOUT_MS) })
    if (!r.ok) throw new Error(String(r.status))
    const body = await r.json() as { events?: unknown[] }
    events.value = mergePublicCalendar(body.events || [])
    state.value = 'ready'
  } catch {
    state.value = 'error'
  }
}
onMounted(load)

const month = computed(() => pubCalShownMonth(events.value, String(route.query.m || ''), today))
const days = computed(() => pubCalMonthDays(events.value, month.value))

function go(step: number) {
  void router.replace({ query: { ...route.query, m: pubCalAddMonths(month.value, step) } })
}

useHead(() => ({ title: t('public_calendar.title') }))
</script>

<style scoped>
.pubcal-page {
  height: 100%;
  overflow-x: clip;
  overflow-y: auto;
  background: var(--color-bg);
  color: var(--color-fg);
}
.pubcal-bar {
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
.pubcal-bar__home { display: inline-flex; align-items: center; gap: 8px; min-width: 0; color: var(--color-fg); font-weight: 700; }
.pubcal-bar__home img { display: block; width: 28px; height: 28px; border-radius: var(--radius-sm); }
.pubcal-bar__name { color: var(--color-accent); letter-spacing: 0.08em; text-transform: uppercase; font-size: 0.9375rem; }
.pubcal-bar__sep { color: var(--color-muted); }
.pubcal-bar__signin { display: inline-flex; align-items: center; min-height: var(--tap, 44px); font-weight: 600; }
.pubcal-main { max-width: 720px; margin: 0 auto; padding: 24px 16px 48px; display: grid; gap: 16px; min-width: 0; }
.pubcal-title { margin: 0; font-size: 1.85rem; font-weight: 700; line-height: 1.2; }
.pubcal-lede { margin: 0; color: var(--color-muted); }
.pubcal-nav { display: flex; align-items: center; justify-content: space-between; gap: 8px; flex-wrap: wrap; }
.pubcal-month { margin: 0; font-size: 1.25rem; font-weight: 700; }
.pubcal-note { margin: 0; color: var(--color-muted); }
.pubcal-days, .pubcal-features { list-style: none; margin: 0; padding: 0; display: grid; gap: 12px; }
.pubcal-day {
  display: grid;
  gap: 8px;
  padding: 12px 16px;
  border: 1px solid var(--color-border);
  border-radius: var(--radius-md);
  background: var(--color-surface);
  min-width: 0;
}
.pubcal-day__date { margin: 0; font-size: 1rem; font-weight: 700; }
.pubcal-features { gap: 6px; }
.pubcal-feature { display: flex; align-items: baseline; gap: 8px; color: var(--color-fg); overflow-wrap: anywhere; }
.pubcal-feature__title { font-weight: 600; }
.pubcal-kind {
  flex: none;
  padding: 1px 8px;
  border: 1px solid var(--color-border);
  border-radius: var(--radius-pill);
  font-size: 0.8rem;
  color: var(--color-muted);
}
.pubcal-releases { display: flex; flex-wrap: wrap; align-items: center; gap: 6px 10px; margin: 0; }
.pubcal-release { font-family: var(--font-mono, monospace); font-size: 0.875rem; }
@media (max-width: 600px) {
  .pubcal-main { padding: 16px 12px 32px; }
  .pubcal-title { font-size: 1.5rem; }
}
</style>
