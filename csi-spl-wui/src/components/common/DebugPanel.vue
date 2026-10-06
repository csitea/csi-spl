<!-- Diagnostics panel (ported from the donor WUI's common/DebugPanel.vue).

     In an error situation nobody can tell what the error actually was; this
     is the answer for the human who asked to see it — and only for them.

     WHO SEES IT: a signed-in human who ticked "Debug pane" in Settings →
     Appearance, carried as the `diagnostics_enabled` session
     claim (debugAudience.mjs). The badge says "Only you see this": the
     records are this browser's own. The gate is a `v-if`, never a
     `v-show` and never CSS: a hidden element is still in the DOM, still in
     view-source and still in the accessibility tree.

     WHAT IT SHOWS: the already-redacted records held by errorJournal.mjs.
     Redaction happens at CAPTURE, not here, so this component cannot widen
     what is visible.

     IT MUST NOT BREAK THE PAGE IT REPORTS ON: no fetch of any kind, no hub
     dependency, no top-level await, no modal, nothing that can throw.

     The raw technical text is NEVER passed through t(), and the block carries
     dir="ltr" so a URL is not mirrored.

     WHERE A RECORD CAME FROM: the buffer is per TAB and survives navigation,
     so records are GROUPED into "this page" and "recorded on other pages",
     each carries its age, each foreign one names its route, and navigating
     away collapses the list; it never clears it. -->
<template>
  <aside
    v-if="visible"
    class="debug-panel"
    data-test="debug-panel"
    :aria-label="t('debug_panel.title')"
  >
    <div class="debug-panel__bar">
      <button
        type="button"
        class="debug-panel__toggle"
        :aria-expanded="open ? 'true' : 'false'"
        aria-controls="debug-panel-body"
        data-test="debug-panel-toggle"
        @click="open = !open"
      >
        <UiIcon class="debug-panel__icon" name="alert-triangle" :size="16" />
        <span class="debug-panel__title">{{ t('debug_panel.title') }}</span>
        <span class="debug-panel__count" data-test="debug-panel-count">
          {{ countLabel }}
        </span>
      </button>
      <span class="debug-panel__staff">{{ t('debug_panel.only_you') }}</span>
    </div>

    <div v-if="open" id="debug-panel-body" class="debug-panel__body">
      <p class="debug-panel__meta" dir="ltr" data-test="debug-panel-meta">{{ meta }}</p>

      <p v-if="!count" class="debug-panel__empty">{{ t('debug_panel.no_errors') }}</p>

      <!-- Two GROUPS, never two buffers: "this page" first, then everything
           else this session, and every record is in exactly one of them. The
           split is presentational — nothing is filtered out, so an error
           recorded during a navigation that then redirected is still here,
           under `elsewhere`, with the route it happened on printed above it.

           Oldest first inside each group, so the MOST RECENT technical error
           is still the bottom-most content of the page — which is literally
           what was asked for. -->
      <template v-else>
        <section
          v-for="g in groups"
          :key="g.key"
          class="debug-panel__group"
        >
          <p class="debug-panel__group-title" data-test="debug-panel-group">
            {{ g.key === 'here' ? t('debug_panel.here') : t('debug_panel.elsewhere') }}
            ({{ g.items.length }})
          </p>
          <ol class="debug-panel__list" data-test="debug-panel-list">
            <li v-for="r in g.items" :key="r.seq" class="debug-panel__item">
              <!-- WHEN, and — when it is not this page — WHERE. The route is
                   technical text and is never passed through t(); only the
                   label around it is translated. -->
              <p class="debug-panel__ctx">
                <span data-test="debug-panel-age">{{ ageOf(r) }}</span>
                <template v-if="g.key !== 'here' && r.route">
                  <span aria-hidden="true"> · </span>
                  <span>{{ t('debug_panel.recorded_on') }}</span>
                  <code class="debug-panel__route" dir="ltr" data-test="debug-panel-origin">{{ r.route }}</code>
                </template>
              </p>
              <pre
                class="debug-panel__tech"
                dir="ltr"
                data-test="debug-panel-tech"
              >{{ headline(r) }}</pre>
              <pre
                v-if="r.message"
                class="debug-panel__detail"
                dir="ltr"
                data-test="debug-panel-detail"
              >{{ r.message }}</pre>
            </li>
          </ol>
        </section>
      </template>

      <div class="debug-panel__actions">
        <button
          type="button"
          class="debug-panel__action"
          data-test="debug-panel-copy"
          @click="copy"
        >
          {{ copyLabel }}
        </button>
        <button
          v-if="count"
          type="button"
          class="debug-panel__action"
          data-test="debug-panel-clear"
          @click="clear"
        >
          {{ t('debug_panel.clear') }}
        </button>
      </div>
    </div>
  </aside>
</template>

<script setup lang="ts">
import { writeClipboard } from '~/utils/clipboard.mjs'
import { displayVersion } from '~/utils/display-version.mjs'
import UiIcon from '@/components/UiIcon.vue'
import { useErrorJournal } from '@/composables/useErrorJournal'
import { isoDateTimeSec } from '~/utils/date-iso.mjs'
import type { ErrorRecord } from '@/composables/useErrorJournal'
import {
  ageParts,
  formatRecords,
  groupByOrigin,
  shouldCollapseOnRouteChange,
  summariseRecord,
} from '@/composables/errorJournal.mjs'

/* how often the relative ages re-render */
const CLOCK_TICK_MS = 15_000
/* how long the copy result label stays before it clears */
const COPY_STATE_RESET_MS = 2500

const { t, locale } = useI18n({ useScope: 'global' })
const { records, visible, clear: clearJournal } = useErrorJournal()

const config = useRuntimeConfig()
const appVersion = String(config.public.appVersion || '')
const envName = String(config.public.envName || '')

const items = computed(() => records.value as ErrorRecord[])
const count = computed(() => items.value.length)

// Open automatically the moment something has gone wrong; a clean session
// keeps the panel to one collapsed line so it is never in the way. That the
// line is there at all is the point: a granted reader can tell "nothing broke"
// apart from "the panel is missing".
const open = ref(false)
watch(count, (n, was) => {
  if (n > (was || 0)) open.value = true
})

const route = useRoute()

// ── origin scoping ─────────────────────────────────────────────────────────
// The buffer survives navigation on purpose; the presentation says where and
// when each record came from. Nothing below drops a record.

const grouped = computed(() => groupByOrigin(items.value, route.path) as {
  here: ErrorRecord[]
  elsewhere: ErrorRecord[]
})
const groups = computed(() =>
  ([
    { key: 'here' as const, items: grouped.value.here },
    { key: 'elsewhere' as const, items: grouped.value.elsewhere },
  ]).filter((g) => g.items.length > 0),
)

// The collapsed one-liner is the whole fix for the common case: a reader
// who lands on an unrelated page reads "3 recorded · none on this page" and
// never has to open the panel to find that out.
const countLabel = computed(() => {
  if (!count.value) return t('debug_panel.clean')
  const base = t('debug_panel.recorded', { count: count.value })
  const here = grouped.value.here.length
  return `${base} · ${here
    ? t('debug_panel.here_count', { count: here })
    : t('debug_panel.none_here')}`
})

// Navigating away collapses the panel — and ONLY collapses it. The records
// stay, the count stays, one click reopens the list. It does not collapse
// while anything in the buffer belongs to the new route or was recorded in the
// last few seconds, which is what keeps an error from a redirecting navigation
// on screen at the destination. That case is the reason a "clear on navigate"
// fix was rejected: it would delete the error before it could be read.
watch(() => route.path, (to) => {
  if (!open.value) return
  if (shouldCollapseOnRouteChange(items.value, to, Date.now())) open.value = false
})

// A ticking clock so "4 minutes ago" does not freeze at the value it had when
// the panel opened. It runs only while the panel is expanded, and it is torn
// down on unmount: this component must never be the reason a page misbehaves.
const now = ref(Date.now())
let clock: ReturnType<typeof setInterval> | null = null
function stopClock(): void {
  if (clock) { clearInterval(clock); clock = null }
}
watch(open, (isOpen) => {
  stopClock()
  if (!isOpen) return
  now.value = Date.now()
  clock = setInterval(() => { now.value = Date.now() }, CLOCK_TICK_MS)
}, { immediate: true })
onBeforeUnmount(stopClock)

/**
 * Relative age, formatted by the platform in the active locale, so ageing a
 * record costs no translated string per unit.
 */
function ageOf(r: ErrorRecord): string {
  const parts = ageParts(r.at, now.value) as { value: number, unit: string } | null
  if (!parts) return ''
  try {
    return new Intl.RelativeTimeFormat(String(locale.value || 'en'), { numeric: 'auto' })
      .format(parts.value, parts.unit as Intl.RelativeTimeFormatUnit)
  } catch {
    return ''
  }
}

// The baked appVersion is the bare semver on a deploy (Nuxt keeps
// NUXT_PUBLIC_APP_VERSION as-is). Show one leading v, never two.
const meta = computed(() =>
  [
    displayVersion(appVersion),
    envName,
    route.path,
    String(locale.value || ''),
  ].filter(Boolean).join(' · '),
)

function headline(r: ErrorRecord): string {
  /* CLE-77908: the viewer's local clock, like every other time in the WUI */
  const at = isoDateTimeSec(r.at) || String(r.at || '')
  return [at, summariseRecord(r), r.origin || ''].filter(Boolean).join('  ')
}

type CopyState = '' | 'ok' | 'fail'
const copyState = ref<CopyState>('')
const copyLabel = computed(() =>
  copyState.value === 'ok'
    ? t('debug_panel.copied')
    : copyState.value === 'fail'
      ? t('debug_panel.copy_failed')
      : t('debug_panel.copy'),
)

async function copy(): Promise<void> {
  // Clipboard access is denied outright in some contexts (insecure origin,
  // permissions policy). That is a state to show, never an exception to throw
  // — this panel exists for moments when the page is already unwell.
  try {
    const text = formatRecords(items.value, {
      version: appVersion,
      env: envName,
      page: route.path,
    })
    copyState.value = (await writeClipboard(text)) ? 'ok' : 'fail'
  } catch {
    copyState.value = 'fail'
  }
  setTimeout(() => { copyState.value = '' }, COPY_STATE_RESET_MS)
}

function clear(): void {
  clearJournal()
  open.value = false
}
</script>

<style scoped>
/* Sits at the very end of the document. Contained on every axis so it can
   never widen html/body (no document horizontal scroll on mobile). */
.debug-panel {
  width: 100%;
  max-width: 100%;
  min-width: 0;
  box-sizing: border-box;
  margin: 0;
  padding: var(--spacing-sm, 8px) var(--spacing-md, 16px);
  padding-bottom: calc(var(--spacing-md, 16px) + env(safe-area-inset-bottom, 0px));
  border-block-start: 1px solid var(--color-border);
  background: var(--color-bg-2);
  color: var(--color-fg);
  font-size: 0.8125rem;
  text-align: start;
}
.debug-panel__bar {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: var(--spacing-sm, 8px);
  max-width: 100%;
  min-width: 0;
}
.debug-panel__toggle {
  display: inline-flex;
  align-items: center;
  gap: var(--spacing-xs, 4px);
  flex: 1 1 auto;
  min-width: 0;
  padding: 0;
  border: 0;
  background: none;
  color: inherit;
  font: inherit;
  text-align: start;
  cursor: pointer;
}
.debug-panel__icon {
  flex: none;
  color: var(--color-warn);
}
.debug-panel__title {
  font-weight: 600;
}
.debug-panel__count,
.debug-panel__staff {
  opacity: 0.75;
  overflow-wrap: anywhere;
}
.debug-panel__staff {
  flex: none;
  font-size: 0.75rem;
}
.debug-panel__body {
  margin-block-start: var(--spacing-sm, 8px);
  max-width: 100%;
  min-width: 0;
}
.debug-panel__meta,
.debug-panel__empty {
  margin: 0 0 var(--spacing-sm, 8px);
  opacity: 0.75;
  overflow-wrap: anywhere;
}
.debug-panel__group {
  margin-block-end: var(--spacing-sm, 8px);
  max-width: 100%;
  min-width: 0;
}
/* The heading that says which page a group of records belongs to. Not an
   <h*>: the panel must not inject a heading into the document outline. */
.debug-panel__group-title {
  margin: 0 0 var(--spacing-xs, 4px);
  font-weight: 600;
  font-size: 0.75rem;
  opacity: 0.8;
  overflow-wrap: anywhere;
}
/* When, and — for a record from another page — where. */
.debug-panel__ctx {
  margin: 0 0 2px;
  font-size: 0.6875rem;
  opacity: 0.75;
  overflow-wrap: anywhere;
}
.debug-panel__route {
  /* The gap is CSS and not a literal space in the template: Vue's whitespace
     condensing removes the one between two adjacent inline elements. */
  margin-inline-start: 0.35em;
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  overflow-wrap: anywhere;
}
.debug-panel__list {
  margin: 0;
  padding: 0;
  list-style: none;
  max-width: 100%;
  min-width: 0;
}
.debug-panel__item {
  margin-block-end: var(--spacing-sm, 8px);
  max-width: 100%;
  min-width: 0;
}
/* The technical block. Monospace, LTR even under dir="rtl", wrapped rather
   than scrolled so a copy grabs the whole line, and contained so a long URL
   cannot widen the document. */
.debug-panel__tech,
.debug-panel__detail {
  margin: 0;
  max-width: 100%;
  min-width: 0;
  box-sizing: border-box;
  padding: var(--spacing-xs, 4px) var(--spacing-sm, 8px);
  border: 1px solid var(--color-border);
  border-radius: var(--radius-sm, 6px);
  background: var(--color-bg);
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-size: 0.75rem;
  line-height: 1.5;
  text-align: start;
  white-space: pre-wrap;
  overflow-wrap: anywhere;
  overflow-x: auto;
}
.debug-panel__detail {
  margin-block-start: 2px;
  opacity: 0.85;
}
.debug-panel__actions {
  display: flex;
  flex-wrap: wrap;
  gap: var(--spacing-sm, 8px);
  margin-block-start: var(--spacing-sm, 8px);
}
.debug-panel__action {
  padding: 4px 10px;
  border: 1px solid var(--color-border);
  border-radius: var(--radius-sm, 6px);
  background: var(--color-bg);
  color: inherit;
  font: inherit;
  font-size: 0.75rem;
  cursor: pointer;
}
</style>
