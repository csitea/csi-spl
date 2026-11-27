<!-- SPL-6675 (owner HUM-10, t1 bcfd15e1 msg 2f0259cc): the search results are
     their OWN panel. It slides open beside the icon rail when the Omnibox
     runs a search and closes with it; it is not the sidebar's list (the
     channels, the calendar months, the contacts), which keeps its own width
     and hides while this is open (ChannelSidebar searchShut). Wider than that
     list by default (SEARCH_W_FRAC of the window), resizable by its divider
     (kept in this browser). On a phone it covers the page under the bar and
     the section strip (SPL-6702: the strip stays painted at every level,
     SPL-3785). -->
<template>
  <aside
    v-show="!search.asideFrom"
    class="search-panel"
    :class="{ 'search-panel--phone': phone }"
    :style="phone ? phoneTop : { width: width + 'px' }"
    data-testid="search-panel"
    :data-q="search.q"
    :aria-label="t('search.title')"
  >
    <LazySearchSidePanel ref="body" @close="search.closePanel()" />
  </aside>
  <PaneDivider
    v-if="!phone"
    pane="search"
    :value="width"
    :min="bounds.min"
    :max="bounds.max"
    @input="setWidth"
    @reset="resetWidth"
  />
</template>

<script setup lang="ts">
import { useSearchStore } from '~/stores/search'
import { useMobileStack } from '~/composables/useMobileStack'
import { SEARCH_W_KEY, searchPanelBounds, searchPanelDefault, clampSearchPanel } from '~/utils/search-panel'
import { storageGetJson, storageSetJson } from '~/utils/prefs.mjs'

const { t } = useI18n({ useScope: 'global' })
const search = useSearchStore()
const phone = useMobileStack().isMobile
/* a phone tap stepped the panel aside: Back to that page brings it back.
   The router's own route: useRoute() in the layout lags a Back (Nuxt syncs
   it on page:finish), and the panel then stayed hidden. */
const router = useRouter()
watch(() => router.currentRoute.value.fullPath, (p) => search.routeAt(p))

const viewportW = ref(typeof window !== 'undefined' ? window.innerWidth : 1280)
const stored = ref<number | null>(null)
function onResize() { viewportW.value = window.innerWidth; placeUnderStrip() }

/* SPL-6702 (SPL-3785, owner HUM-10, t1 c3e53990 msg 1f55e7e1: once in a
   section the strip "should always be shown"): on a phone the panel starts
   under the section strip, never over it. The strip moves (the bars slide
   away on a scroll, the keyboard folds it, the dock goes to the top), so its
   bottom is read again on each of those, once per frame. The first read is
   synchronous: a page that is not visible runs no animation frame, and the
   panel then sat over the strip (R7 c-094 W1); a hidden page reads at once
   and again when it is shown. The rail itself is watched too, so a rail that
   mounts or resizes later still moves the panel (W2). No strip painted: the
   panel starts under the top bar as before. */
const stripBottom = ref<number | null>(null)
const phoneTop = computed(() => (stripBottom.value === null ? undefined : { top: stripBottom.value + 'px' }))
let placeFrame = 0
let railSeen: Element | null = null
let railObs: ResizeObserver | null = null
function readStrip() {
  if (!phone.value) return
  const rail = document.querySelector('[data-testid=sidebar-rail]')
  if (rail !== railSeen) {
    railObs?.disconnect()
    railSeen = rail
    if (rail && railObs) railObs.observe(rail)
  }
  const r = rail?.getBoundingClientRect()
  stripBottom.value = r && r.width > 0 && r.height > 0 ? Math.max(0, r.bottom) : null
}
function placeUnderStrip() {
  if (!phone.value || placeFrame) return
  if (document.visibilityState === 'hidden') { readStrip(); return }
  placeFrame = requestAnimationFrame(() => { placeFrame = 0; readStrip() })
}
let shellObs: MutationObserver | null = null
watch(phone, placeUnderStrip)
watch(() => router.currentRoute.value.fullPath, placeUnderStrip)

onMounted(() => {
  const v = storageGetJson(SEARCH_W_KEY, null)
  stored.value = typeof v === 'number' && Number.isFinite(v) ? v : null
  window.addEventListener('resize', onResize, { passive: true })
  document.addEventListener('transitionend', placeUnderStrip, { capture: true, passive: true })
  document.addEventListener('visibilitychange', placeUnderStrip)
  shellObs = new MutationObserver(placeUnderStrip)
  for (const el of document.querySelectorAll('.app-frame, .spool-shell')) shellObs.observe(el, { attributes: true })
  if (typeof ResizeObserver !== 'undefined') railObs = new ResizeObserver(placeUnderStrip)
  readStrip()
  nextTick(placeUnderStrip)
})
onBeforeUnmount(() => {
  window.removeEventListener('resize', onResize)
  document.removeEventListener('transitionend', placeUnderStrip, { capture: true })
  document.removeEventListener('visibilitychange', placeUnderStrip)
  shellObs?.disconnect()
  railObs?.disconnect()
  if (placeFrame) cancelAnimationFrame(placeFrame)
})

const bounds = computed(() => searchPanelBounds(viewportW.value))
const width = computed(() => clampSearchPanel(stored.value ?? searchPanelDefault(viewportW.value), viewportW.value))
function setWidth(n: number) {
  stored.value = clampSearchPanel(n, viewportW.value)
  storageSetJson(SEARCH_W_KEY, stored.value)
}
function resetWidth() {
  stored.value = null
  storageSetJson(SEARCH_W_KEY, null)
}
</script>

<style scoped>
.search-panel {
  flex: 0 0 auto;
  min-width: 0;
  min-height: 0;
  display: flex;
  flex-direction: column;
  background: var(--color-sidebar);
  border-inline-end: 1px solid var(--color-border);
  overflow: clip;
  animation: search-panel-in 160ms ease-out;
}
@keyframes search-panel-in {
  from { transform: translateX(-24px); opacity: 0; }
  to { transform: none; opacity: 1; }
}
@media (prefers-reduced-motion: reduce) {
  .search-panel { animation: none; }
}
.search-panel--phone {
  position: fixed;
  inset: var(--top-bar-h, 0px) 0 0 0;
  z-index: var(--z-sticky);
  width: auto;
  border: 0;
}
</style>
