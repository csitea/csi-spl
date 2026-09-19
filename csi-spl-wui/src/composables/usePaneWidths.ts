import {
  SIDEBAR_DEFAULT,
  THREAD_DEFAULT,
  clampPair,
  clampSidebar,
  clampThread,
  loadPaneWidths,
  savePaneWidths,
  resetPane,
  sidebarRange,
  threadRange,
  sidebarShown,
  threadShown,
} from '~/utils/pane-widths.mjs'

export function usePaneWidths(opts: {
  threadOpen: Ref<boolean>
}) {
  const viewportW = ref(import.meta.client && typeof window !== 'undefined' ? window.innerWidth : 1280)
  const storedSidebar = ref(SIDEBAR_DEFAULT)
  const storedThread = ref(THREAD_DEFAULT)

  const ctx = computed(() => ({
    viewportW: viewportW.value,
    threadOpen: opts.threadOpen.value,
    sidebarW: storedSidebar.value,
    threadW: storedThread.value,
  }))

  const displayed = computed(() => clampPair(
    storedSidebar.value,
    storedThread.value,
    { viewportW: viewportW.value, threadOpen: opts.threadOpen.value },
  ))

  const sidebarBounds = computed(() => sidebarRange({
    ...ctx.value,
    threadW: displayed.value.thread,
  }))
  const threadBounds = computed(() => threadRange({
    ...ctx.value,
    sidebarW: displayed.value.sidebar,
  }))

  const showSidebarDivider = computed(() => sidebarShown(viewportW.value))
  const showThreadDivider = computed(() => threadShown(viewportW.value, opts.threadOpen.value))

  const shellStyle = computed(() => ({
    '--sidebar-w': `${displayed.value.sidebar}px`,
    '--thread-w': `${displayed.value.thread}px`,
  }))

  function persist() {
    savePaneWidths({ sidebar: storedSidebar.value, thread: storedThread.value })
  }

  function setSidebar(n: number) {
    storedSidebar.value = clampSidebar(n, {
      viewportW: viewportW.value,
      threadOpen: opts.threadOpen.value,
      threadW: storedThread.value,
    })
    persist()
  }

  function setThread(n: number) {
    storedThread.value = clampThread(n, {
      viewportW: viewportW.value,
      threadOpen: opts.threadOpen.value,
      sidebarW: storedSidebar.value,
    })
    persist()
  }

  function resetSidebar() {
    storedSidebar.value = resetPane('sidebar')
    persist()
  }

  function resetThread() {
    storedThread.value = resetPane('thread')
    persist()
  }

  function onResize() {
    if (typeof window === 'undefined') return
    viewportW.value = window.innerWidth
  }

  function hydrate() {
    const loaded = loadPaneWidths()
    storedSidebar.value = loaded.sidebar
    storedThread.value = loaded.thread
    onResize()
  }

  onMounted(() => {
    hydrate()
    window.addEventListener('resize', onResize)
  })
  onUnmounted(() => {
    window.removeEventListener('resize', onResize)
    document.documentElement.classList.remove('pane-dragging')
  })

  return {
    displayed,
    sidebarBounds,
    threadBounds,
    showSidebarDivider,
    showThreadDivider,
    shellStyle,
    setSidebar,
    setThread,
    resetSidebar,
    resetThread,
    hydrate,
  }
}
