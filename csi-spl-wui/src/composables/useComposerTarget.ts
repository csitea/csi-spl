// r13-03: where the composer's next post goes, as the box shows it - the
// mode (glyph, accent, GO words) and the target chip - moved out of
// MessageComposer.vue.
import type { Ref } from 'vue'
import { useOmniboxStore } from '~/stores/omnibox'
import { chipLabel, composerModeLabel, composerSendKey, dockTargetHint } from '~/utils/omnibox-topic.mjs'
import { resolveInClause } from '~/utils/topic-in.mjs'
import type { TopicRow } from '~/composables/useComposerPickers'
import type { ComposerProps } from '~/composables/composerProps'

interface TargetOpts {
  text: Ref<string>
  inputEl: Ref<HTMLTextAreaElement | null>
  docked: Ref<boolean>
  searchMode: Ref<boolean>
  topicCatalogue: Ref<TopicRow[]>
  props: ComposerProps
  t: (key: string, params?: Record<string, unknown>) => string
}

/* HUM-24 (CLE-77879): one mode, one look - the label, its icon, the field's
   accent (data-mode) and the GO button's words all follow dockHint */
function useMode(o: TargetOpts) {
  const { props, searchMode, docked } = o
  /* SPL-1003: where the next post goes, shown above the docked box */
  const dockHint = computed(() => dockTargetHint(props.dockTarget, o.text.value))
  const modeText = computed(() => {
    const label = composerModeLabel(dockHint.value)
    return label ? o.t(label.key, label.params) : ''
  })
  /* owner, t1 3d6d945d "A": the glyph in the box marks a post into the tree.
     A DM, /search and a page with no send target show none.
     HUM-10: a new topic already shows the channel as #name (the phone
     placeholder is "#{name}"; the desktop placeholder and the target chip
     both carry that same hash). A hash glyph in front of it reads "# #name"
     on the desktop and on the phone. Drop the glyph on both; the gap it
     opened goes with it. The tree glyph stays for a reply. */
  const intoTree = computed(() => Boolean(dockHint.value && (dockHint.value.mode === 'thread' || dockHint.value.mode === 'comment')))
  const modeGlyph = computed<'thread-tree' | 'hash' | null>(() => {
    if (!props.global || searchMode.value || !dockHint.value) return null
    if (intoTree.value) return 'thread-tree'
    if (dockHint.value.mode === 'new') return null
    return null
  })
  /* a phone page with no send target (/issues list, /events, /settings): GO
     there searches for the text, never nothing - data-mode="search", no accent */
  const modeAttr = computed(() => {
    if (!props.global || searchMode.value) return undefined
    if (dockHint.value) return dockHint.value.mode
    return docked.value && props.sendBlocked ? 'search' : undefined
  })
  const sendKey = computed(() => composerSendKey(searchMode.value ? null : dockHint.value))
  return { modeText, modeGlyph, modeAttr, sendKey }
}

/* spec Q3: a chip click opens the target - the channel, the DM or the topic
   (an open pane already shows it, so nothing moves) - and the box keeps the focus */
function useOpenChip(at: () => string, inputEl: Ref<HTMLTextAreaElement | null>) {
  const chipRoute = useRoute()
  const chipLocalePath = useLocalePath()
  return function openChip() {
    const open = at()
    const name = encodeURIComponent(open.slice(open.indexOf(':') + 1))
    if (open.startsWith('t:')) {
      const id = open.slice(2)
      if (chipRoute.query.topic !== id && chipRoute.params.task_id !== id) void navigateTo(chipLocalePath('/t/' + name))
    } else if (open === 'ch:lobby') void navigateTo(chipLocalePath('/lobby'))
    else if (open.startsWith('ch:')) void navigateTo(chipLocalePath('/channel/' + name))
    else if (open.startsWith('dm:')) void navigateTo(chipLocalePath('/dm/' + name))
    inputEl.value?.focus()
  }
}

/*
 * 080 FR-006 / FR-007: the target chip. chipLabel reads what send reads - the
 * page's dock() and place() (one replyTarget()) and the `in: <title>` the
 * line resolves to - so it cannot name one place while the send goes to
 * another. Top-bar box only, not in /search. 085 FR-001 / FR-002: no chip
 * on the phone dock (owner msg b2e7c197-ca37-489a-899d-20f4b946d120); the
 * send target there is unchanged, the open thread or channel names it.
 */
export function useComposerTarget(o: TargetOpts) {
  const { props, searchMode, docked, text, topicCatalogue } = o
  const omniboxTargets = useOmniboxStore()
  const chipWords = (c: { key: string, params: Record<string, string>, text: string }) => (c.key ? o.t(c.key, c.params) : c.text)
  const chipInfo = computed(() => {
    if (!props.global || searchMode.value || props.sendBlocked) return null
    if (docked.value) return null
    const place = String(omniboxTargets.target?.place?.() ?? '')
    const resolved = /(^|\s)in:/i.test(text.value) ? resolveInClause(text.value, topicCatalogue.value) : null
    const named = resolved && resolved.taskId ? { taskId: resolved.taskId, title: resolved.title } : null
    const id = place.startsWith('t:') ? place.slice(2) : ''
    const title = id ? (topicCatalogue.value.find((r) => r.taskId === id)?.title ?? '') : ''
    const opts = { dock: props.dockTarget, place, text: text.value, named, title }
    const c = chipLabel(opts)
    return c ? { ...c, full: chipWords(c), short: chipWords(c) } : null
  })
  const chipMode = computed(() => {
    const c = chipInfo.value
    if (!c) return undefined
    if (c.key === 'composer.chip_reply') return 'thread'
    return c.text.startsWith('@') ? 'dm' : 'new'
  })
  return {
    ...useMode(o),
    chip: computed(() => Boolean(chipInfo.value)),
    chipText: computed(() => chipInfo.value?.short ?? ''),
    chipFull: computed(() => chipInfo.value?.full ?? ''),
    chipMode,
    openChip: useOpenChip(() => chipInfo.value?.open || '', o.inputEl),
  }
}
