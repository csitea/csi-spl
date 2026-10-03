import { useSessionStore } from '~/stores/session'
import { useAuthClient } from '~/composables/useAuthClient'
import {
  SIDEBAR_DEFAULT,
  TOPIC_DEFAULT,
  clampPair,
  clampSidebar,
  clampTopic,
  loadPaneWidths,
  savePaneWidths,
  resetPane,
  sidebarRange,
  topicRange,
  sidebarShown,
  topicShown,
} from '~/utils/pane-widths.mjs'
import { MOBILE_STACK_MAX_PX } from '~/utils/mobile-stack.mjs'

/* SPL-1182: below this width the layout is one pane (phone); pane sizes are
   neither saved to nor read from the account. */
const PANE_ACCOUNT_MIN_W = MOBILE_STACK_MAX_PX
/* fractions are rounded here so "did it change?" is stable and the payload small. */
const FRAC = (px: number, w: number) => (w > 0 ? Math.round((px / w) * 1e4) / 1e4 : 0)

export function usePaneWidths(opts: {
  topicOpen: Ref<boolean>
}) {
  const viewportW = ref(import.meta.client && typeof window !== 'undefined' ? window.innerWidth : 1280)
  const storedSidebar = ref(SIDEBAR_DEFAULT)
  const storedTopic = ref(TOPIC_DEFAULT)
  const session = useSessionStore()
  const auth = useAuthClient()
  /* SPL-1182: the last fractions written to the account, so a drag that ends
     where it began writes nothing (skip the no-op PUT). */
  let lastSaved: { sidebar: number, topic: number } | null = null
  let commitTimer: ReturnType<typeof setTimeout> | null = null

  const ctx = computed(() => ({
    viewportW: viewportW.value,
    topicOpen: opts.topicOpen.value,
    sidebarW: storedSidebar.value,
    topicW: storedTopic.value,
  }))

  const displayed = computed(() => clampPair(
    storedSidebar.value,
    storedTopic.value,
    { viewportW: viewportW.value, topicOpen: opts.topicOpen.value },
  ))

  const sidebarBounds = computed(() => sidebarRange({
    ...ctx.value,
    topicW: displayed.value.topic,
  }))
  const topicBounds = computed(() => topicRange({
    ...ctx.value,
    sidebarW: displayed.value.sidebar,
  }))

  const showSidebarDivider = computed(() => sidebarShown(viewportW.value))
  const showTopicDivider = computed(() => topicShown(viewportW.value, opts.topicOpen.value))

  const shellStyle = computed(() => ({
    '--sidebar-w': `${displayed.value.sidebar}px`,
    '--topic-w': `${displayed.value.topic}px`,
  }))

  function persist() {
    savePaneWidths({ sidebar: storedSidebar.value, topic: storedTopic.value })
    scheduleCommit()
  }

  /* SPL-1182: the current widths as window fractions (screen-independent). */
  function fractions() {
    return { sidebar: FRAC(storedSidebar.value, viewportW.value), topic: FRAC(storedTopic.value, viewportW.value) }
  }

  /* SPL-1182: keep the divider widths on the account, per (person, tenant),
     ONE PUT per gesture — a trailing debounce collapses the drag's stream of
     moves into a single write after it settles (owner: "save once on drag end,
     debounce it, skip if unchanged"). Only above the phone width; a failed
     save is left to the localStorage copy. */
  function commit() {
    if (commitTimer) { clearTimeout(commitTimer); commitTimer = null }
    if (session.state !== 'in' || viewportW.value <= PANE_ACCOUNT_MIN_W) return
    const f = fractions()
    if (lastSaved && lastSaved.sidebar === f.sidebar && lastSaved.topic === f.topic) return
    lastSaved = f
    session.setPaneSizes(f)
    void auth.savePaneSizes(f).catch(() => { lastSaved = null })
  }

  function scheduleCommit() {
    if (!import.meta.client) return
    if (commitTimer) clearTimeout(commitTimer)
    commitTimer = setTimeout(commit, 500)
  }

  function setSidebar(n: number) {
    storedSidebar.value = clampSidebar(n, {
      viewportW: viewportW.value,
      topicOpen: opts.topicOpen.value,
      topicW: storedTopic.value,
    })
    persist()
  }

  function setTopic(n: number) {
    storedTopic.value = clampTopic(n, {
      viewportW: viewportW.value,
      topicOpen: opts.topicOpen.value,
      sidebarW: storedSidebar.value,
    })
    persist()
  }

  function resetSidebar() {
    storedSidebar.value = resetPane('sidebar')
    persist()
  }

  function resetTopic() {
    storedTopic.value = resetPane('topic')
    persist()
  }

  /* SPL-1182: "Reset pane sizes" — both dividers back to the default and clear
     the account override (the read then falls back to the product default). */
  function resetAll() {
    storedSidebar.value = resetPane('sidebar')
    storedTopic.value = resetPane('topic')
    savePaneWidths({ sidebar: storedSidebar.value, topic: storedTopic.value })
    if (commitTimer) { clearTimeout(commitTimer); commitTimer = null }
    if (session.state === 'in') {
      lastSaved = null
      session.setPaneSizes(null)
      void auth.savePaneSizes(null).catch(() => {})
    }
  }

  function onResize() {
    if (typeof window === 'undefined') return
    viewportW.value = window.innerWidth
  }

  /* perf round 4 W3: no geometry read at mount. viewportW was read in setup,
     before this component's DOM went in; reading innerWidth again here, in
     onMounted, forced a synchronous layout of the whole freshly mounted shell
     (62.7..65.8 ms self on /issues, m390 CPU 4x). A later width change comes
     through the resize listener. */
  function hydrate() {
    const loaded = loadPaneWidths()
    /* SPL-1182: on a wide screen a signed-in person's account override
       (fractions -> px, clamped) wins over this browser's localStorage, so a
       new device draws their kept layout. The result is written back to
       localStorage so the next load on this device paints it before hydrate. */
    const acct = session.claims?.pane_sizes
    if (session.state === 'in' && acct && viewportW.value > PANE_ACCOUNT_MIN_W) {
      const sb = acct.sidebar ? Math.round(acct.sidebar * viewportW.value) : loaded.sidebar
      const tp = acct.topic ? Math.round(acct.topic * viewportW.value) : loaded.topic
      storedSidebar.value = clampSidebar(sb, { viewportW: viewportW.value, topicOpen: opts.topicOpen.value, topicW: tp })
      storedTopic.value = clampTopic(tp, { viewportW: viewportW.value, topicOpen: opts.topicOpen.value, sidebarW: storedSidebar.value })
      lastSaved = fractions() // where we are now = already on the account, so no re-save
      savePaneWidths({ sidebar: storedSidebar.value, topic: storedTopic.value })
      return
    }
    storedSidebar.value = loaded.sidebar
    storedTopic.value = loaded.topic
  }

  onMounted(() => {
    hydrate()
    window.addEventListener('resize', onResize)
  })
  onUnmounted(() => {
    if (commitTimer) clearTimeout(commitTimer)
    window.removeEventListener('resize', onResize)
    document.documentElement.classList.remove('pane-dragging')
  })

  return {
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
    resetAll,
    hydrate,
  }
}
