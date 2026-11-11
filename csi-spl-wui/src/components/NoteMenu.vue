<!-- Spec 155 2.10 (SPL-5255, owner HUM-10 t1 b7eb7c9a: "Each of the notes
     should have a right-click menu button so that one could archive the
     note, delete it, or turn it into a discussion"): a note's menu, opened by
     a right-click on a list row or the open note, or by its menu button (a
     phone has no right-click). The panel is UiPointMenu, the WUI's one menu
     opened at a point (a bottom sheet at <= 820 px); the items are
     utils/note-menu.mjs noteMenuItems. The parent acts on `choose`
     (composables/useNoteActions.ts). -->
<template>
  <UiPointMenu
    :open="open"
    :x="x"
    :y="y"
    :items="items"
    :label="t('notes.menu.label')"
    block="note-menu"
    testid="note-actions-menu"
    :over-modal="overModal"
    @choose="emit('choose', $event)"
    @close="emit('close')"
  />
</template>

<script setup lang="ts">
import { noteMenuItems } from '~/utils/note-menu.mjs'

const props = defineProps<{
  open: boolean
  x: number
  y: number
  /** the note (a list row or the open note): archived, and whether it has text */
  note: { archived?: boolean, title?: string, body?: string, snippet?: string, items?: unknown[], items_total?: number } | null
  /** opened from the open note's modal: lift above it */
  overModal?: boolean
}>()
const emit = defineEmits<{ close: [], choose: [id: string] }>()
const { t } = useI18n({ useScope: 'global' })
const items = computed(() => noteMenuItems(props.note))
</script>
