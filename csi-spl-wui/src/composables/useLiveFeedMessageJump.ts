import type { Ref } from 'vue'
import type { SpoolMessage } from '~/types/spool'
import { scrollRowToTop } from '~/utils/pane-scroll.mjs'
import { JUMP_FOCUS_MS, onMessageJump } from '~/utils/msg-jump.mjs'

/** the LiveFeed props a message jump reads */
interface JumpFeed {
  rows: SpoolMessage[]
  hasOlder: boolean
  loading?: boolean
  loadingOlder?: boolean
  holdScroll?: boolean
}

/* HUM-10 (t1 36ea84a6): a link from one thread to another, on a phone, can
   land while the pane still holds the old topic's rows; when they go, the
   pane shrinks and the browser clamps the scroll, and the row ends above the
   pane. Keep the row at the top for the frames that layout takes to settle,
   until the reader moves the pane themselves. */
const SETTLE_FRAMES = 30
function settleRowTop(scroller: HTMLElement, el: HTMLElement) {
  let left = SETTLE_FRAMES
  const stop = () => { left = 0 }
  const opts = { once: true, passive: true }
  scroller.addEventListener('touchstart', stop, opts)
  scroller.addEventListener('wheel', stop, opts)
  const tick = () => {
    if (left-- <= 0 || !el.isConnected) {
      scroller.removeEventListener('touchstart', stop)
      scroller.removeEventListener('wheel', stop)
      return
    }
    if (Math.abs(el.getBoundingClientRect().top - scroller.getBoundingClientRect().top) > 2) scrollRowToTop(scroller, el)
    requestAnimationFrame(tick)
  }
  requestAnimationFrame(tick)
}
function highlight(el: HTMLElement) {
  el.classList.add('open-focus')
  setTimeout(() => el.classList.remove('open-focus'), JUMP_FOCUS_MS)
}

/**
 * A pasted link to a thread line (#<msg_id>) moves that line to the top of
 * its list once it has loaded, selects it and highlights it. Only a thread
 * feed does this, and only once per hash, so later rows do not pull the
 * reader back. The document itself does not scroll. A row near the end needs
 * room after it (`landTail`) or the pane stops short and leaves the row down
 * the list.
 * Owner priority (t1 48d09034): a link clicked inside the topic that holds
 * it jumps too - also the same link again, or /m/<id> coming back to this
 * address (msg-jump.mjs asks, the hash does not change). A line older than
 * the rows held is read in with Load more, at most JUMP_PAGES pages, so a
 * question 50 messages up opens without scrolling.
 */
export function useLiveFeedMessageJump(o: {
  props: JumpFeed
  root: Ref<HTMLElement | null>
  hold: () => void
  older: () => void
}) {
  const { props, root, hold } = o
  const route = useRoute()
  const landTail = ref(0)
  let hashDone = ''
  const JUMP_PAGES = 10
  const want = ref('')
  /* bumped per request, so the same id asked again runs the watch again */
  const wantSeq = ref(0)
  let wantPages = 0
  const offJump = onMessageJump((id) => {
    if (!props.holdScroll) return
    hashDone = ''
    wantPages = 0
    want.value = id
    wantSeq.value += 1
  })
  onUnmounted(offJump)
  watch(() => route.hash, (hash) => {
    const id = String(hash || '').replace(/^#/, '')
    if (id && id !== want.value) { wantPages = 0; want.value = id }
  }, { immediate: true })
  watch(() => [want.value, wantSeq.value, props.rows.length, props.loadingOlder] as const, async ([id]) => {
    if (!props.holdScroll || !id || id === hashDone) return
    if (!props.rows.some((m) => String(m.msg_id) === id)) {
      /* not held yet: read the next older page; the rows watch comes back here */
      if (props.hasOlder && !props.loadingOlder && !props.loading && wantPages < JUMP_PAGES) {
        wantPages += 1
        o.older()
      }
      return
    }
    for (let i = 0; i < 8; i++) {
      await nextTick()
      const el = root.value?.querySelector<HTMLElement>(`[data-msg-id="${CSS.escape(id)}"]`)
      const scroller = el?.closest<HTMLElement>('.feed-body')
      if (!el || !scroller || scroller.clientHeight <= 0) {
        await new Promise((r) => requestAnimationFrame(r))
        continue
      }
      landTail.value = scroller.clientHeight
      await nextTick()
      /* newest last: the linked row wins over following the bottom (A9).
         Focus first: a focus that still scrolls the pane is then corrected. */
      hold()
      el.focus({ preventScroll: true })
      scrollRowToTop(scroller, el)
      hashDone = id
      highlight(el)
      settleRowTop(scroller, el)
      return
    }
  }, { immediate: true })

  return { landTail }
}
