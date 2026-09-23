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

export function usePaneWidths(opts: {
  topicOpen: Ref<boolean>
}) {
  const viewportW = ref(import.meta.client && typeof window !== 'undefined' ? window.innerWidth : 1280)
  const storedSidebar = ref(SIDEBAR_DEFAULT)
  const storedTopic = ref(TOPIC_DEFAULT)

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

  function onResize() {
    if (typeof window === 'undefined') return
    viewportW.value = window.innerWidth
  }

  function hydrate() {
    const loaded = loadPaneWidths()
    storedSidebar.value = loaded.sidebar
    storedTopic.value = loaded.topic
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
    topicBounds,
    showSidebarDivider,
    showTopicDivider,
    shellStyle,
    setSidebar,
    setTopic,
    resetSidebar,
    resetTopic,
    hydrate,
  }
}
