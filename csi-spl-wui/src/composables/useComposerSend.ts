// r17-05: the composer's send path, moved out of MessageComposer.vue.
//
// Enter, Ctrl+Enter and the Send button all call onSend. Before a post is
// sent the line may be something else, checked in this order: a pane switch
// (`/switch-pane: ...`), an open-channel ask (t1 2b15a748), a search, a
// blocked send (022: no page target), an open `in:` title list, an omnibox
// search. Only what is left is posted: its body, the topic its `in: <title>`
// names and that topic's channel.
import type { Ref } from 'vue'
import { useSidePane } from '~/composables/useSidePane'
import { closeOpenFence } from '~/utils/code-blocks.mjs'
import { sendLimitError } from '~/utils/code-view.mjs'
import { perfSendStart } from '~/utils/perf-mark.mjs'
import { parseOmnibox } from '~/utils/feed.mjs'
import { switchPaneOf } from '~/utils/sidebar-tabs.mjs'
import { channelLookupOf, searchQueryOf } from '~/utils/search.mjs'
import { resolveInClause } from '~/utils/topic-in.mjs'
import type { ComposerProps } from '~/composables/composerProps'
import type { TopicRow } from '~/composables/useComposerPickers'

type SendEmit = {
  (e: 'send', text: string, parentTaskId?: string, files?: File[], channelId?: string): void
  (e: 'search', q: string): void
}

interface SendOpts {
  props: ComposerProps & { parentTaskId?: string, busy?: boolean }
  emit: SendEmit
  text: Ref<string>
  picked: Ref<File[]>
  docked: Readonly<Ref<boolean>>
  searchMode: Readonly<Ref<boolean>>
  opClosed: Ref<boolean>
  inPickerOpen: Readonly<Ref<boolean>>
  inCandidates: Readonly<Ref<TopicRow[]>>
  inIdx: Ref<number>
  pickIn: (row: TopicRow) => void
  pickedIn: Ref<TopicRow | null>
  topicCatalogue: Readonly<Ref<TopicRow[]>>
  mp: { encode: (s: string) => string }
  openAsk: { beforeSend: () => boolean }
  clearBox: () => void
  sizeError: Ref<ReturnType<typeof sendLimitError>>
  inCode: Ref<boolean>
}

/** The line is a search, not a post: it has been run (true). */
function searchInstead({ props, emit, text, picked, searchMode, opClosed }: SendOpts): boolean {
  if (props.global && searchMode.value) {
    // the rest of the line goes to the hub verbatim (search-v1 §0)
    emit('search', searchQueryOf(text.value))
    opClosed.value = true
    return true
  }
  /* t1 2b15a748: a # or / word that is not a visible channel still
     searches. A visible one was asked above. A file picked with it is a post. */
  const lookup = (props.global || props.omnibox) && !picked.value.length ? channelLookupOf(text.value) : null
  if (!lookup) return false
  emit('search', lookup)
  text.value = props.global ? `/search ${lookup}` : ''
  return true
}

/** Not a post: a pane switch, an open-channel ask, a search, a pick; true = handled. */
function handledBeforeSend(o: SendOpts): boolean {
  const { props, emit, text, docked, openAsk, clearBox, inPickerOpen, inCandidates, inIdx, pickIn } = o
  /* `/switch-pane: messages|channels|topics|flow` changes the left pane
     and is never sent. `topic` is the same pane. An unknown name stays in the box. */
  const pane = props.global || props.omnibox ? switchPaneOf(text.value) : null
  if (pane !== null) {
    if (pane) {
      useSidePane().request(pane)
      clearBox()
    }
    return true
  }
  if (openAsk.beforeSend() || searchInstead(o)) return true
  if (props.global && props.sendBlocked) {
    /* (owner: "clicking the GO button does not create a comment"):
       on a phone GO is the only button, so with no send target the text is
       a search rather than a tap that does nothing. Desktop is unchanged. */
    const q = text.value.trim()
    if (docked.value && q) {
      emit('search', q)
      text.value = ''
    }
    return true
  }
  /* Enter and the Send button both land here. An open title list picks;
     it does not send the half-typed `in:`. */
  if (inPickerOpen.value) {
    const row = inCandidates.value[inIdx.value]
    if (row) pickIn(row)
    return true
  }
  if (!props.omnibox || props.global) return false
  const parsed = parseOmnibox(text.value)
  if (!('search' in parsed)) return false
  emit('search', parsed.search || '')
  text.value = ''
  return true
}

/** The post's body and where it goes: an `in: <title>` names the topic. */
function sendTarget({ props, text, mp, topicCatalogue, pickedIn }: SendOpts) {
  /* SPL-1009: the field shows picked people by name; the message stores their tags */
  let body = closeOpenFence(mp.encode(text.value)).trim()
  let topicId = props.parentTaskId
  let channelId: string | undefined
  if ((props.global || props.omnibox) && body) {
    const resolved = resolveInClause(body, topicCatalogue.value)
    if (resolved.taskId) {
      const chosen = pickedIn.value
      const same = Boolean(chosen && resolved.title.toLowerCase() === chosen.title.toLowerCase())
      body = resolved.body
      topicId = same && chosen ? chosen.taskId : resolved.taskId
      channelId = (same && chosen ? chosen.channel : resolved.channel) || undefined
    }
  }
  return { body, topicId, channelId }
}

export function useComposerSend(o: SendOpts) {
  const { props, emit, picked, sizeError, clearBox, pickedIn, inCode } = o
  function onSend() {
    if (handledBeforeSend(o)) return
    const { body, topicId, channelId } = sendTarget(o)
    if ((!body && !picked.value.length) || props.busy) return
    const tooBig = sendLimitError(body)
    if (tooBig) {
      // nothing is sent and nothing is cleared: the author keeps the text and
      // can attach it as a file (005 T023 upload) instead
      sizeError.value = tooBig
      return
    }
    /* spec 066 M3 starts here; LiveFeed ends it when the row is confirmed */
    perfSendStart()
    emit('send', body, topicId, picked.value.slice(), channelId)
    clearBox()
    pickedIn.value = null
    inCode.value = false
  }
  return { onSend }
}
