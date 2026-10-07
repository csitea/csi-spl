<!-- Right-click menu on a message. Same panel as a channel row: icon plus
     the action name, Escape and a click outside close it, arrows move.
     SPL-991: at <= 820 px it is a bottom sheet (long-press or the ⋯ button),
     over a dimmed page a tap on which closes it.
     t1 7a6be5a3: that sheet opens WHOLE - see the style below. -->
<template>
  <UiPointMenu
    :open="open"
    :x="x"
    :y="y"
    :items="items"
    :label="t('feed.msg_menu.label')"
    block="msg-menu"
    testid="msg-menu"
    @choose="choose"
    @close="onClose"
    @escape="emit('escape')"
  />
</template>

<script setup lang="ts">
import { msgMenuItems } from '~/utils/msg-menu.mjs'
import { runAiAction } from '~/utils/msg-ai-run'
import { useAiMenuGroup } from '~/composables/useAiMenuGroup'
import { useChannelStore } from '~/stores/channel'
import { useSpoolApi } from '~/composables/useSpoolApi'
import type { TopicMenuLocks } from '~/utils/topic-menu.mjs'
import { useMsgShortcutsOn } from '~/composables/useMsgShortcuts'
import { shortcutHint } from '~/utils/msg-shortcuts.mjs'

const props = defineProps<{
  open: boolean
  x: number
  y: number
  editable?: boolean
  mergePrev?: boolean
  mergeNext?: boolean
  /** a thread line: offer Open parent section */
  parent?: boolean
  /** HUM-10 (topic c15b557e): the place it names - 'dm' | 'channel' | 'issue' */
  parentKind?: 'dm' | 'channel' | 'issue' | ''
  /** SPL-983: a topic card the viewer may archive / delete (both) */
  topic?: boolean
  /** SPL-983 / CLE-77819: offer Archive (author, addressee, owner or admin) */
  topicArchive?: boolean
  /** SPL-983: offer Delete the topic (author, owner or admin) */
  topicDelete?: boolean
  /** SPL-991: the viewer may re-type this message (the sheet's Kind item) */
  kind?: boolean
  /** SPL-1024: a card the viewer may move to another channel */
  moveChannel?: boolean
  /** SPL-1024: a reply the viewer may move to another topic */
  moveTopic?: boolean
  /** 714c7028: a card the viewer may merge into another topic */
  mergeTopic?: boolean
  /** 8f588edd: a reply the viewer may promote into a new topic of its own */
  promoteTopic?: boolean
  /** HUM-10 (t1 7d9faaad): a topic-view reply a left swipe may hide */
  hide?: boolean
  /** CLE-77891: a topic card's entries the viewer may not use, shown disabled with the reason */
  locks?: Partial<TopicMenuLocks>
  /** t1 b6c742f0: the message, for the AI actions group (a person's message only) */
  aiMsg?: unknown
  /** t1 b6c742f0: told the i18n key when an AI action fails (the menu is closed by then, so no emit) */
  aiFail?: (key: string) => void
}>()

const emit = defineEmits<{
  close: []
  escape: []
  open: []
  parent: []
  edit: []
  copy: []
  'merge-prev': []
  'merge-next': []
  delete: []
  archive: []
  'delete-topic': []
  reply: []
  react: []
  'copy-text': []
  kind: []
  'move-channel': []
  'move-topic': []
  'merge-topic': []
  'promote-topic': []
  'hide-flow': []
}>()

const { t } = useI18n({ useScope: 'global' })
/* HUM-10 ae2e5093: each entry's Shift + letter on its right, while the setting is on */
const keysOn = useMsgShortcutsOn()
/* t1 b6c742f0: the AI actions group closes the list, on a person's message
   only (composables/useAiMenuGroup.ts). The phone sheet opens WHOLE
   (t1 7a6be5a3), Delete last: there the group is one "AI actions" entry
   before Delete that turns the same sheet into the seven actions.
   The item list differs on a phone (msgMenuItems `touch`). */
const ai = useAiMenuGroup(() => props.aiMsg)
const sheet = ai.sheet
function onClose() {
  if (ai.keep()) return
  emit('close')
}
/* the menu runs the pick itself: it outlives the close (the promise keeps it) */
const aiDeps = { api: useSpoolApi(), router: useRouter(), localePath: useLocalePath(), send: useChannelStore().send }
async function runAi(id: string) {
  const key = await runAiAction(id, props.aiMsg, aiDeps)
  if (key) props.aiFail?.(key)
}
const items = computed(() => withKeys(ai.items(topicItems.value)))
const topicItems = computed(() => msgMenuItems({
  touch: sheet.value,
  kind: props.kind,
  editable: props.editable,
  mergePrev: props.mergePrev,
  mergeNext: props.mergeNext,
  parent: props.parent,
  parentKind: props.parentKind,
  topic: props.topic,
  topicArchive: props.topicArchive,
  topicDelete: props.topicDelete,
  moveChannel: props.moveChannel,
  moveTopic: props.moveTopic,
  mergeTopic: props.mergeTopic,
  promoteTopic: props.promoteTopic,
  hide: props.hide,
  locks: props.locks,
}))
function withKeys<T extends { id: string }>(list: T[]): (T & { keyHint?: string })[] {
  return keysOn.value ? list.map((it) => ({ ...it, keyHint: shortcutHint(it.id) || undefined })) : list
}
/* UiPointMenu skips a disabled entry and emits close after this */
function choose(id: string) {
  if (id === 'open') emit('open')
  else if (id === 'parent') emit('parent')
  else if (id === 'edit') emit('edit')
  else if (id === 'copy') emit('copy')
  else if (id === 'merge-prev') emit('merge-prev')
  else if (id === 'merge-next') emit('merge-next')
  else if (id === 'delete') emit('delete')
  else if (id === 'archive') emit('archive')
  else if (id === 'delete-topic') emit('delete-topic')
  else if (id === 'reply') emit('reply')
  else if (id === 'react') emit('react')
  else if (id === 'copy-text') emit('copy-text')
  else if (id === 'kind') emit('kind')
  else if (id === 'move-channel') emit('move-channel')
  else if (id === 'move-topic') emit('move-topic')
  else if (id === 'merge-topic') emit('merge-topic')
  else if (id === 'promote-topic') emit('promote-topic')
  else if (id === 'hide-flow') emit('hide-flow')
  else if (ai.more(id)) { /* the sheet now shows the seven actions */ }
  else if (id.startsWith('ai-')) void runAi(id)
}
</script>

<style>
/* t1 7a6be5a3 (owner: "the menu not appearing whole and one having to slide
   it up"): the shared sheet stops at 70dvh, and a topic card's sheet is 11
   rows, some with a reason line - taller than 70dvh on most phones, so its
   last rows sat under the fold. This sheet may use the whole visual viewport
   above the keyboard bar (the sheet still grows only as tall as its rows);
   on a short screen the rows tighten so it fits without scrolling.
   (0,4,0) beats SheetBackdrop's :root .touch-sheet.touch-sheet (0,3,0). */
:root .msg-menu.touch-sheet.touch-sheet {
  max-height: calc(100dvh - var(--kb-inset, 0px) - 8px);
}
@media (max-height: 700px) {
  :root .msg-menu.touch-sheet.touch-sheet { padding-top: 6px; }
  :root .msg-menu.touch-sheet.touch-sheet::before { margin-bottom: 4px; }
  :root .msg-menu.touch-sheet.touch-sheet [role="menuitem"] { min-height: 40px; padding-block: 4px; }
}
</style>
