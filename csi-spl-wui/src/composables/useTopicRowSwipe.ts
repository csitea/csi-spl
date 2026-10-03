// HUM-10 (owner, t1 topic 548c17ae, 2026-10-03): "In the topics listing I
// should be able to archive a whole topic by swiping left from the topics
// view. On mobile of course."
//
// The Topics home (pages/index.vue) row's swipe. The gesture is the cards'
// own (utils/swipe-archive.mjs, MessageCard): a finger sliding a row to the
// LEFT uncovers the archive strip; lifting past the threshold archives the
// whole topic through the row menu's Archive (useTopicRowActions: the same
// endpoint, the hub's can_archive, the same "Archived · Undo" snackbar).
// Short of it, or the hub says no, the row snaps back. Only at phone widths
// (useMobileStack.isMobile) and only for a finger or a pen; a right swipe is
// not the row's, so the shell's Back keeps it.
//
// One finger moves one row at a time, so one machine serves every row: the
// row under the finger is `task`.
import { useMobileStack } from '~/composables/useMobileStack'
import { SWIPE_SETTLE_MS, createSwipe } from '~/utils/swipe-archive.mjs'

/** Where the sliding row is: its travel, armed, and whether it animates. */
function useRowSlide() {
  /** travel towards the start, >= 0 */
  const dx = ref(0)
  const armed = ref(false)
  /** the snap back / the slide out animates; a finger-driven move does not */
  const settle = ref(false)
  let timer: ReturnType<typeof setTimeout> | null = null

  function slide(to: number, animate: boolean) {
    if (timer) clearTimeout(timer)
    timer = null
    settle.value = animate
    dx.value = to
    /* the transform must not outlive the animation: a transformed row is the
       containing block of its fixed row menu */
    if (animate && to === 0) timer = setTimeout(() => { settle.value = false; timer = null }, SWIPE_SETTLE_MS)
  }

  function stop() {
    if (timer) clearTimeout(timer)
  }

  return { dx, armed, settle, slide, stop }
}

type RowSwipeOpts = {
  /** may the viewer archive this row's topic; null = the hub has not said yet */
  allowed: (taskId: string) => boolean | null
  /** ask the hub (useTopicRowActions.resolve); resolves once it answered */
  prepare: (taskId: string) => Promise<void>
  /** archive it; true once archived */
  archive: (taskId: string) => Promise<boolean>
}

export function useTopicRowSwipe(opts: RowSwipeOpts) {
  const stack = useMobileStack()
  /** the row under the finger (or sliding out) */
  const task = ref('')
  const { dx, armed, settle, slide, stop } = useRowSlide()
  let rowEl: HTMLElement | null = null
  let busy = false

  const rtl = () => typeof document !== 'undefined' && document.documentElement.dir === 'rtl'
  const swipe = createSwipe({
    width: () => rowEl?.getBoundingClientRect().width || 0,
    rtl,
    /* unknown yet is offered: the commit waits for the hub's answer */
    canLeft: () => opts.allowed(task.value) !== false,
    onMove: (d, isArmed) => {
      if (isArmed && !armed.value && typeof navigator !== 'undefined' && typeof navigator.vibrate === 'function') navigator.vibrate(10)
      armed.value = isArmed
      slide(d, false)
    },
    onCommit: () => void commit(task.value),
    onCancel: () => {
      armed.value = false
      slide(0, true)
    },
  })

  async function commit(id: string) {
    busy = true
    stack.swipe.claim()
    slide(rowEl?.getBoundingClientRect().width || 0, true)
    let ok = false
    try {
      await opts.prepare(id)
      ok = opts.allowed(id) === true && await opts.archive(id)
    } finally {
      busy = false
      armed.value = false
      /* archived: the row has left the list; refused: it slides back */
      slide(0, !ok)
    }
  }

  function down(ev: PointerEvent, taskId: string) {
    if (!stack.isMobile.value || busy) return
    if (ev.pointerType !== 'touch' && ev.pointerType !== 'pen') return
    task.value = String(taskId)
    rowEl = ev.currentTarget as HTMLElement | null
    /* ask the hub now, so the answer is there (or nearly) by the lift */
    void opts.prepare(task.value)
    swipe.down(ev)
  }

  /** the click a swipe's lift sends is not a tap: it neither opens the topic nor the menu */
  function swallowClick(ev: MouseEvent) {
    if (!swipe.takeClick()) return
    ev.preventDefault()
    ev.stopPropagation()
  }

  onBeforeUnmount(() => {
    swipe.cancel()
    stop()
  })

  return {
    on: stack.isMobile,
    task,
    dx,
    armed,
    settle,
    down,
    move: (ev: PointerEvent) => swipe.move(ev),
    up: () => swipe.up(),
    cancel: () => swipe.cancel(),
    swallowClick,
  }
}
