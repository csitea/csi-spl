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
      <p :id="slashHintId" class="sr-only" data-test="slash-shortcut-hint">{{ t('search.slash_shortcut') }}</p>
      <!-- CLE-3433: a send that did not land says so HERE, next to the box
           that still holds the text, and offers the one action that helps -->
      <ErrorNotice
        v-if="sendError"
        class="top-bar__send-error"
        :message="t(sendError.key)"
        source="omnibox-send"
        test-id="omnibox-send-error"
      >
        <template #detail>
          <button type="button" class="btn ghost" data-test="omnibox-send-retry" @click="retrySend">
            {{ t('composer.send_retry') }}
          </button>
        </template>
      </ErrorNotice>
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
/* Async (CLE-34984): its Combobox pulls @headlessui/vue + @tanstack/virtual-core
   (~17 KB gzip) into the first download of every page; it loads right after. */
const LanguageSwitcher = defineAsyncComponent(() => import('@/components/LanguageSwitcher.vue'))
import MessageComposer from '@/components/MessageComposer.vue'
import ThemeToggle from '@/components/ThemeToggle.vue'
import { useOmniboxStore } from '~/stores/omnibox'
import { useSearchStore } from '~/stores/search'
import { searchPath, shouldLoadOperators } from '~/utils/search.mjs'
import { slashFocusAction, slashFocusContext } from '~/utils/slash-focus.mjs'
import { sendFailureKey } from '~/utils/send-failure.mjs'
import ErrorNotice from '~/components/common/ErrorNotice.vue'
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

/* CLE-3433. This handler used to be `await target.send(...)` with no catch.
   Vue does not await an emit's listener, so a rejection here became an
   UNHANDLED promise rejection: the composer had already cleared the box on
   the same tick it emitted, and channel.sendLive had already rolled its
   optimistic row back - so a dropped frame left no text, no row and no
   error. That is how the owner's message disappeared on 2026-09-21.

   Now a failure puts the text back in the box, names the reason and offers a
   Retry. Nothing is cleared until the send has resolved. */
const sendError = ref<{ key: string, err: unknown, text: string, files: File[], topicId?: string, channelId?: string } | null>(null)

async function onSend(text: string, parent?: string, files?: File[], channelId?: string) {
  const target = omnibox.target
  if (!target) return
  const sent = files || []
  sendError.value = null
  try {
    await target.send(text, sent, parent, channelId)
  } catch (err) {
    sendError.value = { key: sendFailureKey(err), err, text, files: sent, topicId: parent, channelId }
    composer.value?.restore(text, sent)
  }
}

async function retrySend() {
  const failed = sendError.value
  if (!failed) return
  await onSend(failed.text, failed.topicId, failed.files, failed.channelId)
}

/* the reader edited the text, or moved on: the old failure is not about what
   is in the box any more */
watch(() => route.fullPath, () => { sendError.value = null })

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
  /* This header is a column flex item of .app-frame. min-height:auto there
     is the content size and beats both height and max-height, so a tall
     omnibox would stretch the bar. Pin all three and do not grow. */
  height: var(--top-bar-h);
  min-height: var(--top-bar-h);
  max-height: var(--top-bar-h);
  flex: 0 0 var(--top-bar-h);
  /* 2px of this bar shows above the omnibox and 2px below it. The bottom
     1px of the bar is the border, so the bottom padding is 1px. */
  padding: var(--top-bar-inset-top) 12px var(--top-bar-inset-bottom);
  background: var(--color-sidebar);
  border-bottom: var(--top-bar-border) solid var(--color-border);
  max-width: 100%;
  min-width: 0;
  box-sizing: border-box;
  overflow: visible;
}
.top-bar__start {
  display: flex;
  align-items: center;
  gap: 4px;
  flex-shrink: 0;
  min-width: 0;
}
.top-bar__brand {
  font-size: 0.9375rem;
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
  display: flex;
  flex-direction: column;
  align-items: stretch;
  justify-content: flex-start;
  gap: 0;
  /* One-line slot, centred in the bar. min-height:0 stops the composer's
     content minimum from beating max-height; the composer then overflows
     this slot downward, over the page, and the bar stays put. */
  max-height: 100%;
  min-height: 0;
  overflow: visible;
  align-self: center;
}
.top-bar__omnibox > .composer {
  flex: 1 1 auto;
  flex-shrink: 0;
  min-width: 0;
  min-height: 0;
}
.top-bar__send-error {
  position: static;
  margin-top: 4px;
  z-index: 60;
  flex: 0 0 auto;
}
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
  .top-bar__omnibox { display: none; }
  .top-bar__search-toggle { display: inline-grid; place-items: center; }
  .top-bar--open .top-bar__omnibox {
    display: flex;
    flex-direction: row;
    align-items: flex-start;
    gap: 6px;
    position: absolute;
    z-index: 2;
    inset-inline: 0;
    top: 0;
    height: auto;
    max-height: none;
    max-width: 100%;
    padding: 4px 8px;
    background: var(--color-sidebar);
    border-bottom: 1px solid var(--color-border);
    box-sizing: border-box;
  }
  .top-bar--open .top-bar__send-error {
    position: absolute;
    top: 100%;
    inset-inline: 0;
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
