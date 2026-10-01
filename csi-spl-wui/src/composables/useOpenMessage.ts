// CLE-77882 (Flow + Search rework, lane A): one call that opens any message
// in its original place - its channel or DM with the topic open, scrolled to
// and marked; a thread reply in its thread on the right. The Flow list and
// the Search results call it with their row; /m/<msg_id> calls it with the id.
// The rules live in utils/open-message.mjs, loaded on the first open.
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useLive } from '~/composables/useLive'
import { useSidePane } from '~/composables/useSidePane'
import { useAccessStore } from '~/stores/access'
import { useRosterStore } from '~/stores/roster'
import type { OpenMessageReason, OpenMessageResult } from '~/utils/open-message.mjs'

/** How long a failure notice stays up. */
export const OPEN_NOTICE_MS = 6000

type OpenNotice = { id: number, reason: OpenMessageReason, msgId: string }

/* one notice per tab, shown by the shell's OpenMessageToast */
const openNotice = shallowRef<OpenNotice | null>(null)
let noticeSeq = 0

/** The shell's OpenMessageToast reads and dismisses the notice. */
export function useOpenMessageNotice() {
  return { notice: openNotice, dismiss: () => { openNotice.value = null } }
}

export function useOpenMessage() {
  const api = useSpoolApi()
  const router = useRouter()
  const localePath = useLocalePath()
  const access = useAccessStore()
  const roster = useRosterStore()
  const live = useLive()
  const sidePane = useSidePane()

  /**
   * Open `ref` (a msg_id, or the row the caller holds) where it was posted.
   * keepList (default true): the left panel keeps the list it shows - the
   * route change does not switch the sidebar tab. notify (default true): a
   * failure raises the shell notice.
   */
  async function openMessage(ref: string | Record<string, any>, opts: { keepList?: boolean, notify?: boolean, replace?: boolean } = {}): Promise<OpenMessageResult> {
    const m = await import('~/utils/open-message.mjs')
    const self = String(access.me?.humanId || live.identity.value || roster.me?.id || '')
    const release = opts.keepList === false ? () => {} : sidePane.holdList()
    let out: OpenMessageResult
    try {
      out = await m.openMessage(ref, { self, api, router, localePath, replace: opts.replace })
    } finally {
      await nextTick()
      release()
    }
    if (!out.ok && opts.notify !== false) openNotice.value = { id: ++noticeSeq, reason: out.reason, msgId: out.msgId }
    return out
  }

  /** The deep link of a message, for a Copy link or an <a href>. */
  function messageHref(msgId: string) {
    return localePath('/m/' + encodeURIComponent(String(msgId || '')))
  }

  return { openMessage, messageHref }
}
