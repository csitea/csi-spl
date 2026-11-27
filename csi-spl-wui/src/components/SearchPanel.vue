<!-- SPL-6675 (owner HUM-10, t1 bcfd15e1 msg 2f0259cc): the search results are
     their OWN panel. It slides open beside the icon rail when the Omnibox
     runs a search and closes with it; it is not the sidebar's list (the
     channels, the calendar months, the contacts), which keeps its own width
     and hides while this is open (ChannelSidebar searchShut). Wider than that
     list by default (SEARCH_W_FRAC of the window), resizable by its divider
     (kept in this browser). On a phone it covers the page, under the bar. -->
<template>
  <aside
    v-show="!search.asideFrom"
    class="search-panel"
    :class="{ 'search-panel--phone': phone }"
    :style="phone ? undefined : { width: width + 'px' }"
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
function onResize() { viewportW.value = window.innerWidth }
onMounted(() => {
  const v = storageGetJson(SEARCH_W_KEY, null)
  stored.value = typeof v === 'number' && Number.isFinite(v) ? v : null
  window.addEventListener('resize', onResize, { passive: true })
})
onBeforeUnmount(() => window.removeEventListener('resize', onResize))

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
