// t1 2b15a748 option A. One word that names a visible channel asks
// "Open #name?" and does not send. The matcher is channelNamedIn (the same
// grammar as channelLookupOf). A reply, a comment, an open edit, or a picked
// file still posts. Esc, or any edit of the line, dismisses the choice.
// Enter while it is up opens the channel.
import { reactive, ref, type Ref } from 'vue'
import { channelNamedIn } from '~/utils/search.mjs'

export interface OpenChannelHit {
  name: string
  id: string
  typed: string
}

export function useOpenChannelAsk(opts: {
  text: Ref<string>
  pickedCount: () => number
  channels: () => { channel_id?: string, name?: string }[] | null | undefined
  replyOrComment: () => boolean
  clearAndGo: (id: string) => void
  send: () => void
}) {
  const hit = ref<OpenChannelHit | null>(null)
  let bypass = false

  function note(s: string) {
    if (hit.value && s !== hit.value.typed) hit.value = null
  }

  function writingElsewhere(): boolean {
    if (opts.replyOrComment() || opts.pickedCount() > 0) return true
    return typeof document !== 'undefined' && Boolean(document.querySelector('[data-test="msg-edit-box"]'))
  }

  function askInstead(): boolean {
    if (hit.value || writingElsewhere()) return false
    const found = channelNamedIn(opts.text.value, opts.channels())
    if (!found) return false
    hit.value = { name: found.name, id: found.id, typed: opts.text.value }
    return true
  }

  function dismiss() {
    hit.value = null
  }

  function confirm() {
    const row = hit.value
    if (!row) return
    hit.value = null
    opts.clearAndGo(row.id)
  }

  function post() {
    if (!hit.value) return
    hit.value = null
    bypass = true
    try { opts.send() } finally { bypass = false }
  }

  /** True when this send was the choice (open, or ask) and must not post. */
  function beforeSend(): boolean {
    if (bypass) return false
    if (hit.value) {
      confirm()
      return true
    }
    return askInstead()
  }

  /** True when the key was the choice's. Enter opens. Esc keeps the text. */
  function onKey(ev: KeyboardEvent): boolean {
    if (!hit.value) return false
    if (ev.key === 'Escape') {
      ev.preventDefault()
      dismiss()
      return true
    }
    if (ev.key === 'Enter' && !ev.shiftKey && !ev.altKey) {
      ev.preventDefault()
      confirm()
      return true
    }
    return false
  }

  return reactive({ hit, note, confirm, post, dismiss, beforeSend, onKey })
}
