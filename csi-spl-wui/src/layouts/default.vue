<!-- App frame, shaped like the donor WUI's layouts/default.vue: one contained
     .layout box (no document x-scroll), the page content, and the gated
     diagnostics panel LAST so the most recent technical error is literally the
     bottom-most content of the page. The spool shell (sidebar, feed, topic
     panes) stays client-only: it reads sessionStorage/localStorage and opens
     the live socket. Vertical pane dividers are pointer+keyboard resizers.
     022: the persistent top bar (Omnibox, language switcher, user menu) sits
     above the 3-pane shell, which fills the rest of the viewport.
     CLE-3429: exactly ONE topic section at a time (1..1) — see below.
     SPL-989: at <= 820 px ONE panel of the three shows (useMobileStack);
     data-mobile-level is what main.css reads, above 820 px nothing does. -->
<template>
  <div class="layout">
    <!-- 081 T006 (FR-007): the first Tab stop; Enter puts the focus in the
         middle pane (its selected card, else its first). The live region
         says the page after a navigation moved the focus (FR-009). -->
    <a class="skip-link" href="#" data-testid="skip-link" @click.prevent="skipToMsgs">{{ $t('pane.skip_to_msgs') }}</a>
    <div class="sr-only" role="status" aria-live="polite" data-testid="route-announce">{{ routeAnnounce }}</div>
    <ClientOnly>
      <div class="app-frame">
      <TopBar />
      <div
        class="spool-shell"
        style="max-width:100%;min-width:0"
        :style="shellStyle"
        :data-mobile-level="stack.level.value"
        :data-mobile-topic="topicPaneOpen ? '1' : undefined"
        :data-topic-browse="topicPage ? '1' : undefined"
        :data-mobile-section="sectionStrip ? '1' : undefined"
        :data-collapse-channels="collapse.collapsed.channels ? '1' : undefined"
        :data-collapse-topic="collapse.collapsed.topic ? '1' : undefined"
        :data-collapse-threads="collapse.collapsed.threads ? '1' : undefined"
        :data-filler="filler"
        @pointerdown.capture="paneFocus.noteEvent"
        @focusin="paneFocus.noteEvent"
        @touchstart.passive="stack.swipe.onTouchStart"
        @touchend.passive="stack.swipe.onTouchEnd"
      >
        <ChannelSidebar />
        <!-- 050: a collapsed panel is a strip, so resizing it makes no sense -
             hide the divider that would grow it (also while the middle is a
             strip, which overrides the widths). CLE-35099 owns show*Divider. -->
        <PaneDivider
          v-if="showSidebarDivider && !collapse.collapsed.channels && !collapse.collapsed.topic"
          pane="sidebar"
          :value="displayed.sidebar"
          :min="sidebarBounds.min"
          :max="sidebarBounds.max"
          @input="setSidebar"
          @reset="resetSidebar"
        />
        <template v-if="mountMain">
        <main class="spool-main">
          <slot />
          <!-- topic c6994436 (lane B): the bottom Omnibox dock - under the
               MIDDLE pane only. TopBar teleports its one composer here when
               Settings -> Behaviour says "at the bottom" (never on a phone).
               In the tree whenever this pane is mounted, so the Teleport
               has a target; it takes no room while empty. Phone level 1
               unmounts the pane (mountMain); a phone never docks here. -->
          <div
            :id="DOCK_ID"
            ref="dockEl"
            class="omnibox-dock"
            data-test="omnibox-dock"
            :data-on="dockOn ? 'true' : undefined"
          />
          <!-- 050: the middle (topic/messages) panel's collapse triangle, in its
               bottom corner. Kept a DIRECT child of .spool-main so the collapse
               CSS can hide every sibling and leave only this strip. -->
          <PaneCollapseToggle pane="topic" />
        </main>
        </template>
        <PaneDivider
          v-if="topicPaneOpen && showTopicDivider && !collapse.collapsed.threads && !collapse.collapsed.topic"
          pane="topic"
          :value="displayed.topic"
          :min="topicBounds.min"
          :max="topicBounds.max"
          @input="setTopic"
          @reset="resetTopic"
        />
        <!-- (1..1): ONE topic section, whichever store holds it.
             This v-if / v-else chain is the structural half of the invariant —
             the two panes can never both be in the tree, on any route, theme or
             width. Do NOT mount either of them a second time: utils/topic-pane
             is the only place allowed to decide which one renders. -->
        <LiveTopicPane v-if="section === LIVE" />
        <TopicPane v-else-if="section === CHANNEL" />
        <!-- spec 074 T008: the operator console, the third kind of the one section -->
        <OperatorPane v-else-if="section === OPERATOR" />
      </div>
      <!-- CLE-77888 (owner, t1 topic 1701ae89): on a phone, the desktop
           footer's dot, bell, note and version as a ~5 mm strip at the very
           bottom, under the docked composer -->
      <MobileStatusStrip v-if="stack.isMobile.value" />
      </div>
      <template #fallback>
        <!-- 047 W2: the prerendered shell is the document a stranger's first
             request gets, so the way in to /checkout rides in it -->
        <div class="login"><p class="muted">{{ $t('app.loading') }}</p><BuyWorkspaceLink /></div>
      </template>
    </ClientOnly>
    <!-- Renders only for a human who ticked "Debug pane" in Settings →
         Appearance (session claim `diagnostics_enabled`). SPL-1201: the gate is
         the outer v-if below, so everyone else neither downloads the async
         chunk nor mounts the panel. <ClientOnly> keeps it out of the prerender. -->
    <ClientOnly>
      <ErrorSnackbar />
    </ClientOnly>
    <!-- SPL-1024: "Moved to ... · Undo". CLE-77840: EAGER, like the archive
         one below - a lazy chunk is gone on a tab older than the last deploy,
         and chunk-reload then reloads the page instead of showing it -->
    <ClientOnly>
      <MoveUndoToast v-if="move.toast.value" />
    </ClientOnly>
    <!-- SPL-1264: "Archived · Undo". CLE-77840: EAGER, not Lazy - a lazy chunk
         is fetched on the first archive, and on a tab older than the last
         deploy that chunk is gone, so chunk-reload reloaded the page instead
         of showing it (owner: "cannot see this snackbar at all") -->
    <ClientOnly>
      <ArchiveUndoToast v-if="archiveUndo.toast.value" />
    </ClientOnly>
    <!-- HUM-10 ae2e5093: Shift + ? lists the message keyboard shortcuts; the
         chunk loads on the first Shift + ? only -->
    <ClientOnly>
      <LazyKindKeyHost />
      <LazyMsgShortcutsHelp v-if="shortcutsHelp" />
    </ClientOnly>
    <!-- 081 T004: Ctrl + K, the command palette; its chunk loads on the first open -->
    <ClientOnly><LazyCommandPalette v-if="globalKeys.paletteOpen.value" /></ClientOnly>
    <!-- spec 096: "Set a status"; its chunk loads on the first open -->
    <ClientOnly><LazyStatusPicker v-if="statusPicker.open.value" /></ClientOnly>
    <!-- CLE-77840: "Deleted · Undo" after Delete on a reply; eager like the archive one -->
    <ClientOnly>
      <DeleteUndoToast v-if="deleteUndo.toast.value" />
    </ClientOnly>
    <!-- CLE-77852: "Sent to <agent> as a direct message: not a member of
         this channel" after an @-mention of a seated non-member agent; eager
         for the same reason (CLE-77840) -->
    <ClientOnly>
      <MentionDirectToast v-if="mentionDirect.note.value" />
    </ClientOnly>
    <!-- 714c7028: "Merge topic (N messages) into Y?" when a topic is dropped
         on a topic; eager for the same reason (CLE-77840) -->
    <ClientOnly>
      <MergeConfirmDialog v-if="move.mergeAsk.value" />
    </ClientOnly>
    <!-- CLE-77882: "This message is gone or not yours to see" after an open-in-place; eager (CLE-77840) -->
    <ClientOnly>
      <OpenMessageToast v-if="openNotice.notice.value" />
    </ClientOnly>
    <ClientOnly>
      <DebugPanel v-if="debugAllowed" />
    </ClientOnly>
  </div>
</template>

<script setup lang="ts">
import { useStatusPicker } from '~/composables/useStatusPicker'
import { usePaneFocus } from '~/stores/pane-focus'
/* which pane the reader selected last decides where the Omnibox line goes */
const paneFocus = usePaneFocus()
/* SPL-1201: the debug pane is off for all but the rare human who ticked
   "Debug pane" (session claim diagnostics_enabled). Statically imported it
   rode in the shell chunk every reader downloads; async + gated on the same
   claim useErrorJournal reads, its chunk loads only for that human. */
const DebugPanel = defineAsyncComponent(() => import('@/components/common/DebugPanel.vue'))
import ErrorSnackbar from '@/components/common/ErrorSnackbar.vue'
import { useSessionStore } from '~/stores/session'
import { debugPanelVisibleFor } from '~/composables/debugAudience.mjs'
import TopBar from '@/components/TopBar.vue'
import BuyWorkspaceLink from '@/components/BuyWorkspaceLink.vue'
/* CLE-77888: phones only, so its chunk is fetched only there */
const MobileStatusStrip = defineAsyncComponent(() => import('@/components/MobileStatusStrip.vue'))
import PaneCollapseToggle from '@/components/PaneCollapseToggle.vue'
import { usePaneCollapse } from '~/stores/pane-collapse'
import { fillerPane } from '~/utils/pane-collapse.mjs'
import { isSectionPage } from '~/utils/section-strip.mjs'
import { productPath } from '~/utils/signed-out-redirect.mjs'
import { useTopicStore } from '~/stores/topic'
import { useLiveFeed } from '~/stores/live'
import { usePaneWidths } from '~/composables/usePaneWidths'
import { CHANNEL, LIVE, NONE, OPERATOR, closes, operatorCloses, routeLeavesTopic, topicSection } from '~/utils/topic-pane.mjs'
import { useOperatorPane } from '~/stores/operator-pane'
/* spec 074 T008: the operator console's chunk loads on its first open only */
const OperatorPane = defineAsyncComponent(() => import('@/components/OperatorPane.vue'))
import { useLive } from '~/composables/useLive'
import { useMessageEdit } from '~/composables/useMessageEdit'
import { topicFrameDrops, topicFrameRows, topicFrameTasks } from '~/utils/topic-archive.mjs'
import { useViewerStore } from '~/stores/viewer'
import { useMobileStack } from '~/composables/useMobileStack'
import { isMobileFrontDoor } from '~/utils/mobile-stack.mjs'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { shouldOpenHubSocket } from '~/utils/shell-bootstrap.mjs'
import { useOmniboxDock } from '~/composables/useOmniboxDock'
import { DOCK_ID } from '~/utils/omnibox-dock.mjs'
import { useMove } from '~/composables/useMove'
import { closeArchivedPane, useArchiveUndo } from '~/composables/useArchiveUndo'
import { useMsgShortcutsHelp } from '~/composables/useMsgShortcuts'
import { focusPane, useGlobalKeys } from '~/composables/useGlobalKeys'
import { MIDDLE, routeTakesFocus } from '~/utils/pane-focus.mjs'
import { useDeleteUndo } from '~/composables/useDeleteUndo'
import { useMentionDirectNote } from '~/composables/useMentionPoke'
import { useOpenMessageNotice } from '~/composables/useOpenMessage'
import { perfWhenIdle } from '~/utils/perf-idle.mjs'

const topic = useTopicStore()
/* SPL-1201: gate the (async) debug pane on the same claim it checks internally,
   so its chunk is fetched only for a human who turned it on. */
const session = useSessionStore()
const debugAllowed = computed(() => session.state === 'in' && debugPanelVisibleFor(session.claims ?? null))
/* 050: the collapsed state of the 3 vertical panels (shared Pinia store, also
   read by each panel's PaneCollapseToggle). Hydrated from localStorage on mount
   below; the shell is ClientOnly so there is no SSR read. */
const collapse = usePaneCollapse()
/* topic c6994436: the bottom dock under the middle pane is on */
const dockOn = useOmniboxDock()
/* its height, for the panes that overlay the middle one (main.css). A ref,
   not onMounted: <ClientOnly> renders the shell after this layout mounts. */
const dockEl = ref<HTMLElement | null>(null)
let dockObserver: ResizeObserver | null = null
function dockHeight() {
  const el = dockEl.value
  const px = dockOn.value && el ? Math.round(el.getBoundingClientRect().height) : 0
  document.documentElement.style.setProperty('--omnibox-dock-h', `${px}px`)
}
watch(dockEl, (el) => {
  dockObserver?.disconnect()
  dockObserver = null
  if (el && typeof ResizeObserver !== 'undefined') {
    dockObserver = new ResizeObserver(dockHeight)
    dockObserver.observe(el)
  }
  dockHeight()
})
watch(dockOn, () => { void nextTick(dockHeight) })
onUnmounted(() => {
  dockObserver?.disconnect()
  document.documentElement.style.removeProperty('--omnibox-dock-h')
})
const livePane = useLiveFeed('pane')
const operatorPane = useOperatorPane()
/* A delete from another tab drops the row from every store this shell holds. */
const live = useLive()
const { dropEverywhere } = useMessageEdit()
/* SPL-1024: another tab's topic_moved / message_moved frame moves the rows here too */
const move = useMove()
/* SPL-1264: the "Archived · Undo" snackbar this tab shows after archiving a card */
const archiveUndo = useArchiveUndo()
const deleteUndo = useDeleteUndo()
/* HUM-10 ae2e5093: Shift + ? opens the shortcuts list (useMsgShortcuts) */
const shortcutsHelp = useMsgShortcutsHelp()
/* 081 T004: the always-on keys (Ctrl + K) */
const globalKeys = useGlobalKeys()
/* spec 096: the status picker's open state (self row + avatar menu) */
const statusPicker = useStatusPicker()
const mentionDirect = useMentionDirectNote()
const openNotice = useOpenMessageNotice()
let offDeleted = () => {}
let offTopic = () => {}
/* t1 5108d85d: archiving a topic closes the right pane open on it */
const onArchived = (ev: Event) => closeArchivedPane((ev as CustomEvent).detail, live.lobbyTaskId.value)
/* SPL-996: a focusin chooses a pane only right after the reader's own
   navigation key (stores/pane-focus.ts); capture, so a handler that stops
   the key cannot hide it */
const noteKey = (ev: KeyboardEvent) => paneFocus.noteKey(ev)
onMounted(() => {
  collapse.load() /* 050: read the remembered collapsed state on the client */
  document.addEventListener('keydown', noteKey, true)
  window.addEventListener('spool:topic-archived', onArchived)
  offDeleted = live.onDeleted((m) => dropEverywhere(String(m.msg_id || '')))
  /* SPL-983: an archived card leaves the feeds; a deleted topic takes every
     row, and a pane open on one of its tasks has nothing left to show. */
  offTopic = live.onTopic((f) => {
    for (const id of topicFrameDrops(f)) dropEverywhere(id)
    /* SPL-986: and its row leaves the Topics / Flow lists */
    useViewerStore().dropTopics(topicFrameRows(f, live.lobbyTaskId.value))
    const gone = topicFrameTasks(f, live.lobbyTaskId.value)
    if (livePane.taskId && gone.includes(String(livePane.taskId))) livePane.close()
    if (topic.open && gone.includes(String(topic.parentTaskId || ''))) topic.close()
    move.dispatch(f)
  })
})
onUnmounted(() => { offDeleted(); offTopic(); window.removeEventListener('spool:topic-archived', onArchived); document.removeEventListener('keydown', noteKey, true) })
/* the single source of truth for which topic section is on screen. */
/* /t/:id mounts TopicPane inside the page. This shell must not open a
   third column or a second copy of that pane. route is declared here,
   before topicPaneOpen: stack.install reads it during setup. */
const route = useRoute()
const topicPage = computed(() => /^\/t\/[^/]+$/.test(productPath(route.path)))
const section = computed(() => topicPage.value ? NONE : topicSection({ paneTaskId: livePane.taskId, topicOpen: topic.open, operatorOpen: operatorPane.open }))
const topicPaneOpen = computed(() => section.value !== NONE)
/* 050: which panel absorbs the slack the fixed/collapsed panels leave, as a
   data-filler attribute the collapse CSS reads. Normally the middle feed. */
const filler = computed(() => fillerPane(collapse.collapsed, topicPaneOpen.value))

/* SPL-989: the phone stack. Level 3 follows either topic store; Back from it
   closes whichever is open, exactly as the pane's own Close does. */
const stack = useMobileStack()
stack.install({
  topicOpen: topicPaneOpen,
  closeTopic: () => { livePane.close(); topic.close(); operatorPane.close() },
})
/* E08 (perf 20261004): phone level 1 CSS-hides this pane (main.css,
   data-mobile-level="1") and the reader never sees its ~120 nodes. Unmount
   it. Levels 2 and 3, and every width above 820 px, keep it: level 3 hides
   the page with CSS so Back does not rebuild it, and a page's own right
   panel lives inside main. While the page is unmounted, this watch holds
   the topic-list follow the front door used to start. It returns at once
   while main is mounted, so a desktop leave still unfollows from the page. */
const mountMain = computed(() => !(stack.isMobile.value && stack.level.value === 1))
/* A cold load of /?topic= hydrates against the query-less prerender, so
   the first level is 1 and this pane is unmounted. The page that would
   open the right pane never mounts, and the pane never appears. Open it
   from here; level 3 then mounts the page. A phone home with no topic
   id stays unmounted. */
const frontTopic = useSettledQuery('topic')
watch(frontTopic.value, (id) => {
  if (!import.meta.client || !stack.isMobile.value) return
  if (!isMobileFrontDoor(route.path)) return
  if (!/^[0-9a-f-]{36}$/i.test(id)) return
  if (String(livePane.taskId || '') === id) return
  void livePane.open(id)
}, { immediate: true })
const frontApi = useSpoolApi()
const frontViewer = useViewerStore()
let frontStarted = false
watch([mountMain, () => frontApi.mock || String(session.state) === 'in'], ([mounted, ready]) => {
  if (mounted || !ready || !import.meta.client || frontStarted) return
  frontStarted = true
  void frontViewer.loadTopics().then(() => {
    if (shouldOpenHubSocket(session.state, frontApi.mock)) frontViewer.follow()
  })
}, { immediate: true, flush: 'post' })
/* CLE-77886 (owner, t1 topic ac0fa400): a section's own page on a phone
   (Issues, People, Help, ...) keeps the section strip on top, as level 1 does */
/* t1 6e21c7d8: on a phone the topic pane covers the page, so a link from a
   post to another page (an in-post /t/<id> link) closes it and the page it
   went to shows; Back returns to the post (its entry still holds ?topic=).
   Back / Forward never closes it here: history.listen sees only popstates. */
const router = useRouter()
let popNav = false
const offPop = router.options.history.listen(() => { popNav = true })
const offNav = router.afterEach((to, from, failure) => {
  const popstate = popNav
  popNav = false
  if (failure) return
  const nav = { mobile: stack.isMobile.value, open: topicPaneOpen.value, popstate, fromPath: from.path, toPath: to.path, toQuery: to.query }
  /* spec 078 FR-004, Q3: on desktop a section page or /search closes the
     right pane too, whichever section it holds (the operator console too) */
  if (routeLeavesTopic(nav)) { livePane.close(); topic.close(); operatorPane.close() }
  /* 081 T006 (FR-009): a navigation that is not Back / Forward puts the
     focus on the new middle pane's selected row or heading, once the page
     has rendered (page:finish), and the live region says its title */
  const initial = from.matched.length === 0
  if (routeTakesFocus({ ...nav, initial, typing: typingNow(), channelList: inChannelList() })) routeFocusDue = Date.now()
})
onUnmounted(() => { offPop(); offNav() })
/* spec 103 T005: the vim keys (h j k l, g g, G, Esc) - ONE global listener,
   imported on window idle so it, its store and its ring css stay out of the
   initial chunk (composables/useVimNavigation.ts) */
let offVim = () => {}
let vimGone = false
onMounted(() => perfWhenIdle(() => {
  import('~/composables/useVimNavigation').then((m) => {
    if (vimGone) return
    offVim = m.installVimNavigation({ claim: () => session.claims?.keyboard_shortcuts, phone: () => stack.isMobile.value, router })
  }).catch(() => { /* a chunk gone after a deploy: no vim keys on this tab */ })
}))
onUnmounted(() => { vimGone = true; offVim() })
/* 081 T006: the skip link and the focus after a route change */
const routeAnnounce = ref('')
let routeFocusDue = 0
const ROUTE_FOCUS_MS = 3000
function typingNow() {
  return Boolean(document.activeElement?.closest?.('textarea, input, select, [contenteditable="true"]'))
}
/* HUM-10 (t1 7d9e1681): a channel opened from its row keeps the focus there */
function inChannelList() {
  return Boolean(document.activeElement?.closest?.('#sidebar-panel-channels a.nav-item'))
}
function skipToMsgs() {
  focusPane(MIDDLE)
}
function focusAfterRoute() {
  if (!routeFocusDue || Date.now() - routeFocusDue > ROUTE_FOCUS_MS) return
  routeFocusDue = 0
  if (typingNow() || document.querySelector('[role="dialog"][aria-modal="true"], dialog[open]')) return
  if (!document.querySelector('.spool-main')?.contains(document.activeElement)) focusPane(MIDDLE, { firstRow: false })
  /* the head writes the new title a frame later; clear first so the same title is said again */
  routeAnnounce.value = ''
  setTimeout(() => { routeAnnounce.value = document.title }, 150)
}
const offPageFinish = useNuxtApp().hook('page:finish', () => { void nextTick(focusAfterRoute) })
onUnmounted(() => offPageFinish())
const sectionStrip = computed(() => stack.isMobile.value && stack.level.value === 2 && isSectionPage(route.path))

/* CLE-3429, the state half of 1..1: opening one section closes the other, so
   the section the reader opened LAST is the one they see. Without this a stale
   live pane would outrank a freshly opened channel topic and the click would
   look dead. `flush: 'sync'` so the losing store is cleared before the render
   that would otherwise show the wrong pane for one frame. Neither watcher can
   re-trigger the other: closing only ever writes the falsy side. */
watch(() => livePane.taskId, (id) => {
  if (id && closes(LIVE, { topicOpen: topic.open }) === CHANNEL) topic.close()
}, { flush: 'sync' })
watch(() => topic.open, (open) => {
  if (open && closes(CHANNEL, { paneTaskId: livePane.taskId }) === LIVE) livePane.close()
}, { flush: 'sync' })
/* spec 074 T008: the operator console takes the same slot, both ways */
watch(() => [Boolean(livePane.taskId), topic.open] as const, ([live, chan], [wasLive, wasChan]) => {
  const opened = (live && !wasLive) ? LIVE : (chan && !wasChan) ? CHANNEL : ''
  if (opened && operatorCloses(opened, { operatorOpen: operatorPane.open }).length) operatorPane.close()
}, { flush: 'sync' })
watch(() => operatorPane.open, (open) => {
  if (!open) return
  for (const s of operatorCloses(OPERATOR, { paneTaskId: livePane.taskId, topicOpen: topic.open })) {
    if (s === LIVE) livePane.close()
    if (s === CHANNEL) topic.close()
  }
}, { flush: 'sync' })

const {
  displayed,
  sidebarBounds,
  topicBounds,
  showSidebarDivider,
  showTopicDivider,
  shellStyle,
  setSidebar,
  setTopic,
  resetSidebar,
  resetTopic,
} = usePaneWidths({ topicOpen: topicPaneOpen })
</script>

<style scoped>
/* 081 T006: off screen until it holds the focus */
.skip-link {
  position: absolute;
  left: 0.5rem;
  top: -10rem;
  z-index: var(--z-overlay);
  padding: 0.5rem 0.75rem;
  border-radius: var(--radius-sm);
  background: var(--color-bg);
  color: var(--color-fg);
  box-shadow: var(--focus-3d);
}
.skip-link:focus {
  top: 0.5rem;
}
.layout {
  max-width: 100%;
  min-width: 0;
  height: 100%;
  max-height: 100%;
  display: flex;
  flex-direction: column;
  overflow: hidden;
}
</style>
