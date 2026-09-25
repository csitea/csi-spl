/** One message menu at a time. A right-click on another row replaces it. */
const openId = ref('')
const point = ref({ x: 0, y: 0 })

export function useMessageMenu(id: () => string) {
  const open = computed(() => openId.value !== '' && openId.value === String(id() || ''))

  function openAt(x: number, y: number) {
    const key = String(id() || '')
    if (!key) return
    openId.value = key
    point.value = { x, y }
  }

  function close() {
    if (openId.value === String(id() || '')) openId.value = ''
  }

  return { open, point, openAt, close }
}
