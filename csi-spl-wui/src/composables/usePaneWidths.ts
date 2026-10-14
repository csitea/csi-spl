import { useSessionStore } from '~/stores/session'
import { useAuthClient } from '~/composables/useAuthClient'
import {
  PANE_WIDTHS_KEY,
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
import { storageGetJson, storageSetJson } from '~/utils/prefs.mjs'

/* SPL-1182: below this width the layout is one pane (phone); pane sizes are
   neither saved to nor read from the account. */
const PANE_ACCOUNT_MIN_W = MOBILE_STACK_MAX_PX
/* fractions are rounded here so "did it change?" is stable and the payload small. */
const FRAC = (px: number, w: number) => (w > 0 ? Math.round((px / w) * 1e4) / 1e4 : 0)

type PaneOpts = { topicOpen: Ref<boolean> }

/* The widths in force and where they come from: the view, the session, the
   window, and what this browser or the account stored. */
function paneState(opts: PaneOpts) {
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
  /* The topic width in force: the dragged one, else 40 % of the space right
     of the left pane (spec 078 FR-006). */
  const topicW = computed(() => storedTopic.value ?? topicDefaultFor(mainWidthFor(
    viewportW.value,
    clampSidebar(storedSidebar.value, { viewportW: viewportW.value, topicOpen: opts.topicOpen.value }),
  )))
  return { opts, viewportW, storedSidebar, storedTopic, session, auth, view, topicW }
}
type PaneState = ReturnType<typeof paneState>

/* What the shell draws: the clamped pair, each divider's range and the CSS vars. */
function paneLayout(s: PaneState) {
  const { opts, viewportW, storedSidebar, topicW } = s
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
  return { displayed, sidebarBounds, topicBounds, showSidebarDivider, showTopicDivider, shellStyle }
}

/* SPL-1182: the current widths as window fractions (screen-independent).
   An undragged topic is left out, so the account keeps the default too. */
function paneFractions(s: PaneState): { sidebar: number, topic?: number } {
  const f: { sidebar: number, topic?: number } = { sidebar: FRAC(s.storedSidebar.value, s.viewportW.value) }
  if (s.storedTopic.value !== null) f.topic = FRAC(s.storedTopic.value, s.viewportW.value)
  return f
}

/* perf round 4 W3: no geometry read at mount. viewportW was read in setup,
   before this component's DOM went in; reading innerWidth again here, in
   onMounted, forced a synchronous layout of the whole freshly mounted shell
   (62.7..65.8 ms self on /issues, m390 CPU 4x). A later width change comes
   through the resize listener. Returns true when the account's set won. */
function hydratePanes(s: PaneState): boolean {
  const { opts, viewportW, storedSidebar, storedTopic, session } = s
  const v = s.view.value
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
    savePaneWidths({ sidebar: storedSidebar.value, topic: storedTopic.value }, undefined, v)
    return true
  }
  storedSidebar.value = loaded.sidebar
  storedTopic.value = loadedTopic
  return false
}

/* The account copy of the widths: the debounced save, the full reset, the
   hydrate that marks the account's set as already saved, and the view watch. */
function paneAccount(s: PaneState) {
  const { viewportW, storedSidebar, storedTopic, session, auth, view } = s
  /* SPL-1182: the last fractions written to the account for a view, so a drag
     that ends where it began writes nothing (skip the no-op PUT). */
  let lastSaved: { view: string, sidebar: number, topic?: number } | null = null
  let commitTimer: ReturnType<typeof setTimeout> | null = null

  function persist() {
    savePaneWidths({ sidebar: storedSidebar.value, topic: storedTopic.value }, undefined, view.value)
    scheduleCommit()
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
    const f = paneFractions(s)
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

  function hydrate() {
    const v = view.value
    // where we are now = already on the account, so no re-save
    if (hydratePanes(s)) lastSaved = { view: v, ...paneFractions(s) }
  }

  /* Spec 078 FR-007: a view change first lands a pending drag on the view it
     was made in, then draws the new view's widths. */
  watch(view, (_next, prev) => {
    if (!import.meta.client) return
    if (commitTimer) commit(prev)
    hydrate()
  })

  function stop() {
    if (commitTimer) clearTimeout(commitTimer)
  }
  return { persist, resetAll, hydrate, stop }
}

/* The divider gestures: a drag or a key sets a width, a double click resets it. */
function paneSetters(s: PaneState, persist: () => void) {
  const { opts, viewportW, storedSidebar, storedTopic, topicW } = s
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
  return { setSidebar, setTopic, resetSidebar, resetTopic }
}

export function usePaneWidths(opts: PaneOpts) {
  const s = paneState(opts)
  const layout = paneLayout(s)
  const account = paneAccount(s)
  const setters = paneSetters(s, account.persist)

  function onResize() {
    if (typeof window === 'undefined') return
    s.viewportW.value = window.innerWidth
  }

  onMounted(() => {
    account.hydrate()
    window.addEventListener('resize', onResize)
  })
  onUnmounted(() => {
    account.stop()
    window.removeEventListener('resize', onResize)
    document.documentElement.classList.remove('pane-dragging')
  })

  return {
    displayed: layout.displayed,
    sidebarBounds: layout.sidebarBounds,
    topicBounds: layout.topicBounds,
    showSidebarDivider: layout.showSidebarDivider,
    showTopicDivider: layout.showTopicDivider,
    shellStyle: layout.shellStyle,
    setSidebar: setters.setSidebar,
    setTopic: setters.setTopic,
    resetSidebar: setters.resetSidebar,
    resetTopic: setters.resetTopic,
    resetAll: account.resetAll,
    hydrate: account.hydrate,
  }
}

/* SPL-1857 (owner HUM-10, t1 6b980c46 msg 4f8d5e43): the Qto doc view's
   tree | doc bar drags "the same ways as the panel for the channels, or the
   issues". One more pane key, nothing above changes: the tree takes the
   channel sidebar's clamp (clampSidebar / sidebarRange) and a PaneDivider
   pane="sidebar" drives it; its width is kept on this device beside the
   other pane widths, key docsTree (as the issue detail keeps `issues`). */
function storedPanes(): Record<string, unknown> {
  const raw = storageGetJson(PANE_WIDTHS_KEY, null)
  return raw && typeof raw === 'object' && !Array.isArray(raw) ? raw : {}
}

export function useDocsTreeWidth() {
  const viewportW = ref(1280)
  const width = ref(SIDEBAR_DEFAULT)
  const ctx = () => ({ viewportW: viewportW.value, topicOpen: false })
  const shown = computed(() => clampSidebar(width.value, ctx()))
  const bounds = computed(() => sidebarRange(ctx()))

  function save(n?: number) {
    const { docsTree: _old, ...rest } = storedPanes()
    storageSetJson(PANE_WIDTHS_KEY, n === undefined ? rest : { ...rest, docsTree: n })
  }
  function set(n: number) {
    width.value = clampSidebar(n, ctx())
    save(width.value)
  }
  function reset() {
    width.value = SIDEBAR_DEFAULT
    save()
  }
  const onResize = () => { viewportW.value = window.innerWidth }

  onMounted(() => {
    onResize()
    const n = Number(storedPanes().docsTree)
    if (Number.isFinite(n)) width.value = n
    window.addEventListener('resize', onResize)
  })
  onUnmounted(() => window.removeEventListener('resize', onResize))

  return { width: shown, bounds, set, reset }
}
