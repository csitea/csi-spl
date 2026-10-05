import { useSessionStore } from '~/stores/session'
import { useAuthClient } from '~/composables/useAuthClient'
import {
  SIDEBAR_DEFAULT,
  clampPair,
  clampSidebar,
  clampTopic,
  clearPaneWidths,
  loadPaneWidths,
  loadStoredTopic,
  mainWidthFor,
  paneSetFor,
  paneViews,
  savePaneWidths,
  topicDefaultFor,
  resetPane,
  sidebarRange,
  topicRange,
  sidebarShown,
  topicShown,
  viewOf,
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
  /* Spec 078 FR-006: null = never dragged; the pane then takes the
     proportional default, which follows the window. */
  const storedTopic = ref<number | null>(null)
  const session = useSessionStore()
  const auth = useAuthClient()
  /* Spec 078 FR-007: the view whose widths are in force (channel, issues,
     help, docs, else default). */
  const route = useRoute()
  const view = computed(() => viewOf(route.path))
  /* SPL-1182: the last fractions written to the account for a view, so a drag
     that ends where it began writes nothing (skip the no-op PUT). */
  let lastSaved: { view: string, sidebar: number, topic?: number } | null = null
  let commitTimer: ReturnType<typeof setTimeout> | null = null

  /* The topic width in force: the dragged one, else 40 % of the space right
     of the left pane (spec 078 FR-006). */
  const topicW = computed(() => storedTopic.value ?? topicDefaultFor(mainWidthFor(
    viewportW.value,
    clampSidebar(storedSidebar.value, { viewportW: viewportW.value, topicOpen: opts.topicOpen.value }),
  )))

  const ctx = computed(() => ({
    viewportW: viewportW.value,
    topicOpen: opts.topicOpen.value,
    sidebarW: storedSidebar.value,
    topicW: topicW.value,
  }))

  const displayed = computed(() => clampPair(
    storedSidebar.value,
    topicW.value,
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
    savePaneWidths({ sidebar: storedSidebar.value, topic: storedTopic.value }, undefined, view.value)
    scheduleCommit()
  }

  /* SPL-1182: the current widths as window fractions (screen-independent).
     An undragged topic is left out, so the account keeps the default too. */
  function fractions(): { sidebar: number, topic?: number } {
    const f: { sidebar: number, topic?: number } = { sidebar: FRAC(storedSidebar.value, viewportW.value) }
    if (storedTopic.value !== null) f.topic = FRAC(storedTopic.value, viewportW.value)
    return f
  }

  /* SPL-1182: keep the divider widths on the account, per (person, tenant),
     ONE PUT per gesture — a trailing debounce collapses the drag's stream of
     moves into a single write after it settles (owner: "save once on drag end,
     debounce it, skip if unchanged"). Only above the phone width; a failed
     save is left to the localStorage copy. Spec 078 FR-007: it writes only
     view v; the account's other views go back as they were (an old flat
     value goes back as default). */
  function commit(v: string = view.value) {
    if (commitTimer) { clearTimeout(commitTimer); commitTimer = null }
    if (session.state !== 'in' || viewportW.value <= PANE_ACCOUNT_MIN_W) return
    const f = fractions()
    if (lastSaved && lastSaved.view === v && lastSaved.sidebar === f.sidebar && lastSaved.topic === f.topic) return
    lastSaved = { view: v, ...f }
    const next = { ...paneViews(session.claims?.pane_sizes), [v]: f }
    session.setPaneSizes(next)
    void auth.savePaneSizes(next).catch(() => { lastSaved = null })
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
      topicW: topicW.value,
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
    storedTopic.value = null
    persist()
  }

  /* SPL-1182: "Reset pane sizes" — both dividers back to the default and clear
     the account override (the read then falls back to the product default). */
  function resetAll() {
    storedSidebar.value = resetPane('sidebar')
    storedTopic.value = null
    clearPaneWidths()
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
    const v = view.value
    const loaded = loadPaneWidths(undefined, v)
    const loadedTopic = loadStoredTopic(undefined, v)
    /* SPL-1182: on a wide screen a signed-in person's account override
       (fractions -> px, clamped) wins over this browser's localStorage, so a
       new device draws their kept layout. The result is written back to
       localStorage so the next load on this device paints it before hydrate.
       Spec 078 FR-007: the set is this view's, else the account's default. */
    const acct = paneSetFor(paneViews(session.claims?.pane_sizes), v)
    if (session.state === 'in' && acct && viewportW.value > PANE_ACCOUNT_MIN_W) {
      const sb = acct.sidebar ? Math.round(acct.sidebar * viewportW.value) : loaded.sidebar
      const tp = acct.topic ? Math.round(acct.topic * viewportW.value) : loadedTopic
      storedSidebar.value = clampSidebar(sb, { viewportW: viewportW.value, topicOpen: opts.topicOpen.value, topicW: tp ?? undefined })
      storedTopic.value = tp === null ? null : clampTopic(tp, { viewportW: viewportW.value, topicOpen: opts.topicOpen.value, sidebarW: storedSidebar.value })
      lastSaved = { view: v, ...fractions() } // where we are now = already on the account, so no re-save
      savePaneWidths({ sidebar: storedSidebar.value, topic: storedTopic.value }, undefined, v)
      return
    }
    storedSidebar.value = loaded.sidebar
    storedTopic.value = loadedTopic
  }

  /* Spec 078 FR-007: a view change first lands a pending drag on the view it
     was made in, then draws the new view's widths. */
  watch(view, (_next, prev) => {
    if (!import.meta.client) return
    if (commitTimer) commit(prev)
    hydrate()
  })

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
