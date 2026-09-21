<!-- 022 FR-001..003: the persistent top strip. Brand | the Omnibox (the one
     MessageComposer, so the ``` code-block composer works in it; plain text
     goes to the page's send target, `/search <q>` opens /search?q=) | the
     language switcher + the user menu (the former .app-corner, CLE-3402 /
     spec 021). On a phone the Omnibox folds into a search icon. -->
<template>
  <header class="top-bar" data-test="top-bar" :class="{ 'top-bar--open': expanded }">
    <div class="top-bar__start" data-test="top-bar-start">
      <NuxtLink class="top-bar__brand" :to="localePath('/')" :aria-label="t('search.home')">spool</NuxtLink>
      <ThemeToggle />
    </div>
    <div class="top-bar__omnibox" data-test="top-bar-omnibox">
      <MessageComposer
        ref="composer"
        omnibox
        global
        :placeholder="placeholder"
        :busy="busy"
        :send-blocked="!omnibox.target"
        :operators="search.operators"
        @send="onSend"
        @search="onSearch"
        @dismiss="onDismiss"
        @results="omnibox.focusResults++"
      />
      <kbd
        class="slash-badge"
        data-test="slash-badge"
        aria-hidden="true"
        :title="t('search.slash_badge_title')"
      >/</kbd>
      <p :id="slashHintId" class="sr-only" data-test="slash-shortcut-hint">{{ t('search.slash_shortcut') }}</p>
      <button
        type="button"
        class="icon-btn top-bar__close"
        data-test="top-bar-search-close"
        :aria-label="t('common.close')"
        :title="t('common.close')"
        @click="onDismiss"
      >
        <UiIcon name="x" :size="18" />
      </button>
    </div>
    <button
      type="button"
      class="top-bar__search-toggle"
      data-test="top-bar-search-toggle"
      :aria-label="t('search.open_omnibox')"
      :title="t('search.open_omnibox')"
      :aria-expanded="expanded ? 'true' : 'false'"
      @click="expand"
    >
      <UiIcon name="search" :size="20" />
    </button>
    <div class="top-bar__end app-corner" data-test="app-corner">
      <LanguageSwitcher />
      <UserMenu />
    </div>
  </header>
</template>

<script setup lang="ts">
import LanguageSwitcher from '@/components/LanguageSwitcher.vue'
import MessageComposer from '@/components/MessageComposer.vue'
import ThemeToggle from '@/components/ThemeToggle.vue'
import { useOmniboxStore } from '~/stores/omnibox'
import { useSearchStore } from '~/stores/search'
import { searchPath, shouldLoadOperators } from '~/utils/search.mjs'
import { slashFocusAction, slashFocusContext } from '~/utils/slash-focus.mjs'
import { useSessionStore } from '~/stores/session'

const { t } = useI18n({ useScope: 'global' })
const localePath = useLocalePath()
const router = useRouter()
const route = useRoute()
const omnibox = useOmniboxStore()
const search = useSearchStore()
const session = useSessionStore()
const api = useSpoolApi()
const composer = ref<InstanceType<typeof MessageComposer> | null>(null)
const expanded = ref(false)
const slashHintId = useId()
const restoreEl = ref<HTMLElement | null>(null)

function onDocKey(ev: KeyboardEvent) {
  const root = document.querySelector('[data-test=top-bar-omnibox]')
  const ctx = slashFocusContext(ev, {
    omniboxRoot: root,
    document,
    viewportWidth: window.innerWidth,
    hasRestore: Boolean(restoreEl.value),
  })
  const act = slashFocusAction(ev, ctx)
  if (act === 'focus') {
    ev.preventDefault()
    const prev = document.activeElement
    restoreEl.value = prev instanceof HTMLElement ? prev : null
    composer.value?.focus()
    return
  }
  if (act === 'restore') {
    ev.preventDefault()
    ev.stopImmediatePropagation()
    const prev = restoreEl.value
    restoreEl.value = null
    const ta = root?.querySelector('textarea')
    ta?.blur()
    if (prev && document.contains(prev) && prev !== document.body) prev.focus()
  }
}

const placeholder = computed(() => omnibox.target ? omnibox.target.placeholder() : t('search.placeholder_no_target'))
const busy = computed(() => Boolean(omnibox.target && omnibox.target.busy && omnibox.target.busy()))

async function onSend(text: string, _parent?: string, files?: File[]) {
  const target = omnibox.target
  if (!target) return
  await target.send(text, files || [])
}

function onSearch(q: string) {
  void router.push(localePath(searchPath(q)))
}

function expand() {
  expanded.value = true
  nextTick(() => composer.value?.focus())
}

function onDismiss() {
  expanded.value = false
}

/* a deep link /search?q=… shows its query in the Omnibox, ready to refine */
const onSearchPage = computed(() => /\/search$/.test(route.path))
function showQuery() {
  const q = route.query.q
  if (onSearchPage.value && typeof q === 'string' && q) composer.value?.setText(`/search ${q}`)
}
watch(() => [onSearchPage.value, route.query.q], showQuery, { flush: 'post' })

/* 022 catalogue: mock hydrates immediately; live waits for a member session
   so signed-out /channel/lobby does not GET /v1/view/search/operators (401).
   A human who signs in (and never opens /search) still gets autocomplete. */
watch(() => session.state, (st) => {
  if (shouldLoadOperators({ mock: api.mock, sessionState: st })) void search.loadOperators()
}, { immediate: true })

onMounted(() => {
  showQuery()
  document.addEventListener('keydown', onDocKey, true)
})
onUnmounted(() => {
  document.removeEventListener('keydown', onDocKey, true)
})
</script>

<style scoped>
.top-bar {
  position: sticky;
  top: 0;
  z-index: var(--z-sticky, 40);
  display: flex;
  align-items: center;
  gap: 12px;
  min-height: var(--top-bar-h);
  padding: 4px 12px;
  background: var(--color-sidebar);
  border-bottom: 1px solid var(--color-border);
  max-width: 100%;
  min-width: 0;
  box-sizing: border-box;
  flex-shrink: 0;
}
.top-bar__start {
  display: flex;
  align-items: center;
  gap: 4px;
  flex-shrink: 0;
  min-width: 0;
}
.top-bar__brand {
  font-size: 15px;
  font-weight: 700;
  letter-spacing: 0.08em;
  text-transform: uppercase;
  color: var(--color-accent);
  flex-shrink: 0;
}
.top-bar__omnibox {
  flex: 1;
  min-width: 0;
  max-width: 960px;
  margin-inline: auto;
  position: relative;
  /* CLE-3433: a FLEX row, so the `/` keycap is a sibling of the composer
     pill instead of an absolutely positioned overlay. Absolute placement
     resolved against this box, whose inline end is also where the
     composer's Send button sits — the keycap landed ON the word "Send"
     and clipped it (measured on dev build 28ec27b at 1440x900: badge
     x 1089..1110, Send x 1050..1112, rectangles intersecting). Laid out
     in flow the two can never collide at any width. */
  display: flex;
  align-items: center;
  gap: 8px;
}
.top-bar__omnibox > .composer {
  flex: 1 1 auto;
  min-width: 0;
}
.slash-badge {
  flex: 0 0 auto;
  pointer-events: none;
  font-size: 11px;
  font-family: var(--font-mono, ui-monospace, monospace);
  line-height: 1;
  padding: 2px 6px;
  border: 1px solid var(--color-border);
  border-radius: var(--radius-sm);
  color: var(--color-muted, var(--color-fg));
  background: var(--color-surface);
  opacity: 0.85;
}
.top-bar__omnibox:focus-within .slash-badge { display: none; }
.top-bar__close { display: none; }
.top-bar__search-toggle {
  display: none;
  min-width: var(--tap);
  min-height: var(--tap);
  border: 1px solid var(--color-border);
  border-radius: var(--radius-sm);
  background: transparent;
  color: var(--color-fg);
  cursor: pointer;
  margin-inline-start: auto;
  flex-shrink: 0;
}
.top-bar__end {
  display: flex;
  align-items: center;
  gap: 6px;
  flex-shrink: 0;
  min-width: 0;
}
/* FR-003: phone — the Omnibox folds into the icon; opened, it covers the bar */
@media (max-width: 640px) {
  .slash-badge { display: none; }
  .top-bar__omnibox { display: none; }
  .top-bar__search-toggle { display: inline-grid; place-items: center; }
  .top-bar--open .top-bar__omnibox {
    display: flex;
    align-items: flex-start;
    gap: 6px;
    position: absolute;
    z-index: 2;
    inset-inline: 0;
    top: 0;
    max-width: 100%;
    padding: 4px 8px;
    background: var(--color-sidebar);
    border-bottom: 1px solid var(--color-border);
    box-sizing: border-box;
  }
  .top-bar--open .top-bar__omnibox > :first-child { flex: 1; min-width: 0; }
  .top-bar--open .top-bar__close {
    display: inline-flex;
    min-width: var(--tap);
    min-height: var(--tap);
    width: var(--tap);
    height: var(--tap);
    border: 1px solid var(--color-border);
  }
}
</style>
