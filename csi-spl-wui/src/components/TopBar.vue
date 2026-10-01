<!-- 022 FR-001..003: the persistent top strip. Tenant drop box + theme
     (owner 2026-09-27: no brand text) | the Omnibox (the one
     MessageComposer, so the ``` code-block composer works in it; plain text
     goes to the page's send target, `/search <q>` opens /search?q=) | the
     language switcher + the user menu (the former .app-corner, CLE-3402 /
     spec 021).
     SPL-990 (<= 820 px, the mobile revamp): ONE compact row - the tenant
     switcher (SPL-995: a drop box opening a bottom sheet) ... the avatar
     menu (Back is M1's MobileBack in each pane header). The omnibox leaves
     the row: SPL-1005 (owner, topic 9b58a27b) retired E's floating GO at the
     middle of the right edge and its full-screen sheet - the composer is
     docked at the bottom on EVERY phone level, its bottom-right Send is the
     GO, and `/search` is typed there. The theme, language and notification
     controls live in the avatar menu's bottom sheet. Above 820 px nothing
     here renders differently. -->
<template>
  <header class="top-bar" :class="{ 'top-bar--bottom': atBottom }" data-test="top-bar">
    <div class="top-bar__start" data-test="top-bar-start">
      <!-- owner 2026-09-27: the spool-hub brand text is gone (topic d5504c2b).
           The logo (topic 38ba1dae: the owner's own image, a human and an
           AI in one glowing net) comes first, small; a click opens it at its
           true size in a centred dialog with the slogan (LogoDialog). Then
           the tenant drop box, just before the theme icon. -->
      <button type="button" class="top-bar__logo" data-test="top-bar-logo" :aria-label="t('logo.open')" :title="t('logo.open')" @click="logoOpen = true">
        <img src="/logo.webp" alt="" width="28" height="28" decoding="async">
      </button>
      <LazyLogoDialog v-if="logoOpen" v-model:open="logoOpen" />
      <TenantDropBox />
      <ThemeToggle />
    </div>
    <!-- SPL-995: the tenant switcher, first in the phone row -->
    <TopBarTenant class="top-bar__tenant" />
    <!-- topic c6994436 (lane B): Settings -> Behaviour "at the bottom" moves
         this same box, not a copy, into the dock under the middle pane
         (layouts/default.vue). A Teleport keeps the draft, the picked files
         and the send error across the move. `defer`: the dock renders after
         this bar. The bar keeps one button that puts `/search ` in it. -->
    <button
      v-if="atBottom"
      type="button"
      class="top-bar__search icon-btn"
      data-test="top-bar-search"
      :aria-label="t('search.title')"
      :title="t('search.title')"
      @click="openSearch"
    ><UiIcon name="search" :size="18" /></button>
    <Teleport :to="dockSelector" :disabled="!atBottom" defer>
    <div class="top-bar__omnibox" :class="{ 'top-bar__omnibox--bottom': atBottom }" data-test="top-bar-omnibox" :data-position="atBottom ? 'bottom' : undefined">
      <MessageComposer
        ref="composer"
        omnibox
        global
        :placeholder="placeholder"
        :busy="busy"
        :send-blocked="!omnibox.target"
        :dock-target="dockTarget"
        :bottom="atBottom"
        :operators="search.operators"
        @send="onSend"
        @search="onSearch"
        @results="omnibox.focusResults++"
        @ready="onComposerReady"
      />
      <p :id="slashHintId" class="sr-only" data-test="slash-shortcut-hint">{{ t('search.slash_shortcut') }}</p>
      <!-- a send that did not land says so HERE, next to the box
           that still holds the text, and offers the one action that helps -->
      <ErrorNotice
        v-if="sendError"
        class="top-bar__send-error"
        :message="t(sendError.key)"
        :error="sendError.err"
        source="omnibox-send"
        test-id="omnibox-send-error"
      >
        <template #detail>
          <button type="button" class="btn ghost" data-test="omnibox-send-retry" @click="retrySend">
            {{ t('composer.send_retry') }}
          </button>
        </template>
      </ErrorNotice>
    </div>
    </Teleport>
    <div class="top-bar__end app-corner" data-test="app-corner">
      <div class="top-bar__lang"><LanguageSwitcher /></div>
      <UserMenu />
    </div>
  </header>
</template>

<script setup lang="ts">
/* Async: its Combobox pulls @headlessui/vue + @tanstack/virtual-core
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
import TopBarTenant from '~/components/TopBarTenant.vue'
import TenantDropBox from '~/components/TenantDropBox.vue'
import { useOmniboxDock } from '~/composables/useOmniboxDock'
import { DOCK_ID } from '~/utils/omnibox-dock.mjs'

const { t } = useI18n({ useScope: 'global' })
const localePath = useLocalePath()
const router = useRouter()
const route = useRoute()
const omnibox = useOmniboxStore()
/* topic 38ba1dae: the logo's true-size dialog, mounted only once asked for */
const logoOpen = ref(false)
const search = useSearchStore()
const session = useSessionStore()
const api = useSpoolApi()
const composer = ref<InstanceType<typeof MessageComposer> | null>(null)
const slashHintId = useId()
const restoreEl = ref<HTMLElement | null>(null)
/* topic c6994436: the Omnibox's place (Settings -> Behaviour), never on a phone */
const atBottom = useOmniboxDock()
const dockSelector = `#${DOCK_ID}`
/* the bar's search button: the box is at the bottom now, `/search ` goes in it */
function openSearch() {
  composer.value?.setText('/search ')
  composer.value?.focus()
}

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
/* SPL-1003: the page's answer to "where does the next post go" (the dock's hint) */
const dockTarget = computed(() => {
  const dock = omnibox.target && omnibox.target.dock ? omnibox.target.dock() : null
  /* HUM-24: a reply names the open thread ("Reply in: <title>") */
  return dock && dock.reply && omnibox.threadTitle ? { ...dock, title: omnibox.threadTitle } : dock
})
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


/* a deep link /search?q=… shows its query in the Omnibox, ready to refine */
const onSearchPage = computed(() => /\/search$/.test(route.path))
function showQuery(box: { setText: (s: string) => void } | null = composer.value) {
  const q = route.query.q
  if (onSearchPage.value && typeof q === 'string' && q) box?.setText(`/search ${q}`)
}
watch(() => [onSearchPage.value, route.query.q], () => showQuery(), { flush: 'post' })
/* topic c6994436: the Teleport is `defer`red (Vue 3.5 defers it even while
   disabled), so the composer mounts AFTER this bar's onMounted - and a
   re-render can mount it a second time before `composer` points at the new
   one. A deep link's query goes to the box that says it is ready. */
function onComposerReady(box: { setText: (s: string) => void }) {
  showQuery(box)
}
/* SPL-13: leaving /search takes its query out of the Omnibox. Left there, the
   `/search …` line kept search mode on every page, and search mode has no
   Attach and no Send - the owner read that as "the attach button is gone". */
watch(onSearchPage, (now, was) => { if (was && !now) composer.value?.leaveSearch() }, { flush: 'post' })

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
.top-bar__logo {
  display: inline-flex;
  flex: 0 0 auto;
  padding: 0;
  border: 0;
  background: none;
  cursor: pointer;
  border-radius: var(--radius-sm);
}
.top-bar__logo img { display: block; width: 28px; height: 28px; border-radius: var(--radius-sm); transition: transform 140ms ease-out, filter 140ms ease-out; }
/* SPL-1150: the logo answers the pointer - a small lift and glow; the
   keyboard ring is the one global :focus-visible rule (main.css) */
.top-bar__logo:hover img,
.top-bar__logo:focus-visible img { transform: scale(1.08); filter: brightness(1.12) drop-shadow(0 0 6px var(--color-accent)); }
.top-bar__logo:active img { transform: scale(0.96); }
@media (prefers-reduced-motion: reduce) {
  .top-bar__logo img { transition: none; }
  .top-bar__logo:hover img,
  .top-bar__logo:focus-visible img,
  .top-bar__logo:active img { transform: none; }
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
.top-bar__end {
  display: flex;
  align-items: center;
  gap: 6px;
  flex-shrink: 0;
  min-width: 0;
}
/* topic c6994436: the box moved to the bottom dock - the bar keeps its
   height (every offset under it stays), the end group keeps its corner */
.top-bar--bottom .top-bar__end { margin-inline-start: auto; }
.top-bar__search { flex: 0 0 auto; }
/* In the dock (teleported under the middle pane): no one-line slot, full
   pane width, and the send error sits ABOVE the box, next to the feed */
.top-bar__omnibox--bottom {
  flex: none;
  max-width: none;
  max-height: none;
  margin: 0;
  align-self: stretch;
}
.top-bar__omnibox--bottom .top-bar__send-error { order: -1; margin: 0 0 4px; }
/* SPL-990: phone-only parts; above 820 px they take no space at all */
.top-bar__tenant { display: none; }
.top-bar__lang { display: contents; }

/* SPL-990 (was FR-003 at 640 px): phones and small tablets. One compact
   row: tenant | search | avatar. The Omnibox is no longer in
   the row: with a send target the composer docks at the bottom (M3,
   MessageComposer `dock`), without one it is hidden; the search icon opens
   it as a full-screen sheet with the composer and its GO at the top. */
@media (max-width: 820px) {
  /* viewport-fit=cover: the bar reaches under the status bar / notch. The
     insets are 0 without a notch; M1's --top-bar-h carries the top one. */
  .top-bar {
    gap: 4px;
    padding-top: calc(var(--top-bar-inset-top) + env(safe-area-inset-top, 0px));
    padding-inline: calc(4px + env(safe-area-inset-left, 0px)) calc(8px + env(safe-area-inset-right, 0px));
  }
  .top-bar__lang { display: none; }
  /* SPL-1025 (owner, topic f8950b7f): [logo] [tenant ▾] ... [avatar]. Of the
     start group only the logo stays - the same 28 px image in a 44 px target;
     the desktop drop box hides itself here and the theme is in the avatar menu */
  .top-bar__start { flex: 0 0 auto; gap: 0; }
  .top-bar__start > .theme-picker { display: none; }
  .top-bar__logo { align-items: center; justify-content: center; min-width: var(--tap); min-height: var(--tap); }
  /* SPL-995: [tenant ▾] ... [avatar]; the box hugs the name and shrinks to
     an ellipsis before anything else moves */
  .top-bar__tenant {
    display: flex;
    flex: 0 1 auto;
    min-width: var(--tap);
    max-width: min(20rem, 100%);
  }
  .top-bar__end { margin-inline-start: auto; }
  .top-bar__omnibox { display: none; }
  /* display:contents, never none, while M3's composer is docked: a
     display:none ancestor would hide the fixed bottom dock too. Keyed on the
     composer's own class (SPL-1005: the composer docks on every phone level). */
  .top-bar__omnibox:has(> .composer--dock) { display: contents; }
  .top-bar__send-error {
    position: fixed;
    inset-inline: 8px;
    bottom: calc(var(--kb-inset, 0px) + var(--composer-dock-h, 0px) + 8px);
    margin: 0;
  }
}
</style>
