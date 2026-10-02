import { nextMenuIndex } from '~/utils/user-menu.mjs'
import { applyPopoverAtPoint, focusWithoutScroll } from '~/utils/place-popover.mjs'
import { usePhone } from '~/composables/useTouchUi'

/**
 * The behaviour of a menu opened AT A POINT (a row's right-click or ... button):
 * a popover placed at (x, y) on a desktop, a bottom sheet on a phone (SPL-991)
 * that Back closes first (SPL-994); arrows move, Escape / Tab / a click outside
 * close it; the first item takes focus on a desktop, never on a phone (a finger
 * has no focus ring, and stealing focus drops the on-screen keyboard).
 *
 * MessageMenu, SearchRowMenu and IssueRowMenu each carried this body, copied
 * (CLE-77915, refactor item 9); their templates stay their own.
 *
 * The host may mount the menu lazily, already open: the opening is then the
 * mount itself, not a change of `open`.
 */
export function usePointMenu(opts: {
  open: () => boolean
  x: () => number
  y: () => number
  close: () => void
  /** after close, when the key was Escape (the host returns focus) */
  escape?: () => void
  /** re-place when the point moves while open (the issue sheet's rows) */
  followPoint?: boolean
}) {
  const root = ref<HTMLElement | null>(null)
  const focused = ref(-1)
  const sheet = usePhone()
  useMobileStack().overlay(opts.open, opts.close)

  function itemEls(): HTMLElement[] {
    return [...(root.value?.querySelectorAll<HTMLElement>('[role="menuitem"]') ?? [])]
  }

  async function focusItem(i: number) {
    focused.value = i
    await nextTick()
    focusWithoutScroll(itemEls()[i])
  }

  async function place() {
    await nextTick()
    if (sheet.value) return
    applyPopoverAtPoint(root.value, opts.x(), opts.y())
  }

  function onDocPointer(e: PointerEvent) {
    const target = e.target
    if (!(target instanceof Node) || root.value?.contains(target)) return
    /* the backdrop closes on its click, so the tap reaches nothing under it */
    if (target instanceof Element && target.closest('.touch-sheet-backdrop')) return
    opts.close()
  }

  async function onOpen() {
    document.addEventListener('pointerdown', onDocPointer, true)
    await place()
    if (!opts.open() || sheet.value) return
    await focusItem(0)
  }

  watch(opts.open, (v) => {
    if (v) {
      onOpen()
    } else {
      document.removeEventListener('pointerdown', onDocPointer, true)
      focused.value = -1
    }
  })
  if (opts.followPoint) watch(() => [opts.x(), opts.y()], () => { if (opts.open()) void place() })
  onMounted(() => { if (opts.open()) onOpen() })
  onBeforeUnmount(() => document.removeEventListener('pointerdown', onDocPointer, true))

  function onMenuKey(e: KeyboardEvent) {
    const next = nextMenuIndex(focused.value, e.key, itemEls().length)
    if (next === -1) {
      e.preventDefault()
      opts.close()
      if (e.key === 'Escape') opts.escape?.()
      return
    }
    if (next !== focused.value) {
      e.preventDefault()
      void focusItem(next)
    }
  }

  return { root, sheet, onMenuKey }
}
