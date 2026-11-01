<!-- SPL-1226: the issue context menu. A right-click (or long-press on touch)
     opens it AT the pointer, clamped inside the viewport; Escape and a click
     outside close it, arrows move. At <= 820 px it is a bottom sheet over a
     dimmed page (the same shape as MessageMenu). The parent passes the items
     and handles `choose`; this component is generic (rows and the epics
     sidebar both use it).
     Spec 155 B8 (SPL-4578): it adds Add to note itself, right before
     Archive, for the issue the shared menu target names (useIssueMenu), while
     the person's notes are on; picking it opens the note picker here, so the
     parent never sees that id. -->
<template>
  <UiPointMenu
    :open="open"
    :x="x"
    :y="y"
    :items="shown"
    :label="t('issues_menu.label')"
    block="issue-menu"
    testid="issue-menu"
    data-test="issues-ctxmenu"
    wide
    :over-modal="overModal"
    follow-point
    @choose="choose"
    @close="emit('close')"
  />
</template>

<script setup lang="ts">
import type { PointMenuItem } from '~/components/UiPointMenu.vue'
import { useIssueMenu } from '~/composables/useIssueMenu'
import { useAddToNote } from '~/composables/useAddToNote'
import { ADD_TO_NOTE_ID, issueNoteLink, withNoteItem } from '~/utils/add-to-note.mjs'

export type IssueMenuItem = PointMenuItem

const props = defineProps<{
  open: boolean
  x: number
  y: number
  items: IssueMenuItem[]
  /** CLE-77806: lift above the issue modal (the actions menu opened from its
      header). The desktop popover sits at --z-overlay, below --z-modal. */
  overModal?: boolean
}>()
const emit = defineEmits<{
  close: []
  choose: [id: string]
}>()
const { t } = useI18n({ useScope: 'global' })

const { target } = useIssueMenu()
const note = useAddToNote()
const NOTE_ITEM: IssueMenuItem = { id: ADD_TO_NOTE_ID, icon: 'notes', labelKey: 'issues_menu.add_to_note' }
const shown = computed(() => withNoteItem(props.items, Boolean(target.value?.key) && note.offered.value, NOTE_ITEM))
watch(() => props.open, (on) => { if (on) note.probe() }, { immediate: true })

function choose(id: string) {
  if (id !== ADD_TO_NOTE_ID) emit('choose', id)
  else if (target.value) note.open(issueNoteLink(target.value, note.workspace()))
}
</script>
